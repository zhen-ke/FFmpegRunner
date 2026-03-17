//
//  TemplateHeaderViewModel.swift
//  FFmpegRunner
//
//  模板头部视图 ViewModel - 管理执行、保存模板等业务逻辑
//

import Foundation
import SwiftUI

/// 模板头部视图 ViewModel
@MainActor
class TemplateHeaderViewModel: ObservableObject {

    private struct PendingExecutionRequest {
        let binding: TemplateBinding
        let currentCommand: RenderedCommand
        let templateName: String
    }

    // MARK: - Published Properties

    /// 显示保存为模板弹窗
    @Published var showSaveAsTemplateSheet = false

    /// 显示执行前确认
    @Published var showRunConfirmation = false

    /// 显示执行前完整预览
    @Published var showRunPreviewSheet = false

    /// 显示首次运行安全提醒
    @Published var showSafetyWarning = false

    /// 执行前确认标题
    @Published private(set) var runConfirmationTitle = "确认执行"

    /// 执行前确认内容
    @Published private(set) var runConfirmationMessage = ""

    /// 执行前预览标题
    @Published private(set) var runPreviewTitle = "执行预览"

    /// 执行前预览的完整命令
    @Published private(set) var runPreviewCommand = ""

    /// 执行前预览的输出路径
    @Published private(set) var runPreviewOutputPath: String?

    /// 执行前预览的可执行文件
    @Published private(set) var runPreviewExecutable = CommandExecutable.ffmpeg.binaryName

    /// 显示覆盖确认对话框
    @Published var showOverwriteConfirm = false

    /// 待覆盖的文件名
    @Published var existingOutputFile = ""

    /// 模板名称
    @Published var templateName = ""

    /// 模板分类
    @Published var templateCategory = ""

    // MARK: - Error Handling

    /// 显示错误提示
    @Published var showError = false

    /// 错误信息
    @Published var errorMessage = ""

    /// 显示成功提示
    @Published var showSuccess = false

    /// 成功信息
    @Published var successMessage = ""

    // MARK: - Dependencies

    private let templateRepository: TemplateRepository
    private var pendingExecutionRequest: PendingExecutionRequest?

    // MARK: - Initialization

    init(templateRepository: TemplateRepository? = nil) {
        self.templateRepository = templateRepository ?? .shared
    }

    // MARK: - Public Methods

    /// 统一处理执行请求（按钮 / 菜单 / 快捷键共用）
    func requestExecution(
        binding: TemplateBinding?,
        currentCommand: RenderedCommand?,
        executionViewModel: ExecutionViewModel
    ) async {
        guard let binding,
              let currentCommand = currentCommand,
              !executionViewModel.isRunning else {
            return
        }

        let request = PendingExecutionRequest(
            binding: binding,
            currentCommand: currentCommand,
            templateName: binding.template.name
        )
        pendingExecutionRequest = request

        if CommandValidator.needsFirstRunWarning(
            hasAcknowledged: UserSettings.shared.hasAcknowledgedSafetyWarning
        ) {
            showSafetyWarning = true
            return
        }

        await presentExecutionReviewIfNeeded(executionViewModel: executionViewModel)
    }

    func confirmPendingExecution(executionViewModel: ExecutionViewModel) async {
        showRunConfirmation = false
        showRunPreviewSheet = false
        await continuePendingExecution(executionViewModel: executionViewModel)
    }

    func acknowledgeSafetyWarning(executionViewModel: ExecutionViewModel) async {
        UserSettings.shared.hasAcknowledgedSafetyWarning = true
        showSafetyWarning = false
        await presentExecutionReviewIfNeeded(executionViewModel: executionViewModel)
    }

    func confirmPendingOverwrite(executionViewModel: ExecutionViewModel) async {
        guard let request = pendingExecutionRequest else { return }

        showOverwriteConfirm = false
        pendingExecutionRequest = nil
        await executeCommand(
            forceOverwrite: true,
            binding: request.binding,
            executionViewModel: executionViewModel
        )
    }

    func cancelPendingExecution() {
        pendingExecutionRequest = nil
        showRunConfirmation = false
        showRunPreviewSheet = false
        showSafetyWarning = false
        showOverwriteConfirm = false
        existingOutputFile = ""
        runConfirmationMessage = ""
        runPreviewCommand = ""
        runPreviewOutputPath = nil
        runPreviewExecutable = CommandExecutable.ffmpeg.binaryName
    }

    /// 执行命令
    func executeCommand(
        forceOverwrite: Bool,
        binding: TemplateBinding?,
        executionViewModel: ExecutionViewModel
    ) async {
        guard let binding else { return }

        await executionViewModel.execute(
            binding: binding,
            forceOverwrite: forceOverwrite
        )
    }

    /// 保存为模板
    func saveAsTemplate(
        command: String,
        listViewModel: TemplateListViewModel,
        executionViewModel: ExecutionViewModel
    ) async {
        let template = Template.makeRawCommandTemplate(
            id: "user-\(UUID().uuidString)",
            name: templateName,
            description: "用户创建于 \(Date().formatted(date: .abbreviated, time: .shortened))",
            defaultCommand: command,
            placeholder: "FFmpeg 命令",
            category: templateCategory.isEmpty ? "用户模板" : templateCategory,
            icon: "star.fill"
        )

        // 保存模板到用户目录 - 带错误处理
        do {
            try templateRepository.saveUserTemplate(template)

            // 成功提示
            successMessage = "模板「\(templateName)」保存成功"
            showSuccess = true

            // 重新加载模板列表以纳入新保存的模板
            await listViewModel.loadTemplates()

            // 清空控制台和重置执行状态
            executionViewModel.clearLogs()
            executionViewModel.reset()

            // 重置表单
            templateName = ""
            templateCategory = ""

        } catch {
            errorMessage = "保存模板失败: \(error.localizedDescription)"
            showError = true
        }
    }

    /// 重置表单状态
    func resetForm() {
        templateName = ""
        templateCategory = ""
        showSaveAsTemplateSheet = false
    }

    private func continuePendingExecution(executionViewModel: ExecutionViewModel) async {
        guard let request = pendingExecutionRequest else { return }

        let outputExists = request.currentCommand.executable == .ffmpeg && outputConflictExists(for: request)
        if outputExists && UserSettings.shared.confirmOverwrite {
            showOverwriteConfirm = true
            return
        }

        pendingExecutionRequest = nil
        await executeCommand(
            forceOverwrite: outputExists,
            binding: request.binding,
            executionViewModel: executionViewModel
        )
    }

    private func presentExecutionReviewIfNeeded(executionViewModel: ExecutionViewModel) async {
        guard let request = pendingExecutionRequest else { return }

        guard UserSettings.shared.confirmBeforeRun else {
            await continuePendingExecution(executionViewModel: executionViewModel)
            return
        }

        if UserSettings.shared.showCommandPreviewBeforeRun {
            prepareRunPreview(for: request)
            showRunPreviewSheet = true
        } else {
            prepareRunConfirmation(for: request)
            showRunConfirmation = true
        }
    }

    private func outputConflictExists(for request: PendingExecutionRequest) -> Bool {
        guard let outputPath = request.currentCommand.outputPath,
              FileManager.default.fileExists(atPath: outputPath) else {
            existingOutputFile = ""
            return false
        }

        existingOutputFile = request.currentCommand.outputFileName ?? (outputPath as NSString).lastPathComponent
        return true
    }

    private func prepareRunConfirmation(for request: PendingExecutionRequest) {
        runConfirmationTitle = "执行「\(request.templateName)」"

        let commandPreview = request.currentCommand.displayString.count > 160
            ? String(request.currentCommand.displayString.prefix(160)) + "..."
            : request.currentCommand.displayString

        if let outputPath = request.currentCommand.outputPath, !outputPath.isEmpty {
            runConfirmationMessage = """
            输出: \(outputPath)

            \(commandPreview)
            """
        } else {
            runConfirmationMessage = commandPreview
        }
    }

    private func prepareRunPreview(for request: PendingExecutionRequest) {
        runPreviewTitle = "执行「\(request.templateName)」"
        runPreviewCommand = request.currentCommand.displayString
        runPreviewOutputPath = request.currentCommand.outputPath
        runPreviewExecutable = request.currentCommand.executable.binaryName
    }
}
