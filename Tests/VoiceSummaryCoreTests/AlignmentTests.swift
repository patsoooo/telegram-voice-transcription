import Foundation
import XCTest
@testable import VoiceSummaryCore

final class AlignmentTests: XCTestCase {
    private func align(_ server: [String], _ speech: [String]) -> [VoiceAlignmentToken]? {
        return alignVoiceTranscriptWords(serverWords: server, recognizedWords: speech.enumerated().map {
            VoiceAlignmentToken(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5)
        }, duration: Double(max(1, speech.count)))
    }

    func testBoundaryPunctuationWhitespaceAndOriginalText() {
        let words = [" \tHello,\n", "“WORLD!”"]
        let result = self.align(words, ["hello", "world"])
        XCTAssertEqual(result?.map(\.text), words)
        XCTAssertEqual(result?.map(\.start), [0, 1])
        XCTAssertEqual(result?.map(\.end), [0.5, 1.5])
        for invalid in ["", " \n", "...", "a b", "a\tb", "a\u{200B}b"] {
            XCTAssertNil(self.align([invalid], [invalid]), invalid)
        }
    }

    func testCanonicalUnicodeCaseFoldingWithoutAccentOrCompatibilityFolding() {
        XCTAssertNotNil(self.align(["CAFÉ", "Straße", "Σ", "ПРИВІТ"], ["cafe\u{301}", "STRASSE", "ς", "привіт"]))
        for pair in [("café", "cafe"), ("İ", "i"), ("ı", "I"), ("①", "1"), ("１", "1")] {
            XCTAssertNil(self.align([pair.0], [pair.1]))
        }
    }

    func testNoInsertionDeletionReorderingOrRepeatedWordSearch() {
        XCTAssertNotNil(self.align(["go", "GO,", "now"], ["go", "go", "now"]))
        XCTAssertNil(self.align(["go", "go", "now"], ["go", "now"]))
        XCTAssertNil(self.align(["go", "now"], ["go", "go", "now"]))
        XCTAssertNil(self.align(["go", "now", "go"], ["go", "go", "now"]))
        XCTAssertNil(self.align(["can't"], ["can", "not"]))
    }

    func testNegationNumbersAndSymbolsAreNotErased() {
        XCTAssertNotNil(self.align(["DON'T", "don’t", "-12", "1.25"], ["don't", "DON’T", "-12", "1.25"]))
        XCTAssertNotNil(self.align(["(.5)", ",5"], [".5", ",5"]))
        for pair in [("don't", "dont"), ("don’t", "dont"), ("don't", "do"), ("can't", "can"),
                     ("don't", "don’t"), ("-1", "1"), ("−1", "1"), ("+1", "1"), ("$1", "1"),
                     ("1%", "1"), ("1.2", "12"), (".5", "5"), (",5", "5"),
                     ("1,000", "1000"), ("#1", "1"), ("👍", "yes")] {
            XCTAssertNil(self.align([pair.0], [pair.1]), "\(pair)")
        }
    }

    func testStrictTimingAndOverlapTolerance() {
        func timed(_ tokens: [VoiceAlignmentToken], _ duration: Double = 3) -> [VoiceAlignmentToken]? {
            return alignVoiceTranscriptWords(serverWords: tokens.map(\.text), recognizedWords: tokens, duration: duration)
        }
        let first = VoiceAlignmentToken(text: "a", start: 0, end: 1)
        XCTAssertNotNil(timed([first, .init(text: "b", start: 0.95, end: 2)]))
        XCTAssertNil(timed([first, .init(text: "b", start: 0.949, end: 2)]))
        XCTAssertNil(timed([.init(text: "a", start: 1, end: 1.01), .init(text: "b", start: 0.99, end: 2)]))
        XCTAssertNotNil(timed([.init(text: "a", start: 0, end: 3)]))
        for (start, end) in [(-0.01, 1.0), (1, 0.9), (1, 1), (0, 3.001), (.nan, 1), (0, .nan), (.infinity, 1), (0, .infinity)] {
            XCTAssertNil(timed([.init(text: "a", start: start, end: end)]))
        }
        for duration in [0.0, -1, .nan, .infinity, -.infinity] {
            XCTAssertNil(timed([first], duration))
        }
    }

    func testEmptyAndResourceBounds() {
        XCTAssertNil(self.align([], []))
        let maximum = (0..<20_000).map { VoiceAlignmentToken(text: "a", start: Double($0), end: Double($0) + 0.5) }
        XCTAssertNotNil(alignVoiceTranscriptWords(serverWords: maximum.map(\.text), recognizedWords: maximum, duration: 20_000))
        let tooMany = maximum + [.init(text: "a", start: 20_000, end: 20_001)]
        XCTAssertNil(alignVoiceTranscriptWords(serverWords: tooMany.map(\.text), recognizedWords: tooMany, duration: 20_001))
        XCTAssertNotNil(self.align([String(repeating: "a", count: 4_096)], [String(repeating: "a", count: 4_096)]))
        let huge = "a" + String(repeating: "\u{301}", count: 100_000)
        XCTAssertNil(self.align([huge], [huge]))
        let long = Array(repeating: String(repeating: "a", count: 100), count: 5_001)
        XCTAssertNil(self.align(long, long))
    }
}