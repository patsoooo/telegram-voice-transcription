import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

/// Best-effort lexical verification, not arbitrary-speech forced alignment. Server text is kept
/// only when every recognition token agrees. Failure never falls back to estimated timestamps.
/// The existing recognizer's permission and locale policy still applies; no UI default changes.
public final class AlignedVoiceTranscriptProvider: VoiceTranscriptProvider {
    private let server = ServerVoiceTranscriptProvider()
    private let speech: RecognizedVoiceTranscriptProvider

    public init(localeIdentifier: String = Locale.current.identifier) {
        self.speech = RecognizedVoiceTranscriptProvider(localeIdentifier: localeIdentifier)
    }

    public func summary() -> VoiceSummary {
        return VoiceSummary(headline: "", keyPoints: [], tasks: [], questions: [])
    }

    public func summary(context: AccountContext, messageId: EngineMessage.Id, transcript: VoiceTranscript) -> Signal<VoiceSummaryState, NoError> {
        return self.server.summary(context: context, messageId: messageId, transcript: transcript)
    }

    // Filter loading BEFORE the deadline, so repeated loading cannot reset the budget. Empty
    // completion and a provider that never completes both produce exactly one terminal state.
    private func terminal(_ signal: Signal<VoiceTranscriptState, NoError>, deadline: Double) -> Signal<VoiceTranscriptState, NoError> {
        return signal
        |> filter { state in
            switch state {
            case .loading: return false
            case .ready, .unavailable: return true
            }
        }
        |> then(Signal<VoiceTranscriptState, NoError>.single(.unavailable))
        |> take(1)
        |> timeout(deadline, queue: Queue.mainQueue(), alternate: .single(.unavailable))
    }

    private func words(_ transcript: VoiceTranscript) -> [VoiceTranscriptWord]? {
        // Do not flatMap unbounded provider output into another large array.
        guard transcript.segments.count <= 20_000 else { return nil }
        var words: [VoiceTranscriptWord] = []
        for segment in transcript.segments {
            guard segment.words.count <= 20_000 - words.count else { return nil }
            words.append(contentsOf: segment.words)
        }
        return words.isEmpty ? nil : words
    }

    public func transcript(context: AccountContext, messageId: EngineMessage.Id, duration: Double) -> Signal<VoiceTranscriptState, NoError> {
        guard duration.isFinite, duration > 0 else {
            return .single(.loading) |> then(.single(.unavailable))
        }
        let aligned = self.terminal(self.server.transcript(context: context, messageId: messageId, duration: duration), deadline: 90.0)
        |> mapToSignal { state -> Signal<VoiceTranscriptState, NoError> in
            guard case let .ready(serverTranscript) = state,
                  serverTranscript.timingProvenance == .estimated,
                  let serverWords = self.words(serverTranscript) else { return .single(.unavailable) }
            // Recognition is requested only after a usable server result, with its own deadline.
            return self.terminal(self.speech.transcript(context: context, messageId: messageId, duration: duration), deadline: voiceTranscriptSpeechDeadline(duration: duration))
            |> map { state -> VoiceTranscriptState in
                guard case let .ready(recognized) = state,
                      recognized.timingProvenance == .measured,
                      let recognizedWords = self.words(recognized),
                      let tokens = alignVoiceTranscriptWords(
                        serverWords: serverWords.map(\.text),
                        recognizedWords: recognizedWords.map { VoiceAlignmentToken(text: $0.text, start: $0.start, end: $0.end) },
                        duration: duration
                      ) else { return .unavailable }
                let words = tokens.map { VoiceTranscriptWord(text: $0.text, start: $0.start, end: $0.end) }
                return .ready(VoiceTranscript(segments: voiceTranscriptSegments(words: words), timingProvenance: .aligned))
            }
        }
        return .single(.loading) |> then(aligned)
    }
}
