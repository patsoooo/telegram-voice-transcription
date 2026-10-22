import Foundation

// Compiled alongside VoiceSummaryCore.swift in the same module; no package import.
private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}

private final class SmokeRunner {
    private var assertionsPassed = 0

    // Unlike Swift assert, these checks still execute in optimized builds.
    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SmokeFailure(description: message) }
        assertionsPassed += 1
    }

    private func bodies(_ prompts: [String], language: String? = nil) throws -> [String] {
        let header = voiceSummaryInstruction(languageName: language, maxItems: 3) + "\n\nTranscript:\n"
        var result: [String] = []
        for (index, prompt) in prompts.enumerated() {
            try require(prompt.utf8.starts(with: header.utf8), "Prompt \(index) lost its instruction")
            try require(prompt.utf16.count <= 900, "Prompt \(index) exceeds 900 UTF-16 units")
            // Byte slicing avoids Character/grapheme boundaries changing at chunk joins.
            result.append(String(decoding: prompt.utf8.dropFirst(header.utf8.count), as: UTF8.self))
        }
        return result
    }

    func run() throws {
        let lines = (0..<50).map { "line\($0) " + String(repeating: " x  ", count: 70) }
        let prompts = voiceSummaryPrompts(lines: lines, languageName: nil)
        try require(prompts.count > 6, "Long transcript must use more than six chunks")
        let restoredLines = try bodies(prompts).joined()
        try require(Array(restoredLines.utf8) == Array(lines.joined(separator: "\n").utf8),
                    "Long transcript lost or reordered source content")

        // A single grapheme exceeds a prompt; include non-BMP and ZWJ scalars too.
        let timestamp = "[1:23] "
        let unicodeSource = timestamp + "e" + String(repeating: "\u{301}", count: 12_000)
            + String(repeating: "👩🏽‍💻", count: 400)
        let unicodePrompts = voiceSummaryPrompts(lines: [unicodeSource], languageName: "Ukrainian")
        try require(unicodePrompts.count > 6, "Huge Unicode source did not exercise continuation chunks")
        let unicodeBodies = try bodies(unicodePrompts, language: "Ukrainian")
        var restoredBytes: [UInt8] = []
        for (index, body) in unicodeBodies.enumerated() {
            try require(body.utf8.starts(with: timestamp.utf8), "Continuation lost its timestamp")
            // Strip only the synthetic prefix, never by Character count: a chunk can
            // begin with a combining scalar that joins the prefix's trailing space.
            restoredBytes.append(contentsOf: body.utf8.dropFirst(index == 0 ? 0 : timestamp.utf8.count))
        }
        try require(restoredBytes == Array(unicodeSource.utf8), "Unicode source bytes were changed or lost")
        let restoredUnicode = String(decoding: restoredBytes, as: UTF8.self)
        try require(restoredUnicode.unicodeScalars.map(\.value) == unicodeSource.unicodeScalars.map(\.value),
                    "Unicode source scalars were changed or lost")

        let whitespaceLines = ["", "  leading  ", "", String(repeating: "界", count: 2_000), "", " tail ", ""]
        let whitespacePrompts = voiceSummaryPrompts(lines: whitespaceLines, languageName: nil)
        try require(!whitespacePrompts.isEmpty, "Whitespace fixture was refused")
        let restoredWhitespace = try bodies(whitespacePrompts).joined()
        try require(Array(restoredWhitespace.utf8) == Array(whitespaceLines.joined(separator: "\n").utf8),
                    "Blank lines or whitespace were lost")

        let header = voiceSummaryInstruction(languageName: nil, maxItems: 3) + "\n\nTranscript:\n"
        let budget = 900 - header.utf16.count
        try require(budget > 0, "Instruction leaves no source budget")
        let boundarySource = String(repeating: "x", count: budget * 128)
        let boundaryPrompts = voiceSummaryPrompts(lines: [boundarySource], languageName: nil)
        try require(boundaryPrompts.count == 128, "Exactly 128 chunks must be accepted")
        let restoredBoundary = try bodies(boundaryPrompts).joined()
        try require(restoredBoundary == boundarySource, "128-chunk boundary lost content")
        try require(voiceSummaryPrompts(lines: [boundarySource + "x"], languageName: nil).isEmpty,
                    "A 129th chunk must refuse the entire source, not truncate or sample")
        try require(voiceSummaryPrompts(lines: [String(repeating: "😀", count: 500_000)], languageName: nil).isEmpty,
                    "Pathological Unicode source must be refused")
        try require(voiceSummaryPrompts(lines: ["text"], languageName: String(repeating: "a", count: 5_000)).isEmpty,
                    "Oversized language name must be refused")
        try require(voiceSummaryPrompts(lines: [], languageName: nil).isEmpty, "Empty input must be refused")

        let validTimes: [(String, Double)] = [
            ("0:00", 0), ("1:23", 83), ("125:59", 7559), ("1:02:03", 3723),
            ("[1:23]", 83), (" (1:23) ", 83), ("150119987579016:31", 9_007_199_254_740_991)
        ]
        for (input, expected) in validTimes {
            try require(voiceSummaryTime(input) == expected, "Valid timestamp rejected: \(input)")
        }
        let invalidTimes = [
            "", "42", "1:2", "1:60", "1:60:00", "-1:00", "-0:00", "1:-01", "+1:00", "1::00",
            "1:00:00:00", "1.0:00", "1:00.5", "1: 00", "[1:00)", "[[1:00]]", "1:00]",
            "١:٠٠", "NaN:00", "inf:00", "9223372036854775807:59", "9007199254740991:00",
            "150119987579016:32", String(repeating: "9", count: 100_000) + ":00"
        ]
        for input in invalidTimes {
            try require(voiceSummaryTime(input) == nil, "Invalid/overflow timestamp accepted: \(input.prefix(80))")
        }

        let parsed = parseVoiceSummary("""
        • **SUMMARY:** A decision. KEY: [0:12] | First 0:20 | Second
        - **TASK:** 0:20 | Send report QUESTION: 1:02:03 | Ready?
        1. TASK: Legacy untimed task
        * key: (0:30) | Third
        """)
        try require(parsed != nil, "Structured summary did not parse")
        try require(parsed?.headline == "A decision.", "Headline parsing failed")
        try require(parsed?.keyPoints.map(\.time) == [12, 20, 30], "Key timestamps did not parse")
        try require(parsed?.tasks.map(\.text) == ["Send report", "Legacy untimed task"], "Tasks did not parse")
        try require(parsed?.tasks.map(\.time) == [20, nil], "Timed/legacy task times changed")
        try require(parsed?.tasks.allSatisfy { !$0.isCompleted } == true, "Parsed tasks must start incomplete")
        try require(parsed?.questions == [.init(time: 3723, text: "Ready?")], "Question timestamp did not parse")
        try require(parseVoiceSummary("KEY: missing time QUESTION: bad | question TASK: 0:99 | bad") == nil,
                    "Invalid timestamps must not become zero-time entries")
        try require(voiceSummaryKeyPoints(from: "-1:00 | bad 0:12 | good 999999999999999999999:00 | bad")
                    == [.init(time: 12, text: "good")], "Invalid token boundaries contaminated valid entries")

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let legacyTask = try decoder.decode(VoiceSummary.Task.self,
            from: Data(#"{"text":"Send report","isCompleted":true}"#.utf8))
        try require(legacyTask.time == nil && legacyTask.isCompleted, "Legacy task Codable compatibility failed")
        try require(VoiceSummary.Task(text: "Legacy initializer", isCompleted: false).time == nil,
                    "Legacy task initializer must remain untimed")
        let timedTask = VoiceSummary.Task(text: "Call", isCompleted: true, time: 83)
        let decodedTask = try decoder.decode(VoiceSummary.Task.self, from: encoder.encode(timedTask))
        try require(decodedTask == timedTask, "Timed task Codable round trip failed")
        let legacySummary = try decoder.decode(VoiceSummary.self, from: Data(
            #"{"headline":"Report","keyPoints":[],"tasks":[{"text":"Send report","isCompleted":true}],"questions":[]}"#.utf8))
        try require(!legacySummary.isPlaceholder, "Missing legacy placeholder flag must default to false")
        try require(legacySummary.tasks == [legacyTask], "Legacy summary task compatibility failed")
        let decodedSummary = try decoder.decode(VoiceSummary.self, from: encoder.encode(legacySummary))
        try require(decodedSummary == legacySummary, "Legacy summary Codable round trip failed")

        let invalidSeekTimes: [Double] = [.nan, .infinity, -.infinity, -1, 40]
        let invalidSeeks = VoiceSummary(headline: " \n", keyPoints: invalidSeekTimes.map {
            .init(time: $0, text: "Bad point")
        }, tasks: invalidSeekTimes.map {
            .init(text: "Bad task", isCompleted: false, time: $0)
        }, questions: invalidSeekTimes.map {
            .init(time: $0, text: "Bad question?")
        })
        try require(voiceSummaryValidated(invalidSeeks, allowedTimes: [10, 20]) == nil,
                    "Nonfinite, negative, or off-source seek targets survived validation")
        let validSeeks = VoiceSummary(headline: " Decision ", keyPoints: [
            .init(time: 10, text: "Rounded"), .init(time: 10, text: " ")
        ], tasks: [timedTask, .init(text: "Timed", isCompleted: true, time: 21), legacyTask],
            questions: [.init(time: 20.8, text: "Ready?"), .init(time: 0, text: "Off source?")])
        let validated = voiceSummaryValidated(validSeeks, allowedTimes: [.nan, .infinity, -1, 10.3, 20])
        try require(validated != nil, "Usable summary was rejected")
        try require(validated?.headline == "Decision", "Headline whitespace was not trimmed")
        try require(validated?.keyPoints == [.init(time: 10.3, text: "Rounded")], "Key seek must snap to source time")
        try require(validated?.tasks.map(\.time) == [20, nil], "Invalid task seek was retained or legacy seek invented")
        try require(validated?.tasks.allSatisfy(\.isCompleted) == true, "Task completion was lost during validation")
        try require(validated?.questions == [.init(time: 20, text: "Ready?")], "Question seek validation failed")
        try require(voiceSummaryValidated(invalidSeeks, allowedTimes: [.nan, .infinity, -1]) == nil,
                    "Invalid allowed times must not authorize seeks")
        let untimed = VoiceSummary(headline: "", keyPoints: [], tasks: [legacyTask], questions: [])
        try require(voiceSummaryValidated(untimed, allowedTimes: [])?.tasks == [legacyTask],
                    "Untimed legacy task must survive without inventing a seek")

        let placeholder = VoiceSummary(headline: "Plausible", keyPoints: [.init(time: 10, text: "Point")],
            tasks: [legacyTask], questions: [], isPlaceholder: true)
        try require(voiceSummaryValidated(placeholder, allowedTimes: [10]) == nil,
                    "Placeholder summary must be rejected even with valid content")
        let decodedPlaceholder = try decoder.decode(VoiceSummary.self, from: encoder.encode(placeholder))
        try require(decodedPlaceholder.isPlaceholder, "Codable lost the placeholder flag")
        try require(voiceSummaryValidated(decodedPlaceholder, allowedTimes: [10]) == nil,
                    "Decoded placeholder bypassed rejection")

        try require(parseVoiceSummary("SUMMARY: Plan TASK: 0:99 | invalid", rejectMalformedItems: true) == nil,
                    "Strict server parsing must reject malformed task times")
        try require(parseVoiceSummary("SUMMARY: Plan KEY: 0:12 | valid -1:00 | invalid", rejectMalformedItems: true) == nil,
                    "Strict server parsing must reject a mixed valid/invalid item list")
        try require(parseVoiceSummary("SUMMARY: Plan TASK: missing time", rejectMalformedItems: true) == nil,
                    "New server tasks must have source timestamps")
        try require(parseVoiceSummary("SUMMARY: Plan TASK: 0:12 | valid", rejectMalformedItems: true) != nil,
                    "Strict parsing rejected a valid timestamped task")
        let parts = (0..<8).map { index in
            VoiceSummary(headline: "Part \(index)", keyPoints: [.init(time: Double(index), text: "Repeated")],
                tasks: [.init(text: "Repeated task", isCompleted: false, time: Double(index))],
                questions: [.init(time: Double(index), text: "Repeated question?")])
        }
        let merged = voiceSummaryCombined(Array(parts.reversed()) + [parts[0]])
        try require(merged.keyPoints.count == 8 && merged.tasks.count == 8 && merged.questions.count == 8,
                    "Merge dropped distinct timestamps or retained exact duplicates")
        try require(merged.tasks.compactMap(\.time) == (0..<8).map(Double.init), "Task merge is not chronological")
        print("PASS: \(assertionsPassed) smoke assertions passed")
    }
}

try SmokeRunner().run()