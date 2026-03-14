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
            selectedRange: NSRange(location: 16, length: 0),
            partialRange: NSRange(location: 15, length: 1)
        )

        XCTAssertTrue(completions.contains("veryfast"))
        XCTAssertTrue(completions.contains("veryslow"))
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
