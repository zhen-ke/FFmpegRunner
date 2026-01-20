//
//  TemplateListView.swift
//  FFmpegRunner
//
//  模板列表视图（含历史记录）
//

import SwiftUI

/// 模板列表视图
struct TemplateListView: View {

    // MARK: - Environment

    @EnvironmentObject var viewModel: TemplateListViewModel
    @EnvironmentObject var historyViewModel: HistoryViewModel

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            SearchBarView(text: $viewModel.searchText)
                .padding(8)

            Divider()

            // 模板列表
            if viewModel.isLoading {
                LoadingView()
            } else if viewModel.filteredTemplates.isEmpty && historyViewModel.isEmpty {
                NoResultsView()
            } else {
                SidebarContentView()
            }
        }
        .navigationTitle("FFmpeg 模板")
        .alert("错误", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}

// MARK: - 侧边栏内容视图

struct SidebarContentView: View {

    @EnvironmentObject var viewModel: TemplateListViewModel
    @EnvironmentObject var historyViewModel: HistoryViewModel
    @EnvironmentObject var detailViewModel: TemplateDetailViewModel
    @EnvironmentObject var executionViewModel: ExecutionViewModel

    @State private var templateToDelete: Template?

    @State private var showDeleteConfirm = false
    @State private var showHistoryClearConfirm = false

    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedTemplate },
            set: { viewModel.selectedTemplate = $0 }
        )) {
            // 历史记录区域
            if !historyViewModel.isEmpty {
                HistorySection(
                    history: historyViewModel.history,
                    historyCount: historyViewModel.history.count,
                    onFill: fillCommand,
                    onRename: historyViewModel.renameEntry,
                    onSaveAsTemplate: saveAsTemplate,
                    onDelete: historyViewModel.deleteEntry,
                    showClearConfirm: $showHistoryClearConfirm
                )
            }

            // 模板分类
            ForEach(viewModel.categories, id: \.self) { category in
                Section(header: Text(category)) {
                    ForEach(viewModel.groupedTemplates[category] ?? []) { template in
                        TemplateRowView(
                            template: template,
                            isSelected: viewModel.selectedTemplate?.id == template.id
                        )
                        .tag(template)
                            .contextMenu {
                                if TemplateLoader.shared.canDeleteTemplate(template) {
                                    Button(role: .destructive) {
                                        templateToDelete = template
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("删除模板", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .alert("删除模板", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let template = templateToDelete {
                    deleteTemplate(template)
                }
            }
        } message: {
            Text("确定要删除模板「\(templateToDelete?.name ?? "")」吗？此操作无法撤销。")
        }
        .alert("清空历史记录", isPresented: $showHistoryClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                historyViewModel.clearAll()
            }
        } message: {
            Text("确定要清空所有历史记录吗？此操作无法撤销。")
        }
    }

    // MARK: - 历史记录操作

    private func fillCommand(_ entry: CommandHistory) {
        // 清空控制台
        executionViewModel.clearLogs()
        executionViewModel.reset()

        // 选择 RawCommand 模板并填充命令
        if let rawTemplate = viewModel.templates.first(where: { $0.id == "raw-command" }) {
            viewModel.selectedTemplate = rawTemplate
            // 更新命令值
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                detailViewModel.updateValue(key: "command", value: entry.command)
            }
        }
    }

    private func saveAsTemplate(_ entry: CommandHistory) {
        // 创建并保存模板
        _ = historyViewModel.saveAsTemplate(entry, name: entry.title, category: nil)
        // 通知模板列表刷新
        Task {
            await viewModel.loadTemplates()
        }
    }

    private func deleteTemplate(_ template: Template) {
        if TemplateLoader.shared.deleteUserTemplate(template) {
            // 如果删除的是当前选中的模板，清空选择
            if viewModel.selectedTemplate?.id == template.id {
                viewModel.selectedTemplate = nil
            }
            // 刷新模板列表
            Task {
                await viewModel.loadTemplates()
            }
        }
    }
}

// MARK: - 历史记录区域

/// 历史记录区域 - 使用显式参数传递，提高可测试性和可复用性
struct HistorySection: View {

    // MARK: - Properties (显式依赖注入)

    let history: [CommandHistory]
    let historyCount: Int
    let onFill: (CommandHistory) -> Void
    let onRename: (CommandHistory, String) -> Void
    let onSaveAsTemplate: (CommandHistory) -> Void
    let onDelete: (CommandHistory) -> Void
    @Binding var showClearConfirm: Bool

    // MARK: - State

    @State private var showRenameSheet = false
    @State private var renameText = ""
    @State private var selectedEntry: CommandHistory?

    // MARK: - Body

    var body: some View {
        Group {
            Section {
                // 自定义 Header (模拟 Section Header 样式)
                HStack {
                    Text("历史记录")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Spacer()

                    if !history.isEmpty {
                        Button(action: { showClearConfirm = true }) {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 20)
                        .help("清空历史")
                    }
                }
                .padding(.vertical, 4)
                .padding(.top, 4)

                ForEach(history.prefix(10)) { entry in
                    Button(action: {
                        onFill(entry)
                    }) {
                        HistoryRowView(entry: entry)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("填充到编辑器") {
                            onFill(entry)
                        }

                        Divider()

                        Button("重命名...") {
                            selectedEntry = entry
                            renameText = entry.displayName ?? ""
                            showRenameSheet = true
                        }

                        Button("保存为模板...") {
                            onSaveAsTemplate(entry)
                        }

                        Divider()

                        Button("删除", role: .destructive) {
                            onDelete(entry)
                        }
                    }
                }

                if historyCount > 10 {
                    Text("还有 \(historyCount - 10) 条记录...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSheetView(
                title: "重命名历史记录",
                text: $renameText,
                onSave: {
                    if let entry = selectedEntry {
                        onRename(entry, renameText)
                    }
                }
            )
        }
    }
}

// MARK: - 历史记录行视图

struct HistoryRowView: View {
    let entry: CommandHistory

    var body: some View {
        HStack(spacing: 8) {
            // 状态图标
            Image(systemName: entry.wasSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(entry.wasSuccessful ? .green : .red)
                .font(.caption)

            // 内容
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline)
                    .lineLimit(1)

                Text(entry.relativeDate)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 重命名弹窗

struct RenameSheetView: View {
    let title: String
    @Binding var text: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)

            TextField("名称", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - 搜索栏

struct SearchBarView: View {
    @Binding var text: String

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("搜索模板...", text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - 模板行视图

struct TemplateRowView: View {
    let template: Template
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // 图标 - 根据选中状态切换颜色
            Image(systemName: template.icon ?? "terminal")
                .font(.system(size: 15, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundColor(isSelected ? .white : .accentColor)
                .frame(width: 24)

            // 信息
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)

                Text(template.description)
                    .font(.caption)
                    .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 加载中视图

struct LoadingView: View {
    var body: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("加载模板...")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }
}

// MARK: - 无结果视图

struct NoResultsView: View {
    @EnvironmentObject var viewModel: TemplateListViewModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            if viewModel.searchText.isEmpty {
                Text("没有可用的模板")
            } else {
                Text("未找到匹配的模板")
            }

            Spacer()
        }
        .foregroundColor(.secondary)
    }
}

// MARK: - Preview

#Preview {
    TemplateListView()
        .environmentObject(TemplateListViewModel())
        .environmentObject(HistoryViewModel())
        .environmentObject(TemplateDetailViewModel())
        .frame(width: 300, height: 600)
}
