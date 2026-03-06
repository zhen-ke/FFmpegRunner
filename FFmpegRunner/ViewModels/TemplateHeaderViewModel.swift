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

    // MARK: - Published Properties

    /// 显示保存为模板弹窗
    @Published var showSaveAsTemplateSheet = false

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

    // MARK: - Initialization

    init(templateRepository: TemplateRepository = .shared) {
        self.templateRepository = templateRepository
    }

    // MARK: - Public Methods

    /// 从参数数组中检测输出文件路径
    func detectOutputPath(from arguments: [String]) -> String? {
        CommandPathDetector.detectOutputPath(from: arguments)
    }

    /// 检查输出文件并决定是否执行
    func checkAndExecuteCommand(
        binding: TemplateBinding?,
        currentCommand: RenderedCommand?,
        executionViewModel: ExecutionViewModel
    ) async {
        guard let binding, let currentCommand = currentCommand else { return }

        // 使用 arguments 检测输出文件路径
        if let outputPath = detectOutputPath(from: currentCommand.arguments) {
            if FileManager.default.fileExists(atPath: outputPath) {
                existingOutputFile = (outputPath as NSString).lastPathComponent
                showOverwriteConfirm = true
                return
            }
        }

        // 没有冲突，直接执行
        await executeCommand(
            forceOverwrite: false,
            binding: binding,
            executionViewModel: executionViewModel
        )
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
        let template = Template(
            id: "user-\(UUID().uuidString)",
            name: templateName,
            description: "用户创建于 \(Date().formatted(date: .abbreviated, time: .shortened))",
            commandTemplate: "{{command}}",
            parameters: [
                TemplateParameter(
                    key: "command",
                    label: "FFmpeg 命令",
                    type: .string,
                    defaultValue: command,
                    placeholder: "FFmpeg 命令",
                    isRequired: true,
                    constraints: nil,
                    role: .raw,
                    escapeStrategy: .raw,
                    uiHint: ParameterUIHint(multiline: true, monospace: true)
                )
            ],
            category: templateCategory.isEmpty ? "用户模板" : templateCategory,
            icon: "star.fill"
        )

        // 保存模板到用户目录 - 带错误处理
        do {
            try await saveTemplateToFile(template)

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

    /// 保存模板到文件 - 带错误处理
    private func saveTemplateToFile(_ template: Template) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        let data = try encoder.encode(template)

        let userTemplatesDir = templateRepository.userTemplatesDirectory

        try FileManager.default.createDirectory(
            at: userTemplatesDir,
            withIntermediateDirectories: true
        )

        let fileURL = userTemplatesDir.appendingPathComponent("\(template.id).json")
        try data.write(to: fileURL)
    }

    /// 重置表单状态
    func resetForm() {
        templateName = ""
        templateCategory = ""
        showSaveAsTemplateSheet = false
    }
}
