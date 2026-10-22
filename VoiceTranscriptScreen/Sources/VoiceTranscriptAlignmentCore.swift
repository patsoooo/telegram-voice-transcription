import Foundation

public struct VoiceAlignmentToken: Equatable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

// Bound both token count and normalization work, including pathological combining sequences.
private let voiceAlignmentMaximumTokens = 20_000
private let voiceAlignmentMaximumTokenScalars = 4_096
private let voiceAlignmentMaximumTotalScalars = 1_000_000

private func voiceAlignmentNormalized(_ text: String, budget: inout Int) -> String? {
    var count = 0
    for _ in text.unicodeScalars {
        count += 1
        budget -= 1
        guard count <= voiceAlignmentMaximumTokenScalars, budget >= 0 else { return nil }
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.unicodeScalars.contains(where: {
              CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
          }) else { return nil }

    // Only boundary punctuation is cosmetic. Preserve internal apostrophes, decimal separators,
    // and all symbols. Keep potentially semantic boundary punctuation too (notably minus signs,
    // apostrophes, percentages and identifiers): refusing is safer than changing a number/word.
    let meaningful = CharacterSet(charactersIn: "-'’ʼ＇‐‑‒–—﹘﹣－#@%‰‱/\\&*_٫٬")
    let cosmetic = CharacterSet.punctuationCharacters.subtracting(meaningful)
    let scalars = trimmed.unicodeScalars
    var lower = scalars.startIndex
    var upper = scalars.endIndex
    while lower < upper, cosmetic.contains(scalars[lower]) {
        let next = scalars.index(after: lower)
        // Leading decimal separators carry numeric meaning: .5 must never match 5.
        if (scalars[lower] == "." || scalars[lower] == ","), next < upper,
           CharacterSet.decimalDigits.contains(scalars[next]) {
            break
        }
        lower = next
    }
    while upper > lower {
        let previous = scalars.index(before: upper)
        guard cosmetic.contains(scalars[previous]) else { break }
        upper = previous
    }
    let lexical = String(scalars[lower..<upper])
    guard !lexical.isEmpty else { return nil }
    // Canonical normalization, not compatibility/diacritic folding. A fixed locale makes Unicode
    // case folding independent of device language (e.g. Turkish casing must not change results).
    return lexical.precomposedStringWithCanonicalMapping
        .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .precomposedStringWithCanonicalMapping
}

/// Transfers recognition timestamps only after complete, positional lexical agreement.
/// This is NOT forced alignment or a guarantee that recognition timestamps are acoustically exact.
/// Unsupported tokenization, insertions/deletions, malformed timing or oversize input return nil;
/// no words are skipped, merged, reordered, estimated, or partially returned.
public func alignVoiceTranscriptWords(
    serverWords: [String], recognizedWords: [VoiceAlignmentToken], duration: Double
) -> [VoiceAlignmentToken]? {
    guard duration.isFinite, duration > 0,
          !serverWords.isEmpty, serverWords.count <= voiceAlignmentMaximumTokens,
          serverWords.count == recognizedWords.count else { return nil }
    var budget = voiceAlignmentMaximumTotalScalars
    var result: [VoiceAlignmentToken] = []
    result.reserveCapacity(serverWords.count)
    var previous: VoiceAlignmentToken?
    for (serverWord, recognized) in zip(serverWords, recognizedWords) {
        guard recognized.start.isFinite, recognized.end.isFinite,
              recognized.start >= 0, recognized.end > recognized.start,
              recognized.end <= duration else { return nil }
        if let previous {
            guard recognized.start >= previous.start,
                  previous.end <= recognized.start + 0.05 else { return nil }
        }
        guard let server = voiceAlignmentNormalized(serverWord, budget: &budget),
              let speech = voiceAlignmentNormalized(recognized.text, budget: &budget),
              server == speech else { return nil }
        result.append(VoiceAlignmentToken(text: serverWord, start: recognized.start, end: recognized.end))
        previous = recognized
    }
    return result
}
