import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import AccountContext
import NaturalLanguage

/// The words of a transcript that has no times of its own, given times that fill the voice message: shared out by the length
/// of each word, with a short pause after every sentence. The text is real, the timing is an approximation.
func approximateVoiceTranscript(text: String, duration: Double) -> VoiceTranscript {
    let rawWords = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if rawWords.isEmpty {
        return VoiceTranscript(segments: [])
    }
    
    // Speech fills the voice message, leaving a short silence at both ends.
    let margin = min(0.3, duration * 0.05)
    let speechStart = margin
    let speechEnd = max(speechStart + 0.5, duration - margin)
    
    let sentenceEnd: Set<Character> = [".", "!", "?", "…"]
    let pauseWeight = 3.0
    var weights: [Double] = []
    var pauses: [Double] = []
    for (index, word) in rawWords.enumerated() {
        weights.append(Double(max(word.count, 2)))
        let endsSentence = word.last.map { sentenceEnd.contains($0) } ?? false
        pauses.append(endsSentence && index != rawWords.count - 1 ? pauseWeight : 0.0)
    }
    let totalWeight = weights.reduce(0.0, +) + pauses.reduce(0.0, +)
    let secondsPerWeight = (speechEnd - speechStart) / max(1.0, totalWeight)
    
    var words: [VoiceTranscriptWord] = []
    var position = speechStart
    for (index, word) in rawWords.enumerated() {
        let end = position + weights[index] * secondsPerWeight
        words.append(VoiceTranscriptWord(text: word, start: position, end: end))
        position = end + pauses[index] * secondsPerWeight
    }
    return VoiceTranscript(segments: voiceTranscriptSegments(words: words))
}

/// The real transcript: the text Telegram makes of the voice message (the same one the transcribe button of a voice message in
/// the chat shows), cut into lines, with times that are only approximate: the server sends no times for words.
///
/// The text is taken from the message when it is already there. Otherwise it is asked for, and the transcript waits until the
/// whole of it has arrived. This provider only reports "unavailable" when the server refuses (not Premium and out of trials, a
/// voice message that is too long, an error), or when it takes too long.
public final class ServerVoiceTranscriptProvider: VoiceTranscriptProvider {
    public init() {
    }
    
    public func summary() -> VoiceSummary {
        return VoiceSummary(headline: "", keyPoints: [], tasks: [], questions: [])
    }
    
    public func summary(context: AccountContext, messageId: EngineMessage.Id, transcript: VoiceTranscript) -> Signal<VoiceSummaryState, NoError> {
        return self.makeSummary(context: context, messageId: messageId, transcript: transcript)
    }
    
    public func transcript(context: AccountContext, messageId: EngineMessage.Id, duration: Double) -> Signal<VoiceTranscriptState, NoError> {
        return Signal { subscriber in
            #if DEBUG
            voiceTranscriptDebugReason = nil
            #endif
            subscriber.putNext(.loading)
            
            var isFinished = false
            let finish: (VoiceTranscriptState) -> Void = { state in
                if isFinished {
                    return
                }
                isFinished = true
                subscriber.putNext(state)
                subscriber.putCompletion()
            }
            
            let requestDisposable = MetaDisposable()
            let refreshDisposable = MetaDisposable()
            var didRequest = false
            var requestInFlight = false
            let consumeMessage: (EngineMessage?) -> Bool = { message in
                guard !isFinished else { return false }
                guard let message else {
                    #if DEBUG
                    voiceTranscriptDebugReason = "Telegram message lookup returned no message"
                    #endif
                    finish(.unavailable)
                    return false
                }
                let attribute = message._asMessage().attributes.first(where: { $0 is AudioTranscriptionMessageAttribute }) as? AudioTranscriptionMessageAttribute
                switch voiceServerTranscriptDecision(
                    text: attribute?.text, isPending: attribute?.isPending ?? false,
                    hasError: attribute?.error != nil, isTooLong: attribute?.error == .tooLong,
                    didRequest: didRequest, requestInFlight: requestInFlight
                ) {
                case .wait:
                    return false
                case let .ready(text):
                    finish(.ready(approximateVoiceTranscript(text: text, duration: duration)))
                    return false
                case .unavailable:
                    #if DEBUG
                    voiceTranscriptDebugReason = attribute?.error == .tooLong
                        ? "Telegram reports this voice message is too long to transcribe"
                        : "Telegram returned no usable transcript after retry"
                    #endif
                    finish(.unavailable)
                    return false
                case .request:
                    return true
                }
            }
            let messageDisposable = (context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
            |> deliverOnMainQueue).start(next: { message in
                guard consumeMessage(message) else { return }
                if !didRequest {
                    didRequest = true
                    requestInFlight = true
                    requestDisposable.set((context.engine.messages.transcribeAudio(messageId: messageId)
                    |> deliverOnMainQueue).start(next: { result in
                        guard !isFinished else { return }
                        if case let .error(code) = result {
                            #if DEBUG
                            voiceTranscriptDebugReason = "Telegram rejected transcription (RPC: \(code))"
                            #endif
                            finish(.unavailable)
                        } else {
                            #if DEBUG
                            voiceTranscriptDebugReason = "Telegram accepted the request; waiting for its transcript update"
                            #endif
                            // The RPC emits success after committing its attribute. Re-read it:
                            // queued subscription events can still contain the cached empty/error,
                            // and an identical fresh empty result need not emit a changed view.
                            refreshDisposable.set((context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
                            |> deliverOnMainQueue).start(next: { refreshedMessage in
                                guard !isFinished else { return }
                                requestInFlight = false
                                _ = consumeMessage(refreshedMessage)
                            }))
                        }
                    }))
                }
            })
            
            // A voice message that never gets its text must not leave the sheet on the skeleton forever.
            let timer = SwiftSignalKit.Timer(timeout: 90.0, repeat: false, completion: {
                #if DEBUG
                voiceTranscriptDebugReason = "Timed out waiting for Telegram transcript text (90 seconds)"
                #endif
                finish(.unavailable)
            }, queue: Queue.mainQueue())
            timer.start()
            
            return ActionDisposable {
                messageDisposable.dispose()
                requestDisposable.dispose()
                refreshDisposable.dispose()
                timer.invalidate()
            }
        }
    }
}

// MARK: - Summary

/// The language the transcript is in, by its English name ("Ukrainian"), or nil when it cannot be told. A model that is only
/// told "the language of the text" answers in English all the same, so the language is named.
private func voiceSummaryLanguageName(of text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let language = recognizer.dominantLanguage, language != .undetermined else {
        return nil
    }
    return Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue)
}

/// One request to the AI: the text of the answer, or nil. A request the server refused is tried once more after a second, because
/// the same request sometimes goes through. The 30-second budget includes the retry and its delay.
private func voiceSummaryGenerate(context: AccountContext, prompt: String) -> Signal<String?, NoError> {
    func attempt(_ remaining: Int) -> Signal<String?, NoError> {
        return context.engine.messages.composeAIMessage(text: .empty, mode: .generate(prompt: prompt))
        |> take(1)
        |> map { result -> String? in
            let text = voiceSummaryAnswerText(result.text).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        |> `catch` { error -> Signal<String?, NoError> in
            if case .generic = error, remaining > 0 {
                return Signal<Void, NoError>.single(Void())
                |> delay(1.0, queue: Queue.mainQueue())
                |> mapToSignal { _ -> Signal<String?, NoError> in
                    return attempt(remaining - 1)
                }
            }
            return .single(nil)
        }
    }
    return attempt(1)
    // Also treat a request that completes without an answer as a failure.
    |> then(Signal<String?, NoError>.single(nil))
    |> take(1)
    |> timeout(30.0, queue: Queue.mainQueue(), alternate: .single(nil))
}

/// The text of what the AI answered, whatever form it came in (a plain message, or a rich one made of blocks).
private func voiceSummaryAnswerText(_ message: ComposedRichMessage) -> String {
    switch message {
    case let .plain(text, _):
        return text
    case let .rich(instantPage):
        return voiceSummaryBlocksText(instantPage.blocks)
    case .empty:
        return ""
    }
}

private func voiceSummaryBlocksText(_ blocks: [InstantPageBlock]) -> String {
    var lines: [String] = []
    for block in blocks {
        switch block {
        case let .title(text), let .subtitle(text), let .header(text), let .subheader(text), let .paragraph(text), let .footer(text), let .kicker(text):
            lines.append(text.plainText)
        case let .heading(text, _):
            lines.append(text.plainText)
        case let .preformatted(text, _):
            lines.append(text.plainText)
        case let .list(items, _):
            for item in items {
                switch item {
                case let .text(text, _, _):
                    lines.append(text.plainText)
                case let .blocks(blocks, _, _):
                    lines.append(voiceSummaryBlocksText(blocks))
                case .unknown:
                    break
                }
            }
        case let .blockQuote(blocks, _, _):
            lines.append(voiceSummaryBlocksText(blocks))
        default:
            break
        }
    }
    return lines.filter { !$0.isEmpty }.joined(separator: "\n")
}

/// Bounded, memory-only cache. Legacy UserDefaults entries are neither read nor deleted.
/// An exact source identity avoids hash collisions and invalidates summaries when transcript text or timing changes.
private final class VoiceSummaryCache {
    static let shared = VoiceSummaryCache()
    private struct Entry {
        let source: String
        let summary: VoiceSummary
    }

    private let lock = NSLock()
    private var values: [String: Entry] = [:]
    private var recentKeys: [String] = []

    static func key(accountId: PeerId, messageId: EngineMessage.Id) -> String {
        return "\(accountId.toInt64())_\(messageId.peerId.toInt64())_\(messageId.namespace)_\(messageId.id)"
    }

    static func source(for transcript: VoiceTranscript) -> String {
        // Length-prefixed text and exact floating-point bit patterns, not rounded display timestamps.
        return transcript.segments.map { segment in
            let text = segment.text
            return "\(segment.start.bitPattern):\(segment.end.bitPattern):\(text.utf8.count):" + text
        }.joined(separator: "\n")
    }

    func value(for key: String, source: String) -> VoiceSummary? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let entry = self.values[key], entry.source == source else { return nil }
        self.recentKeys.removeAll(where: { $0 == key })
        self.recentKeys.append(key)
        return entry.summary
    }

    func set(_ summary: VoiceSummary, for key: String, source: String) {
        guard !summary.isPlaceholder else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.values[key] = Entry(source: source, summary: summary)
        self.recentKeys.removeAll(where: { $0 == key })
        self.recentKeys.append(key)
        while self.recentKeys.count > 32 {
            self.values.removeValue(forKey: self.recentKeys.removeFirst())
        }
    }
}

extension ServerVoiceTranscriptProvider {
    func makeSummary(context: AccountContext, messageId: EngineMessage.Id, transcript: VoiceTranscript) -> Signal<VoiceSummaryState, NoError> {
        let cacheKey = VoiceSummaryCache.key(accountId: context.account.peerId, messageId: messageId)
        let source = VoiceSummaryCache.source(for: transcript)
        if let cached = VoiceSummaryCache.shared.value(for: cacheKey, source: source) {
            return .single(.ready(cached))
        }
        let segments = transcript.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Reject unusable timing before converting it to integer display timestamps.
        guard !segments.isEmpty, segments.allSatisfy({ $0.start.isFinite && $0.start >= 0 && $0.start < Double(Int.max) }) else {
            return .single(.unavailable)
        }
        let lines = segments.map { segment in
            return "[" + formatVoiceTranscriptTime(segment.start) + "] " + segment.text
        }
        #if DEBUG
        voiceSummaryDebugReason = nil
        #endif
        let languageName = voiceSummaryLanguageName(of: lines.joined(separator: " "))
        let prompts = voiceSummaryPromptChunks(lines: lines, sourceTimes: segments.map { $0.start }, languageName: languageName)
        guard !prompts.isEmpty else {
            // The portable chunker refuses oversize input rather than dropping any of it.
            return .single(.unavailable)
        }
        // Subscribe to the next part only after the current part succeeds. No parallel fanout,
        // rewrite fallback, or partially successful result; each part has its own bounded retry budget.
        func accumulate(_ index: Int, summaries: [VoiceSummary]) -> Signal<VoiceSummaryState, NoError> {
            if index == prompts.count {
                return .single(.ready(voiceSummaryCombined(summaries)))
            }
            return voiceSummaryGenerate(context: context, prompt: prompts[index].text)
            |> mapToSignal { text -> Signal<VoiceSummaryState, NoError> in
                guard let text, let parsed = parseVoiceSummary(text, rejectMalformedItems: true),
                      let validated = voiceSummaryValidated(parsed, allowedTimes: prompts[index].sourceTimes),
                      validated.keyPoints.count == parsed.keyPoints.count,
                      validated.questions.count == parsed.questions.count,
                      validated.tasks.count == parsed.tasks.count else {
                    // A malformed answer or invalid source timestamp invalidates the whole summary.
                    // Do not expose raw model output or server error descriptions, even in DEBUG.
                    return .single(.unavailable)
                }
                return accumulate(index + 1, summaries: summaries + [validated])
            }
        }

        let request = accumulate(0, summaries: [])
        |> deliverOnMainQueue
        |> map { state -> VoiceSummaryState in
            if case let .ready(summary) = state {
                VoiceSummaryCache.shared.set(summary, for: cacheKey, source: source)
            }
            return state
        }

        return Signal<VoiceSummaryState, NoError>.single(.loading)
        |> then(request)
    }
}
