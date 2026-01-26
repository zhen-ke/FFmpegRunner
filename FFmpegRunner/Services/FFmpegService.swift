//
//  FFmpegService.swift
//  FFmpegRunner
//
//  FFmpeg 执行服务
//

import Foundation

/// FFmpeg 来源类型
enum FFmpegSource: String, CaseIterable, Codable {
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
    /// FFmpeg 来源：从 UserSettings 读取，统一数据源
    var ffmpegSource: FFmpegSource {
        get { UserSettings.shared.ffmpegSource }
        set {
            UserSettings.shared.ffmpegSource = newValue
            objectWillChange.send()
            updateFFmpegPath()
        }
    }

    // MARK: - Properties

    /// 日志回调
    var onLogOutput: ((LogEntry) -> Void)?

    /// 当前使用的 FFmpeg 路径
    private(set) var ffmpegPath: String = ""

    /// 自定义 FFmpeg 路径：从 UserSettings 读取，统一数据源
    var customFFmpegPath: String {
        get { UserSettings.shared.customFFmpegPath }
        set {
            UserSettings.shared.customFFmpegPath = newValue
            if ffmpegSource == .custom {
                updateFFmpegPath()
            }
        }
    }

    /// 路径解析器（依赖注入）
    private let pathResolver: FFmpegPathProviding

    /// 内置 FFmpeg 路径（委托给 pathResolver）
    var bundledFFmpegPath: String? {
        pathResolver.bundledPath
    }

    // MARK: - Initialization

    private init(pathResolver: FFmpegPathProviding = FFmpegPathResolver()) {
        self.pathResolver = pathResolver

        // 仅在首次启动时自动检测可用的 FFmpeg 来源
        // 如果当前选择的来源不可用，自动切换到可用的来源
        let currentSource = UserSettings.shared.ffmpegSource
        if currentSource == .bundled && pathResolver.bundledPath == nil {
            if pathResolver.systemPath != nil {
                UserSettings.shared.ffmpegSource = .system
            }
        }
        updateFFmpegPath()
    }

    // MARK: - Path Management

    /// 更新 FFmpeg 路径
    private func updateFFmpegPath() {
        ffmpegPath = pathResolver.resolvePath(for: ffmpegSource, customPath: customFFmpegPath) ?? ""
    }

    // MARK: - Public Methods

    /// 查找系统中的 FFmpeg
    func findSystemFFmpeg() -> String? {
        pathResolver.systemPath
    }

    /// 检查内置 FFmpeg 是否可用
    var isBundledFFmpegAvailable: Bool {
        bundledFFmpegPath != nil
    }

    /// 检查系统 FFmpeg 是否可用
    var isSystemFFmpegAvailable: Bool {
        findSystemFFmpeg() != nil
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

        // 设置管道
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 使用线程安全的数据收集器
        let dataCollector = OutputDataCollector()

        // 更新状态
        isRunning = true
        currentProcess = process

        // 设置输出处理
        let processLogger = ProcessLogger()
        processLogger.onLog = { [weak self] entry in
            Task { @MainActor in
                self?.onLogOutput?(entry)
            }
        }

        // 开始流式读取 - 使用线程安全的方式
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

        // 清理函数 - 用于 run() 失败时的清理
        func cleanupOnFailure() {
            isRunning = false
            currentProcess = nil
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        // 记录开始
        onLogOutput?(LogEntry(
            timestamp: Date(),
            level: .info,
            message: "开始执行: \(displayCommand)"
        ))

        do {
            try process.run()
        } catch {
            // run() 失败时清理状态
            cleanupOnFailure()
            throw FFmpegError.executionFailed(error.localizedDescription)
        }

        // 等待完成 - 状态清理绑定到 terminationHandler
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { [weak self] _ in
                // 清理 readabilityHandler
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                // 在主线程更新状态
                Task { @MainActor in
                    self?.isRunning = false
                    self?.currentProcess = nil
                }

                continuation.resume()
            }
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
    }

    /// 执行 FFmpeg 命令（使用命令字符串）
    /// - Parameter command: 完整的命令字符串
    /// - Returns: 执行结果
    /// - Note: 此方法仅用于手动输入/粘贴命令场景。
    ///         对于 Template → Execute 的主路径，请使用 execute(arguments:displayCommand:)
    @available(*, deprecated, message: "Use execute(arguments:displayCommand:) instead. This method is only for legacy command string input.")
    func execute(command: String) async throws -> ExecutionResult {
        guard !isRunning else {
            throw FFmpegError.alreadyRunning
        }

        guard isFFmpegAvailable() else {
            throw FFmpegError.ffmpegNotFound
        }

        let startTime = Date()

        // 解析命令参数
        let args = CommandRenderer.splitCommand(command)
        guard args.first == "ffmpeg" || args.first?.hasSuffix("ffmpeg") == true else {
            throw FFmpegError.invalidCommand("命令必须以 ffmpeg 开头")
        }

        // 创建进程
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)

        // 自动添加 -nostdin 防止因等待输入而死锁
        var finalArgs = Array(args.dropFirst()) // 移除 ffmpeg 本身
        if !finalArgs.contains("-nostdin") {
            finalArgs.insert("-nostdin", at: 0)
        }
        process.arguments = finalArgs

        // 设置管道
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 使用线程安全的数据收集器
        let dataCollector = OutputDataCollector()

        // 更新状态
        isRunning = true
        currentProcess = process

        // 设置输出处理
        let processLogger = ProcessLogger()
        processLogger.onLog = { [weak self] entry in
            Task { @MainActor in
                self?.onLogOutput?(entry)
            }
        }

        // 开始流式读取 - 使用线程安全的方式
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

        // 清理函数 - 用于 run() 失败时的清理
        func cleanupOnFailure() {
            isRunning = false
            currentProcess = nil
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        // 记录开始
        onLogOutput?(LogEntry(
            timestamp: Date(),
            level: .info,
            message: "开始执行: \(command)"
        ))

        do {
            try process.run()
        } catch {
            // run() 失败时清理状态
            cleanupOnFailure()
            throw FFmpegError.executionFailed(error.localizedDescription)
        }

        // 等待完成 - 状态清理绑定到 terminationHandler
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { [weak self] _ in
                // 清理 readabilityHandler
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                // 在主线程更新状态
                Task { @MainActor in
                    self?.isRunning = false
                    self?.currentProcess = nil
                }

                continuation.resume()
            }
        }

        let endTime = Date()

        let result = ExecutionResult(
            command: command,
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
    }

    /// 取消当前执行
    func cancel() {
        guard let process = currentProcess, process.isRunning else { return }
        cancelProcess(process)
    }

    /// 终止进程：先优雅（SIGINT），超时后强制（SIGKILL）
    private func cancelProcess(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }

        onLogOutput?(LogEntry(
            timestamp: Date(),
            level: .warning,
            message: "用户取消执行"
        ))

        // 优雅终止 (SIGINT = Ctrl+C)，FFmpeg 对此响应良好
        kill(pid, SIGINT)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // 检查进程是否仍存在 (kill with signal 0 只检测不发信号)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)

                Task { @MainActor in
                    self?.onLogOutput?(LogEntry(
                        timestamp: Date(),
                        level: .warning,
                        message: "进程未响应，已强制终止"
                    ))
                }
            }
        }

        onLogOutput?(LogEntry(
            timestamp: Date(),
            level: .warning,
            message: "执行已取消"
        ))
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
    private var _stdoutData = Data()
    private var _stderrData = Data()

    /// 最大缓冲区大小 (1MB)
    private let maxBufferSize = 1_000_000

    func appendStdout(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        _stdoutData.append(data)
        // 限制缓冲区大小，保留最新数据
        if _stdoutData.count > maxBufferSize {
            _stdoutData.removeFirst(_stdoutData.count - maxBufferSize)
        }
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        _stderrData.append(data)
        // 限制缓冲区大小，保留最新数据
        if _stderrData.count > maxBufferSize {
            _stderrData.removeFirst(_stderrData.count - maxBufferSize)
        }
    }

    var stdoutData: Data {
        lock.lock()
        defer { lock.unlock() }
        return _stdoutData
    }

    var stderrData: Data {
        lock.lock()
        defer { lock.unlock() }
        return _stderrData
    }

    var stdoutString: String {
        String(data: stdoutData, encoding: .utf8) ?? ""
    }

    var stderrString: String {
        String(data: stderrData, encoding: .utf8) ?? ""
    }
}
