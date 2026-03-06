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

        let ffprobeScript = try makeExecutableScript(body: """
        #!/bin/sh
        exit 0
        """)
        defer { try? FileManager.default.removeItem(atPath: ffprobeScript) }

        let resolver = MockPathResolver(
            bundledPath: nil,
            systemPathValue: nil
        )
        let service = FFmpegService.makeForTesting(pathResolver: resolver)

        service.setSource(.custom, customPath: ffprobeScript)
        try await waitForCondition {
            service.ffmpegPath == ffprobeScript
        }

        let result = try await service.execute(
            arguments: [],
            displayCommand: ffprobeScript,
            executable: .ffprobe
        )

        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Helpers

    private func snapshotSettings() -> (source: FFmpegSource, customPath: String) {
        (UserSettings.shared.ffmpegSource, UserSettings.shared.customFFmpegPath)
    }

    private func restoreSettings(_ snapshot: (source: FFmpegSource, customPath: String)) {
        UserSettings.shared.ffmpegSource = snapshot.source
        UserSettings.shared.customFFmpegPath = snapshot.customPath
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
