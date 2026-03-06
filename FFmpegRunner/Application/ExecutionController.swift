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
//  - ✅ 历史记录写入
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
        case .cancelled:
            return "执行已取消"
        case .alreadyRunning:
            return "已有任务正在执行"
        }
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
/// - 历史记录写入
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

    // MARK: - Dependencies

    private let ffmpegService: FFmpegService
    private let historyService: HistoryService
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Callbacks

    /// 日志输出回调
    var onLogOutput: ((LogEntry) -> Void)?

    /// 历史记录变更回调
    var onHistoryChanged: (() -> Void)?

    // MARK: - Initialization

    init(
        ffmpegService: FFmpegService? = nil,
        historyService: HistoryService? = nil
    ) {
        self.ffmpegService = ffmpegService ?? FFmpegService.shared
        self.historyService = historyService ?? HistoryService.shared

        // 设置日志回调转发
        self.ffmpegService.onLogOutput = { [weak self] entry in
            Task { @MainActor in
                self?.onLogOutput?(entry)
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
        if ffmpegService.isRunning || state.isCancelling {
            throw ExecutionError.alreadyRunning
        }

        guard ffmpegService.isExecutableAvailable(for: plan.executable) else {
            let message = "\(plan.executable.binaryName) 不可用"
            state = .error(message)
            throw ExecutionError.executionFailed(message)
        }

        state = .running

        do {
            let result = try await ffmpegService.execute(
                arguments: plan.arguments,
                displayCommand: plan.displayCommand,
                executable: plan.executable
            )

            // ✅ 兼容外部取消（未显式调用 cancel）
            if Task.isCancelled || state.isCancelling {
                state = .cancelled
                throw ExecutionError.cancelled
            }

            state = .completed(result)

            // 保存到历史记录
            saveToHistory(command: plan.displayCommand, wasSuccessful: result.isSuccess)

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

            // 失败也保存到历史
            saveToHistory(command: plan.displayCommand, wasSuccessful: false)

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
        guard !state.isRunning else {
            throw ExecutionError.alreadyRunning
        }

        state = .preparing

        do {
            var plan = try CommandPlanner.prepare(template: template, values: values)
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
        guard !state.isRunning else {
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
        guard !state.isRunning else {
            throw ExecutionError.alreadyRunning
        }

        let plan = ExecutionPlan(
            arguments: arguments,
            displayCommand: displayCommand,
            executable: executable
        )
        return try await execute(plan: plan)
    }

    // MARK: - Cancel

    /// 取消当前执行
    func cancel() {
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

    private func saveToHistory(command: String, wasSuccessful: Bool) {
        Task {
            let entry = CommandHistory(
                command: command,
                wasSuccessful: wasSuccessful
            )
            try? await historyService.addEntry(entry)
            // 通知变更 (回到主线程)
            await MainActor.run {
                self.onHistoryChanged?()
            }
        }
    }

    private func notifyCompletion(success: Bool, plan: ExecutionPlan, message: String) {
        Task {
            let outputPath: String? = success
                ? CommandPathDetector.detectOutputDirectory(from: plan.arguments)?.path
                : nil
            await NotificationService.shared.sendExecutionNotification(
                success: success,
                message: message,
                outputDirectory: outputPath
            )
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
}
