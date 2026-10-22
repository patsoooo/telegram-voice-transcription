import Foundation

// Standalone: compile with VoiceSummaryCore.swift and VoiceTranscriptAlignmentCore.swift.
// No XCTest, Telegram, Speech, SwiftUI, network or permissions required.
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    guard condition() else { fatalError("Alignment smoke failed: \(label)") }
}
func align(_ server: [String], _ speech: [String]) -> [VoiceAlignmentToken]? {
    return alignVoiceTranscriptWords(serverWords: server, recognizedWords: speech.enumerated().map {
        VoiceAlignmentToken(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5)
    }, duration: Double(max(1, speech.count)))
}

let originals = [" \tHello,\n", "“WORLD!”", "go", "GO,"]
let result = align(originals, ["hello", "world", "go", "go"])
check(result?.map(\.text) == originals, "preserve server words, including surrounding whitespace")
check(result?.map(\.start) == [0, 1, 2, 3], "preserve repeated-word starts")
check(result?.map(\.end) == [0.5, 1.5, 2.5, 3.5], "preserve measured ends")
check(align(["CAFÉ", "Straße", "Σ", "ПРИВІТ"], ["cafe\u{301}", "STRASSE", "ς", "привіт"]) != nil, "Unicode canonical case folding")
check(align(["DON'T", "don’t", "-12", "1.25"], ["don't", "DON’T", "-12", "1.25"]) != nil, "preserve meaningful characters")
check(align(["(.5)", ",5"], [".5", ",5"]) != nil, "preserve leading decimal separators")
for text in ["", " \n", "...", "a b", "a\tb", "a\u{200B}b"] {
    check(align([text], [text]) == nil, "invalid token \(text)")
}
for (server, speech) in [("don't", "dont"), ("don’t", "dont"), ("can't", "can"), ("don't", "don’t"),
                         ("-1", "1"), ("−1", "1"), ("+1", "1"), ("$1", "1"), ("1%", "1"),
                         ("1.2", "12"), (".5", "5"), (",5", "5"), ("1,000", "1000"), ("#1", "1"), ("café", "cafe"),
                         ("İ", "i"), ("ı", "I"), ("①", "1"), ("１", "1"), ("👍", "yes")] {
    check(align([server], [speech]) == nil, "lexical mismatch \(server)/\(speech)")
}
check(align([], []) == nil, "empty transcript")
check(align(["go", "go", "now"], ["go", "now"]) == nil, "deletion")
check(align(["go", "now"], ["go", "go", "now"]) == nil, "insertion")
check(align(["go", "now", "go"], ["go", "go", "now"]) == nil, "reordered repeated words")
check(align(["can't"], ["can", "not"]) == nil, "unsupported split")

func timed(_ tokens: [VoiceAlignmentToken], _ duration: Double = 3) -> [VoiceAlignmentToken]? {
    return alignVoiceTranscriptWords(serverWords: tokens.map(\.text), recognizedWords: tokens, duration: duration)
}
let first = VoiceAlignmentToken(text: "a", start: 0, end: 1)
check(timed([first, .init(text: "b", start: 0.95, end: 2)]) != nil, "50ms overlap accepted")
check(timed([first, .init(text: "b", start: 0.949, end: 2)]) == nil, "overlap beyond 50ms refused")
check(timed([.init(text: "a", start: 1, end: 1.01), .init(text: "b", start: 0.99, end: 2)]) == nil, "backwards start")
check(timed([.init(text: "a", start: 0, end: 3)]) != nil, "exact duration boundary")
for (start, end) in [(-0.01, 1.0), (1, 0.9), (1, 1), (0, 3.001), (.nan, 1), (0, .nan), (.infinity, 1), (0, .infinity)] {
    check(timed([.init(text: "a", start: start, end: end)]) == nil, "invalid timing \(start), \(end)")
}
for duration in [0.0, -1, .nan, .infinity, -.infinity] {
    check(timed([first], duration) == nil, "invalid duration \(duration)")
}
let maximum = (0..<20_000).map { VoiceAlignmentToken(text: "a", start: Double($0), end: Double($0) + 0.5) }
check(alignVoiceTranscriptWords(serverWords: maximum.map(\.text), recognizedWords: maximum, duration: 20_000) != nil, "20k tokens accepted")
let tooMany = maximum + [.init(text: "a", start: 20_000, end: 20_001)]
check(alignVoiceTranscriptWords(serverWords: tooMany.map(\.text), recognizedWords: tooMany, duration: 20_001) == nil, "over 20k tokens refused")
let atLimit = String(repeating: "a", count: 4_096)
check(align([atLimit], [atLimit]) != nil, "per-token boundary")
let huge = "a" + String(repeating: "\u{301}", count: 100_000)
check(align([huge], [huge]) == nil, "huge combining sequence refused")
let long = Array(repeating: String(repeating: "a", count: 100), count: 5_001)
check(align(long, long) == nil, "aggregate normalization budget")
print("Alignment smoke: \(checks) checks passed")