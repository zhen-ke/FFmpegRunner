//
//  FFmpegService.swift
//  FFmpegRunner
//
//  FFmpeg 执行服务
//

import Foundation
import os

/// FFmpeg 来源类型
enum FFmpegSource: String, CaseIterable, Codable, Sendable {
    /// 使用 App 内置的二进制文件
    case bundled = "bundled"
    /// 使用系统安装的 FFmpeg
    case system = "system"
    /// 使用自定义路径
    case custom = "custom"

    var displayName: String {
        switch self {
        case .bundled: return "内置二进制"
        case .system: return "系统安装"
        case .custom: return "自定义路径"
        }
    }
}

/// FFmpeg 执行服务
/// - Responsibility:
///   - Execute prepared ffmpeg arguments
///   - Manage process lifecycle (isRunning, currentProcess)
///   - Handle cancellation with graceful shutdown (stdin "q" → SIGTERM → SIGKILL)
/// - Non-responsibility:
///   - Command parsing (use CommandRenderer)
///   - Template binding (use CommandRenderer)
///   - Path resolution (delegated to FFmpegPathResolver)
@MainActor
class FFmpegService: ObservableObject {

    // MARK: - Singleton

    // NOTE: First access must happen on @MainActor (Swift 6 requirement).
    // Thread safety is generally handled by @MainActor on the class.
    static let shared = FFmpegService()

#if DEBUG
    /// 测试用工厂：允许注入 mock resolver 验证并发与取消边界条件
    static func makeForTesting(pathResolver: FFmpegPathProviding) -> FFmpegService {
        FFmpegService(pathResolver: pathResolver)
    }
#endif

    // MARK: - Published Properties

    @Published private(set) var isRunning = false
    @Published private(set) var currentProcess: Process?

    /// 当前执行任务的唯一标识，防止并发取消时的误杀
    private var activeTaskId: UUID?

    /// 当前执行会话（封装一次 Process 执行的资源与取消逻辑）
    private var currentSession: ProcessExecutionSession?

    /// 系统 FFmpeg 路径的缓存（用于 UI 展示）
    @Published private(set) var cachedSystemPath: String?

    /// FFmpeg 来源：从 UserSettings 读取，统一数据源
    var ffmpegSource: FFmpegSource {
        get { UserSettings.shared.ffmpegSource }
        set {
            UserSettings.shared.ffmpegSource = newValue
            applyImmediateResolvedPaths()
            objectWillChange.send()
            Task { await updateResolvedPathsAsync() }
        }
    }

    // MARK: - Properties

    /// 日志回调
    var onLogOutput: ((LogEntry) -> Void)?

    /// 当前使用的 FFmpeg 路径
    @Published private(set) var ffmpegPath: String = ""

    /// 当前使用的 FFprobe 路径
    @Published private(set) var ffprobePath: String = ""

    /// 自定义 FFmpeg 路径：从 UserSettings 读取，统一数据源
    var customFFmpegPath: String {
        get { UserSettings.shared.customFFmpegPath }
        set {
            UserSettings.shared.customFFmpegPath = newValue
            if ffmpegSource == .custom {
                applyImmediateResolvedPaths()
                Task { await updateResolvedPathsAsync() }
            }
        }
    }

    /// 路径解析器（依赖注入）
    private let pathResolver: FFmpegPathProviding

    /// 内置 FFmpeg 路径（委托给 pathResolver，同步访问）
    var bundledFFmpegPath: String? {
        pathResolver.bundledPath
    }

    /// 显式配置的 ffprobe 路径（可为空；为空时走 sibling / fallback 推导）
    private var configuredFFprobePath: String {
        UserSettings.shared.ffprobePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Initialization

    private init(pathResolver: FFmpegPathProviding = FFmpegPathResolver()) {
        self.pathResolver = pathResolver

        applyImmediateResolvedPaths()

        // 延迟异步初始化（避免阻塞主线程）
        Task { await initializePathAsync() }
    }

    /// 异步初始化路径（处理需要 I/O 的情况）
    private func initializePathAsync() async {
        let currentSource = UserSettings.shared.ffmpegSource

        // 如果选择了 bundled 但不可用，尝试切换到 system
        if currentSource == .bundled && pathResolver.bundledPath == nil {
            if await pathResolver.systemPath != nil {
                UserSettings.shared.ffmpegSource = .system
            }
        }

        applyImmediateResolvedPaths()
        await updateResolvedPathsAsync()
    }

    // MARK: - Path Management

    /// 同步更新当前配置可直接推导出的路径，避免 UI 长时间停留在旧状态
    private func applyImmediateResolvedPaths() {
        let resolvedFFmpegPath: String
        switch ffmpegSource {
        case .bundled:
            resolvedFFmpegPath = bundledFFmpegPath ?? ""
        case .system:
            resolvedFFmpegPath = cachedSystemPath ?? ""
        case .custom:
            resolvedFFmpegPath = customFFmpegPath
        }

        let resolvedFFprobePath = resolveFFprobePath(
            ffmpegCandidatePath: resolvedFFmpegPath,
            preferredFFprobePath: configuredFFprobePath
        ) ?? ""

        if ffmpegPath != resolvedFFmpegPath {
            ffmpegPath = resolvedFFmpegPath
        }
        if ffprobePath != resolvedFFprobePath {
            ffprobePath = resolvedFFprobePath
        }
    }

    /// 异步更新 FFmpeg / FFprobe 路径
    private func updateResolvedPathsAsync() async {
        let sourceSnapshot = ffmpegSource
        let customPathSnapshot = customFFmpegPath
        let configuredFFprobePathSnapshot = configuredFFprobePath
        pathUpdateGeneration &+= 1
        let generation = pathUpdateGeneration

        let resolvedFFmpegPath = await pathResolver.resolvePath(
            for: sourceSnapshot,
            customPath: customPathSnapshot
        ) ?? ""
        let resolvedFFprobePath = resolveFFprobePath(
            ffmpegCandidatePath: resolvedFFmpegPath,
            preferredFFprobePath: configuredFFprobePathSnapshot
        ) ?? ""

        // 丢弃过时任务结果，避免快速切换来源时旧结果覆盖新状态
        guard generation == pathUpdateGeneration else { return }
        ffmpegPath = resolvedFFmpegPath
        ffprobePath = resolvedFFprobePath

        // 同时更新缓存的系统路径
        if sourceSnapshot == .system {
            cachedSystemPath = resolvedFFmpegPath.isEmpty ? nil : resolvedFFmpegPath
        }
    }

    // MARK: - Public Methods

    /// 查找系统中的 FFmpeg（异步）
    func findSystemFFmpeg() async -> String? {
        let path = await pathResolver.systemPath
        cachedSystemPath = path
        if ffmpegSource == .system {
            ffmpegPath = path ?? ""
            ffprobePath = resolveFFprobePath(
                ffmpegCandidatePath: ffmpegPath,
                preferredFFprobePath: configuredFFprobePath
            ) ?? ""
        }
        return path
    }

    /// 检查内置 FFmpeg 是否可用
    var isBundledFFmpegAvailable: Bool {
        bundledFFmpegPath != nil
    }

    /// 检查系统 FFmpeg 是否可用（异步）
    func isSystemFFmpegAvailable() async -> Bool {
        await findSystemFFmpeg() != nil
    }

    /// 检查当前配置的 FFmpeg 是否可用
    func isFFmpegAvailable() -> Bool {
        isExecutableAvailable(for: .ffmpeg)
    }

    /// 检查指定可执行文件是否可用
    func isExecutableAvailable(for executable: CommandExecutable) -> Bool {
        resolveExecutablePath(for: executable) != nil
    }

    // MARK: - Executable Resolution

    /// ffprobe 常见系统路径（当无法从 ffmpegPath 推导时兜底）
    private let ffprobeFallbackPaths = [
        "/opt/homebrew/bin/ffprobe",
        "/usr/local/bin/ffprobe",
        "/usr/bin/ffprobe",
        "/opt/local/bin/ffprobe"
    ]

    /// 根据当前配置解析可执行文件路径
    private func resolveExecutablePath(for executable: CommandExecutable) -> String? {
        let fm = FileManager.default

        switch executable {
        case .ffmpeg:
            guard !ffmpegPath.isEmpty else { return nil }

            if fm.isExecutableFile(atPath: ffmpegPath) {
                return ffmpegPath
            }

            let siblingFFmpeg = siblingExecutablePath(named: "ffmpeg", from: ffmpegPath)
            if fm.isExecutableFile(atPath: siblingFFmpeg) {
                return siblingFFmpeg
            }

            return nil

        case .ffprobe:
            if !ffprobePath.isEmpty, fm.isExecutableFile(atPath: ffprobePath) {
                return ffprobePath
            }

            return resolveFFprobePath(
                ffmpegCandidatePath: ffmpegPath,
                preferredFFprobePath: configuredFFprobePath,
                fileManager: fm
            )
        }
    }

    private func siblingExecutablePath(named executableName: String, from path: String) -> String {
        URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent(executableName)
            .path
    }

    private func resolveFFprobePath(
        ffmpegCandidatePath: String,
        preferredFFprobePath: String,
        fileManager: FileManager = .default
    ) -> String? {
        if !preferredFFprobePath.isEmpty,
           fileManager.isExecutableFile(atPath: preferredFFprobePath) {
            return preferredFFprobePath
        }

        if !ffmpegCandidatePath.isEmpty {
            let currentExecutableName = (ffmpegCandidatePath as NSString)
                .lastPathComponent
                .lowercased()

            if currentExecutableName == "ffprobe",
               fileManager.isExecutableFile(atPath: ffmpegCandidatePath) {
                return ffmpegCandidatePath
            }

            let siblingFFprobe = siblingExecutablePath(named: "ffprobe", from: ffmpegCandidatePath)
            if fileManager.isExecutableFile(atPath: siblingFFprobe) {
                return siblingFFprobe
            }
        }

        for path in ffprobeFallbackPaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        return nil
    }

    /// 缓存的 FFmpeg 版本（按可执行路径区分）
    private struct VersionCacheEntry {
        let path: String
        let version: String
    }

    private var cachedVersion: VersionCacheEntry?

    /// 路径更新代号（用于丢弃过时异步结果，避免乱序覆盖）
    private var pathUpdateGeneration: UInt64 = 0

    /// 设置 FFmpeg 来源
    func setSource(_ source: FFmpegSource, customPath: String? = nil) {
        if let customPath = customPath {
            self.customFFmpegPath = customPath
        }
        self.ffmpegSource = source
    }

    /// 刷新系统 FFmpeg 路径缓存
    func refreshSystemPath() async {
        await pathResolver.invalidateCache()
        cachedSystemPath = await pathResolver.systemPath
        if ffmpegSource == .system {
            ffmpegPath = cachedSystemPath ?? ""
            ffprobePath = resolveFFprobePath(
                ffmpegCandidatePath: ffmpegPath,
                preferredFFprobePath: configuredFFprobePath
            ) ?? ""
        }
    }

    /// 获取 FFmpeg 版本
    func getFFmpegVersion() async throws -> String {
        guard let path = resolveExecutablePath(for: .ffmpeg) else {
            throw FFmpegError.ffmpegNotFound
        }
        if let cached = cachedVersion, cached.path == path {
            return cached.version
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try await self.runProcessAndWait(process)
        let exitCode = process.terminationStatus

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)

        let firstLine = output
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

        guard exitCode == 0 else {
            let reason = firstLine.isEmpty ? "未知错误" : firstLine
            throw FFmpegError.executionFailed("读取 FFmpeg 版本失败（退出码: \(exitCode)）：\(reason)")
        }

        guard !firstLine.isEmpty else {
            throw FFmpegError.executionFailed("无法解析 FFmpeg 版本输出")
        }

        let version = firstLine
        self.cachedVersion = VersionCacheEntry(path: path, version: version)
        return version
    }

    /// 执行命令（使用参数数组，推荐路径）
    /// - Parameters:
    ///   - arguments: 参数数组（不包含 ffmpeg 本身）
    ///   - displayCommand: 用于日志显示的命令字符串
    ///   - executable: 目标可执行文件（ffmpeg / ffprobe）
    /// - Returns: 执行结果
    /// - Note: 这是 Template → Execute 的推荐路径，直接使用参数数组，
    ///         避免 shell escaping + splitCommand 的不可逆问题
    func execute(
        arguments: [String],
        displayCommand: String,
        executable: CommandExecutable = .ffmpeg
    ) async throws -> ExecutionResult {
        guard !isRunning else {
            throw FFmpegError.alreadyRunning
        }

        guard let executablePath = resolveExecutablePath(for: executable) else {
            throw FFmpegError.executableNotFound(executable.binaryName)
        }

        let startTime = Date()

        // 🔍 调试日志：输出实际 arguments（仅在开启详细日志时）
        AppLogger.debug(AppLogger.ffmpeg, "\(executable.binaryName) arguments count: \(arguments.count)")
        for (i, arg) in arguments.enumerated() {
            AppLogger.debug(AppLogger.ffmpeg, "  [\(i)] = \(arg)")
        }

        let session = ProcessExecutionSession(
            executablePath: executablePath,
            arguments: arguments,
            displayCommand: displayCommand,
            onLog: { [weak self] entry in
                Task { @MainActor in
                    self?.onLogOutput?(entry)
                }
            }
        )

        // 状态管理
        isRunning = true
        currentSession = session
        currentProcess = session.process
        let currentTaskId = UUID()
        activeTaskId = currentTaskId

        // 记录开始
        onLogOutput?(LogEntry(
            timestamp: Date(),
            level: .info,
            message: "开始执行: \(displayCommand)"
        ))

        return try await withTaskCancellationHandler {
            // 使用 defer 确保严格的资源释放，防止崩溃或异常导致句柄泄露
            defer {
                session.cleanup()
            }

            do {
                // 先绑定 terminationHandler 再启动进程，避免快速退出竞态
                try await runProcessAndWait(session.process)
                let result = await session.finish(startTime: startTime)

                // 同步更新状态 (已在 MainActor)
                if self.activeTaskId == currentTaskId {
                    self.isRunning = false
                    self.currentSession = nil
                    self.currentProcess = nil
                    self.activeTaskId = nil
                }

                // 记录结束
                let statusMessage: String
                let statusLevel: LogLevel

                if result.isCancelled || Task.isCancelled {
                    statusMessage = "执行已取消"
                    statusLevel = .warning
                } else if result.isSuccess {
                    statusMessage = "执行成功"
                    statusLevel = .info
                } else {
                    statusMessage = "执行失败 (退出码: \(result.exitCode))"
                    statusLevel = .error
                }

                onLogOutput?(LogEntry(
                    timestamp: Date(),
                    level: statusLevel,
                    message: "\(statusMessage)，耗时: \(result.formattedDuration)"
                ))

                return result

            } catch {
                // 同步更新状态
                if self.activeTaskId == currentTaskId {
                    self.isRunning = false
                    self.currentSession = nil
                    self.currentProcess = nil
                    self.activeTaskId = nil
                }

                // 记录错误 (先记录再 throw)
                let errorMsg = error.localizedDescription
                self.onLogOutput?(LogEntry(
                    timestamp: Date(),
                    level: .error,
                    message: "执行异常: \(errorMsg)"
                ))

                throw FFmpegError.executionFailed(errorMsg)
            }

        } onCancel: { [weak session] in
            Task {
                await session?.cancel()
            }
        }
    }

    /// 执行 FFmpeg 命令（使用命令字符串）
    /// - Parameter command: 完整的命令字符串
    /// - Returns: 执行结果
    /// - Note: 此方法仅用于手动输入/粘贴命令场景。
    ///         对于 Template → Execute 的主路径，请使用 execute(arguments:displayCommand:)
    @available(*, deprecated, message: "Use execute(arguments:displayCommand:) instead. This method is only for legacy command string input.")
    func execute(command: String) async throws -> ExecutionResult {
        // 严格解析命令参数
        let args = try CommandRenderer.splitCommandStrict(command)
        guard let executableToken = args.first,
              let executable = CommandExecutable.from(token: executableToken) else {
            throw FFmpegError.invalidCommand("命令必须以 ffmpeg 或 ffprobe 开头")
        }

        // 移除可执行文件本身，保留参数
        let finalArgs = Array(args.dropFirst())

        // 委托给主实现
        return try await execute(
            arguments: finalArgs,
            displayCommand: command,
            executable: executable
        )
    }

    /// 取消当前执行
    func cancel() {
        guard let session = currentSession else { return }
        Task {
            await session.cancel()
        }
    }

    /// 启动并等待进程结束
    /// - Note: 必须先设置 `terminationHandler` 再 `run()`，避免快速退出竞态
    private func runProcessAndWait(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { terminatedProcess in
                terminatedProcess.terminationHandler = nil
                continuation.resume(returning: ())
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

}

// MARK: - Errors

/// 单次命令执行会话
/// 封装 Process、管道、流式日志和取消逻辑，避免 FFmpegService 承担过多细节
private final class ProcessExecutionSession {
    let process: Process

    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let stdoutLogger = ProcessLogger()
    private let stderrLogger = ProcessLogger()
    private let dataCollector = OutputDataCollector()
    private let displayCommand: String
    private let onLog: (LogEntry) -> Void

    /// 防止 cleanup() 与 cancel() 并发执行时重复关闭管道
    private var isCleaned = false

    init(
        executablePath: String,
        arguments: [String],
        displayCommand: String,
        onLog: @escaping (LogEntry) -> Void
    ) {
        self.displayCommand = displayCommand
        self.onLog = onLog
        self.process = Process()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        stdoutLogger.onLog = onLog
        stderrLogger.onLog = onLog

        startStreaming()
    }

    func finish(startTime: Date) async -> ExecutionResult {
        stopStreaming()

        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if !remainingStdout.isEmpty {
            append(remainingStdout, isError: false)
        }

        if !remainingStderr.isEmpty {
            append(remainingStderr, isError: true)
        }

        stdoutLogger.flushPendingLineSync(asError: false)
        stderrLogger.flushPendingLineSync(asError: true)

        return ExecutionResult(
            command: displayCommand,
            exitCode: process.terminationStatus,
            standardOutput: dataCollector.stdoutString,
            standardError: dataCollector.stderrString,
            startTime: startTime,
            endTime: Date()
        )
    }

    func cleanup() {
        guard !isCleaned else { return }
        isCleaned = true
        stopStreaming()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        try? stdinPipe.fileHandleForWriting.close()
    }

    func cancel() async {
        let pid = process.processIdentifier
        guard pid > 0 else { return }

        onLog(LogEntry(
            timestamp: Date(),
            level: .info,
            message: "正在停止执行..."
        ))

        if let qData = "q\n".data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: qData)
        }

        if await waitForExit(maxPollCount: 20) {
            return
        }

        if process.isRunning {
            process.terminate()
        }

        if await waitForExit(maxPollCount: 20) {
            return
        }

        if process.isRunning {
            kill(pid, SIGKILL)
            onLog(LogEntry(
                timestamp: Date(),
                level: .warning,
                message: "进程未响应，已发送 SIGKILL 强制终止"
            ))
        }
    }

    private func startStreaming() {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.append(data, isError: false)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.append(data, isError: true)
        }
    }

    private func stopStreaming() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func append(_ data: Data, isError: Bool) {
        let text = String(decoding: data, as: UTF8.self)
        if isError {
            dataCollector.appendStderr(data)
            stderrLogger.processOutput(text, isError: true)
        } else {
            dataCollector.appendStdout(data)
            stdoutLogger.processOutput(text, isError: false)
        }
    }

    private func waitForExit(maxPollCount: Int) async -> Bool {
        for _ in 0..<maxPollCount {
            if !process.isRunning {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !process.isRunning
    }
}

enum FFmpegError: LocalizedError {
    case ffmpegNotFound
    case executableNotFound(String)
    case alreadyRunning
    case invalidCommand(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "未找到 FFmpeg，请确保已安装 FFmpeg"
        case .executableNotFound(let executable):
            return "未找到可执行文件 \(executable)，请检查 FFmpeg 安装或路径配置"
        case .alreadyRunning:
            return "FFmpeg 正在运行中"
        case .invalidCommand(let msg):
            return "无效的命令: \(msg)"
        case .executionFailed(let msg):
            return "执行失败: \(msg)"
        }
    }
}

// MARK: - 线程安全的输出收集器

/// 线程安全的输出数据收集器
/// 包含 1MB 缓冲区上限，防止长时间任务导致内存溢出
final class OutputDataCollector: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var stdoutChunks: [Data] = []
    private var stderrChunks: [Data] = []
    private var stdoutSize = 0
    private var stderrSize = 0

    /// 最大缓冲区大小 (1MB)
    private let maxBufferSize = 1_000_000

    func appendStdout(_ data: Data) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        append(data, to: &stdoutChunks, size: &stdoutSize)
    }

    func appendStderr(_ data: Data) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        append(data, to: &stderrChunks, size: &stderrSize)
    }

    var stdoutData: Data {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return combinedData(from: stdoutChunks, totalSize: stdoutSize)
    }

    var stderrData: Data {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return combinedData(from: stderrChunks, totalSize: stderrSize)
    }

    var stdoutString: String {
        String(decoding: stdoutData, as: UTF8.self)
    }

    var stderrString: String {
        String(decoding: stderrData, as: UTF8.self)
    }

    // MARK: - Buffer Helpers

    private func append(_ data: Data, to chunks: inout [Data], size: inout Int) {
        guard !data.isEmpty else { return }
        chunks.append(data)
        size += data.count

        // 如果超出限制，移除最早的块，直到满足大小限制
        // 注意：这里按块移除，避免从中间截断 Data 导致 invalid UTF-8 序列
        while size > maxBufferSize, !chunks.isEmpty {
            let removed = chunks.removeFirst()
            size -= removed.count
        }
    }

    private func combinedData(from chunks: [Data], totalSize: Int) -> Data {
        var data = Data()
        data.reserveCapacity(totalSize)
        for chunk in chunks {
            data.append(chunk)
        }
        return data
    }
}
