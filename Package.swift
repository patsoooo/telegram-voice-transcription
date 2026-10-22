// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceSummaryCore",
    platforms: [.macOS(.v10_15)],
    products: [.library(name: "VoiceSummaryCore", targets: ["VoiceSummaryCore"])],
    targets: [
        .target(
            name: "VoiceSummaryCore",
            path: "VoiceTranscriptScreen/Sources",
            exclude: ["ServerVoiceTranscript.swift", "VoiceTranscriptData.swift", "VoiceTranscriptRecognition.swift", "VoiceTranscriptScreen.swift", "VoiceTranscriptAlignment.swift"],
            sources: ["VoiceSummaryCore.swift", "VoiceTranscriptAlignmentCore.swift"]
        ),
        .testTarget(name: "VoiceSummaryCoreTests", dependencies: ["VoiceSummaryCore"])
    ]
)