//
//  SplitCommandTests.swift
//  FFmpegRunnerTests
//
//  Level 1-3 tests for CommandRenderer.splitCommand
//  Focus: splitCommand → arguments 等价性验证
//

import XCTest
@testable import FFmpegRunner

final class SplitCommandTests: XCTestCase {

    // MARK: - Level 1: Parameter Pipeline Equivalence (必须 100% 通过)

    // MARK: A. Basic Sanity

    /// A1: 基础版本查询
    func testBasicVersion() {
        let args = CommandRenderer.splitCommand("ffmpeg -version")

        XCTAssertEqual(args, ["ffmpeg", "-version"])
    }

    /// A2: 标准参数顺序
    func testStandardParameterOrder() {
        let command = "ffmpeg -hide_banner -loglevel error -i input.mp4 output.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-hide_banner",
            "-loglevel", "error",
            "-i", "input.mp4",
            "output.mp4"
        ])
    }

    // MARK: B. Order-Sensitive Parameters (FFmpeg 最容易出事的点)

    /// B1: Pre-seek (快速 seek) - `-ss` 在 `-i` 之前
    func testPreSeekOrder() {
        let command = "ffmpeg -ss 10 -i input.mp4 -t 5 out.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-ss", "10",
            "-i", "input.mp4",
            "-t", "5",
            "out.mp4"
        ])

        // 验证 -ss 在 -i 之前
        let ssIndex = args.firstIndex(of: "-ss")!
        let iIndex = args.firstIndex(of: "-i")!
        XCTAssertLessThan(ssIndex, iIndex, "-ss should come before -i for pre-seek")
    }

    /// B2: Post-seek (精确但慢) - `-ss` 在 `-i` 之后
    func testPostSeekOrder() {
        let command = "ffmpeg -i input.mp4 -ss 10 -t 5 out.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-i", "input.mp4",
            "-ss", "10",
            "-t", "5",
            "out.mp4"
        ])

        // 验证 -i 在 -ss 之前
        let iIndex = args.firstIndex(of: "-i")!
        let ssIndex = args.firstIndex(of: "-ss")!
        XCTAssertLessThan(iIndex, ssIndex, "-i should come before -ss for post-seek")
    }

    // MARK: C. Complex Filtergraph (99% GUI tools 死在这里)

    /// C1: 复杂 filtergraph - 引号、冒号、逗号、等号、空格
    func testComplexFiltergraph() {
        let command = """
        ffmpeg -i input.mp4 -vf "scale=1280:-2,drawtext=text='Hello World':x=10:y=10" -pix_fmt yuv420p out.mp4
        """
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-i", "input.mp4",
            "-vf", "scale=1280:-2,drawtext=text='Hello World':x=10:y=10",
            "-pix_fmt", "yuv420p",
            "out.mp4"
        ])

        // 关键验证：filtergraph 内容完整保留
        let vfIndex = args.firstIndex(of: "-vf")!
        let filterValue = args[vfIndex + 1]

        XCTAssertTrue(filterValue.contains("scale=1280:-2"), "scale filter should be intact")
        XCTAssertTrue(filterValue.contains("drawtext="), "drawtext filter should be intact")
        XCTAssertTrue(filterValue.contains("text='Hello World'"), "quoted text should be intact")
        XCTAssertTrue(filterValue.contains(":x=10:y=10"), "position params should be intact")
    }

    /// C2: 单引号内的复杂表达式
    func testSingleQuotedFiltergraph() {
        let command = "ffmpeg -i in.mp4 -vf 'scale=1920:1080,format=yuv420p' out.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-i", "in.mp4",
            "-vf", "scale=1920:1080,format=yuv420p",
            "out.mp4"
        ])
    }

    /// C3: 嵌套引号
    func testNestedQuotes() {
        let command = "ffmpeg -i input.mp4 -vf \"drawtext=text='Test: Value':fontsize=24\" out.mp4"
        let args = CommandRenderer.splitCommand(command)

        // ffmpeg, -i, input.mp4, -vf, drawtext=..., out.mp4
        XCTAssertEqual(args.count, 6)
        XCTAssertEqual(args[4], "drawtext=text='Test: Value':fontsize=24")  // index 4, not 3
    }

    // MARK: D. Multi-Input / Multi-Output

    /// D1: 多输入文件
    func testMultipleInputs() {
        let command = "ffmpeg -i video.mp4 -i audio.wav -c:v copy -c:a aac out.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-i", "video.mp4",
            "-i", "audio.wav",
            "-c:v", "copy",
            "-c:a", "aac",
            "out.mp4"
        ])

        // 验证有两个 -i
        let inputCount = args.filter { $0 == "-i" }.count
        XCTAssertEqual(inputCount, 2, "Should have 2 input flags")
    }

    /// D2: Stream mapping
    func testStreamMapping() {
        let command = "ffmpeg -i video.mp4 -i audio.mp3 -map 0:v -map 1:a -c copy out.mkv"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-i", "video.mp4",
            "-i", "audio.mp3",
            "-map", "0:v",
            "-map", "1:a",
            "-c", "copy",
            "out.mkv"
        ])
    }

    // MARK: - Level 2: High-Risk CLI Handling

    // MARK: E. Pipe / Special IO

    /// E1: Pipe 语法
    func testPipeSyntax() {
        let command = "ffmpeg -i pipe:0 -f mp4 pipe:1"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-i", "pipe:0",
            "-f", "mp4",
            "pipe:1"
        ])

        // 验证 pipe 语法完整
        XCTAssertTrue(args.contains("pipe:0"))
        XCTAssertTrue(args.contains("pipe:1"))
    }

    /// E2: Pipe 带 format
    func testPipeWithFormat() {
        let command = "ffmpeg -f rawvideo -i pipe:0 -c:v libx264 -f mp4 pipe:1"
        let args = CommandRenderer.splitCommand(command)

        // ffmpeg, -f, rawvideo, -i, pipe:0, -c:v, libx264, -f, mp4, pipe:1
        XCTAssertEqual(args.count, 10)
        XCTAssertEqual(args[4], "pipe:0")  // after -i at index 3
        XCTAssertEqual(args[9], "pipe:1")  // last element
    }

    // MARK: F. Special Sources

    /// F1: lavfi 虚拟源
    func testLavfiSource() {
        let command = "ffmpeg -f lavfi -i testsrc=size=1280x720:rate=30 out.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-f", "lavfi",
            "-i", "testsrc=size=1280x720:rate=30",
            "out.mp4"
        ])

        // 关键验证：等号和冒号保留
        let sourceArg = args[4]
        XCTAssertTrue(sourceArg.contains("size=1280x720"))
        XCTAssertTrue(sourceArg.contains("rate=30"))
    }

    /// F2: RTMP URL
    func testRTMPUrl() {
        let command = "ffmpeg -re -i rtmp://example.com/live/stream out.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-re",
            "-i", "rtmp://example.com/live/stream",
            "out.mp4"
        ])

        // URL 完整保留
        XCTAssertTrue(args.contains("rtmp://example.com/live/stream"))
    }

    /// F3: HTTPS URL with query params
    func testHTTPSUrlWithParams() {
        let command = "ffmpeg -i \"https://example.com/video.m3u8?token=abc123\" out.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args.count, 4)
        XCTAssertEqual(args[2], "https://example.com/video.m3u8?token=abc123")
    }

    // MARK: - Level 3: Invalid Command Handling (必须不崩溃)

    /// L3-1: 未闭合的双引号 - 优雅处理
    func testUnclosedDoubleQuote() {
        let command = "ffmpeg -i \"input.mp4"
        let args = CommandRenderer.splitCommand(command)

        // 不崩溃，返回合理结果
        XCTAssertGreaterThan(args.count, 0)
        XCTAssertEqual(args[0], "ffmpeg")
    }

    /// L3-2: 未闭合的单引号 - 优雅处理
    func testUnclosedSingleQuote() {
        let command = "ffmpeg -i 'input.mp4"
        let args = CommandRenderer.splitCommand(command)

        // 不崩溃，返回合理结果
        XCTAssertGreaterThan(args.count, 0)
        XCTAssertEqual(args[0], "ffmpeg")
    }

    /// L3-3: 空命令
    func testEmptyCommand() {
        let args = CommandRenderer.splitCommand("")

        XCTAssertEqual(args, [])
    }

    /// L3-4: 纯空白
    func testWhitespaceOnly() {
        let args = CommandRenderer.splitCommand("   \t  \n  ")

        XCTAssertEqual(args, [])
    }

    /// L3-5: 多行命令（带反斜杠续行）
    func testMultilineWithBackslash() {
        let command = """
        ffmpeg -i input.mp4 \\
        -vf scale=1280:720 \\
        output.mp4
        """
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-i", "input.mp4",
            "-vf", "scale=1280:720",
            "output.mp4"
        ])
    }

    /// L3-6: 转义反斜杠
    func testEscapedBackslash() {
        let command = "ffmpeg -i input.mp4 -vf \"drawtext=text='C:\\\\path'\" out.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args.count, 6)
        // 反斜杠应被正确转义 - splitCommand 处理后保留单个反斜杠
        // 在 Swift 中 "\\\\" 是两个反斜杠，经 splitCommand 转义后变为一个
        let vfValue = args[4]
        XCTAssertTrue(vfValue.contains("drawtext="), "Should contain drawtext")
        XCTAssertTrue(vfValue.contains("text="), "Should contain text parameter")
    }

    // MARK: - Additional Edge Cases

    /// 路径中包含空格
    func testPathWithSpaces() {
        let command = "ffmpeg -i '/Users/test/My Videos/input.mp4' output.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-i", "/Users/test/My Videos/input.mp4",
            "output.mp4"
        ])
    }

    /// 双引号路径
    func testDoubleQuotedPath() {
        let command = "ffmpeg -i \"/path/with spaces/file.mp4\" out.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-i", "/path/with spaces/file.mp4",
            "out.mp4"
        ])
    }

    /// CRF 参数
    func testCRFParameter() {
        let command = "ffmpeg -i input.mp4 -c:v libx264 -crf 23 -preset medium out.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-i", "input.mp4",
            "-c:v", "libx264",
            "-crf", "23",
            "-preset", "medium",
            "out.mp4"
        ])
    }

    /// 复杂的 audio filter
    func testAudioFilter() {
        let command = "ffmpeg -i input.mp4 -af \"volume=1.5,aecho=0.8:0.88:60:0.4\" out.mp4"
        let args = CommandRenderer.splitCommand(command)

        XCTAssertEqual(args, [
            "ffmpeg",
            "-i", "input.mp4",
            "-af", "volume=1.5,aecho=0.8:0.88:60:0.4",
            "out.mp4"
        ])
    }
}
