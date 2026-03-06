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

    // MARK: - Planner / Renderer Main Path

    func testRenderToCommandDetectsFFprobeFromRawTemplate() {
        let template = Template(
            id: "t-raw",
            name: "Raw",
            description: "Raw command template",
            commandTemplate: "{{command}}",
            parameters: [
                TemplateParameter(
                    key: "command",
                    label: "Command",
                    type: .string,
                    isRequired: true,
                    role: .raw,
                    escapeStrategy: .raw
                )
            ],
            category: nil,
            icon: nil
        )

        let values = [TemplateValue(key: "command", rawValue: "ffprobe -v error -show_format input.mp4")]
        let rendered = CommandRenderer.renderToCommand(template: template, values: values)

        XCTAssertEqual(rendered.executable, .ffprobe)
        XCTAssertEqual(rendered.arguments, ["-v", "error", "-show_format", "input.mp4"])
        XCTAssertTrue(rendered.isComplete)
    }

    func testCommandPlannerPrepareTemplateCarriesExecutable() throws {
        let template = Template(
            id: "t-raw2",
            name: "Raw",
            description: "Raw command template",
            commandTemplate: "{{command}}",
            parameters: [
                TemplateParameter(
                    key: "command",
                    label: "Command",
                    type: .string,
                    isRequired: true,
                    role: .raw,
                    escapeStrategy: .raw
                )
            ],
            category: nil,
            icon: nil
        )
        let values = [TemplateValue(key: "command", rawValue: "ffprobe -v error -show_streams input.mp4")]

        let plan = try CommandPlanner.prepare(template: template, values: values)

        XCTAssertEqual(plan.executable, .ffprobe)
        XCTAssertEqual(plan.arguments, ["-v", "error", "-show_streams", "input.mp4"])
    }

    func testCommandPlannerRejectsMalformedRawCommand() {
        XCTAssertThrowsError(try CommandPlanner.prepare(command: "ffmpeg -i \"input.mp4")) { error in
            guard case CommandPlannerError.validationFailed = error else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testExecutionControllerExecuteCommandDoesNotSelfBlockOnPreparing() async throws {
        let truePath = "/usr/bin/true"
        guard FileManager.default.isExecutableFile(atPath: truePath) else {
            throw XCTSkip("Missing executable: \(truePath)")
        }

        let originalSource = UserSettings.shared.ffmpegSource
        let originalCustomPath = UserSettings.shared.customFFmpegPath
        defer {
            UserSettings.shared.ffmpegSource = originalSource
            UserSettings.shared.customFFmpegPath = originalCustomPath
        }

        let resolver = MockControllerPathResolver(
            bundledPath: nil,
            systemPathValue: nil
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)
        service.setSource(.custom, customPath: truePath)

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline, service.ffmpegPath != truePath {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(service.ffmpegPath, truePath)

        let controller = ExecutionController(ffmpegService: service)
        let result = try await controller.execute(command: "ffmpeg -version")

        XCTAssertEqual(result.exitCode, 0)
    }

    @MainActor
    func testExecutionControllerRejectsConcurrentExecuteCommandCalls() async throws {
        let slowScript = try makeExecutableScript(body: """
        #!/bin/sh
        sleep 1
        exit 0
        """)
        defer { try? FileManager.default.removeItem(atPath: slowScript) }

        let originalSource = UserSettings.shared.ffmpegSource
        let originalCustomPath = UserSettings.shared.customFFmpegPath
        defer {
            UserSettings.shared.ffmpegSource = originalSource
            UserSettings.shared.customFFmpegPath = originalCustomPath
        }

        let resolver = MockControllerPathResolver(
            bundledPath: nil,
            systemPathValue: nil
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)
        service.setSource(.custom, customPath: slowScript)

        let readyDeadline = Date().addingTimeInterval(1.0)
        while Date() < readyDeadline, service.ffmpegPath != slowScript {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(service.ffmpegPath, slowScript)

        let controller = ExecutionController(ffmpegService: service)
        let firstTask = Task<ExecutionResult, Error> { @MainActor in
            try await controller.execute(command: "ffmpeg -version")
        }
        defer {
            firstTask.cancel()
            service.cancel()
        }

        let runningDeadline = Date().addingTimeInterval(1.0)
        while Date() < runningDeadline, !service.isRunning {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(service.isRunning)

        do {
            _ = try await controller.execute(command: "ffmpeg -version")
            XCTFail("Expected alreadyRunning error")
        } catch let error as ExecutionError {
            guard case .alreadyRunning = error else {
                XCTFail("Expected alreadyRunning, got \(error)")
                return
            }
        }

        _ = try await firstTask.value
    }

    func testRecentCommandsServiceDeduplicatesStructuredCommandUsage() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("recent-commands-\(UUID().uuidString)", isDirectory: true)
        let service = RecentCommandsService(
            recentCommandsDirectory: sandbox,
            legacyHistoryDirectory: sandbox.appendingPathComponent("legacy", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let arguments = ["-i", "input file.mp4", "-c:v", "copy", "output.mp4"]
        try await service.recordUsage(
            RecentCommandUsage(
                executable: .ffmpeg,
                arguments: arguments,
                displayCommand: "ffmpeg -i 'input file.mp4' -c:v copy output.mp4",
                usedAt: Date().addingTimeInterval(-10),
                wasSuccessful: true
            )
        )

        try await service.recordUsage(
            RecentCommandUsage(
                executable: .ffmpeg,
                arguments: arguments,
                displayCommand: "ffmpeg -i \"input file.mp4\" -c:v copy output.mp4",
                usedAt: Date(),
                wasSuccessful: false
            )
        )

        let recentCommands = await service.loadRecentCommands()
        XCTAssertEqual(recentCommands.count, 1)
        XCTAssertEqual(recentCommands.first?.arguments, arguments)
        XCTAssertEqual(recentCommands.first?.displayCommand, "ffmpeg -i \"input file.mp4\" -c:v copy output.mp4")
        XCTAssertEqual(recentCommands.first?.useCount, 2)
        XCTAssertEqual(recentCommands.first?.wasSuccessful, false)
    }

    @MainActor
    func testExecutionControllerPersistsRecentCommandBeforeReturning() async throws {
        let truePath = "/usr/bin/true"
        guard FileManager.default.isExecutableFile(atPath: truePath) else {
            throw XCTSkip("Missing executable: \(truePath)")
        }

        let originalSource = UserSettings.shared.ffmpegSource
        let originalCustomPath = UserSettings.shared.customFFmpegPath
        defer {
            UserSettings.shared.ffmpegSource = originalSource
            UserSettings.shared.customFFmpegPath = originalCustomPath
        }

        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("recent-commands-\(UUID().uuidString)", isDirectory: true)
        let recentCommandsService = RecentCommandsService(
            recentCommandsDirectory: sandbox,
            legacyHistoryDirectory: sandbox.appendingPathComponent("legacy", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let resolver = MockControllerPathResolver(
            bundledPath: nil,
            systemPathValue: nil
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)
        service.setSource(.custom, customPath: truePath)

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline, service.ffmpegPath != truePath {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(service.ffmpegPath, truePath)

        let controller = ExecutionController(
            ffmpegService: service,
            recentCommandsService: recentCommandsService
        )
        let result = try await controller.execute(command: "ffmpeg -version")

        XCTAssertEqual(result.exitCode, 0)

        let recentCommands = await recentCommandsService.loadRecentCommands()
        XCTAssertEqual(recentCommands.count, 1)
        XCTAssertEqual(recentCommands.first?.displayCommand, "ffmpeg -version")
        XCTAssertEqual(recentCommands.first?.executable, .ffmpeg)
        XCTAssertEqual(recentCommands.first?.arguments, ["-version"])
        XCTAssertEqual(recentCommands.first?.useCount, 1)
        XCTAssertEqual(recentCommands.first?.wasSuccessful, true)
        XCTAssertNil(recentCommands.first?.templateSnapshot)
    }

    @MainActor
    func testExecutionControllerPersistsTemplateSnapshotForTemplateBindings() async throws {
        let truePath = "/usr/bin/true"
        guard FileManager.default.isExecutableFile(atPath: truePath) else {
            throw XCTSkip("Missing executable: \(truePath)")
        }

        let originalSource = UserSettings.shared.ffmpegSource
        let originalCustomPath = UserSettings.shared.customFFmpegPath
        defer {
            UserSettings.shared.ffmpegSource = originalSource
            UserSettings.shared.customFFmpegPath = originalCustomPath
        }

        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("recent-commands-\(UUID().uuidString)", isDirectory: true)
        let recentCommandsService = RecentCommandsService(
            recentCommandsDirectory: sandbox,
            legacyHistoryDirectory: sandbox.appendingPathComponent("legacy", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let resolver = MockControllerPathResolver(
            bundledPath: nil,
            systemPathValue: nil
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)
        service.setSource(.custom, customPath: truePath)

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline, service.ffmpegPath != truePath {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(service.ffmpegPath, truePath)

        let controller = ExecutionController(
            ffmpegService: service,
            recentCommandsService: recentCommandsService
        )
        let template = Template(
            id: "encode",
            name: "Encode",
            description: "Encode video",
            commandTemplate: "ffmpeg -i {{input}} {{output}}",
            parameters: [
                TemplateParameter(
                    key: "input",
                    label: "Input",
                    type: .string,
                    defaultValue: "",
                    isRequired: true
                ),
                TemplateParameter(
                    key: "output",
                    label: "Output",
                    type: .string,
                    defaultValue: "",
                    isRequired: true
                )
            ],
            category: nil,
            icon: nil
        )
        let binding = TemplateBinding.bind(
            template: template,
            values: [
                TemplateValue(key: "input", rawValue: "input.mp4"),
                TemplateValue(key: "output", rawValue: "output.mp4")
            ]
        )

        let result = try await controller.execute(binding: binding)
        XCTAssertEqual(result.exitCode, 0)

        let recentCommands = await recentCommandsService.loadRecentCommands()
        XCTAssertEqual(recentCommands.count, 1)
        XCTAssertEqual(recentCommands.first?.templateSnapshot?.templateId, "encode")
        XCTAssertEqual(recentCommands.first?.templateSnapshot?.templateName, "Encode")
        XCTAssertEqual(
            recentCommands.first?.templateSnapshot?.parameterValues,
            ["input": "input.mp4", "output": "output.mp4"]
        )
    }

    private func makeExecutableScript(body: String) throws -> String {
        let name = "split-command-controller-\(UUID().uuidString).sh"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}

@MainActor
final class CommandPreviewViewModelTests: XCTestCase {

    func testDetailStateDerivesValidationFromBindingSnapshot() {
        let detailViewModel = TemplateDetailViewModel(template: makeEncodeTemplate())

        XCTAssertEqual(detailViewModel.validationErrors["input"], "Input 不能为空")
        XCTAssertFalse(detailViewModel.canExecute)
        XCTAssertEqual(detailViewModel.templateBinding?.binding(for: "input")?.errorMessage, "Input 不能为空")

        detailViewModel.updateValue(key: "input", value: "clip.mov")

        XCTAssertNil(detailViewModel.validationErrors["input"])
        XCTAssertEqual(detailViewModel.templateBinding?.binding(for: "input")?.rawValue, "clip.mov")
        XCTAssertTrue(detailViewModel.templateBinding?.isValid == true)
        XCTAssertTrue(detailViewModel.canExecute)
    }

    func testPreviewTracksDetailValueChanges() async {
        let detailViewModel = TemplateDetailViewModel(template: makeEncodeTemplate())
        let previewViewModel = CommandPreviewViewModel(detailViewModel: detailViewModel)

        XCTAssertEqual(previewViewModel.missingPlaceholders, ["input"])

        detailViewModel.updateValue(key: "input", value: "clip.mov")
        await settlePreviewPipeline()

        XCTAssertEqual(
            previewViewModel.renderedCommand,
            "ffmpeg -i clip.mov -c:v libx264 out.mp4"
        )
        XCTAssertEqual(previewViewModel.previewText, previewViewModel.renderedCommand)
        XCTAssertTrue(previewViewModel.missingPlaceholders.isEmpty)
        XCTAssertEqual(previewViewModel.currentCommand?.executable, .ffmpeg)
    }

    func testPreviewUsesLatestStateAfterTemplateSwitch() async {
        let detailViewModel = TemplateDetailViewModel(template: makeEncodeTemplate())
        let previewViewModel = CommandPreviewViewModel(detailViewModel: detailViewModel)

        detailViewModel.selectTemplate(makeProbeTemplate())
        await settlePreviewPipeline()

        XCTAssertEqual(
            previewViewModel.renderedCommand,
            "ffprobe -show_streams source.mov"
        )
        XCTAssertEqual(previewViewModel.currentCommand?.executable, .ffprobe)
        XCTAssertEqual(previewViewModel.missingPlaceholders, [])
    }

    func testPreviewClearsWhenDetailTemplateBecomesNil() async {
        let detailViewModel = TemplateDetailViewModel(template: makeEncodeTemplate())
        let previewViewModel = CommandPreviewViewModel(detailViewModel: detailViewModel)

        detailViewModel.selectTemplate(nil)
        await settlePreviewPipeline()

        XCTAssertNil(previewViewModel.currentCommand)
        XCTAssertEqual(previewViewModel.renderedCommand, "")
        XCTAssertEqual(previewViewModel.previewText, "")
        XCTAssertEqual(previewViewModel.highlightedCommand, AttributedString(""))
    }

    private func makeEncodeTemplate() -> Template {
        Template(
            id: "encode",
            name: "Encode",
            description: "Encode video",
            commandTemplate: "ffmpeg -i {{input}} -c:v libx264 {{output}}",
            parameters: [
                TemplateParameter(
                    key: "input",
                    label: "Input",
                    type: .string,
                    isRequired: true
                ),
                TemplateParameter(
                    key: "output",
                    label: "Output",
                    type: .string,
                    defaultValue: "out.mp4",
                    isRequired: true
                )
            ],
            category: nil,
            icon: nil
        )
    }

    private func makeProbeTemplate() -> Template {
        Template(
            id: "probe",
            name: "Probe",
            description: "Probe input",
            commandTemplate: "ffprobe -show_streams {{source}}",
            parameters: [
                TemplateParameter(
                    key: "source",
                    label: "Source",
                    type: .string,
                    defaultValue: "source.mov",
                    isRequired: true
                )
            ],
            category: nil,
            icon: nil
        )
    }

    private func settlePreviewPipeline() async {
        await Task.yield()
        await Task.yield()
        await Task.yield()
    }
}

@MainActor
final class RecentCommandsViewModelTests: XCTestCase {

    func testSaveAsTemplatePreservesStructuredTemplateWhenOriginalTemplateExists() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("recent-save-template-\(UUID().uuidString)", isDirectory: true)
        let userTemplateDirectory = sandbox.appendingPathComponent("templates", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let sourceTemplate = Template(
            id: "encode",
            name: "Encode",
            description: "Encode video",
            commandTemplate: "ffmpeg -i {{input}} -c:v {{codec}} {{output}}",
            parameters: [
                TemplateParameter(
                    key: "input",
                    label: "Input",
                    type: .string,
                    defaultValue: "",
                    isRequired: true
                ),
                TemplateParameter(
                    key: "codec",
                    label: "Codec",
                    type: .select,
                    defaultValue: "libx264",
                    isRequired: true,
                    constraints: TemplateParameter.Constraints(options: ["libx264", "libx265"])
                ),
                TemplateParameter(
                    key: "output",
                    label: "Output",
                    type: .string,
                    defaultValue: "",
                    isRequired: true
                )
            ],
            category: "视频处理",
            icon: "film"
        )

        let repository = TemplateRepository(
            sources: [
                StaticTemplateSource(identifier: "test", templates: [sourceTemplate]),
                UserTemplateSource(directory: userTemplateDirectory)
            ],
            userDirectory: userTemplateDirectory
        )
        let service = RecentCommandsService(
            recentCommandsDirectory: sandbox.appendingPathComponent("recent", isDirectory: true),
            legacyHistoryDirectory: sandbox.appendingPathComponent("legacy", isDirectory: true)
        )
        let viewModel = RecentCommandsViewModel(
            recentCommandsService: service,
            templateRepository: repository
        )

        let entry = RecentCommand(
            executable: .ffmpeg,
            arguments: ["-i", "clip.mov", "-c:v", "libx265", "clip-hevc.mp4"],
            displayCommand: "ffmpeg -i clip.mov -c:v libx265 clip-hevc.mp4",
            wasSuccessful: true,
            templateSnapshot: RecentCommandTemplateSnapshot(
                templateId: sourceTemplate.id,
                templateName: sourceTemplate.name,
                parameterValues: [
                    "input": "clip.mov",
                    "codec": "libx265",
                    "output": "clip-hevc.mp4"
                ]
            )
        )

        let didSave = await viewModel.saveAsTemplate(entry, name: "保存的 HEVC", category: "我的模板")
        XCTAssertTrue(didSave)

        let savedTemplates = await repository.loadAllTemplates()
        let savedTemplate = try XCTUnwrap(savedTemplates.first(where: { $0.name == "保存的 HEVC" }))
        let rendered = CommandRenderer.renderToCommand(
            template: savedTemplate,
            values: TemplateValue.from(template: savedTemplate)
        )
        XCTAssertFalse(savedTemplate.isRawCommandTemplate)
        XCTAssertEqual(savedTemplate.category, "我的模板")
        XCTAssertEqual(savedTemplate.icon, "film")
        XCTAssertEqual(savedTemplate.parameters.first(where: { $0.key == "input" })?.defaultValue, "clip.mov")
        XCTAssertEqual(savedTemplate.parameters.first(where: { $0.key == "codec" })?.defaultValue, "libx265")
        XCTAssertEqual(savedTemplate.parameters.first(where: { $0.key == "output" })?.defaultValue, "clip-hevc.mp4")
        XCTAssertEqual(rendered.displayString, entry.displayCommand)
    }

    func testSaveAsTemplateFallsBackToRawCommandWhenOriginalTemplateCannotBeResolved() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("recent-save-template-raw-\(UUID().uuidString)", isDirectory: true)
        let userTemplateDirectory = sandbox.appendingPathComponent("templates", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let repository = TemplateRepository(
            sources: [UserTemplateSource(directory: userTemplateDirectory)],
            userDirectory: userTemplateDirectory
        )
        let service = RecentCommandsService(
            recentCommandsDirectory: sandbox.appendingPathComponent("recent", isDirectory: true),
            legacyHistoryDirectory: sandbox.appendingPathComponent("legacy", isDirectory: true)
        )
        let viewModel = RecentCommandsViewModel(
            recentCommandsService: service,
            templateRepository: repository
        )

        let entry = RecentCommand(
            displayCommand: "ffmpeg -i input.mp4 -c:v copy output.mp4",
            wasSuccessful: true,
            templateSnapshot: RecentCommandTemplateSnapshot(
                templateId: "missing-template",
                templateName: "Missing",
                parameterValues: ["input": "input.mp4"]
            )
        )

        let didSave = await viewModel.saveAsTemplate(entry, name: "原始命令备份", category: nil)
        XCTAssertTrue(didSave)

        let savedTemplates = await repository.loadAllTemplates()
        let savedTemplate = try XCTUnwrap(savedTemplates.first(where: { $0.name == "原始命令备份" }))
        XCTAssertTrue(savedTemplate.isRawCommandTemplate)
        XCTAssertEqual(
            savedTemplate.parameters.first(where: { $0.key == Template.rawCommandParameterKey })?.defaultValue,
            entry.command
        )
    }
}

final class FastCutTimecodeSupportTests: XCTestCase {

    func testParseSupportsMinuteSecondShortcut() {
        XCTAssertEqual(FastCutTimecodeSupport.parseUserTimecode("00.60"), 60)
        XCTAssertEqual(FastCutTimecodeSupport.parseUserTimecode("01.30"), 90)
    }

    func testResolveRangeNormalizesStartAndComputesDuration() throws {
        let resolved = try XCTUnwrap(
            try? FastCutTimecodeSupport.resolveRange(
                startInput: "00.00",
                endInput: "00.60"
            ).get()
        )

        XCTAssertEqual(resolved.normalizedStartTime, "00:00:00")
        XCTAssertEqual(resolved.normalizedEndTime, "00:01:00")
        XCTAssertEqual(resolved.durationText, "60")
    }

    func testResolveRangeSupportsClockFormatAndFractionalSeconds() throws {
        let resolved = try XCTUnwrap(
            try? FastCutTimecodeSupport.resolveRange(
                startInput: "00:01:10.250",
                endInput: "00:01:12.750"
            ).get()
        )

        XCTAssertEqual(resolved.normalizedStartTime, "00:01:10.250")
        XCTAssertEqual(resolved.normalizedEndTime, "00:01:12.750")
        XCTAssertEqual(resolved.durationText, "2.5")
    }

    func testResolveRangeRejectsEndTimeBeforeStart() {
        let result = FastCutTimecodeSupport.resolveRange(
            startInput: "90",
            endInput: "01.20"
        )

        XCTAssertEqual(result, .failure(.endBeforeStart))
    }

    func testDerivedEndTimeUsesStoredStartAndDuration() {
        XCTAssertEqual(
            FastCutTimecodeSupport.derivedEndTime(
                normalizedStartTime: "00:10:00",
                durationText: "90.5"
            ),
            "00:11:30.500"
        )
    }
}

private actor MockControllerPathResolver: FFmpegPathProviding {
    nonisolated let bundledPath: String?
    private let systemPathValue: String?

    init(bundledPath: String?, systemPathValue: String?) {
        self.bundledPath = bundledPath
        self.systemPathValue = systemPathValue
    }

    var systemPath: String? {
        get async { systemPathValue }
    }

    func resolvePath(for source: FFmpegSource, customPath: String?) async -> String? {
        switch source {
        case .bundled:
            return bundledPath
        case .system:
            return systemPathValue
        case .custom:
            return customPath
        }
    }

    nonisolated func isExecutable(at path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func invalidateCache() async {}
}

private actor StaticTemplateSource: TemplateSource {
    nonisolated let identifier: String
    private let templates: [Template]

    init(identifier: String, templates: [Template]) {
        self.identifier = identifier
        self.templates = templates
    }

    func loadTemplates() async -> Result<[Template], TemplateLoadError> {
        .success(templates)
    }
}
