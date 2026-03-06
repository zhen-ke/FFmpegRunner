//
//  ExecutionViewModel.swift
//  FFmpegRunner
//
//  执行 ViewModel - UI 状态管理层
//
//  ⚠️ 架构约定：
//  此 ViewModel 仅负责 UI 状态管理和日志展示。
//  所有业务逻辑（命令验证、执行编排、历史记录）已下沉到 ExecutionController。
//  后续功能（执行队列、多任务、失败重试等）应添加到 Application Layer，
//  而非直接在此 ViewModel 中实现。
//

import Foundation
import Combine

/// 执行 ViewModel
/// 负责管理 UI 执行状态和日志展示
///
/// 职责边界：
/// - ✅ UI 状态展示（state, logs, lastResult）
/// - ✅ 日志收集与裁剪
/// - ✅ 状态描述与颜色
/// - ❌ 命令验证 → ExecutionController
/// - ❌ 执行编排 → ExecutionController
/// - ❌ 历史记录 → ExecutionController
@MainActor
class ExecutionViewModel: ObservableObject {

    // MARK: - Published Properties (UI State)

    /// 执行状态
    @Published private(set) var state: ExecutionState = .idle

    /// 日志条目
    @Published private(set) var logs: [LogEntry] = []

    /// 日志过滤级别
    @Published var logFilter: LogFilter = .all

    /// 过滤后的日志（缓存结果，避免每次 body 刷新都重新过滤）
    @Published private(set) var visibleLogs: [LogEntry] = []

    /// 最近的执行结果
    @Published private(set) var lastResult: ExecutionResult?

    /// FFmpeg 版本信息（从 Controller 同步）
    @Published private(set) var ffmpegVersion: String?

    /// 简短的 FFmpeg 版本号（优化 UI 显示）
    var ffmpegVersionShort: String {
        guard let fullVersion = ffmpegVersion else { return "FFmpeg" }
        // 尝试提取类似 "ffmpeg version 7.1" 中的 "7.1"
        if let range = fullVersion.range(of: #"version\s+(\d+\.\d+(?:\.\d+)?)"#, options: .regularExpression) {
            let versionPart = fullVersion[range]
            if let numberRange = versionPart.range(of: #"\d+\.\d+(?:\.\d+)?"#, options: .regularExpression) {
                return "v\(versionPart[numberRange])"
            }
        }
        return "FFmpeg"
    }

    /// FFmpeg 是否可用（从 Controller 同步）
    @Published private(set) var isFFmpegAvailable = false

    // MARK: - Computed Properties

    /// 是否正在运行
    var isRunning: Bool {
        state.isRunning
    }

    // MARK: - Configuration

    /// 最大日志条目数
    private var maxLogEntries: Int {
        UserSettings.shared.maxLogEntries
    }

    /// 是否合并进度日志
    private var shouldCoalesceProgressLogs: Bool {
        UserSettings.shared.coalesceProgressLogs
    }

    /// 进度日志合并间隔（秒）
    private var progressCoalesceInterval: TimeInterval {
        TimeInterval(UserSettings.shared.progressCoalesceIntervalMs) / 1000.0
    }

    // MARK: - Dependencies

    /// 执行控制器 (Application Layer)
    private let controller: ExecutionController

    /// Combine 订阅
    private var cancellables = Set<AnyCancellable>()

    /// 历史记录变更回调（用于通知 HistoryViewModel 刷新）
    var onHistoryChanged: (() -> Void)? {
        didSet {
            controller.onHistoryChanged = onHistoryChanged
        }
    }

    /// 上次进度日志更新时间
    private var lastProgressLogTime: Date?

    // MARK: - Initialization

    init(controller: ExecutionController? = nil) {
        self.controller = controller ?? ExecutionController()

        setupBindings()
    }

    private func setupBindings() {
        // 订阅 Controller 状态变更
        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.state = newState
            }
            .store(in: &cancellables)

        // 订阅 FFmpeg 可用性
        controller.$isFFmpegAvailable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] available in
                self?.isFFmpegAvailable = available
            }
            .store(in: &cancellables)

        // 订阅 FFmpeg 版本
        controller.$ffmpegVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] version in
                self?.ffmpegVersion = version
            }
            .store(in: &cancellables)

        // 设置日志回调
        controller.onLogOutput = { [weak self] entry in
            self?.appendLog(entry)
        }

        // 监听 logs 和 filter 变化，使用 throttle 防抖处理
        // 避免每次 body 刷新都重新过滤整个日志数组
        Publishers.CombineLatest($logs, $logFilter)
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .map { logs, filter -> [LogEntry] in
                switch filter {
                case .all:
                    return logs
                case .important:
                    return logs.filter { $0.level == .error || $0.level == .warning }
                case .noDebug:
                    return logs.filter { $0.level != .debug }
                }
            }
            .assign(to: &$visibleLogs)
    }

    // MARK: - Public Methods (Delegate to Controller)

    /// 检查 FFmpeg 可用性
    func checkFFmpegAvailability() {
        controller.checkFFmpegAvailability()
    }

    /// 验证命令安全性
    func validateCommand(_ command: String) -> CommandValidationResult {
        CommandValidator.validate(command)
    }

    /// 执行命令
    func execute(command: String) async {
        guard !isRunning else { return }

        clearLogs()

        do {
            let result = try await controller.execute(command: command)
            lastResult = result
        } catch {
            appendLog(LogEntry(
                timestamp: Date(),
                level: .error,
                message: "执行失败: \(error.localizedDescription)"
            ))
        }
    }

    /// 执行模板（推荐路径：CommandPlanner -> ExecutionPlan -> Execute）
    func execute(
        template: Template,
        values: [TemplateValue],
        forceOverwrite: Bool = false
    ) async {
        let binding = TemplateBinding.bind(template: template, values: values)
        await execute(binding: binding, forceOverwrite: forceOverwrite)
    }

    /// 执行模板绑定（推荐路径：复用详情页的权威绑定快照）
    func execute(
        binding: TemplateBinding,
        forceOverwrite: Bool = false
    ) async {
        guard !isRunning else { return }

        clearLogs()

        do {
            let result = try await controller.execute(
                binding: binding,
                forceOverwrite: forceOverwrite
            )
            lastResult = result
        } catch {
            appendLog(LogEntry(
                timestamp: Date(),
                level: .error,
                message: "执行失败: \(error.localizedDescription)"
            ))
        }
    }

    /// 执行命令（使用参数数组，推荐路径）
    /// - Parameters:
    ///   - arguments: 参数数组（不包含 ffmpeg 本身）
    ///   - displayCommand: 用于日志/历史记录显示的命令字符串
    /// - Note: 这是 Template → Execute 的推荐路径，直接使用参数数组，
    ///         避免 shell escaping + splitCommand 的不可逆问题
    func execute(
        arguments: [String],
        displayCommand: String,
        executable: CommandExecutable = .ffmpeg
    ) async {
        guard !isRunning else { return }

        clearLogs()

        do {
            let result = try await controller.execute(
                arguments: arguments,
                displayCommand: displayCommand,
                executable: executable
            )
            lastResult = result
        } catch {
            appendLog(LogEntry(
                timestamp: Date(),
                level: .error,
                message: "执行失败: \(error.localizedDescription)"
            ))
        }
    }

    /// 取消执行
    func cancel() {
        controller.cancel()

        appendLog(LogEntry(
            timestamp: Date(),
            level: .warning,
            message: "用户取消执行"
        ))
    }

    /// 重置状态
    func reset() {
        controller.reset()
        lastResult = nil
    }

    /// 设置 FFmpeg 来源
    func setFFmpegSource(_ source: FFmpegSource, customPath: String? = nil) {
        controller.setFFmpegSource(source, customPath: customPath)
    }

    /// 刷新 FFmpeg 状态
    func refreshFFmpegStatus() {
        controller.checkFFmpegAvailability()
    }

    // MARK: - Log Management (UI Responsibility)

    /// 清空日志
    func clearLogs() {
        logs = []
        visibleLogs = []
        lastProgressLogTime = nil
    }

    /// 添加日志条目
    func appendLog(_ entry: LogEntry) {
        if entry.isProgress, shouldCoalesceProgressLogs {
            let now = entry.timestamp
            if let lastIndex = logs.indices.last,
               logs[lastIndex].isProgress,
               let lastTime = lastProgressLogTime,
               now.timeIntervalSince(lastTime) < progressCoalesceInterval {
                logs[lastIndex] = entry.withId(logs[lastIndex].id)
                lastProgressLogTime = now
                return
            }
            lastProgressLogTime = now
        }

        logs.append(entry)
        trimLogsIfNeeded()
    }

    private func trimLogsIfNeeded() {
        guard logs.count > maxLogEntries else { return }

        var overflow = logs.count - maxLogEntries

        // 优先移除不重要日志（debug/info），保留错误/警告
        var index = 0
        while overflow > 0, index < logs.count {
            if !logs[index].isImportant {
                logs.remove(at: index)
                overflow -= 1
                continue
            }
            index += 1
        }

        // 如果仍超出，移除最旧的日志
        if overflow > 0 {
            logs.removeFirst(overflow)
        }
    }

    /// 导出日志
    func exportLogs() -> String {
        logs.map { (entry: LogEntry) -> String in entry.displayString }.joined(separator: "\n")
    }
}

// MARK: - 状态辅助

extension ExecutionViewModel {
    /// 状态描述
    var stateDescription: String {
        switch state {
        case .idle:
            return "就绪"
        case .preparing:
            return "准备中..."
        case .running:
            return "执行中..."
        case .cancelling:
            return "取消中..."
        case .completed(let result):
            return result.isSuccess ? "执行成功" : "执行失败"
        case .cancelled:
            return "已取消"
        case .error(let msg):
            return "错误: \(msg)"
        }
    }

    /// 状态颜色
    var stateColor: String {
        switch state {
        case .idle: return "secondary"
        case .preparing: return "blue"
        case .running: return "blue"
        case .cancelling: return "orange"
        case .completed(let result): return result.isSuccess ? "green" : "red"
        case .cancelled: return "orange"
        case .error: return "red"
        }
    }
}
