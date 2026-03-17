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

    func testDiagnosticsRecoverWhenMissingValueIsFollowedByAnotherFlag() {
        let diagnostics = CommandEditorAssistant.diagnostics(
            for: "ffmpeg -c:v -vf scale=1280:-2 output.mp4"
        )

        XCTAssertTrue(diagnostics.contains(where: { $0.message.contains("参数 -c:v 缺少取值") }))
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

    func testFlagCompletionPrioritizesInputFlagsAtStart() {
        let command = "ffmpeg "
        let cursor = command.utf16.count
        let completions = CommandEditorAssistant.completions(
            for: command,
            selectedRange: NSRange(location: cursor, length: 0),
            partialRange: NSRange(location: cursor, length: 0)
        )

        XCTAssertEqual(Array(completions.prefix(3)), ["-i", "-f", "-ss"])
    }

    func testFlagCompletionPrioritizesOutputShapingAfterInput() {
        let command = "ffmpeg -i input.mp4 "
        let cursor = command.utf16.count
        let completions = CommandEditorAssistant.completions(
            for: command,
            selectedRange: NSRange(location: cursor, length: 0),
            partialRange: NSRange(location: cursor, length: 0)
        )

        XCTAssertEqual(Array(completions.prefix(4)), ["-c:v", "-preset", "-crf", "-c:a"])
    }

    func testFlagCompletionSuggestsMovflagsForMP4Context() {
        let command = "ffmpeg -i input.mov -f mp4 "
        let cursor = command.utf16.count
        let completions = CommandEditorAssistant.completions(
            for: command,
            selectedRange: NSRange(location: cursor, length: 0),
            partialRange: NSRange(location: cursor, length: 0)
        )

        XCTAssertTrue(completions.prefix(12).contains("-movflags"))
    }

    func testFlagCompletionResetsFormatContextAfterOutputBoundary() {
        let command = "ffmpeg -i input.mov output.mp4 "
        let cursor = command.utf16.count
        let completions = CommandEditorAssistant.completions(
            for: command,
            selectedRange: NSRange(location: cursor, length: 0),
            partialRange: NSRange(location: cursor, length: 0)
        )

        XCTAssertEqual(Array(completions.prefix(4)), ["-map", "-c:v", "-c:a", "-f"])
        XCTAssertFalse(completions.prefix(12).contains("-movflags"))
    }

    func testValueCompletionForPreset() {
        let completions = CommandEditorAssistant.completions(
            for: "ffmpeg -preset v",
            selectedRange: NSRange(location: 16, length: 0),
            partialRange: NSRange(location: 15, length: 1)
        )

        XCTAssertTrue(completions.contains("veryfast"))
        XCTAssertTrue(completions.contains("veryslow"))
    }

    func testDiagnosticsCanonicalizeMatroskaExtensionAlias() {
        let diagnostics = CommandEditorAssistant.diagnostics(
            for: "ffmpeg -i input.mov -f matroska output.mkv"
        )

        XCTAssertFalse(diagnostics.contains(where: { $0.message.contains("可能不一致") }))
    }

    func testCodecCompletionCanonicalizesFormatAlias() {
        let command = "ffmpeg -i input.mov -f mkv -c:v "
        let cursor = command.utf16.count
        let completions = CommandEditorAssistant.completions(
            for: command,
            selectedRange: NSRange(location: cursor, length: 0),
            partialRange: NSRange(location: cursor, length: 0)
        )

        XCTAssertTrue(completions.contains("libvpx-vp9"))
        XCTAssertTrue(completions.contains("av1"))
    }

    func testFlagCompletionPrunesVideoFilterWhenVideoDisabled() {
        let command = "ffmpeg -i input.mp4 -vn "
        let cursor = command.utf16.count
        let completions = CommandEditorAssistant.completions(
            for: command,
            selectedRange: NSRange(location: cursor, length: 0),
            partialRange: NSRange(location: cursor, length: 0)
        )

        XCTAssertFalse(completions.contains("-vf"))
        XCTAssertFalse(completions.contains("-c:v"))
    }

    func testFlagCompletionPrunesConflictsAfterCopyCodecSelection() {
        let command = "ffmpeg -i input.mp4 -c:v copy "
        let cursor = command.utf16.count
        let completions = CommandEditorAssistant.completions(
            for: command,
            selectedRange: NSRange(location: cursor, length: 0),
            partialRange: NSRange(location: cursor, length: 0)
        )

        XCTAssertFalse(completions.contains("-vf"))
        XCTAssertFalse(completions.contains("-filter_complex"))
    }

    func testCompletionContextDoesNotAutoInlineForEmptyFlagSlot() {
        let context = CommandEditorAssistant.completionContext(
            for: "ffmpeg ",
            selectedRange: NSRange(location: 7, length: 0),
            partialRange: NSRange(location: 7, length: 0)
        )

        XCTAssertFalse(context.allowsInlineSuggestionWhenPartialIsEmpty)
    }

    func testCompletionContextAllowsAutoInlineForFlagValueSlot() {
        let command = "ffmpeg -c:v "
        let cursor = command.utf16.count
        let context = CommandEditorAssistant.completionContext(
            for: command,
            selectedRange: NSRange(location: cursor, length: 0),
            partialRange: NSRange(location: cursor, length: 0)
        )

        XCTAssertTrue(context.allowsInlineSuggestionWhenPartialIsEmpty)
    }

    // MARK: - Level 3: Completion Behavior Verification (End-to-End)

    /// 注入 HW 编解码器后，补全列表首位应该是它
    func testHWCodecAppearsFirstInCompletion() async throws {
        // 1. 准备测试数据
        let testCodecs = [HardwareCodec(name: "h264_videotoolbox", stream: .video)]
        let data = try JSONEncoder().encode(testCodecs)

        // 2. 注入 UserDefaults (cachedVideoCodecNames 会读取此处)
        UserDefaults.standard.set(data, forKey: HardwareAccelerationProbe.CacheKey.codecs)
        defer {
            UserDefaults.standard.removeObject(forKey: HardwareAccelerationProbe.CacheKey.codecs)
        }

        // 3. 模拟用户输入 "ffmpeg -i a.mov -f mp4 -c:v "
        let command = "ffmpeg -i a.mov -f mp4 -c:v "
        let results = CommandEditorAssistant.completions(
            for: command,
            selectedRange: NSRange(location: command.utf16.count, length: 0),
            partialRange: NSRange(location: command.utf16.count, length: 0)
        )

        XCTAssertEqual(results.first, "h264_videotoolbox",
                       "有格式上下文（mp4）时，HW 加速器应排在首位")

        // libvpx 不应出现（mp4 不支持 WebM 编解码器）
        XCTAssertFalse(results.contains("libvpx-vp9"),
                       "mp4 格式不应提示 libvpx-vp9")
    }

    /// 无 HW 编解码器时，退化到纯静态列表
    func testFallbackWhenNoHWCodecs() async {
        // 确保缓存为空
        UserDefaults.standard.removeObject(forKey: HardwareAccelerationProbe.CacheKey.codecs)

        let command = "ffmpeg -i a.mov -c:v "
        let results = CommandEditorAssistant.completions(
            for: command,
            selectedRange: NSRange(location: command.utf16.count, length: 0),
            partialRange: NSRange(location: command.utf16.count, length: 0)
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.contains("libx264"))
    }
}
