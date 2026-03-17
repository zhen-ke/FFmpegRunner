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
/// - ✅ 自动滚动状态持久化（autoScroll，@AppStorage source of truth）
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

    /// 过滤后的日志（缓存结果，避免每次 body 刷新都重新过滤）
    @Published private(set) var visibleLogs: [LogEntry] = []

    /// 最近的执行结果
    @Published private(set) var lastResult: ExecutionResult?

    /// FFmpeg 版本信息（从 Controller 同步）
    @Published private(set) var ffmpegVersion: String?

    // FIX 1: autoScroll 从 View 层的 @AppStorage + @State 双重状态
    //        下沉到 ViewModel，成为唯一 source of truth。
    //        View 层通过 Binding 读写，消除了 onAppear 首帧同步的闪烁风险。
    //
    //        原设计问题：
    //        - @AppStorage(preferredAutoScroll) + @State(autoScroll) 两份状态
    //        - onAppear { autoScroll = preferredAutoScroll } 存在首帧不一致
    //        - onChangeCompat 单向写回，逻辑分散在 View 层
    //
    //        修复：ViewModel 直接持有 @Published autoScroll，持久化在 UserDefaults
    //        通过 didSet 实现，View 层只使用 $viewModel.autoScroll Binding。
    @Published var autoScroll: Bool {
        didSet {
            UserDefaults.standard.set(autoScroll, forKey: "autoScrollLog")
            // 诊断：记录所有 autoScroll 赋值，包含调用栈，覆盖 ViewModel 层的路径
            #if DEBUG
            let stack = Thread.callStackSymbols.prefix(6).joined(separator: "\n    ")
            let ts = String(format: "%.4f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
            print("📌 [VM.autoScroll \(ts)] → \(autoScroll)\n    \(stack)")
            #endif
        }
    }

    /// 简短的 FFmpeg 版本号（优化 UI 显示）
    var ffmpegVersionShort: String {
        guard let fullVersion = ffmpegVersion else { return "FFmpeg" }
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

    // MARK: - Private State

    /// 日志裁剪的溢出容忍量
    /// FIX 3: 不再每次 appendLog 都裁剪，而是攒够 trimOverflowThreshold 条后批量裁剪
    /// 原设计：每条日志都触发 O(n) 遍历，FFmpeg 高频输出下持续有开销
    private let trimOverflowThreshold: Int = 50

    // MARK: - Dependencies

    /// 执行控制器 (Application Layer)
    private let controller: ExecutionController

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

    // MARK: - Initialization

    init(controller: ExecutionController? = nil) {
        // FIX 1 cont.: 初始化时从 UserDefaults 读取持久化值，不依赖 onAppear
        self.autoScroll = UserDefaults.standard.object(forKey: "autoScrollLog") as? Bool ?? true
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

        // FIX 4: 搜索与日志新增使用不同的防抖策略
        //
        // 原设计：所有场景统一 throttle(100ms)，搜索输入有明显延迟感
        //
        // 修复：在合并前各自预处理，保持单一 CombineLatest3 结构避免
        // @MainActor + assign(to:) 在分段 pipeline 下的编译器类型推断问题。
        // - $logs / $logFilter：throttle 100ms，高频日志不触发过多重算
        // - $searchText：debounce 50ms，输入停顿后立即响应
        Publishers.CombineLatest3(
            $logs.throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true),
            $logFilter.throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true),
            $searchText.debounce(for: .milliseconds(50), scheduler: RunLoop.main)
        )
        .map { logs, filter, search -> [LogEntry] in
            var result: [LogEntry]
            switch filter {
            case .all:
                result = logs
            case .important:
                result = logs.filter { $0.level == .error || $0.level == .warning }
            case .noDebug:
                result = logs.filter { $0.level != .debug }
            }
            if !search.isEmpty {
                result = result.filter {
                    $0.message.localizedCaseInsensitiveContains(search)
                }
            }
            return result
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
        searchText = ""
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

        // FIX 3 cont.: 批量裁剪，超出容忍量才触发，而非每条都检查
        // 触发条件：logs.count > maxLogEntries + trimOverflowThreshold
        // 这样在高频场景下，裁剪频率从 O(每条) 降低到 O(每 N 条)
        if logs.count > maxLogEntries + trimOverflowThreshold {
            trimLogs()
        }
    }

    /// 批量裁剪日志至 maxLogEntries
    private func trimLogs() {
        let overflow = logs.count - maxLogEntries
        guard overflow > 0 else { return }

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

        if removedCount < overflow {
            let extra = overflow - removedCount
            keepIndices = Array(keepIndices.dropFirst(extra))
        }

        logs = keepIndices.map { logs[$0] }
    }

    /// 导出日志
    func exportLogs() -> String {
        logs.map { (entry: LogEntry) -> String in entry.displayString }.joined(separator: "\n")
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

// MARK: - LogFilter 扩展
// FIX 3 cont.: 新增 shortLabel 供 Picker segmented style 使用（更简短的标签）

extension LogFilter {
    /// Picker 显示用短标签
    var shortLabel: String {
        switch self {
        case .all:       return "全部"
        case .important: return "重要"
        case .noDebug:   return "精简"
        }
    }
}
