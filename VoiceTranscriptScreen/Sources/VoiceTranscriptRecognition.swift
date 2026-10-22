import Foundation
import Speech
import AVFoundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import LocalAudioTranscription
import ConvertOpusToAAC

/// Shared by direct speech recognition and the strict alignment wrapper.
func voiceTranscriptSpeechDeadline(duration: Double) -> Double {
    return min(900.0, max(90.0, Double(voiceAudioRecognitionChunks(duration: duration).count) * 90.0))
}

/// Turns recognised words into lines: a line ends after sentence punctuation, a pause, or when it gets long.
func voiceTranscriptSegments(words: [VoiceTranscriptWord]) -> [VoiceTranscriptSegment] {
    let maxWordsInLine = 14
    let pause = 0.7
    let sentenceEnd: Set<Character> = [".", "!", "?", "…"]
    
    var segments: [VoiceTranscriptSegment] = []
    var current: [VoiceTranscriptWord] = []
    for (index, word) in words.enumerated() {
        current.append(word)
        
        var endsLine = false
        if let last = word.text.last, sentenceEnd.contains(last) {
            endsLine = true
        }
        if current.count >= maxWordsInLine {
            endsLine = true
        }
        if index + 1 < words.count, words[index + 1].start - word.end > pause {
            endsLine = true
        }
        if endsLine {
            segments.append(VoiceTranscriptSegment(words: current))
            current = []
        }
    }
    if !current.isEmpty {
        segments.append(VoiceTranscriptSegment(words: current))
    }
    return segments
}

/// Reject an entire result with malformed timing rather than inventing or clamping times.
private func validatedVoiceTranscriptWords(_ words: [VoiceTranscriptWord], duration: Double) -> [VoiceTranscriptWord]? {
    guard duration.isFinite, duration > 0.0 else {
        return nil
    }
    var validated: [VoiceTranscriptWord] = []
    var previousStart = 0.0
    for word in words {
        let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            continue
        }
        guard word.start.isFinite, word.end.isFinite,
              word.start >= 0.0, word.end >= word.start,
              word.start >= previousStart, word.end <= duration + 0.5 else {
            return nil
        }
        validated.append(VoiceTranscriptWord(text: text, start: word.start, end: word.end))
        previousStart = word.start
    }
    return validated.isEmpty ? nil : validated
}

/// Exports and recognizes one bounded audio window. The temporary m4a remains alive
/// until recognition completes and is removed on success, failure or cancellation.
private func transcribeAudioChunk(path: String, locales: [String], chunk: VoiceAudioRecognitionChunk) -> Signal<[LocallyTimedWord]?, NoError> {
    return Signal { subscriber in
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voice-recognition-\(UUID().uuidString).m4a")
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            subscriber.putNext(nil)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: chunk.audioStart, preferredTimescale: 600),
            duration: CMTime(seconds: chunk.audioEnd - chunk.audioStart, preferredTimescale: 600)
        )

        let lock = NSLock()
        var isDisposed = false
        var isFinished = false
        let recognitionDisposable = MetaDisposable()
        let removeOutput = {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let finish: ([LocallyTimedWord]?) -> Void = { words in
            lock.lock()
            let shouldFinish = !isDisposed && !isFinished
            if shouldFinish {
                isFinished = true
            }
            lock.unlock()
            guard shouldFinish else { return }
            removeOutput()
            subscriber.putNext(words)
            subscriber.putCompletion()
        }

        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                lock.lock()
                let disposed = isDisposed
                lock.unlock()
                guard !disposed else {
                    removeOutput()
                    return
                }
                guard exportSession.status == .completed else {
                    finish(nil)
                    return
                }

                let disposable = transcribeAudioWithTimings(path: outputURL.path, locales: locales).start(next: { words in
                    guard let words else {
                        finish(nil)
                        return
                    }
                    // Validate EVERY relative time, including context and blank tokens,
                    // before ownership filtering can hide a malformed result.
                    var previousStart = 0.0
                    for word in words {
                        guard word.start.isFinite, word.end.isFinite,
                              word.start >= previousStart, word.end >= word.start,
                              word.end <= chunk.audioEnd - chunk.audioStart + 0.5 else {
                            finish(nil)
                            return
                        }
                        previousStart = word.start
                    }
                    let absoluteWords = words.map { word in
                        LocallyTimedWord(text: word.text, start: chunk.audioStart + word.start, end: chunk.audioStart + word.end)
                    }
                    finish(absoluteWords)
                }, completed: {
                    // Some Speech implementations complete without emitting a result.
                    finish(nil)
                })
                recognitionDisposable.set(disposable)
            }
        }

        return ActionDisposable {
            lock.lock()
            isDisposed = true
            lock.unlock()
            exportSession.cancelExport()
            recognitionDisposable.dispose()
            removeOutput()
        }
    }
}

/// Recognizes windows sequentially so long voice messages stay below Speech's per-request
/// duration limit. Any failed window fails the whole result rather than silently omitting words.
private func transcribeAudioInChunks(path: String, locales: [String], chunks: [VoiceAudioRecognitionChunk], index: Int = 0, accumulated: [LocallyTimedWord] = [], previousContext: [LocallyTimedWord] = []) -> Signal<[LocallyTimedWord]?, NoError> {
    guard index < chunks.count else {
        return .single(accumulated.isEmpty ? nil : accumulated)
    }
    return transcribeAudioChunk(path: path, locales: locales, chunk: chunks[index])
    |> mapToSignal { words -> Signal<[LocallyTimedWord]?, NoError> in
        guard let words else {
            return .single(nil)
        }
        let chunk = chunks[index]
        if index > 0 {
            guard voiceRecognitionOverlapAgrees(
                left: previousContext.map { ($0.text, $0.start, $0.end) },
                right: words.map { ($0.text, $0.start, $0.end) },
                overlapStart: chunk.audioStart, overlapEnd: chunks[index - 1].audioEnd,
                ownershipBoundary: chunk.ownedStart
            ) else { return .single(nil) }
        }
        let ownedWords = words.filter { word in
            let midpoint = (word.start + word.end) * 0.5
            return midpoint >= chunk.ownedStart && (midpoint < chunk.ownedEnd || (index == chunks.count - 1 && midpoint <= chunk.ownedEnd))
        }
        return transcribeAudioInChunks(path: path, locales: locales, chunks: chunks, index: index + 1, accumulated: accumulated + ownedWords, previousContext: words)
    }
}

/// The converter's cancellation is not a writer-completion barrier. On cancellation
/// let conversion drain, retaining its TempBox handle until the writer has closed;
/// deleting earlier can race a late allocation/write. Recognition is cancelled promptly.
private func transcribeConvertedAudio(path: String, locales: [String], chunks: [VoiceAudioRecognitionChunk]) -> Signal<[LocallyTimedWord]?, NoError> {
    return Signal { subscriber in
        let file = EngineTempBox.shared.tempFile(fileName: "audio.m4a")
        let conversion = MetaDisposable()
        let recognition = MetaDisposable()
        // All ownership state below is confined to the main queue.
        var conversionFinished = false
        var conversionDelivered = false
        var disposed = false
        var finished = false
        var fileDisposed = false
        let cleanup: () -> Void = {
            if conversionFinished && !fileDisposed {
                fileDisposed = true
                EngineTempBox.shared.dispose(file)
            }
        }
        let finish: ([LocallyTimedWord]?) -> Void = { words in
            guard !disposed, !finished else { return }
            finished = true
            recognition.dispose()
            cleanup()
            subscriber.putNext(words)
            subscriber.putCompletion()
        }
        conversion.set(convertOpusToAAC(sourcePath: path, allocateTempFile: { file.path }).start(next: { convertedPath in
            Queue.mainQueue().async {
                conversionFinished = true
                conversionDelivered = true
                guard !disposed, !finished else {
                    cleanup()
                    return
                }
                guard let convertedPath, SFSpeechRecognizer.authorizationStatus() == .authorized else {
                    finish(nil)
                    return
                }
                recognition.set(transcribeAudioInChunks(path: convertedPath, locales: locales, chunks: chunks).start(next: { words in
                    finish(words)
                }, completed: {
                    finish(nil)
                }))
            }
        }, completed: {
            Queue.mainQueue().async {
                conversionFinished = true
                conversion.dispose()
                if disposed || finished {
                    cleanup()
                } else if !conversionDelivered {
                    finish(nil)
                }
            }
        }))
        return ActionDisposable {
            Queue.mainQueue().async {
                disposed = true
                recognition.dispose()
                cleanup()
            }
        }
    }
    |> runOn(.mainQueue())
}

/// Sensitive recognised words stay in a bounded, account- and locale-scoped memory cache only.
private enum VoiceTranscriptCache {
    struct Key: Hashable {
        let accountId: Int64
        let fileId: String
        let localeIdentifier: String
    }

    private static let lock = NSLock()
    private static var entries: [Key: [VoiceTranscriptWord]] = [:]
    private static var accessOrder: [Key] = []

    static func load(key: Key) -> [VoiceTranscriptWord]? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let words = self.entries[key] else {
            return nil
        }
        self.accessOrder.removeAll { $0 == key }
        self.accessOrder.append(key)
        return words
    }

    static func store(key: Key, words: [VoiceTranscriptWord]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries[key] = words
        self.accessOrder.removeAll { $0 == key }
        self.accessOrder.append(key)
        while self.accessOrder.count > 32 {
            self.entries.removeValue(forKey: self.accessOrder.removeFirst())
        }
    }
}

/// Uses the existing speech recognition API with measured word times and an explicitly chosen locale.
/// Requests speech permission after explicit provider selection; the upstream API controls where recognition runs.
public final class RecognizedVoiceTranscriptProvider: VoiceTranscriptProvider {
    private let summaryProvider = ServerVoiceTranscriptProvider()
    private let localeIdentifier: String
    
    public init(localeIdentifier: String = Locale.current.identifier) {
        self.localeIdentifier = localeIdentifier
    }
    
    public func summary() -> VoiceSummary {
        return VoiceSummary(headline: "", keyPoints: [], tasks: [], questions: [])
    }

    public func summary(context: AccountContext, messageId: EngineMessage.Id, transcript: VoiceTranscript) -> Signal<VoiceSummaryState, NoError> {
        return self.summaryProvider.summary(context: context, messageId: messageId, transcript: transcript)
    }
    
    public func transcript(context: AccountContext, messageId: EngineMessage.Id, duration: Double) -> Signal<VoiceTranscriptState, NoError> {
        // Selecting this provider is explicit consent to request speech access. Do not silently
        // reject a fresh install before the system has had a chance to ask the user.
        let authorization = Signal<Bool, NoError> { subscriber in
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { status in
                    subscriber.putNext(status == .authorized)
                    subscriber.putCompletion()
                }
            } else {
                subscriber.putNext(SFSpeechRecognizer.authorizationStatus() == .authorized)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
        return authorization
        |> deliverOnMainQueue
        |> mapToSignal { authorized -> Signal<VoiceTranscriptState, NoError> in
            guard authorized else { return .single(.unavailable) }
            return self.authorizedTranscript(context: context, messageId: messageId, duration: duration)
        }
    }

    private func authorizedTranscript(context: AccountContext, messageId: EngineMessage.Id, duration: Double) -> Signal<VoiceTranscriptState, NoError> {
        guard duration.isFinite, duration > 0.0,
              !self.localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return .single(.unavailable)
        }
        let localeIdentifier = self.localeIdentifier
        let recognition = context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
        |> take(1)
        |> mapToSignal { message -> Signal<VoiceTranscriptState, NoError> in
            guard let message, let file = message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile else {
                return .single(.unavailable)
            }
            let key = VoiceTranscriptCache.Key(
                accountId: context.account.peerId.toInt64(),
                fileId: "\(file.fileId.namespace)_\(file.fileId.id)",
                localeIdentifier: localeIdentifier
            )
            if let cached = VoiceTranscriptCache.load(key: key),
               let words = validatedVoiceTranscriptWords(cached, duration: duration) {
                return .single(.ready(VoiceTranscript(segments: voiceTranscriptSegments(words: words), timingProvenance: .measured)))
            }
            
            return context.engine.resources.data(id: EngineMediaResource.Id(file.resource.id))
            |> filter { data -> Bool in
                return data.isComplete
            }
            |> take(1)
            |> map { data -> String? in
                return data.path
            }
            |> mapToSignal { path -> Signal<[LocallyTimedWord]?, NoError> in
                guard let path, SFSpeechRecognizer.authorizationStatus() == .authorized else {
                    return .single(nil)
                }
                let chunks = voiceAudioRecognitionChunks(duration: duration)
                guard !chunks.isEmpty else {
                    return .single(nil)
                }
                return transcribeConvertedAudio(path: path, locales: [localeIdentifier], chunks: chunks)
            }
            |> map { timedWords -> VoiceTranscriptState in
                guard let timedWords else {
                    return .unavailable
                }
                let rawWords = timedWords.map { word in
                    return VoiceTranscriptWord(text: word.text, start: word.start, end: word.end)
                }
                guard let words = validatedVoiceTranscriptWords(rawWords, duration: duration) else {
                    return .unavailable
                }
                VoiceTranscriptCache.store(key: key, words: words)
                return .ready(VoiceTranscript(segments: voiceTranscriptSegments(words: words), timingProvenance: .measured))
            }
        }
        // One deadline covers message lookup, download, conversion, and recognition, not just the download.
        |> then(Signal<VoiceTranscriptState, NoError>.single(.unavailable))
        |> take(1)
        |> timeout(voiceTranscriptSpeechDeadline(duration: duration), queue: Queue.mainQueue(), alternate: .single(.unavailable))
        
        return Signal<VoiceTranscriptState, NoError>.single(.loading)
        |> then(recognition)
    }
}
