//
//  CommandEditorAssistantTests.swift
//  FFmpegRunnerTests
//

import XCTest
@testable import FFmpegRunner

final class CommandEditorAssistantTests: XCTestCase {
    func testDiagnosticsDetectMalformedCommand() {
        let diagnostics = CommandEditorAssistant.diagnostics(for: #"ffmpeg -i "input.mp4"#)
        XCTAssertEqual(diagnostics.first?.severity, .error)
        XCTAssertEqual(diagnostics.first?.message, "命令包含未闭合的双引号")
    }

    func testDiagnosticsDetectMissingOutput() {
        let diagnostics = CommandEditorAssistant.diagnostics(for: "ffmpeg -i input.mp4")
        XCTAssertTrue(diagnostics.contains(where: { $0.message.contains("未检测到输出目标") }))
    }

    func testDiagnosticsDetectFormatMismatch() {
        let diagnostics = CommandEditorAssistant.diagnostics(for: "ffmpeg -i input.mov -f mp4 output.mkv")
        XCTAssertTrue(diagnostics.contains(where: { $0.message.contains("可能不一致") }))
    }

    func testExecutableCompletionAtStart() {
        let completions = CommandEditorAssistant.completions(
            for: "ffm",
            selectedRange: NSRange(location: 3, length: 0),
            partialRange: NSRange(location: 0, length: 3)
        )

        XCTAssertEqual(completions, ["ffmpeg"])
    }

    func testFlagCompletionAfterWhitespace() {
        let completions = CommandEditorAssistant.completions(
            for: "ffmpeg -",
            selectedRange: NSRange(location: 8, length: 0),
            partialRange: NSRange(location: 7, length: 1)
        )

        XCTAssertTrue(completions.contains("-i"))
        XCTAssertTrue(completions.contains("-preset"))
    }

    func testValueCompletionForPreset() {
        let completions = CommandEditorAssistant.completions(
            for: "ffmpeg -preset v",
            selectedRange: NSRange(location: 17, length: 0),
            partialRange: NSRange(location: 16, length: 1)
        )

        XCTAssertTrue(completions.contains("veryfast"))
        XCTAssertTrue(completions.contains("veryslow"))
    }
}
