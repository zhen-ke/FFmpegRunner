//
//  ExecutionController.swift
//  FFmpegRunner
//
//  Application Layer - 执行控制器
//
//  设计说明：
//  - 这是 Application Layer 的核心，负责执行流程编排
//  - 只做"调用顺序、生命周期、错误路由"
//  - 命令语义处理委托给 CommandPlanner
//  - ViewModel 只订阅状态变更，不处理业务逻辑
//  - CLI / UI / 自动化可共用同一条执行路径
//
//  职责边界：
//  - ✅ 执行调度（execute）
//  - ✅ 取消控制（cancel）
//  - ✅ 状态管理（state）
//  - ✅ 最近使用写入
//  - ✅ FFmpeg 可用性检测
//  - ❌ 命令拼装 → CommandPlanner
//  - ❌ 命令验证 → CommandPlanner
//  - ❌ 渲染检查 → CommandPlanner
//

import Foundation
import Combine

// MARK: - Execution Error

/// 执行错误类型
enum ExecutionError: LocalizedError {
    case ffmpegNotAvailable
    case planningFailed(String)
    case executionFailed(String)
    case timedOut(TimeInterval)
    case cancelled
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .ffmpegNotAvailable:
            return "FFmpeg 不可用"
        case .planningFailed(let message):
            return "规划失败: \(message)"
        case .executionFailed(let message):
            return "执行失败: \(message)"
        case .timedOut(let timeout):
            return "执行超时（\(Self.formattedTimeout(timeout))）"
        case .cancelled:
            return "执行已取消"
        case .alreadyRunning:
            return "已有任务正在执行"
        }
    }

    static func formattedTimeout(_ timeout: TimeInterval) -> String {
        let totalSeconds = max(Int(timeout.rounded()), 1)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return seconds == 0
                ? "\(hours) 小时 \(minutes) 分钟"
                : "\(hours) 小时 \(minutes) 分钟 \(seconds) 秒"
        }

        if minutes > 0 {
            return seconds == 0 ? "\(minutes) 分钟" : "\(minutes) 分钟 \(seconds) 秒"
        }

        return "\(seconds) 秒"
    }
}

// MARK: - Execution Controller

/// 执行控制器
/// Application Layer 的核心，负责执行流程编排
///
/// 职责：
/// - 执行调度
/// - 取消控制
/// - 状态管理
/// - 最近使用写入
/// - FFmpeg 可用性检测
///
/// 注意：此控制器不持有 UI 状态，通过 Combine Publisher 通知变更
@MainActor
final class ExecutionController: ObservableObject {

    // MARK: - Published Properties

    /// 当前执行状态
    @Published private(set) var state: ExecutionState = .idle

    /// FFmpeg 是否可用
    @Published private(set) var isFFmpegAvailable = false

    /// FFmpeg 版本信息
    @Published private(set) var ffmpegVersion: String?

    /// 等待执行的队列项
    @Published private(set) var queueItems: [ExecutionQueueItem] = []

    /// 是否正在消费队列
    @Published private(set) var isQueueRunning = false

    /// 当前正在执行的队列项
    @Published private(set) var activeQueueItemID: UUID?

    /// 本轮队列已完成的任务数
    @Published private(set) var completedQueueItemCount = 0

    // MARK: - Dependencies

    private let ffmpegService: FFmpegService
    private let recentCommandsService: RecentCommandsService
    private var cancellables = Set<AnyCancellable>()
    private var queueTask: Task<Void, Never>?
    private var shouldStopQueueAfterCurrentItem = false
    private var isExecutingQueuedItem = false

    // MARK: - Callbacks

    /// 日志输出回调
    var onLogOutput: ((LogEntry) -> Void)?

    /// 进度更新回调
    var onProgressUpdate: ((FFmpegProgress) -> Void)?

    /// 最近使用变更回调
    var onRecentCommandsChanged: (() -> Void)?

    /// 队列项开始执行回调
    var onQueueItemStarted: ((ExecutionQueueItem) -> Void)?

    /// 队列执行结束回调
    var onQueueFinished: (() -> Void)?

    // MARK: - Initialization

    init(
        ffmpegService: FFmpegService? = nil,
        recentCommandsService: RecentCommandsService? = nil
    ) {
        self.ffmpegService = ffmpegService ?? FFmpegService.shared
        self.recentCommandsService = recentCommandsService ?? RecentCommandsService.shared

        // 设置日志回调转发
        self.ffmpegService.onLogOutput = { [weak self] entry in
            Task { @MainActor in
                self?.onLogOutput?(entry)
            }
        }

        // 设置进度回调转发
        self.ffmpegService.onProgressUpdate = { [weak self] progress in
            Task { @MainActor in
                self?.onProgressUpdate?(progress)
            }
        }

        self.ffmpegService.$ffmpegPath
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshFFmpegState()
            }
            .store(in: &cancellables)

        // 检查 FFmpeg 可用性
        checkFFmpegAvailability()
    }

    // MARK: - FFmpeg Availability

    /// 检查 FFmpeg 可用性
    func checkFFmpegAvailability() {
        refreshFFmpegState()
    }

    /// 设置 FFmpeg 来源
    func setFFmpegSource(_ source: FFmpegSource, customPath: String? = nil) {
        ffmpegService.setSource(source, customPath: customPath)
        checkFFmpegAvailability()
    }

    // MARK: - Execute with Plan

    /// 执行计划
    /// - Parameter plan: 执行计划（来自 CommandPlanner）
    /// - Returns: 执行结果
    @discardableResult
    func execute(plan: ExecutionPlan) async throws -> ExecutionResult {
        // 仅阻止真实运行中的并发；.preparing 可能来自当前调用链（command/template -> plan）
        if ffmpegService.isRunning || state.isCancelling || (isQueueRunning && !isExecutingQueuedItem) {
            throw ExecutionError.alreadyRunning
        }

        guard ffmpegService.isExecutableAvailable(for: plan.executable) else {
            let message = "\(plan.executable.binaryName) 不可用"
            state = .error(message)
            throw ExecutionError.executionFailed(message)
        }

        state = .running

        do {
            let result = try await executePlanWithTimeoutIfNeeded(plan)

            // ✅ 兼容外部取消（未显式调用 cancel）
            if Task.isCancelled || state.isCancelling {
                state = .cancelled
                throw ExecutionError.cancelled
            }

            state = .completed(result)

            await recordRecentCommand(for: plan, wasSuccessful: result.isSuccess)

            // 通知（按实际退出码区分成功/失败）
            let notificationMessage: String
            if result.isSuccess {
                notificationMessage = "耗时: \(result.formattedDuration)"
            } else {
                notificationMessage = "退出码: \(result.exitCode)，耗时: \(result.formattedDuration)"
            }
            notifyCompletion(
                success: result.isSuccess,
                plan: plan,
                message: notificationMessage
            )

            return result

        } catch let error as ExecutionError {
            switch error {
            case .cancelled:
                state = .cancelled
                throw error
            case .timedOut:
                state = .error(error.localizedDescription)

                await recordRecentCommand(for: plan, wasSuccessful: false)

                notifyCompletion(
                    success: false,
                    plan: plan,
                    message: error.localizedDescription
                )

                throw error
            default:
                state = .error(error.localizedDescription)

                await recordRecentCommand(for: plan, wasSuccessful: false)

                notifyCompletion(
                    success: false,
                    plan: plan,
                    message: "执行失败，请查看日志"
                )

                throw error
            }
        } catch is CancellationError {
            state = .cancelled
            throw ExecutionError.cancelled
        } catch {
            // 检查是否是取消
            if state.isCancelling || Task.isCancelled {
                state = .cancelled
                throw ExecutionError.cancelled
            }

            state = .error(error.localizedDescription)

            await recordRecentCommand(for: plan, wasSuccessful: false)

            // 通知（失败）
            notifyCompletion(
                success: false,
                plan: plan,
                message: "执行失败，请查看日志"
            )

            throw ExecutionError.executionFailed(error.localizedDescription)
        }
    }

    // MARK: - Convenience Execute Methods

    /// 执行模板（便捷方法：规划 + 执行）
    /// - Parameters:
    ///   - template: 模板定义
    ///   - values: 参数值列表
    /// - Returns: 执行结果
    @discardableResult
    func execute(
        template: Template,
        values: [TemplateValue],
        forceOverwrite: Bool = false
    ) async throws -> ExecutionResult {
        let binding = TemplateBinding.bind(template: template, values: values)
        return try await execute(binding: binding, forceOverwrite: forceOverwrite)
    }

    /// 执行模板绑定（便捷方法：已验证绑定 + 执行）
    /// - Parameters:
    ///   - binding: 模板绑定快照
    ///   - forceOverwrite: 是否强制覆盖输出
    /// - Returns: 执行结果
    @discardableResult
    func execute(
        binding: TemplateBinding,
        forceOverwrite: Bool = false
    ) async throws -> ExecutionResult {
        guard !state.isRunning, !isQueueRunning else {
            throw ExecutionError.alreadyRunning
        }

        state = .preparing

        do {
            let plan = try makeExecutionPlan(binding: binding, forceOverwrite: forceOverwrite)
            return try await execute(plan: plan)
        } catch let error as CommandPlannerError {
            state = .error(error.localizedDescription)
            throw ExecutionError.planningFailed(error.localizedDescription)
        }
    }

    /// 执行原始命令（便捷方法：规划 + 执行）
    /// - Parameter command: 原始命令字符串
    /// - Returns: 执行结果
    @discardableResult
    func execute(command: String) async throws -> ExecutionResult {
        guard !state.isRunning, !isQueueRunning else {
            throw ExecutionError.alreadyRunning
        }

        state = .preparing

        do {
            let plan = try CommandPlanner.prepare(command: command)
            return try await execute(plan: plan)
        } catch let error as CommandPlannerError {
            state = .error(error.localizedDescription)
            throw ExecutionError.planningFailed(error.localizedDescription)
        }
    }

    /// 执行参数数组（便捷方法，用于已验证的模板路径）
    /// - Parameters:
    ///   - arguments: 参数数组
    ///   - displayCommand: 显示命令
    /// - Returns: 执行结果
    @discardableResult
    func execute(
        arguments: [String],
        displayCommand: String,
        executable: CommandExecutable = .ffmpeg
    ) async throws -> ExecutionResult {
        guard !state.isRunning, !isQueueRunning else {
            throw ExecutionError.alreadyRunning
        }

        let plan = ExecutionPlan(
            arguments: arguments,
            displayCommand: displayCommand,
            executable: executable
        )
        return try await execute(plan: plan)
    }

    // MARK: - Queue

    @discardableResult
    func enqueue(plan: ExecutionPlan) -> ExecutionQueueItem {
        let item = ExecutionQueueItem(plan: plan)
        queueItems.append(item)
        return item
    }

    @discardableResult
    func enqueue(
        binding: TemplateBinding,
        forceOverwrite: Bool = false
    ) throws -> ExecutionQueueItem {
        do {
            let plan = try makeExecutionPlan(binding: binding, forceOverwrite: forceOverwrite)
            return enqueue(plan: plan)
        } catch let error as CommandPlannerError {
            throw ExecutionError.planningFailed(error.localizedDescription)
        }
    }

    func removeQueuedItem(id: UUID) {
        guard activeQueueItemID != id else { return }
        queueItems.removeAll { $0.id == id }
        if queueItems.isEmpty && !state.isRunning {
            completedQueueItemCount = 0
        }
    }

    func clearQueue() {
        if let activeQueueItemID {
            queueItems.removeAll { $0.id == activeQueueItemID }
            shouldStopQueueAfterCurrentItem = true
            return
        }

        queueItems = []
        completedQueueItemCount = 0
    }

    func startQueue() {
        guard !isQueueRunning, !queueItems.isEmpty, !state.isRunning else { return }

        isQueueRunning = true
        completedQueueItemCount = 0
        shouldStopQueueAfterCurrentItem = false

        queueTask = Task { [weak self] in
            await self?.runQueue()
        }
    }

    // MARK: - Cancel

    /// 取消当前执行
    func cancel() {
        if isQueueRunning {
            shouldStopQueueAfterCurrentItem = true

            if let activeQueueItemID {
                queueItems.removeAll { $0.id != activeQueueItemID }
            } else {
                queueItems = []
                finishQueueRun()
            }
        }

        guard state.isRunning else { return }

        state = .cancelling
        ffmpegService.cancel()

        // 如果取消后状态还是 cancelling，强制设为 cancelled
        // （正常情况下 execute 会在捕获到取消时设置 cancelled）
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            if state.isCancelling {
                state = .cancelled
            }
        }
    }

    // MARK: - State Management

    /// 重置状态
    func reset() {
        state = .idle
    }

    // MARK: - Private Helpers

    private func recordRecentCommand(for plan: ExecutionPlan, wasSuccessful: Bool) async {
        do {
            try await recentCommandsService.recordUsage(
                RecentCommandUsage(
                    executable: plan.executable,
                    arguments: plan.arguments,
                    displayCommand: plan.displayCommand,
                    usedAt: Date(),
                    wasSuccessful: wasSuccessful,
                    templateSnapshot: makeTemplateSnapshot(from: plan)
                )
            )
            onRecentCommandsChanged?()
        } catch {
            AppLogger.notice(AppLogger.history, "Failed to persist recent command: \(error)")
        }
    }

    private func notifyCompletion(success: Bool, plan: ExecutionPlan, message: String) {
        Task {
            let outputPath = success ? plan.outputDirectoryPath : nil

            await NotificationService.shared.sendExecutionNotification(
                success: success,
                message: message,
                outputDirectory: outputPath
            )
        }
    }

    private func makeTemplateSnapshot(from plan: ExecutionPlan) -> RecentCommandTemplateSnapshot? {
        guard let templateId = plan.templateId,
              let bindings = plan.validatedBindings else {
            return nil
        }

        let parameterValues = Dictionary(
            uniqueKeysWithValues: bindings.map { ($0.key, $0.rawValue) }
        )

        return RecentCommandTemplateSnapshot(
            templateId: templateId,
            templateName: plan.templateName,
            parameterValues: parameterValues
        )
    }

    private func makeExecutionPlan(
        binding: TemplateBinding,
        forceOverwrite: Bool
    ) throws -> ExecutionPlan {
        var plan = try CommandPlanner.prepare(binding: binding)
        if forceOverwrite,
           plan.executable == .ffmpeg,
           !plan.arguments.contains("-y"),
           !plan.arguments.contains("-n") {
            var overwrittenArguments = plan.arguments
            overwrittenArguments.insert("-y", at: 0)
            plan = ExecutionPlan(
                arguments: overwrittenArguments,
                displayCommand: plan.displayCommand,
                executable: plan.executable,
                templateId: plan.templateId,
                templateName: plan.templateName,
                validatedBindings: plan.validatedBindings,
                createdAt: plan.createdAt
            )
        }
        return plan
    }

    private func runQueue() async {
        defer {
            finishQueueRun()
        }

        while !Task.isCancelled {
            guard let item = queueItems.first else { return }

            activeQueueItemID = item.id
            onQueueItemStarted?(item)

            do {
                isExecutingQueuedItem = true
                _ = try await execute(plan: item.plan)
            } catch {
                if Task.isCancelled {
                    return
                }
            }

            isExecutingQueuedItem = false
            queueItems.removeAll { $0.id == item.id }
            completedQueueItemCount += 1
            activeQueueItemID = nil

            if shouldStopQueueAfterCurrentItem {
                queueItems = []
                return
            }
        }
    }

    private func finishQueueRun() {
        queueTask?.cancel()
        queueTask = nil
        isExecutingQueuedItem = false
        isQueueRunning = false
        activeQueueItemID = nil
        shouldStopQueueAfterCurrentItem = false
        onQueueFinished?()
    }

    private func executePlanWithTimeoutIfNeeded(_ plan: ExecutionPlan) async throws -> ExecutionResult {
        guard let timeout = UserSettings.shared.maximumExecutionTime else {
            return try await ffmpegService.execute(
                arguments: plan.arguments,
                displayCommand: plan.displayCommand,
                executable: plan.executable
            )
        }

        let ffmpegService = self.ffmpegService
        let onLogOutput = self.onLogOutput
        let timeoutState = ExecutionTimeoutState()

        return try await withThrowingTaskGroup(of: ExecutionResult.self) { group in
            group.addTask { [ffmpegService] in
                try await ffmpegService.execute(
                    arguments: plan.arguments,
                    displayCommand: plan.displayCommand,
                    executable: plan.executable
                )
            }

            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else {
                    throw CancellationError()
                }

                await timeoutState.markTriggered()

                await MainActor.run {
                    onLogOutput?(LogEntry(
                        timestamp: Date(),
                        level: .warning,
                        message: "已达到全局超时 \(ExecutionError.formattedTimeout(timeout))，正在停止任务"
                    ))
                    ffmpegService.cancel()
                }

                try await Self.waitUntilExecutionStops(ffmpegService: ffmpegService)
                throw ExecutionError.timedOut(timeout)
            }

            do {
                guard let result = try await group.next() else {
                    throw ExecutionError.executionFailed("执行结果缺失")
                }

                if await timeoutState.isTriggered {
                    group.cancelAll()
                    throw ExecutionError.timedOut(timeout)
                }

                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private static func waitUntilExecutionStops(ffmpegService: FFmpegService?) async throws {
        guard let ffmpegService else { return }

        let deadline = Date().addingTimeInterval(10)
        while await MainActor.run(body: { ffmpegService.isRunning }) {
            if Date() >= deadline {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func refreshFFmpegState() {
        isFFmpegAvailable = ffmpegService.isFFmpegAvailable()

        guard isFFmpegAvailable else {
            ffmpegVersion = nil
            return
        }

        let pathSnapshot = ffmpegService.ffmpegPath
        Task { [weak self] in
            guard let self else { return }
            do {
                let version = try await ffmpegService.getFFmpegVersion()
                if ffmpegService.ffmpegPath == pathSnapshot {
                    ffmpegVersion = version
                }
            } catch {
                if ffmpegService.ffmpegPath == pathSnapshot {
                    ffmpegVersion = nil
                }
            }
        }
    }

    // MARK: - Backward Compatibility

    /// 兼容旧调用点
    var onHistoryChanged: (() -> Void)? {
        get { onRecentCommandsChanged }
        set { onRecentCommandsChanged = newValue }
    }
}

private actor ExecutionTimeoutState {
    private(set) var isTriggered = false

    func markTriggered() {
        isTriggered = true
    }
}
