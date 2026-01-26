//
//  MainSplitView.swift
//  FFmpegRunner
//
//  主分栏视图
//

import SwiftUI

/// 主分栏视图
struct MainSplitView: View {

    // MARK: - Environment

    @EnvironmentObject var listViewModel: TemplateListViewModel
    @EnvironmentObject var detailViewModel: TemplateDetailViewModel
    @EnvironmentObject var previewViewModel: CommandPreviewViewModel
    @EnvironmentObject var executionViewModel: ExecutionViewModel

    // MARK: - State

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 左侧：模板列表
            TemplateListView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } detail: {
            // 右侧：详情视图
            if listViewModel.selectedTemplate != nil {
                DetailContentView()
            } else {
                EmptyStateView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await listViewModel.loadTemplates()
        }
        .onChange(of: listViewModel.selectedTemplate) { newTemplate in
            Task { @MainActor in
                detailViewModel.template = newTemplate
                previewViewModel.update(from: detailViewModel)
                // 切换模板或历史记录时，重置控制台
                executionViewModel.clearLogs()
                executionViewModel.reset()
            }
        }
    }
}

// MARK: - 详情内容视图

struct DetailContentView: View {

    @EnvironmentObject var detailViewModel: TemplateDetailViewModel
    @EnvironmentObject var previewViewModel: CommandPreviewViewModel
    @EnvironmentObject var executionViewModel: ExecutionViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 模板信息头部
            TemplateHeaderView()

            Divider()

            // 主内容区域
            HSplitView {
                // 左侧：参数表单
                VStack(spacing: 0) {
                    Text("参数设置")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))

                    Divider()

                    ScrollView {
                        ParameterFormView()
                            .padding()
                    }
                }
                .frame(minWidth: 300)

                // 右侧：命令预览和日志
                VStack(spacing: 0) {
                    // 命令预览
                    CommandPreviewView()
                        .padding([.horizontal, .top], 12)
                        .padding(.bottom, 4)
                        .frame(minHeight: 140, maxHeight: 220)

                    Divider()

                    // 日志控制台
                    LogConsoleView()
                }
                .frame(minWidth: 400)
            }
        }
        .onChange(of: detailViewModel.values) { _ in
            Task { @MainActor in
                previewViewModel.update(from: detailViewModel)
            }
        }
    }
}

// MARK: - 模板头部视图

struct TemplateHeaderView: View {

    @EnvironmentObject var detailViewModel: TemplateDetailViewModel
    @EnvironmentObject var previewViewModel: CommandPreviewViewModel
    @EnvironmentObject var executionViewModel: ExecutionViewModel
    @EnvironmentObject var listViewModel: TemplateListViewModel

    @State private var showSaveAsTemplateSheet = false
    @State private var templateName = ""
    @State private var templateCategory = ""

    @State private var showOverwriteConfirm = false
    @State private var existingOutputFile = ""

    var body: some View {
        HStack {
            // 模板信息
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let icon = detailViewModel.template?.icon {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(.accentColor)
                    }

                    Text(detailViewModel.template?.name ?? "")
                        .font(.title2)
                        .fontWeight(.semibold)
                }

                Text(detailViewModel.template?.description ?? "")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 操作按钮
            HStack(spacing: 12) {
                // 保存为模板按钮（仅在 RawCommand 模板且成功执行后显示）
                if canShowSaveAsTemplate {
                    Button(action: { showSaveAsTemplateSheet = true }) {
                        Label("保存为模板", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }

                // 重置按钮
                Button(action: detailViewModel.resetToDefaults) {
                    Label("重置", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .disabled(executionViewModel.isRunning)

                // 执行/取消按钮
                if executionViewModel.isRunning {
                    Button(action: executionViewModel.cancel) {
                        Label("取消", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button(action: checkAndExecuteCommand) {
                        Label("执行", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!detailViewModel.canExecute || !previewViewModel.isComplete)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $showSaveAsTemplateSheet) {
            SaveAsTemplateSheet(
                command: previewViewModel.renderedCommand,
                templateName: $templateName,
                templateCategory: $templateCategory,
                onSave: saveAsTemplate
            )
        }
        .alert("文件已存在", isPresented: $showOverwriteConfirm) {
            Button("取消", role: .cancel) {}
            Button("覆盖", role: .destructive) {
                executeCommand(forceOverwrite: true)
            }
        } message: {
            Text("输出文件「\(existingOutputFile)」已存在，是否覆盖？")
        }
    }

    /// 是否显示保存为模板按钮
    private var canShowSaveAsTemplate: Bool {
        guard let template = detailViewModel.template else { return false }
        let isRawCommand = template.id == Template.rawCommandId
        let hasSuccessfulResult = executionViewModel.lastResult?.isSuccess == true
        return isRawCommand && hasSuccessfulResult && !executionViewModel.isRunning
    }

    /// 检查输出文件并决定是否执行
    private func checkAndExecuteCommand() {
        guard let currentCommand = previewViewModel.currentCommand else { return }

        // 使用 arguments 检测输出文件路径（避免再次解析命令字符串）
        if let outputPath = detectOutputPath(from: currentCommand.arguments) {
            if FileManager.default.fileExists(atPath: outputPath) {
                existingOutputFile = (outputPath as NSString).lastPathComponent
                showOverwriteConfirm = true
                return
            }
        }

        // 没有冲突，直接执行
        executeCommand(forceOverwrite: false)
    }

    /// 从参数数组中检测输出文件路径
    private func detectOutputPath(from arguments: [String]) -> String? {
        // 过滤掉空参数
        let validArgs = arguments.filter { !$0.isEmpty }

        // 至少要有一些参数
        guard !validArgs.isEmpty else { return nil }

        // 获取最后一个非选项参数作为输出路径
        guard let lastArg = validArgs.last, !lastArg.hasPrefix("-") else { return nil }

        var path = lastArg

        // 跳过特殊输出（如 pipe:, null 等）
        if path.contains(":") && !path.contains("/") {
            return nil
        }

        // 展开 ~ 路径
        if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
        }

        return path
    }

    private func executeCommand(forceOverwrite: Bool) {
        guard let currentCommand = previewViewModel.currentCommand else { return }

        var arguments = currentCommand.arguments
        let displayCommand = currentCommand.displayString

        // 如果需要覆盖，添加 -y 标志
        if forceOverwrite && !arguments.contains("-y") {
            arguments.insert("-y", at: 0)
        }

        Task {
            await executionViewModel.execute(arguments: arguments, displayCommand: displayCommand)
        }
    }

    private func saveAsTemplate() {
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
                    defaultValue: previewViewModel.renderedCommand,
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

        // 保存模板到用户目录
        saveTemplateToFile(template)

        // 刷新模板列表
        Task {
            await listViewModel.loadTemplates()
        }

        // 清空控制台和重置执行状态
        executionViewModel.clearLogs()
        executionViewModel.reset()

        templateName = ""
        templateCategory = ""
    }

    private func saveTemplateToFile(_ template: Template) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        Task.detached(priority: .background) {
            guard let data = try? encoder.encode(template) else { return }

            let userTemplatesDir = TemplateLoader.shared.userTemplatesDirectory
            try? FileManager.default.createDirectory(at: userTemplatesDir, withIntermediateDirectories: true)

            let fileURL = userTemplatesDir.appendingPathComponent("\(template.id).json")
            try? data.write(to: fileURL)
        }
    }
}

// MARK: - 保存为模板弹窗

struct SaveAsTemplateSheet: View {
    let command: String
    @Binding var templateName: String
    @Binding var templateCategory: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("保存为模板")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("模板名称")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField("例如：视频压缩 H265", text: $templateName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("分类（可选）")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField("例如：视频处理", text: $templateCategory)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("命令预览")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(4)
            }

            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("保存") {
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(templateName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

// MARK: - 空状态视图

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("选择一个模板开始")
                .font(.title2)
                .foregroundColor(.secondary)

            Text("从左侧列表选择一个 FFmpeg 命令模板")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    MainSplitView()
        .environmentObject(TemplateListViewModel())
        .environmentObject(TemplateDetailViewModel())
        .environmentObject(CommandPreviewViewModel())
        .environmentObject(ExecutionViewModel())
        .frame(width: 1200, height: 800)
}
