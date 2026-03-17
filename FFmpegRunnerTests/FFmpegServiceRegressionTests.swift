import XCTest
@testable import FFmpegRunner

@MainActor
final class FFmpegServiceRegressionTests: XCTestCase {

    func testFastExitProcessDoesNotHang() async throws {
        let settings = snapshotSettings()
        defer { restoreSettings(settings) }

        let truePath = "/usr/bin/true"
        guard FileManager.default.isExecutableFile(atPath: truePath) else {
            throw XCTSkip("Missing executable: \(truePath)")
        }

        let resolver = MockPathResolver(
            bundledPath: nil,
            systemPathValue: nil
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)

        service.setSource(.custom, customPath: truePath)
        try await waitForCondition {
            service.ffmpegPath == truePath
        }

        let executeTask = Task<ExecutionResult, Error> { @MainActor in
            try await service.execute(arguments: [], displayCommand: truePath)
        }
        let result = try await waitForTaskValue(executeTask, timeout: 2.0)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(service.isRunning)
    }

    func testLatestPathUpdateWinsWhenResolvesOutOfOrder() async throws {
        let settings = snapshotSettings()
        defer { restoreSettings(settings) }

        let systemPath = "/mock/system/ffmpeg"
        let customPath = "/mock/custom/ffmpeg"

        let resolver = MockPathResolver(
            bundledPath: nil,
            systemPathValue: systemPath,
            delays: [
                .system: 350_000_000,
                .custom: 20_000_000
            ]
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)

        service.setSource(.system)
        service.setSource(.custom, customPath: customPath)

        try await waitForCondition(timeout: 1.5) {
            service.ffmpegPath == customPath
        }

        // 等待较慢的 system 解析返回，验证不会覆盖最新 custom 结果
        try await Task.sleep(nanoseconds: 450_000_000)

        XCTAssertEqual(service.ffmpegSource, .custom)
        XCTAssertEqual(service.ffmpegPath, customPath)
    }

    func testChangingSourceInvalidatesVersionCache() async throws {
        let settings = snapshotSettings()
        defer { restoreSettings(settings) }

        let bundledScript = try makeExecutableScript(body: """
        #!/bin/sh
        echo "mock-bundled-version"
        """)
        defer { try? FileManager.default.removeItem(atPath: bundledScript) }

        let systemScript = try makeExecutableScript(body: """
        #!/bin/sh
        echo "mock-system-version"
        """)
        defer { try? FileManager.default.removeItem(atPath: systemScript) }

        let resolver = MockPathResolver(
            bundledPath: bundledScript,
            systemPathValue: systemScript
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)

        service.setSource(.bundled)
        try await waitForCondition {
            service.ffmpegPath == bundledScript
        }
        let bundledVersion = try await service.getFFmpegVersion()
        XCTAssertEqual(bundledVersion, "mock-bundled-version")

        // 使用 ffmpegSource 属性切换，覆盖 setter 缓存失效路径
        service.ffmpegSource = .system
        try await waitForCondition {
            service.ffmpegPath == systemScript
        }
        let systemVersion = try await service.getFFmpegVersion()

        XCTAssertEqual(systemVersion, "mock-system-version")
        XCTAssertNotEqual(systemVersion, bundledVersion)
    }

    func testCancelEscalatesToSIGKILLWhenProcessIgnoresSignals() async throws {
        let settings = snapshotSettings()
        defer { restoreSettings(settings) }

        let loopingScript = try makeExecutableScript(body: """
        #!/bin/sh
        trap '' INT TERM
        while true; do
          sleep 1
        done
        """)
        defer { try? FileManager.default.removeItem(atPath: loopingScript) }

        let resolver = MockPathResolver(
            bundledPath: nil,
            systemPathValue: nil
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)

        service.setSource(.custom, customPath: loopingScript)
        try await waitForCondition {
            service.ffmpegPath == loopingScript
        }

        let executionTask = Task<ExecutionResult, Error> { @MainActor in
            try await service.execute(arguments: [], displayCommand: loopingScript)
        }
        defer {
            executionTask.cancel()
            service.cancel()
        }

        try await waitForCondition(timeout: 2.0) {
            service.isRunning && service.currentProcess != nil
        }

        service.cancel()

        let result = try await waitForTaskValue(executionTask, timeout: 8.0)

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(service.isRunning)
    }

    func testExecuteFFprobeUsesRequestedExecutable() async throws {
        let settings = snapshotSettings()
        defer { restoreSettings(settings) }

        let ffmpegScript = try makeExecutableScript(body: """
        #!/bin/sh
        echo "ffmpeg-script"
        exit 7
        """)
        defer { try? FileManager.default.removeItem(atPath: ffmpegScript) }

        let ffprobeScript = try makeExecutableScript(body: """
        #!/bin/sh
        echo "ffprobe-script"
        exit 0
        """)
        defer { try? FileManager.default.removeItem(atPath: ffprobeScript) }

        let resolver = MockPathResolver(
            bundledPath: nil,
            systemPathValue: nil
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)

        UserSettings.shared.ffprobePath = ffprobeScript
        service.setSource(.custom, customPath: ffmpegScript)
        try await waitForCondition {
            service.ffmpegPath == ffmpegScript
        }

        let result = try await service.execute(
            arguments: ["-version"],
            displayCommand: "ffprobe -version",
            executable: .ffprobe
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "ffprobe-script")
    }

    func testExecutePreservesArgumentsWithoutImplicitMutation() async throws {
        let settings = snapshotSettings()
        defer { restoreSettings(settings) }

        let argsScript = try makeExecutableScript(body: """
        #!/bin/sh
        for arg in "$@"; do
          printf '%s\\n' "$arg"
        done
        """)
        defer { try? FileManager.default.removeItem(atPath: argsScript) }

        let resolver = MockPathResolver(
            bundledPath: nil,
            systemPathValue: nil
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)

        service.setSource(.custom, customPath: argsScript)
        try await waitForCondition {
            service.ffmpegPath == argsScript
        }

        let result = try await service.execute(
            arguments: ["-nostdin", "-i", "input.mp4"],
            displayCommand: "ffmpeg -nostdin -i input.mp4"
        )

        let lines = result.standardOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(lines, ["-nostdin", "-i", "input.mp4"])
    }

    func testLogsKeepStdoutAndStderrSeparatedForTrailingLines() async throws {
        let settings = snapshotSettings()
        defer { restoreSettings(settings) }

        let loggingScript = try makeExecutableScript(body: """
        #!/bin/sh
        printf 'stdout-tail'
        printf 'stderr-tail' >&2
        """)
        defer { try? FileManager.default.removeItem(atPath: loggingScript) }

        let resolver = MockPathResolver(
            bundledPath: nil,
            systemPathValue: nil
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)
        var capturedLogs: [LogEntry] = []
        service.onLogOutput = { entry in
            capturedLogs.append(entry)
        }

        service.setSource(.custom, customPath: loggingScript)
        try await waitForCondition {
            service.ffmpegPath == loggingScript
        }

        _ = try await service.execute(arguments: [], displayCommand: loggingScript)

        try await waitForCondition(timeout: 1.0) {
            capturedLogs.contains(where: { $0.message == "stdout-tail" }) &&
            capturedLogs.contains(where: { $0.message == "stderr-tail" })
        }

        let stdoutLog = try XCTUnwrap(capturedLogs.first(where: { $0.message == "stdout-tail" }))
        let stderrLog = try XCTUnwrap(capturedLogs.first(where: { $0.message == "stderr-tail" }))
        XCTAssertFalse(stdoutLog.isStderr)
        XCTAssertTrue(stderrLog.isStderr)
        XCTAssertEqual(stdoutLog.level, .info)
        XCTAssertEqual(stderrLog.level, .info)
    }

    func testProcessLoggerOnlyElevatesStderrWhenSemanticsRequireIt() async throws {
        let logger = ProcessLogger()
        logger.callbackQueue = .main

        var capturedLogs: [LogEntry] = []
        let logsExpectation = expectation(description: "process logger emits semantic levels")
        logsExpectation.expectedFulfillmentCount = 3

        logger.onLog = { entry in
            capturedLogs.append(entry)
            logsExpectation.fulfill()
        }

        logger.processOutput("muxing overhead: 0.65%\n", isError: true)
        logger.processOutput("deprecated option used\n", isError: true)
        logger.processOutput("Error opening input file\n", isError: true)

        await fulfillment(of: [logsExpectation], timeout: 1.0)

        let muxingLog = try XCTUnwrap(capturedLogs.first(where: { $0.message == "muxing overhead: 0.65%" }))
        let deprecatedLog = try XCTUnwrap(capturedLogs.first(where: { $0.message == "deprecated option used" }))
        let errorLog = try XCTUnwrap(capturedLogs.first(where: { $0.message == "Error opening input file" }))

        XCTAssertEqual(muxingLog.level, .info)
        XCTAssertEqual(deprecatedLog.level, .warning)
        XCTAssertEqual(errorLog.level, .error)
    }

    func testExecutionControllerTracksAsyncSystemPathResolution() async throws {
        let settings = snapshotSettings()
        defer { restoreSettings(settings) }

        let systemScript = try makeExecutableScript(body: """
        #!/bin/sh
        echo "ffmpeg version controller-system"
        """)
        defer { try? FileManager.default.removeItem(atPath: systemScript) }

        UserSettings.shared.ffmpegSource = .system
        UserSettings.shared.customFFmpegPath = ""

        let resolver = MockPathResolver(
            bundledPath: nil,
            systemPathValue: systemScript,
            delays: [.system: 150_000_000]
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)
        let controller = ExecutionController(ffmpegService: service)

        try await waitForCondition(timeout: 2.0) {
            controller.isFFmpegAvailable &&
            controller.ffmpegVersion == "ffmpeg version controller-system"
        }
    }

    // MARK: - Helpers

    private func snapshotSettings() -> (source: FFmpegSource, customPath: String, ffprobePath: String) {
        (
            UserSettings.shared.ffmpegSource,
            UserSettings.shared.customFFmpegPath,
            UserSettings.shared.ffprobePath
        )
    }

    private func restoreSettings(_ snapshot: (source: FFmpegSource, customPath: String, ffprobePath: String)) {
        UserSettings.shared.ffmpegSource = snapshot.source
        UserSettings.shared.customFFmpegPath = snapshot.customPath
        UserSettings.shared.ffprobePath = snapshot.ffprobePath
    }

    private func waitForCondition(
        timeout: TimeInterval = 1.0,
        pollNanoseconds: UInt64 = 20_000_000,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        XCTFail("Timed out waiting for condition")
        throw TimeoutError()
    }

    private func waitForTaskValue<T>(
        _ task: Task<T, Error>,
        timeout: TimeInterval
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await task.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                task.cancel()
                throw TimeoutError()
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func makeExecutableScript(body: String) throws -> String {
        let name = "ffmpeg-service-regression-\(UUID().uuidString).sh"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}

private struct TimeoutError: Error {}

private actor MockPathResolver: FFmpegPathProviding {
    nonisolated let bundledPath: String?

    private let systemPathValue: String?
    private let delays: [FFmpegSource: UInt64]

    init(
        bundledPath: String?,
        systemPathValue: String?,
        delays: [FFmpegSource: UInt64] = [:]
    ) {
        self.bundledPath = bundledPath
        self.systemPathValue = systemPathValue
        self.delays = delays
    }

    var systemPath: String? {
        get async {
            if let delay = delays[.system] {
                try? await Task.sleep(nanoseconds: delay)
            }
            return systemPathValue
        }
    }

    func resolvePath(for source: FFmpegSource, customPath: String?) async -> String? {
        if let delay = delays[source] {
            try? await Task.sleep(nanoseconds: delay)
        }

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
        true
    }

    func invalidateCache() {}
}
