import Foundation
import XCTest
@testable import VoiceSummaryCore

final class VoiceSummaryCoreTests: XCTestCase {
    func testTextExportFailsClosedForEveryProtectionReason() {
        XCTAssertTrue(voiceTranscriptAllowsTextExport(messageExists: true, messageProtected: false, peerProtected: false, myProtected: false, isSecret: false, isViewOnce: false))
        for index in 0..<6 {
            var flags = [true, false, false, false, false, false]
            flags[index].toggle()
            XCTAssertFalse(voiceTranscriptAllowsTextExport(messageExists: flags[0], messageProtected: flags[1], peerProtected: flags[2], myProtected: flags[3], isSecret: flags[4], isViewOnce: flags[5]))
        }
    }

    func testRecognitionOverlapRejectsMissingDifferentAndBoundaryShiftedWords() {
        let left: [(text: String, start: Double, end: Double)] = [("word", 41.0, 41.5)]
        XCTAssertTrue(voiceRecognitionOverlapAgrees(left: left, right: left, overlapStart: 40.5, overlapEnd: 43.5, ownershipBoundary: 42))
        XCTAssertFalse(voiceRecognitionOverlapAgrees(left: left, right: [], overlapStart: 40.5, overlapEnd: 43.5, ownershipBoundary: 42))
        XCTAssertFalse(voiceRecognitionOverlapAgrees(left: left, right: [("other", 41, 41.5)], overlapStart: 40.5, overlapEnd: 43.5, ownershipBoundary: 42))
        XCTAssertFalse(voiceRecognitionOverlapAgrees(left: [("word", 41.8, 42)], right: [("word", 42, 42.2)], overlapStart: 40.5, overlapEnd: 43.5, ownershipBoundary: 42))
        XCTAssertTrue(voiceRecognitionOverlapAgrees(left: [], right: [], overlapStart: 40.5, overlapEnd: 43.5, ownershipBoundary: 42))
    }

    func testServerRetryIgnoresCachedEmptyAndErrorUntilFreshRead() {
        for hasError in [false, true] {
            XCTAssertEqual(voiceServerTranscriptDecision(text: " \n", isPending: false, hasError: hasError, isTooLong: false, didRequest: false, requestInFlight: false), .request)
            // Unrelated message updates can replay the cached attribute many times.
            for _ in 0..<3 {
                XCTAssertEqual(voiceServerTranscriptDecision(text: "", isPending: false, hasError: hasError, isTooLong: false, didRequest: true, requestInFlight: true), .wait)
            }
            // Only the committed post-RPC read can classify an identical fresh empty/error.
            XCTAssertEqual(voiceServerTranscriptDecision(text: "", isPending: false, hasError: hasError, isTooLong: false, didRequest: true, requestInFlight: false), .unavailable)
        }
        XCTAssertEqual(voiceServerTranscriptDecision(text: "New words", isPending: false, hasError: false, isTooLong: false, didRequest: true, requestInFlight: true), .wait)
        XCTAssertEqual(voiceServerTranscriptDecision(text: "New words", isPending: false, hasError: false, isTooLong: false, didRequest: true, requestInFlight: false), .ready("New words"))
    }

    func testServerRetryWaitsForPendingAndKeepsCachedReadyAndTooLongPolicy() {
        XCTAssertEqual(voiceServerTranscriptDecision(text: nil, isPending: false, hasError: false, isTooLong: false, didRequest: false, requestInFlight: false), .request)
        for didRequest in [false, true] {
            XCTAssertEqual(voiceServerTranscriptDecision(text: "Partial", isPending: true, hasError: false, isTooLong: false, didRequest: didRequest, requestInFlight: false), .wait)
        }
        XCTAssertEqual(voiceServerTranscriptDecision(text: " Cached words \n", isPending: false, hasError: false, isTooLong: false, didRequest: false, requestInFlight: false), .ready("Cached words"))
        XCTAssertEqual(voiceServerTranscriptDecision(text: "", isPending: false, hasError: true, isTooLong: true, didRequest: false, requestInFlight: false), .unavailable)
    }

    func testStrictParserRejectsEveryEmptyLabelWithoutChangingLenientAPI() {
        for label in ["SUMMARY", "KEY", "TASK", "QUESTION"] {
            for empty in ["", "  ", "\n\t"] {
                let trailing = "SUMMARY: Valid \(label):\(empty)"
                XCTAssertNil(parseVoiceSummary(trailing, rejectMalformedItems: true), trailing)
                XCTAssertNotNil(parseVoiceSummary(trailing), trailing)
                let leading = "\(label):\(empty)\nKEY: 0:12 | Valid"
                XCTAssertNil(parseVoiceSummary(leading, rejectMalformedItems: true), leading)
                XCTAssertNotNil(parseVoiceSummary(leading), leading)
            }
        }
        XCTAssertNotNil(parseVoiceSummary("SUMMARY: Valid", rejectMalformedItems: true))
        XCTAssertNotNil(parseVoiceSummary("KEY: 0:12 | Valid", rejectMalformedItems: true))
    }

    func testPromptSplitterMovesWholeLineToFreshPrompt() {
        let header = voiceSummaryInstruction(languageName: nil, maxItems: 3) + "\n\nTranscript:\n"
        let budget = 900 - header.utf16.count
        let first = "[0:09] " + String(repeating: "a", count: budget - 25)
        let second = "[0:10] " + String(repeating: "b", count: 30)
        let chunks = voiceSummaryPromptChunks(lines: [first, second], sourceTimes: [9.9, 10.9], languageName: nil)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(bodies(chunks.map(\.text)), [first + "\n", second])
        XCTAssertEqual(chunks.map(\.sourceTimes), [[9.9], [10.9]])
        XCTAssertEqual(voiceSummaryPrompts(lines: [first, second], languageName: nil), chunks.map(\.text))
    }

    func testPromptTimesFollowContinuationAndMixedSourceLines() throws {
        let lines = ["[0:10] " + String(repeating: "😀", count: 700), "[2:00] tail"]
        let chunks = voiceSummaryPromptChunks(lines: lines, sourceTimes: [10.9, 120.25], languageName: nil)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.sourceTimes.contains(10.9) })
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.sourceTimes == [10.9] })
        XCTAssertEqual(chunks.last?.sourceTimes, [10.9, 120.25])
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.utf16.count, 900)
            let parsed = try XCTUnwrap(parseVoiceSummary("KEY: 0:10 | Continuation", rejectMalformedItems: true))
            XCTAssertEqual(voiceSummaryValidated(parsed, allowedTimes: chunk.sourceTimes)?.keyPoints.first?.time, 10.9)
        }
    }

    func testPromptValidationRejectsOtherChunksTimeForEveryItemKind() throws {
        let first = "[0:10] " + String(repeating: "a", count: 300)
        let second = "[2:00] " + String(repeating: "b", count: 300)
        let chunks = voiceSummaryPromptChunks(lines: [first, second], sourceTimes: [10.9, 120.25], languageName: nil)
        XCTAssertEqual(chunks.count, 2)
        let summary = try XCTUnwrap(parseVoiceSummary("KEY: 2:00 | Wrong TASK: 2:00 | Wrong QUESTION: 2:00 | Wrong?", rejectMalformedItems: true))
        XCTAssertNil(voiceSummaryValidated(summary, allowedTimes: chunks[0].sourceTimes))
        let valid = try XCTUnwrap(voiceSummaryValidated(summary, allowedTimes: chunks[1].sourceTimes))
        XCTAssertEqual(valid.keyPoints.map(\.time), [120.25])
        XCTAssertEqual(valid.tasks.map(\.time), [120.25])
        XCTAssertEqual(valid.questions.map(\.time), [120.25])
        let withHeadline = VoiceSummary(headline: "Plausible", keyPoints: summary.keyPoints, tasks: summary.tasks, questions: summary.questions)
        let filtered = try XCTUnwrap(voiceSummaryValidated(withHeadline, allowedTimes: chunks[0].sourceTimes))
        XCTAssertTrue(filtered.keyPoints.isEmpty)
        XCTAssertTrue(filtered.tasks.isEmpty)
        XCTAssertTrue(filtered.questions.isEmpty)
    }

    func testPromptMetadataRejectsMismatchedAndInvalidSourceTimes() {
        XCTAssertTrue(voiceSummaryPromptChunks(lines: ["[0:10] Text"], sourceTimes: [], languageName: nil).isEmpty)
        for time in [Double.nan, .infinity, -1] {
            XCTAssertTrue(voiceSummaryPromptChunks(lines: ["[0:10] Text"], sourceTimes: [time], languageName: nil).isEmpty)
        }
    }

    func testValidatorPrefersDisplayedFloorSecondBeforeNearestTime() throws {
        // formatVoiceTranscriptTime uses Int(value.rounded(.down)), not nearest rounding.
        let parsed = try XCTUnwrap(parseVoiceSummary("KEY: 0:10 | Point TASK: 0:10 | Task QUESTION: 0:10 | Question?", rejectMalformedItems: true))
        for times in [[9.9, 10.9], [10.9, 9.9]] {
            let result = try XCTUnwrap(voiceSummaryValidated(parsed, allowedTimes: times))
            XCTAssertEqual(result.keyPoints.map(\.time), [10.9])
            XCTAssertEqual(result.tasks.map(\.time), [10.9])
            XCTAssertEqual(result.questions.map(\.time), [10.9])
        }
        let fallback = try XCTUnwrap(voiceSummaryValidated(parsed, allowedTimes: [9.9]))
        XCTAssertEqual(fallback.keyPoints.first?.time, 9.9, "Keep the legacy +/-1 tolerance when no displayed second matches")
        let hours = try XCTUnwrap(parseVoiceSummary("KEY: 1:02:03 | Long recording", rejectMalformedItems: true))
        XCTAssertEqual(voiceSummaryValidated(hours, allowedTimes: [3722.9, 3723.9])?.keyPoints.first?.time, 3723.9)
    }

    func testLongAudioRecognitionChunksStayBoundedAndCoverTimelineExactly() {
        let chunks = voiceAudioRecognitionChunks(duration: 126.0)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.first?.ownedStart, 0.0)
        XCTAssertEqual(chunks.last?.ownedEnd, 126.0)
        for chunk in chunks {
            XCTAssertGreaterThan(chunk.audioEnd, chunk.audioStart)
            XCTAssertLessThanOrEqual(chunk.audioEnd - chunk.audioStart, 45.0)
            XCTAssertGreaterThanOrEqual(chunk.audioStart, 0.0)
            XCTAssertLessThanOrEqual(chunk.audioEnd, 126.0)
            XCTAssertGreaterThanOrEqual(chunk.ownedStart, chunk.audioStart)
            XCTAssertLessThanOrEqual(chunk.ownedEnd, chunk.audioEnd)
        }
        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(pair.0.ownedEnd, pair.1.ownedStart)
            XCTAssertGreaterThan(pair.0.audioEnd, pair.1.audioStart, "Adjacent recognition windows should overlap for boundary context")
        }
    }

    func testAudioRecognitionChunkPlanHandlesShortExactAndInvalidDurations() {
        XCTAssertEqual(voiceAudioRecognitionChunks(duration: 10.0), [
            VoiceAudioRecognitionChunk(audioStart: 0.0, audioEnd: 10.0, ownedStart: 0.0, ownedEnd: 10.0)
        ])
        XCTAssertTrue(voiceAudioRecognitionChunks(duration: 0.0).isEmpty)
        XCTAssertTrue(voiceAudioRecognitionChunks(duration: .infinity).isEmpty)
        XCTAssertTrue(voiceAudioRecognitionChunks(duration: 10.0, maximumAudioDuration: 3.0, overlap: 1.5).isEmpty)
    }

    func testTaskStateIdentityIncludesSourceTimeAndPreservesUntimedLegacyTasks() {
        let first = voiceSummaryTaskStateKey(text: "Call Sam", time: 12.0)
        let second = voiceSummaryTaskStateKey(text: "Call Sam", time: 24.0)
        let untimed = voiceSummaryTaskStateKey(text: "Call Sam", time: nil)

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, untimed)
        XCTAssertNotEqual(second, untimed)
        XCTAssertEqual(first, voiceSummaryTaskStateKey(text: "Call Sam", time: 12.0))
    }

    func testStrictServerParsingNeverSilentlyDropsMalformedItems() {
        XCTAssertNil(parseVoiceSummary("SUMMARY: Plan TASK: 0:99 | invalid", rejectMalformedItems: true))
        XCTAssertNil(parseVoiceSummary("SUMMARY: Plan KEY: 0:12 | valid -1:00 | invalid", rejectMalformedItems: true))
        XCTAssertNil(parseVoiceSummary("SUMMARY: Plan QUESTION: missing time", rejectMalformedItems: true))
        XCTAssertNil(parseVoiceSummary("SUMMARY: Plan TASK: missing time", rejectMalformedItems: true))
        XCTAssertNotNil(parseVoiceSummary("SUMMARY: Plan TASK: 0:12 | valid", rejectMalformedItems: true))
        XCTAssertNotNil(parseVoiceSummary("TASK: legacy untimed task"))
    }

    func testCombinedPreservesAllItemsAndChronology() {
        let summaries = [30.0, 10.0, 20.0].map { time in
            VoiceSummary(headline: "Part \(Int(time))", keyPoints: [
                .init(time: time + 1, text: "Point \(time + 1)"),
                .init(time: time, text: "Point \(time)")
            ], tasks: [
                .init(text: "Task \(time + 1)", isCompleted: true, time: time + 1),
                .init(text: "Task \(time)", isCompleted: false, time: time)
            ], questions: [
                .init(time: time + 1, text: "Question \(time + 1)?"),
                .init(time: time, text: "Question \(time)?")
            ])
        }
        let result = voiceSummaryCombined(summaries)
        let times: [Double] = [10, 11, 20, 21, 30, 31]
        XCTAssertEqual(result.keyPoints.map(\.time), times)
        XCTAssertEqual(result.tasks.map(\.time), times.map { Optional($0) })
        XCTAssertEqual(result.questions.map(\.time), times)
        XCTAssertEqual(result.tasks.count, 6)
        XCTAssertEqual(result.questions.count, 6)
        XCTAssertEqual(result.tasks.map(\.isCompleted), [false, true, false, true, false, true])
        XCTAssertEqual(result.headline, "Part 30 Part 10 Part 20")
    }

    func testCombinedDeduplicatesOnlyMatchingTimeAndCaseInsensitiveText() {
        let first = VoiceSummary(headline: "First", keyPoints: [
            .init(time: 20.25, text: "Repeat")
        ], tasks: [
            .init(text: "Repeat", isCompleted: true, time: 20.25)
        ], questions: [.init(time: 20.25, text: "Repeat?")])
        let second = VoiceSummary(headline: "", keyPoints: [
            .init(time: 20.25, text: "REPEAT"),
            .init(time: 20.5, text: "repeat"),
            .init(time: 20.25, text: "Different")
        ], tasks: [
            .init(text: "REPEAT", isCompleted: false, time: 20.25),
            .init(text: "repeat", isCompleted: false, time: 20.5),
            .init(text: "Different", isCompleted: false, time: 20.25)
        ], questions: [
            .init(time: 20.25, text: "REPEAT?"),
            .init(time: 20.5, text: "repeat?"),
            .init(time: 20.25, text: "Different?")
        ])
        let result = voiceSummaryCombined([first, second])
        XCTAssertEqual(result.keyPoints, [
            first.keyPoints[0], second.keyPoints[2], second.keyPoints[1]
        ])
        XCTAssertEqual(result.tasks, [first.tasks[0], second.tasks[2], second.tasks[1]])
        XCTAssertEqual(result.questions, [
            first.questions[0], second.questions[2], second.questions[1]
        ])
        XCTAssertEqual(result.headline, "First")
    }

    func testCombinedUntimedTasksKeepSourceOrderAfterTimedTasks() {
        let first = VoiceSummary(headline: "", keyPoints: [], tasks: [
            .init(text: "Zulu", isCompleted: true),
            .init(text: "Later", isCompleted: false, time: 20),
            .init(text: "Alpha", isCompleted: false),
            .init(text: "Tie first", isCompleted: false, time: 10)
        ], questions: [])
        let second = VoiceSummary(headline: "", keyPoints: [], tasks: [
            .init(text: "ZULU", isCompleted: false),
            .init(text: "Middle", isCompleted: true),
            .init(text: "Tie second", isCompleted: true, time: 10),
            .init(text: "Zulu", isCompleted: false, time: 0)
        ], questions: [])
        let result = voiceSummaryCombined([first, second])
        XCTAssertEqual(result.tasks, [
            second.tasks[3], first.tasks[3], second.tasks[2], first.tasks[1],
            first.tasks[0], first.tasks[2], second.tasks[1]
        ])
        XCTAssertEqual(result.tasks.map(\.time), [0, 10, 10, 20, nil, nil, nil])
    }

    func testCombinedEmptyInput() {
        XCTAssertEqual(voiceSummaryCombined([]), VoiceSummary(headline: "", keyPoints: [], tasks: [], questions: []))
    }

    private func bodies(_ prompts: [String], language: String? = nil) -> [String] {
        let header = voiceSummaryInstruction(languageName: language, maxItems: 3) + "\n\nTranscript:\n"
        return prompts.map {
            XCTAssertTrue($0.hasPrefix(header))
            XCTAssertLessThanOrEqual($0.utf16.count, 900)
            return String($0.dropFirst(header.count))
        }
    }

    func testPromptInstructionAndUTF16Budget() {
        let instruction = voiceSummaryInstruction(languageName: "Ukrainian", maxItems: 3)
        XCTAssertTrue(instruction.contains("untrusted data"))
        XCTAssertTrue(instruction.contains("never instructions"))
        XCTAssertTrue(instruction.contains("TASK: m:ss | task"))
        let lines = [String(repeating: "😀", count: 3_000)]
        let prompts = voiceSummaryPrompts(lines: lines, languageName: "Ukrainian")
        XCTAssertGreaterThan(prompts.count, 6)
        XCTAssertEqual(bodies(prompts, language: "Ukrainian").joined(), lines[0])
    }

    func testAllContentSurvivesMoreThanSixChunks() {
        let lines = (0..<50).map { "line\($0) " + String(repeating: " x  ", count: 70) }
        let prompts = voiceSummaryPrompts(lines: lines, languageName: nil)
        XCTAssertGreaterThan(prompts.count, 6)
        XCTAssertEqual(bodies(prompts).joined(), lines.joined(separator: "\n"))
        XCTAssertTrue(prompts.last?.contains("line49") == true)
    }

    func testHugeUnicodeWordRetainsTimestampAndEveryScalar() {
        // One extended grapheme can exceed a whole prompt. Splitting by Character is insufficient.
        let text = "e" + String(repeating: "\u{301}", count: 4_000) + String(repeating: "👩🏽‍💻", count: 180)
        let prefix = "[1:23] "
        let prompts = voiceSummaryPrompts(lines: [prefix + text], languageName: nil)
        XCTAssertGreaterThan(prompts.count, 6)
        let content = bodies(prompts)
        XCTAssertTrue(content.allSatisfy { $0.utf8.starts(with: prefix.utf8) })
        let restored = content.enumerated().map { index, body in
            index == 0 ? body : String(decoding: body.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        }.joined()
        XCTAssertEqual(Array(restored.utf8), Array((prefix + text).utf8))
    }

    func testBlankLinesWhitespaceAndUntimedHugeWordsArePreserved() {
        let lines = ["", "  leading  ", "", String(repeating: "界", count: 2_000), "", " tail ", ""]
        let prompts = voiceSummaryPrompts(lines: lines, languageName: nil)
        XCTAssertFalse(prompts.isEmpty)
        XCTAssertEqual(bodies(prompts).joined(), lines.joined(separator: "\n"))
    }

    func testChunkLimitRefusesRatherThanSamples() {
        let header = voiceSummaryInstruction(languageName: nil, maxItems: 3) + "\n\nTranscript:\n"
        let budget = 900 - header.utf16.count
        let exactly128 = String(repeating: "x", count: budget * 128)
        let prompts = voiceSummaryPrompts(lines: [exactly128], languageName: nil)
        XCTAssertEqual(prompts.count, 128)
        XCTAssertEqual(bodies(prompts).joined(), exactly128)
        XCTAssertEqual(voiceSummaryPrompts(lines: [exactly128 + "x"], languageName: nil), [])
        XCTAssertEqual(voiceSummaryPrompts(lines: [String(repeating: "😀", count: 500_000)], languageName: nil), [])
        XCTAssertEqual(voiceSummaryPrompts(lines: ["text"], languageName: String(repeating: "a", count: 5_000)), [])
        XCTAssertEqual(voiceSummaryPrompts(lines: [], languageName: nil), [])
    }

    func testValidTimes() {
        for (input, expected) in [("0:00", 0.0), ("1:23", 83), ("125:59", 7559),
                                  ("1:02:03", 3723), ("[1:23]", 83), (" (1:23) ", 83)] {
            XCTAssertEqual(voiceSummaryTime(input), expected, input)
        }
    }

    func testInvalidAndOverflowTimes() {
        let invalid = ["", "42", "1:2", "1:60", "1:60:00", "-1:00", "1:-01", "+1:00", "1::00",
                       "1:00:00:00", "1.0:00", "1:00.5", "1: 00", "[1:00)", "[[1:00]]", "1:00]",
                       "١:٠٠", "NaN:00", "inf:00", "9223372036854775807:59", "9007199254740991:00",
                       String(repeating: "9", count: 100_000) + ":00"]
        for input in invalid { XCTAssertNil(voiceSummaryTime(input), String(input.prefix(80))) }
    }

    func testTaskCodableIsBackwardCompatible() throws {
        let legacy = Data(#"{"text":"Send report","isCompleted":true}"#.utf8)
        let task = try JSONDecoder().decode(VoiceSummary.Task.self, from: legacy)
        XCTAssertNil(task.time)
        XCTAssertTrue(task.isCompleted)
        XCTAssertNil(VoiceSummary.Task(text: "Legacy initializer", isCompleted: false).time)
        let timed = VoiceSummary.Task(text: "Call", isCompleted: false, time: 83)
        XCTAssertEqual(try JSONDecoder().decode(VoiceSummary.Task.self, from: JSONEncoder().encode(timed)), timed)
        let oldSummary = Data(#"{"headline":"Report","keyPoints":[],"tasks":[{"text":"Send report","isCompleted":true}],"questions":[]}"#.utf8)
        let summary = try JSONDecoder().decode(VoiceSummary.self, from: oldSummary)
        XCTAssertFalse(summary.isPlaceholder)
        XCTAssertNil(summary.tasks.first?.time)
        XCTAssertEqual(try JSONDecoder().decode(VoiceSummary.self, from: JSONEncoder().encode(summary)), summary)
    }

    func testParserBulletsInlineLabelsAndTasks() throws {
        let summary = try XCTUnwrap(parseVoiceSummary("""
        • **SUMMARY:** A decision. KEY: [0:12] | First 0:20 | Second
        - **TASK:** 0:20 | Send report QUESTION: 1:02:03 | Ready?
        1. TASK: Legacy untimed task
        * key: (0:30) | Third
        """))
        XCTAssertEqual(summary.headline, "A decision.")
        XCTAssertEqual(summary.keyPoints.map(\.time), [12, 20, 30])
        XCTAssertEqual(summary.keyPoints.map(\.text), ["First", "Second", "Third"])
        XCTAssertEqual(summary.tasks.map(\.text), ["Send report", "Legacy untimed task"])
        XCTAssertEqual(summary.tasks.map(\.time), [20, nil])
        XCTAssertEqual(summary.questions, [.init(time: 3723, text: "Ready?")])
    }

    func testParserNeverInventsZeroForInvalidEntries() throws {
        XCTAssertNil(parseVoiceSummary("KEY: missing time QUESTION: bad | question TASK: 0:99 | bad"))
        let summary = try XCTUnwrap(parseVoiceSummary("KEY: -1:00 | bad 0:12 | good 999999999999999999999:00 | bad QUESTION: 0:99 | bad TASK: old task"))
        XCTAssertEqual(summary.keyPoints, [.init(time: 12, text: "good")])
        XCTAssertTrue(summary.questions.isEmpty)
        XCTAssertEqual(summary.tasks.count, 1)
        XCTAssertNil(summary.tasks[0].time)
        XCTAssertEqual(voiceSummaryKeyPoints(from: "0:00 | Real start"), [.init(time: 0, text: "Real start")])
        XCTAssertTrue(voiceSummaryKeyPoints(from: "-0:00 | Not start").isEmpty)
    }

    func testValidatorFiltersAndMapsNearestSourceTime() throws {
        let summary = VoiceSummary(headline: "Decision", keyPoints: [
            .init(time: 10, text: "Rounded"), .init(time: 12, text: "Unrelated"),
            .init(time: .nan, text: "NaN"), .init(time: -.infinity, text: "Infinite"),
            .init(time: -1, text: "Negative"), .init(time: 10, text: " ")
        ], tasks: [
            .init(text: "Timed", isCompleted: true, time: 21),
            .init(text: "Legacy", isCompleted: false),
            .init(text: "Bad", isCompleted: false, time: .infinity),
            .init(text: "Off source", isCompleted: false, time: 40)
        ], questions: [.init(time: 20.8, text: "Question?"), .init(time: 0, text: "Bad?")])
        let result = try XCTUnwrap(voiceSummaryValidated(summary, allowedTimes: [.nan, -.infinity, -1, 10.3, 20]))
        XCTAssertEqual(result.keyPoints, [.init(time: 10.3, text: "Rounded")])
        XCTAssertEqual(result.tasks.map(\.time), [20, nil])
        XCTAssertTrue(result.tasks[0].isCompleted)
        XCTAssertEqual(result.questions, [.init(time: 20, text: "Question?")])
    }

    func testValidatorRejectsPlaceholderAndEntirelyUnusableSummary() {
        let empty = VoiceSummary(headline: " \n", keyPoints: [.init(time: 500, text: "Bad")], tasks: [], questions: [])
        XCTAssertNil(voiceSummaryValidated(empty, allowedTimes: [0]))
        let placeholder = VoiceSummary(headline: "A plausible headline", keyPoints: [], tasks: [], questions: [], isPlaceholder: true)
        XCTAssertNil(voiceSummaryValidated(placeholder, allowedTimes: [0]))
        let legacy = VoiceSummary(headline: "", keyPoints: [], tasks: [.init(text: "Untimed", isCompleted: false)], questions: [])
        XCTAssertNil(voiceSummaryValidated(legacy, allowedTimes: [])?.tasks[0].time)
        XCTAssertNotNil(voiceSummaryValidated(legacy, allowedTimes: []))
    }
}