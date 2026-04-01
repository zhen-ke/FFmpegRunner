//
//  ExecutionViewModel.swift
//  FFmpegRunner
//
//  执行 ViewModel - UI 状态管理层
//
//  ⚠️ 架构约定：
//  此 ViewModel 仅负责 UI 状态管理和日志展示。
//  所有业务逻辑（命令验证、执行编排、最近使用）已下沉到 ExecutionController。
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
/// - ❌ 最近使用 → ExecutionController
@MainActor
class ExecutionViewModel: ObservableObject {

    // MARK: - Published Properties (UI State)

    /// 执行状态
    @Published private(set) var state: ExecutionState = .idle

    /// 日志条目
    @Published private(set) var logs: [LogEntry] = []

    /// 日志过滤级别
    @Published var logFilter: LogFilter = .all

    /// 日志搜索关键字
    @Published var searchText: String = ""

    /// 是否启用正则搜索
    @Published var isRegexSearchEnabled = false

    /// 过滤后的日志（缓存结果，避免每次 body 刷新都重新过滤）
    @Published private(set) var visibleLogs: [LogEntry] = []

    /// 当前正则搜索错误
    @Published private(set) var regexSearchError: String?

    /// 最近的执行结果
    @Published private(set) var lastResult: ExecutionResult?

    /// 当前转码进度（仅执行期间有值）
    @Published private(set) var progress: FFmpegProgress?

    /// FFmpeg 版本信息（从 Controller 同步）
    @Published private(set) var ffmpegVersion: String?

    /// 日志自动滚动状态
    @Published var autoScroll = UserSettings.shared.autoScrollLog {
        didSet {
            UserSettings.shared.autoScrollLog = autoScroll
        }
    }

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

    /// 当前待执行队列
    @Published private(set) var queueItems: [ExecutionQueueItem] = []

    /// 队列是否正在执行
    @Published private(set) var isQueueRunning = false

    /// 当前队列执行中的任务
    @Published private(set) var activeQueueItemID: UUID?

    /// 本轮队列已完成任务数
    @Published private(set) var completedQueueItemCount = 0

    // MARK: - Computed Properties

    /// 是否正在运行
    var isRunning: Bool {
        state.isRunning
    }

    var hasQueuedItems: Bool {
        !queueItems.isEmpty
    }

    var canStartQueue: Bool {
        hasQueuedItems && !isQueueRunning && !isRunning
    }

    /// 当前命令预览是否对应最近一次执行上下文
    func matchesLastExecutedCommand(_ command: String) -> Bool {
        guard let currentCommand else { return false }

        return currentCommand.trimmingCharacters(in: .whitespacesAndNewlines) ==
            command.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// 日志持久化服务
    private let logPersistenceService: LogPersistenceService

    /// Combine 订阅
    private var cancellables = Set<AnyCancellable>()

    /// 最近使用变更回调（用于通知 RecentCommandsViewModel 刷新）
    var onRecentCommandsChanged: (() -> Void)? {
        didSet {
            controller.onRecentCommandsChanged = onRecentCommandsChanged
        }
    }

    /// 上次进度日志更新时间
    private var lastProgressLogTime: Date?

    /// 持久化/导出日志的进度合并时间
    private var lastPersistedProgressLogTime: Date?

    /// 当前执行的模板名称（用于日志持久化文件名）
    private var currentTemplateName: String?

    /// 当前执行的命令字符串（用于日志持久化）
    private var currentCommand: String?

    /// 用于日志持久化的完整日志快照，不受控制台裁剪影响
    private var persistedLogs: [LogEntry] = []

    // MARK: - Initialization

    init(
        controller: ExecutionController? = nil,
        logPersistenceService: LogPersistenceService = .shared
    ) {
        self.controller = controller ?? ExecutionController()
        self.logPersistenceService = logPersistenceService

        setupBindings()
    }

    private func setupBindings() {
        // 订阅 Controller 状态变更
        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self else { return }
                let previousState = self.state
                self.state = newState
                if case .completed(let result) = newState {
                    self.lastResult = result
                }
                // 执行结束后清除进度（保留最终快照一小段时间供 UI 过渡）
                if newState.isTerminal {
                    self.progress = nil
                }
                // 执行结束时自动保存日志（从运行状态 → 终态，排除 idle → idle）
                if newState.isTerminal && previousState.isRunning {
                    self.autoSaveLogsIfNeeded(state: newState)
                }
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

        controller.$queueItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.queueItems = items
            }
            .store(in: &cancellables)

        controller.$isQueueRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.isQueueRunning = running
            }
            .store(in: &cancellables)

        controller.$activeQueueItemID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                self?.activeQueueItemID = id
            }
            .store(in: &cancellables)

        controller.$completedQueueItemCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.completedQueueItemCount = count
            }
            .store(in: &cancellables)

        // 设置日志回调
        controller.onLogOutput = { [weak self] entry in
            self?.appendLog(entry)
        }

        // 订阅进度更新（通过 Controller → FFmpegService → ProgressTracker）
        controller.onProgressUpdate = { [weak self] progressInfo in
            self?.progress = progressInfo
        }

        controller.onQueueItemStarted = { [weak self] item in
            self?.prepareForQueuedExecution(item)
        }

        // 监听 logs、filter、searchText 变化，使用 throttle 防抖处理
        // 避免每次 body 刷新都重新过滤整个日志数组
        Publishers.CombineLatest4($logs, $logFilter, $searchText, $isRegexSearchEnabled)
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] logs, filter, search, isRegexSearchEnabled in
                let result = Self.filterLogs(
                    logs,
                    filter: filter,
                    searchText: search,
                    isRegexSearchEnabled: isRegexSearchEnabled
                )
                self?.visibleLogs = result.logs
                self?.regexSearchError = result.errorMessage
            }
            .store(in: &cancellables)
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
        guard !isRunning, !isQueueRunning else { return }

        clearLogs()
        currentTemplateName = nil
        currentCommand = command

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
        currentTemplateName = template.name
        let binding = TemplateBinding.bind(template: template, values: values)
        await execute(binding: binding, forceOverwrite: forceOverwrite)
    }

    /// 执行模板绑定（推荐路径：复用详情页的权威绑定快照）
    func execute(
        binding: TemplateBinding,
        forceOverwrite: Bool = false
    ) async {
        guard !isRunning, !isQueueRunning else { return }

        clearLogs()
        currentTemplateName = binding.template.name
        currentCommand = CommandPlanner.preview(binding: binding).displayString

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
    ///   - displayCommand: 用于日志/最近使用显示的命令字符串
    /// - Note: 这是 Template → Execute 的推荐路径，直接使用参数数组，
    ///         避免 shell escaping + splitCommand 的不可逆问题
    func execute(
        arguments: [String],
        displayCommand: String,
        executable: CommandExecutable = .ffmpeg
    ) async {
        guard !isRunning, !isQueueRunning else { return }

        clearLogs()
        currentTemplateName = nil
        currentCommand = displayCommand

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
            level: .info,
            message: "用户取消执行"
        ))
    }

    /// 重置状态
    func reset() {
        controller.reset()
        lastResult = nil
        currentTemplateName = nil
        currentCommand = nil
        persistedLogs = []
        lastProgressLogTime = nil
        lastPersistedProgressLogTime = nil
    }

    @discardableResult
    func enqueue(
        binding: TemplateBinding,
        forceOverwrite: Bool = false
    ) throws -> ExecutionQueueItem {
        try controller.enqueue(binding: binding, forceOverwrite: forceOverwrite)
    }

    func startQueue() {
        controller.startQueue()
    }

    func removeQueuedItem(id: UUID) {
        controller.removeQueuedItem(id: id)
    }

    func clearQueue() {
        controller.clearQueue()
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
        searchText = ""
        regexSearchError = nil
        lastProgressLogTime = nil
        lastPersistedProgressLogTime = nil
        progress = nil
        persistedLogs = []
    }

    static func filterLogs(
        _ logs: [LogEntry],
        filter: LogFilter,
        searchText: String,
        isRegexSearchEnabled: Bool
    ) -> (logs: [LogEntry], errorMessage: String?) {
        let levelFiltered: [LogEntry]
        switch filter {
        case .all:
            levelFiltered = logs
        case .important:
            levelFiltered = logs.filter { $0.level == .error || $0.level == .warning }
        case .noDebug:
            levelFiltered = logs.filter { $0.level != .debug }
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            return (levelFiltered, nil)
        }

        guard isRegexSearchEnabled else {
            return (
                levelFiltered.filter { $0.message.localizedCaseInsensitiveContains(trimmedSearch) },
                nil
            )
        }

        do {
            let regex = try NSRegularExpression(pattern: trimmedSearch, options: [.caseInsensitive])
            let matched = levelFiltered.filter { entry in
                let range = NSRange(entry.message.startIndex..<entry.message.endIndex, in: entry.message)
                return regex.firstMatch(in: entry.message, options: [], range: range) != nil
            }
            return (matched, nil)
        } catch {
            return (levelFiltered, "正则无效: \(error.localizedDescription)")
        }
    }

    /// 添加日志条目
    func appendLog(_ entry: LogEntry) {
        append(entry, to: &persistedLogs, lastProgressTime: &lastPersistedProgressLogTime)
        append(entry, to: &logs, lastProgressTime: &lastProgressLogTime)
        trimLogsIfNeeded()
    }

    private func append(
        _ entry: LogEntry,
        to storage: inout [LogEntry],
        lastProgressTime: inout Date?
    ) {
        guard entry.isProgress, shouldCoalesceProgressLogs else {
            storage.append(entry)
            return
        }

        let now = entry.timestamp
        if let lastIndex = storage.indices.last,
           storage[lastIndex].isProgress,
           let lastTime = lastProgressTime,
           now.timeIntervalSince(lastTime) < progressCoalesceInterval {
            storage[lastIndex] = entry.withId(storage[lastIndex].id)
            lastProgressTime = now
            return
        }

        lastProgressTime = now
        storage.append(entry)
    }

    private func trimLogsIfNeeded() {
        guard logs.count > maxLogEntries else { return }

        let overflow = logs.count - maxLogEntries

        // 单次遍历：优先标记不重要日志为待移除
        var removedCount = 0
        var keepIndices: [Int] = []
        keepIndices.reserveCapacity(maxLogEntries)

        for i in logs.indices {
            if removedCount < overflow && !logs[i].isImportant {
                removedCount += 1
            } else {
                keepIndices.append(i)
            }
        }

        // 如果仍超出，从头部移除最旧的日志（含重要日志）
        if removedCount < overflow {
            let extra = overflow - removedCount
            keepIndices = Array(keepIndices.dropFirst(extra))
        }

        logs = keepIndices.map { logs[$0] }
    }

    private func prepareForQueuedExecution(_ item: ExecutionQueueItem) {
        clearLogs()
        lastResult = nil
        currentTemplateName = item.plan.templateName
        currentCommand = item.plan.displayCommand
        appendLog(LogEntry(
            timestamp: Date(),
            level: .info,
            message: "开始执行队列任务：\(item.title)"
        ))
    }

    /// 导出日志
    func exportLogs() -> String {
        persistedLogs.map { (entry: LogEntry) -> String in entry.displayString }.joined(separator: "\n")
    }

    // MARK: - Log Persistence (Auto-Save)

    /// 自动保存日志到磁盘
    private func autoSaveLogsIfNeeded(state: ExecutionState) {
        guard UserSettings.shared.autoSaveLog else { return }
        guard !logs.isEmpty else { return }

        // 提取执行结果信息
        let exitCode: Int32?
        switch state {
        case .completed(let result):
            exitCode = result.exitCode
        case .cancelled:
            exitCode = nil
        case .error:
            exitCode = nil
        default:
            return  // 非终态不保存
        }

        let command: String
        switch state {
        case .completed(let result):
            command = result.command
        default:
            command = currentCommand ?? lastResult?.command ?? "未知命令"
        }
        let templateName = currentTemplateName
        let logsSnapshot = persistedLogs.filter { !$0.isProgress }
        let maxSaved = max(UserSettings.shared.maxSavedLogs, 1)
        let service = logPersistenceService

        Task.detached {
            do {
                try await service.saveLogs(
                    logsSnapshot,
                    command: command,
                    templateName: templateName,
                    exitCode: exitCode
                )
                // 清理超出上限的旧日志
                try await service.cleanupOldLogs(keeping: maxSaved)
            } catch {
                AppLogger.notice(AppLogger.general, "日志自动保存失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Backward Compatibility

    var onHistoryChanged: (() -> Void)? {
        get { onRecentCommandsChanged }
        set { onRecentCommandsChanged = newValue }
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
