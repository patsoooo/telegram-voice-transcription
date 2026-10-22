import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

/// One recognised word with its position in the voice message, in seconds.
public struct VoiceTranscriptWord: Equatable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A line of the transcript (a sentence or a phrase), shown with one time code.
public struct VoiceTranscriptSegment: Equatable {
    public let words: [VoiceTranscriptWord]

    public init(words: [VoiceTranscriptWord]) {
        self.words = words
    }

    public var start: Double {
        return self.words.first?.start ?? 0.0
    }

    public var end: Double {
        return self.words.last?.end ?? 0.0
    }

    public var text: String {
        return self.words.map(\.text).joined(separator: " ")
    }
}

public enum VoiceTranscriptTimingProvenance: Equatable {
    case measured
    /// Server words matched one-to-one to measured recognizer tokens; not an acoustic accuracy guarantee.
    case aligned
    case estimated
    case demo
}

public struct VoiceTranscript: Equatable {
    public let segments: [VoiceTranscriptSegment]
    public let timingProvenance: VoiceTranscriptTimingProvenance

    public init(segments: [VoiceTranscriptSegment], timingProvenance: VoiceTranscriptTimingProvenance = .estimated) {
        self.segments = segments
        self.timingProvenance = timingProvenance
    }
}

public enum VoiceTranscriptState {
    /// Recognition is running.
    case loading
    case ready(VoiceTranscript)
    /// No permission, an unsupported language, no speech, or the file could not be read.
    case unavailable
}

#if DEBUG
/// Why the last summary request gave nothing. Debug builds show it on the tab, so a screenshot says what went wrong.
var voiceSummaryDebugReason: String?
/// Why the last transcript request gave nothing. Never contains message text or identifiers.
var voiceTranscriptDebugReason: String?
#endif

public enum VoiceSummaryState {
    /// The summary is being generated.
    case loading
    case ready(VoiceSummary)
    /// The server refused (not Premium and out of its free allowance, an error), or the answer could not be read.
    case unavailable
}

/// The source of a transcript and of its summary. Everything the screen shows comes through here.
public protocol VoiceTranscriptProvider: AnyObject {
    func transcript(context: AccountContext, messageId: EngineMessage.Id, duration: Double) -> Signal<VoiceTranscriptState, NoError>
    /// A fixed summary, for the providers that have no real one.
    func summary() -> VoiceSummary
    /// The summary of a voice message whose transcript is ready.
    func summary(context: AccountContext, messageId: EngineMessage.Id, transcript: VoiceTranscript) -> Signal<VoiceSummaryState, NoError>
}

extension VoiceTranscriptProvider {
    public func summary(context: AccountContext, messageId: EngineMessage.Id, transcript: VoiceTranscript) -> Signal<VoiceSummaryState, NoError> {
        return .single(.ready(self.summary()))
    }
}

/// Hard-coded transcript and summary. The summary is still static for every provider.
public final class MockVoiceTranscriptProvider: VoiceTranscriptProvider {
    public init() {
    }

    private static let lines: [(Double, String)] = [
        (0.0, "Harry, it's me."),
        (2.0, "Sorry, Hermione kept shushing me in the common room."),
        (6.0, "So I'm whispering this from the dorm."),
        (10.0, "Neville's asleep and Seamus is snoring like a troll."),
        (15.0, "Anyway."),
        (16.0, "I've been thinking about what Hagrid let slip at tea."),
        (21.0, "And I reckon we've figured it out."),
        (25.0, "Three things, right."),
        (27.0, "First — the three-headed dog is standing on a trapdoor."),
        (32.0, "It's not guarding a corridor."),
        (35.0, "It's guarding whatever's under it."),
        (38.0, "Second — that's the thing Hagrid fetched from Gringotts."),
        (42.0, "The little grubby package, remember?"),
        (45.0, "Third — Snape tried to get past the dog."),
        (48.0, "Vault seven hundred and thirteen.")
    ]

    public func transcript(context: AccountContext, messageId: EngineMessage.Id, duration: Double) -> Signal<VoiceTranscriptState, NoError> {
        return .single(.ready(self.transcript(duration: duration)))
    }

    public func transcript(duration: Double) -> VoiceTranscript {
        let lines = MockVoiceTranscriptProvider.lines
        let nominalEnd = (lines.last?.0 ?? 0.0) + 5.0
        let scale: Double = duration > 0.0 ? duration / nominalEnd : 1.0

        var segments: [VoiceTranscriptSegment] = []
        for i in 0 ..< lines.count {
            let start = lines[i].0 * scale
            let end = (i + 1 < lines.count ? lines[i + 1].0 : nominalEnd) * scale
            let texts = lines[i].1.split(separator: " ").map(String.init)
            let weights = texts.map { Double(max($0.count, 2)) }
            let total = weights.reduce(0.0, +)

            var words: [VoiceTranscriptWord] = []
            var position = start
            for (index, text) in texts.enumerated() {
                let wordEnd = index == texts.count - 1 ? end : position + (end - start) * (weights[index] / total)
                words.append(VoiceTranscriptWord(text: text, start: position, end: wordEnd))
                position = wordEnd
            }
            segments.append(VoiceTranscriptSegment(words: words))
        }
        return VoiceTranscript(segments: segments, timingProvenance: .demo)
    }

    public func summary() -> VoiceSummary {
        return VoiceSummary(
            headline: "Ron thinks the three-headed dog is guarding a trapdoor — and that Snape is trying to get past it.",
            keyPoints: [
                VoiceSummary.KeyPoint(time: 27.0, text: "The three-headed dog is standing on a trapdoor"),
                VoiceSummary.KeyPoint(time: 38.0, text: "Under it is the package Hagrid took from vault 713"),
                VoiceSummary.KeyPoint(time: 45.0, text: "Snape tried to get past the dog, and the troll was a distraction")
            ],
            tasks: [
                VoiceSummary.Task(text: "Meet Ron at the Fat Lady. Tomorrow, before breakfast", isCompleted: false),
                VoiceSummary.Task(text: "Bring the Invisibility Cloak. Before breakfast", isCompleted: true),
                VoiceSummary.Task(text: "Decide whether to bring Hermione in.", isCompleted: false)
            ],
            questions: [
                VoiceSummary.Question(time: 48.0, text: "Do we tell Dumbledore?")
            ]
        )
    }
}

public func formatVoiceTranscriptTime(_ value: Double) -> String {
    let total = max(0, Int(value.rounded(.down)))
    return "\(total / 60):" + String(format: "%02d", total % 60)
}

/// A small deterministic random generator, so one voice message always gets the same text.
private struct VoiceTranscriptRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E3779B97F4A7C15
        var value = self.state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        return range.lowerBound + Int(self.next() % UInt64(range.count))
    }
}

/// A placeholder summary: every part (headline, key points, tasks, questions) is picked at random from small pools, and the
/// key points point at real lines of the transcript so a tap seeks somewhere that exists. The same seed always gives the same
/// summary, so a voice message keeps its summary when it is opened again.
func voiceRandomSummary(seed: UInt64, transcript: VoiceTranscript) -> VoiceSummary {
    var random = VoiceTranscriptRandom(seed: seed ^ 0xA5A5A5A55A5A5A5A)

    func pick(_ pool: [String], _ count: Int) -> [String] {
        var remaining = pool
        var result: [String] = []
        while result.count < count && !remaining.isEmpty {
            result.append(remaining.remove(at: random.int(0...(remaining.count - 1))))
        }
        return result
    }

    let headlines = [
        "A plan for the evening, and a few things to sort out before it.",
        "Quick update on the project, with a couple of decisions still open.",
        "A long story that ends with a request for help on Friday.",
        "Notes from the meeting: who does what, and by when.",
        "A friend is checking in and wants an answer before the weekend.",
        "Three updates, one problem, and a question for you at the end."
    ]
    let keyPointTexts = [
        "The plan changed and the meeting moved to the afternoon",
        "The deadline is Friday, not next week",
        "Someone has to confirm the booking by tomorrow",
        "The new version is ready, but one bug is left",
        "The budget was approved with a small change",
        "The documents are with the team and need a second look",
        "The trip is on if the weather holds",
        "A short call is needed before anything is decided"
    ]
    let taskTexts = [
        "Send the files before the end of the day",
        "Call back and confirm the time",
        "Book the tickets",
        "Check the numbers once more",
        "Reply to the group and ask who is coming",
        "Prepare a short summary for the team",
        "Pick up the package tomorrow morning"
    ]
    let questionTexts = [
        "Can you join on Friday?",
        "Who is going to take care of the booking?",
        "Do we tell the others now or wait?",
        "Is the new date fine for everyone?",
        "Should the files go out today?"
    ]

    // The key points are at the starts of different lines, in the order they are said.
    var starts: [Double] = []
    for segment in transcript.segments where !starts.contains(segment.start) {
        starts.append(segment.start)
    }
    var times: [Double] = []
    var remainingStarts = starts
    while times.count < 3 && !remainingStarts.isEmpty {
        times.append(remainingStarts.remove(at: random.int(0...(remainingStarts.count - 1))))
    }
    times.sort()
    let keyPoints = zip(times, pick(keyPointTexts, times.count)).map { VoiceSummary.KeyPoint(time: $0, text: $1) }

    let tasks = pick(taskTexts, random.int(2...3)).map { VoiceSummary.Task(text: $0, isCompleted: random.int(0...3) == 0) }
    return VoiceSummary(
        headline: pick(headlines, 1)[0],
        keyPoints: keyPoints,
        tasks: tasks,
        questions: pick(questionTexts, random.int(1...2)).map { text in
            // Each question is at the start of a line of the transcript.
            let time = starts.isEmpty ? 0.0 : starts[random.int(0...(starts.count - 1))]
            return VoiceSummary.Question(time: time, text: text)
        },
        isPlaceholder: true
    )
}

/// Fills what a real summary left out, from the transcript itself: without key points, a few real lines at random times (each
/// point is the line's own text); without a headline, the start of the transcript. Tasks and questions are left as they are,
/// the tab simply has no card for a kind that is empty.
func voiceCompletedSummary(_ summary: VoiceSummary, transcript: VoiceTranscript, seed: UInt64) -> VoiceSummary {
    var random = VoiceTranscriptRandom(seed: seed ^ 0x5A5A5A5AA5A5A5A5)
    var keyPoints = summary.keyPoints
    if keyPoints.isEmpty {
        var remaining = transcript.segments.filter { !$0.text.isEmpty }
        var picked: [VoiceTranscriptSegment] = []
        while picked.count < 3 && !remaining.isEmpty {
            picked.append(remaining.remove(at: random.int(0...(remaining.count - 1))))
        }
        picked.sort { $0.start < $1.start }
        keyPoints = picked.map { segment in
            var text = segment.text
            if text.count > 90 {
                text = String(text.prefix(90)).trimmingCharacters(in: .whitespaces) + "…"
            }
            return VoiceSummary.KeyPoint(time: segment.start, text: text)
        }
    }
    var headline = summary.headline
    if headline.isEmpty, let first = transcript.segments.first(where: { !$0.text.isEmpty }) {
        headline = first.text
    }
    return VoiceSummary(headline: headline, keyPoints: keyPoints, tasks: summary.tasks, questions: summary.questions)
}

/// Placeholder text: random words that fill exactly the length of the real voice message, so the timing follows
/// the audio even though the words mean nothing. The same message always produces the same words.
public final class RandomVoiceTranscriptProvider: VoiceTranscriptProvider {
    private let summaryProvider = MockVoiceTranscriptProvider()

    private static let words: [String] = [
        "the", "dragon", "castle", "tomorrow", "library", "secret", "quickly", "remember", "window", "because",
        "midnight", "corridor", "teacher", "potion", "garden", "whisper", "careful", "lantern", "letter", "mountain",
        "forest", "bridge", "answer", "story", "silver", "shadow", "morning", "kitchen", "journey", "gentle",
        "paper", "ocean", "thunder", "friend", "village", "pocket", "river", "candle", "market", "wonder",
        "carry", "listen", "believe", "follow", "forget", "arrive", "borrow", "gather", "notice", "return",
        "and", "then", "maybe", "never", "always", "almost", "inside", "behind", "across", "before"
    ]

    public init() {
    }

    public func summary() -> VoiceSummary {
        return self.summaryProvider.summary()
    }

    public func transcript(context: AccountContext, messageId: EngineMessage.Id, duration: Double) -> Signal<VoiceTranscriptState, NoError> {
        let seed = UInt64(bitPattern: Int64(messageId.id)) &* 0x2545F4914F6CDD1D &+ UInt64(bitPattern: messageId.peerId.toInt64())
        return .single(.ready(self.makeTranscript(seed: seed, duration: duration)))
    }

    private func makeTranscript(seed: UInt64, duration: Double) -> VoiceTranscript {
        var random = VoiceTranscriptRandom(seed: seed)

        // Speech fills the voice message, leaving a short silence at both ends.
        let margin = min(0.3, duration * 0.05)
        let speechStart = margin
        let speechEnd = max(speechStart + 0.5, duration - margin)

        // About two and a half words a second.
        let targetCount = max(3, Int((speechEnd - speechStart) * 2.5))

        var sentences: [[String]] = []
        var count = 0
        while count < targetCount {
            var length = min(targetCount - count, random.int(4 ... 11))
            let remainder = targetCount - count - length
            if remainder > 0 && remainder < 3 {
                length += remainder
            }
            var sentence: [String] = []
            for index in 0 ..< length {
                var word = RandomVoiceTranscriptProvider.words[random.int(0 ... RandomVoiceTranscriptProvider.words.count - 1)]
                if index == 0 {
                    word = word.prefix(1).uppercased() + word.dropFirst()
                }
                sentence.append(word)
            }
            let endings = [".", ".", ".", "?", "!"]
            sentence[sentence.count - 1] += endings[random.int(0 ... endings.count - 1)]
            sentences.append(sentence)
            count += length
        }

        // Time is shared out by word length, with a short pause after every sentence.
        let pauseWeight = 3.0
        var totalWeight = 0.0
        for sentence in sentences {
            for word in sentence {
                totalWeight += Double(max(word.count, 2))
            }
            totalWeight += pauseWeight
        }
        totalWeight -= pauseWeight
        let secondsPerWeight = (speechEnd - speechStart) / max(1.0, totalWeight)

        var segments: [VoiceTranscriptSegment] = []
        var position = speechStart
        for (sentenceIndex, sentence) in sentences.enumerated() {
            var words: [VoiceTranscriptWord] = []
            for text in sentence {
                let end = position + Double(max(text.count, 2)) * secondsPerWeight
                words.append(VoiceTranscriptWord(text: text, start: position, end: end))
                position = end
            }
            segments.append(VoiceTranscriptSegment(words: words))
            if sentenceIndex != sentences.count - 1 {
                position += pauseWeight * secondsPerWeight
            }
        }
        return VoiceTranscript(segments: segments, timingProvenance: .demo)
    }
}
