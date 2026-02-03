//
//  FFmpegService.swift
//  FFmpegRunner
//
//  FFmpeg 执行服务
//

import Foundation

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
///   - Handle cancellation with graceful shutdown (SIGINT → SIGKILL)
/// - Non-responsibility:
///   - Command parsing (use CommandRenderer)
///   - Template binding (use CommandRenderer)
///   - Path resolution (delegated to FFmpegPathResolver)
@MainActor
class FFmpegService: ObservableObject {

    // MARK: - Singleton

    static let shared = FFmpegService()

    // MARK: - Published Properties

    @Published private(set) var isRunning = false
    @Published private(set) var currentProcess: Process?

    /// 系统 FFmpeg 路径的缓存（用于 UI 展示）
    @Published private(set) var cachedSystemPath: String?

    /// FFmpeg 来源：从 UserSettings 读取，统一数据源
    var ffmpegSource: FFmpegSource {
        get { UserSettings.shared.ffmpegSource }
        set {
            UserSettings.shared.ffmpegSource = newValue
            objectWillChange.send()
            Task { await updateFFmpegPathAsync() }
        }
    }

    // MARK: - Properties

    /// 日志回调
    var onLogOutput: ((LogEntry) -> Void)?

    /// 当前使用的 FFmpeg 路径
    @Published private(set) var ffmpegPath: String = ""

    /// 自定义 FFmpeg 路径：从 UserSettings 读取，统一数据源
    var customFFmpegPath: String {
        get { UserSettings.shared.customFFmpegPath }
        set {
            UserSettings.shared.customFFmpegPath = newValue
            cachedVersion = nil // 路径变化时清除缓存
            if ffmpegSource == .custom {
                Task { await updateFFmpegPathAsync() }
            }
        }
    }

    /// 路径解析器（依赖注入）
    private let pathResolver: FFmpegPathProviding

    /// 内置 FFmpeg 路径（委托给 pathResolver，同步访问）
    var bundledFFmpegPath: String? {
        pathResolver.bundledPath
    }

    // MARK: - Initialization

    private init(pathResolver: FFmpegPathProviding = FFmpegPathResolver()) {
        self.pathResolver = pathResolver

        // 同步设置 bundled 路径（无 I/O，安全）
        if ffmpegSource == .bundled, let bundled = pathResolver.bundledPath {
            ffmpegPath = bundled
        } else if ffmpegSource == .custom {
            ffmpegPath = customFFmpegPath
        }

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

        await updateFFmpegPathAsync()
    }

    // MARK: - Path Management

    /// 异步更新 FFmpeg 路径
    private func updateFFmpegPathAsync() async {
        let path = await pathResolver.resolvePath(for: ffmpegSource, customPath: customFFmpegPath)
        ffmpegPath = path ?? ""

        // 同时更新缓存的系统路径
        if ffmpegSource == .system {
            cachedSystemPath = path
        }
    }

    // MARK: - Public Methods

    /// 查找系统中的 FFmpeg（异步）
    func findSystemFFmpeg() async -> String? {
        let path = await pathResolver.systemPath
        cachedSystemPath = path
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
        !ffmpegPath.isEmpty && FileManager.default.isExecutableFile(atPath: ffmpegPath)
    }

    /// 缓存的 FFmpeg 版本
    private var cachedVersion: String?

    /// 设置 FFmpeg 来源
    func setSource(_ source: FFmpegSource, customPath: String? = nil) {
        if let customPath = customPath {
            self.customFFmpegPath = customPath
        }
        self.ffmpegSource = source
        // 如果来源改变，清除版本缓存
        self.cachedVersion = nil
    }

    /// 刷新系统 FFmpeg 路径缓存
    func refreshSystemPath() async {
        await pathResolver.invalidateCache()
        cachedSystemPath = await pathResolver.systemPath
        if ffmpegSource == .system {
            ffmpegPath = cachedSystemPath ?? ""
        }
    }

    /// 获取 FFmpeg 版本
    func getFFmpegVersion() async throws -> String {
        // 如果有缓存，直接返回
        if let cached = cachedVersion {
            return cached
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // 提取第一行版本信息
        if let firstLine = output.split(separator: "\n").first {
            let version = String(firstLine)
            self.cachedVersion = version
            return version
        }

        self.cachedVersion = output
        return output
    }

    /// 执行 FFmpeg 命令（使用参数数组，推荐路径）
    /// - Parameters:
    ///   - arguments: 参数数组（不包含 ffmpeg 本身）
    ///   - displayCommand: 用于日志显示的命令字符串
    /// - Returns: 执行结果
    /// - Note: 这是 Template → Execute 的推荐路径，直接使用参数数组，
    ///         避免 shell escaping + splitCommand 的不可逆问题
    func execute(arguments: [String], displayCommand: String) async throws -> ExecutionResult {
        guard !isRunning else {
            throw FFmpegError.alreadyRunning
        }

        guard isFFmpegAvailable() else {
            throw FFmpegError.ffmpegNotFound
        }

        let startTime = Date()

        // 创建进程
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)

        // 自动添加 -nostdin 防止因等待输入而死锁
        var finalArgs = arguments
        if !finalArgs.contains("-nostdin") {
            finalArgs.insert("-nostdin", at: 0)
        }
        process.arguments = finalArgs

        // 🔍 调试日志：输出实际 arguments（仅在开启详细日志时）
        AppLogger.debug(AppLogger.ffmpeg, "FFmpeg arguments count: \(finalArgs.count)")
        for (i, arg) in finalArgs.enumerated() {
            AppLogger.debug(AppLogger.ffmpeg, "  [\(i)] = \(arg)")
        }

        // 设置管道
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 使用线程安全的数据收集器
        let dataCollector = OutputDataCollector()

        // 状态管理
        isRunning = true
        currentProcess = process

        // 设置输出处理
        let processLogger = ProcessLogger()
        processLogger.onLog = { [weak self] entry in
            Task { @MainActor in
                self?.onLogOutput?(entry)
            }
        }

        // 清理函数：关闭文件句柄，重置状态
        let cleanup = {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        // 开始流式读取
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                dataCollector.appendStderr(data)
                if let text = String(data: data, encoding: .utf8) {
                    processLogger.processOutput(text, isError: true)
                }
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                dataCollector.appendStdout(data)
                if let text = String(data: data, encoding: .utf8) {
                    processLogger.processOutput(text, isError: false)
                }
            }
        }

        // 记录开始
        onLogOutput?(LogEntry(
            timestamp: Date(),
            level: .info,
            message: "开始执行: \(displayCommand)"
        ))

        return try await withTaskCancellationHandler {
            do {
                try process.run()

                // 等待进程结束
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    process.terminationHandler = { _ in
                        continuation.resume()
                    }
                }

                cleanup()

                // 在主线程更新状态
                Task { @MainActor in
                    self.isRunning = false
                    self.currentProcess = nil
                }

                let endTime = Date()
                let result = ExecutionResult(
                    command: displayCommand,
                    exitCode: process.terminationStatus,
                    standardOutput: dataCollector.stdoutString,
                    standardError: dataCollector.stderrString,
                    startTime: startTime,
                    endTime: endTime
                )

                // 记录结束
                let statusMessage = result.isSuccess ? "执行成功" : "执行失败 (退出码: \(result.exitCode))"
                onLogOutput?(LogEntry(
                    timestamp: Date(),
                    level: result.isSuccess ? .info : .error,
                    message: "\(statusMessage)，耗时: \(result.formattedDuration)"
                ))

                return result

            } catch {
                cleanup()
                Task { @MainActor in
                    self.isRunning = false
                    self.currentProcess = nil
                }

                // 记录错误
                let errorMsg = error.localizedDescription
                Task { @MainActor in
                    self.onLogOutput?(LogEntry(
                        timestamp: Date(),
                        level: .error,
                        message: "执行异常: \(errorMsg)"
                    ))
                }
                throw FFmpegError.executionFailed(errorMsg)
            }

        } onCancel: { [weak self, weak process] in
            // 处理取消
            if let proc = process {
                Task {
                    await self?.gracefullyTerminate(proc)
                }
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
        // 解析命令参数
        let args = CommandRenderer.splitCommand(command)
        guard args.first == "ffmpeg" || args.first?.hasSuffix("ffmpeg") == true else {
            throw FFmpegError.invalidCommand("命令必须以 ffmpeg 开头")
        }

        // 移除 ffmpeg 本身，保留参数
        let finalArgs = Array(args.dropFirst())

        // 委托给主实现
        return try await execute(arguments: finalArgs, displayCommand: command)
    }

    /// 取消当前执行
    func cancel() {
        guard let process = currentProcess, process.isRunning else { return }
        gracefullyTerminate(process)
    }

    /// 优雅终止进程
    /// 先发送 SIGINT (Ctrl+C)，如果超时未退出则发送 SIGKILL
    private func gracefullyTerminate(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }

        onLogOutput?(LogEntry(
            timestamp: Date(),
            level: .warning,
            message: "正在停止执行..."
        ))

        // 1. 尝试优雅终止 (SIGINT)
        kill(pid, SIGINT)

        // 2. 延迟检查并强制终止
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            // check if process is still running
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)

                Task { @MainActor [weak self] in
                    self?.onLogOutput?(LogEntry(
                        timestamp: Date(),
                        level: .warning,
                        message: "进程未响应，已强制终止"
                    ))
                }
            } else {
                 Task { @MainActor [weak self] in
                    self?.onLogOutput?(LogEntry(
                        timestamp: Date(),
                        level: .warning,
                        message: "执行已取消"
                    ))
                }
            }
        }
    }
}

// MARK: - Errors

enum FFmpegError: LocalizedError {
    case ffmpegNotFound
    case alreadyRunning
    case invalidCommand(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "未找到 FFmpeg，请确保已安装 FFmpeg"
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
    private let lock = NSLock()
    private var stdoutChunks: [Data] = []
    private var stderrChunks: [Data] = []
    private var stdoutSize = 0
    private var stderrSize = 0

    /// 最大缓冲区大小 (1MB)
    private let maxBufferSize = 1_000_000

    func appendStdout(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        append(data, to: &stdoutChunks, size: &stdoutSize)
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        append(data, to: &stderrChunks, size: &stderrSize)
    }

    var stdoutData: Data {
        lock.lock()
        defer { lock.unlock() }
        return combinedData(from: stdoutChunks, totalSize: stdoutSize)
    }

    var stderrData: Data {
        lock.lock()
        defer { lock.unlock() }
        return combinedData(from: stderrChunks, totalSize: stderrSize)
    }

    var stdoutString: String {
        String(data: stdoutData, encoding: .utf8) ?? ""
    }

    var stderrString: String {
        String(data: stderrData, encoding: .utf8) ?? ""
    }

    // MARK: - Buffer Helpers

    private func append(_ data: Data, to chunks: inout [Data], size: inout Int) {
        guard !data.isEmpty else { return }
        chunks.append(data)
        size += data.count

        guard size > maxBufferSize else { return }

        var overflow = size - maxBufferSize
        while overflow > 0, !chunks.isEmpty {
            let first = chunks[0]
            if first.count <= overflow {
                overflow -= first.count
                size -= first.count
                chunks.removeFirst()
            } else {
                let trimmed = first.dropFirst(overflow)
                size -= overflow
                chunks[0] = Data(trimmed)
                overflow = 0
            }
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
