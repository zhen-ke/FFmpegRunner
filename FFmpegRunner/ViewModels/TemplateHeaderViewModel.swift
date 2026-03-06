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

    /// 执行前确认标题
    @Published private(set) var runConfirmationTitle = "确认执行"

    /// 执行前确认内容
    @Published private(set) var runConfirmationMessage = ""

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

    init(templateRepository: TemplateRepository = .shared) {
        self.templateRepository = templateRepository
    }

    // MARK: - Public Methods

    /// 从参数数组中检测输出文件路径
    func detectOutputPath(from arguments: [String]) -> String? {
        CommandPathDetector.detectOutputPath(from: arguments)
    }

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

        if UserSettings.shared.confirmBeforeRun {
            prepareRunConfirmation(for: request)
            showRunConfirmation = true
            return
        }

        await continuePendingExecution(executionViewModel: executionViewModel)
    }

    func confirmPendingExecution(executionViewModel: ExecutionViewModel) async {
        showRunConfirmation = false
        await continuePendingExecution(executionViewModel: executionViewModel)
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
        showOverwriteConfirm = false
        existingOutputFile = ""
        runConfirmationMessage = ""
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

            // 刷新模板列表
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

    private func outputConflictExists(for request: PendingExecutionRequest) -> Bool {
        guard let outputPath = detectOutputPath(from: request.currentCommand.arguments),
              FileManager.default.fileExists(atPath: outputPath) else {
            existingOutputFile = ""
            return false
        }

        existingOutputFile = (outputPath as NSString).lastPathComponent
        return true
    }

    private func prepareRunConfirmation(for request: PendingExecutionRequest) {
        runConfirmationTitle = "执行「\(request.templateName)」"

        let commandPreview = request.currentCommand.displayString.count > 160
            ? String(request.currentCommand.displayString.prefix(160)) + "..."
            : request.currentCommand.displayString

        if let outputPath = detectOutputPath(from: request.currentCommand.arguments), !outputPath.isEmpty {
            runConfirmationMessage = """
            输出: \(outputPath)

            \(commandPreview)
            """
        } else {
            runConfirmationMessage = commandPreview
        }
    }
}
