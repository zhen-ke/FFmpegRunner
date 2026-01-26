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

    // MARK: - State

    @State private var showHistorySheet = false

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
                SidebarContentView(showHistorySheet: $showHistorySheet)
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
        .sheet(isPresented: $showHistorySheet) {
            HistorySheetView()
        }
    }
}

// MARK: - 侧边栏内容视图

struct SidebarContentView: View {

    @EnvironmentObject var viewModel: TemplateListViewModel
    @EnvironmentObject var historyViewModel: HistoryViewModel
    @EnvironmentObject var detailViewModel: TemplateDetailViewModel
    @EnvironmentObject var executionViewModel: ExecutionViewModel

    @Binding var showHistorySheet: Bool

    @State private var templateToDelete: Template?
    @State private var showDeleteConfirm = false

    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedTemplate },
            set: { viewModel.selectedTemplate = $0 }
        )) {
            // ✅ 最近历史（最多 3 条）
            if !historyViewModel.isEmpty {
                RecentHistorySection(
                    history: Array(historyViewModel.history.prefix(3)),
                    onShowAll: { showHistorySheet = true }
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
    }

    // MARK: - 模板操作

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

// MARK: - 最近历史区（精简版）
/// 只负责「快速填充 + 跳转完整历史」

struct RecentHistorySection: View {

    let history: [CommandHistory]
    let onShowAll: () -> Void

    @EnvironmentObject var executionViewModel: ExecutionViewModel
    @EnvironmentObject var viewModel: TemplateListViewModel
    @EnvironmentObject var detailViewModel: TemplateDetailViewModel

    var body: some View {
        Section(header: Text("最近历史")) {

            ForEach(history) { entry in
                Button {
                    fill(entry)
                } label: {
                    HistoryRowView(entry: entry)
                }
                .buttonStyle(.plain)
            }

            Button {
                onShowAll()
            } label: {
                HStack {
                    Text("查看全部历史…")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func fill(_ entry: CommandHistory) {
        executionViewModel.clearLogs()
        executionViewModel.reset()

        if let raw = viewModel.templates.first(where: { $0.id == Template.rawCommandId }) {
            viewModel.selectedTemplate = raw
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                detailViewModel.updateValue(key: "command", value: entry.command)
            }
        }
    }
}

// MARK: - 完整历史 Sheet

struct HistorySheetView: View {

    @EnvironmentObject var historyViewModel: HistoryViewModel
    @EnvironmentObject var viewModel: TemplateListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var showRenameSheet = false
    @State private var renameText = ""
    @State private var selectedEntry: CommandHistory?
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {

            // 顶部工具栏
            HStack {
                Text("历史记录")
                    .font(.headline)

                Spacer()

                Button("清空全部", role: .destructive) {
                    showClearConfirm = true
                }
                .disabled(historyViewModel.isEmpty)

                Button("关闭") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            // 搜索
            SearchBarView(text: $searchText)
                .padding(.horizontal)
                .padding(.vertical, 8)

            if filteredHistory.isEmpty {
                VStack {
                    Spacer()
                    Text(searchText.isEmpty ? "暂无历史记录" : "未找到匹配结果")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(filteredHistory) { entry in
                        HistoryRowView(entry: entry)
                            .contextMenu {
                                Button("重命名…") {
                                    selectedEntry = entry
                                    renameText = entry.displayName ?? ""
                                    showRenameSheet = true
                                }

                                Button("保存为模板…") {
                                    saveAsTemplate(entry)
                                }

                                Divider()

                                Button("删除", role: .destructive) {
                                    historyViewModel.deleteEntry(entry)
                                }
                            }
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 600)
        .sheet(isPresented: $showRenameSheet) {
            RenameSheetView(
                title: "重命名历史记录",
                text: $renameText,
                onSave: {
                    if let entry = selectedEntry {
                        historyViewModel.renameEntry(entry, to: renameText)
                    }
                }
            )
        }
        .alert("清空历史记录", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                historyViewModel.clearAll()
            }
        } message: {
            Text("确定要清空所有历史记录吗？此操作无法撤销。")
        }
    }

    private var filteredHistory: [CommandHistory] {
        if searchText.isEmpty {
            return historyViewModel.history
        }
        return historyViewModel.history.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.command.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func saveAsTemplate(_ entry: CommandHistory) {
        _ = historyViewModel.saveAsTemplate(entry, name: entry.title, category: nil)
        Task {
            await viewModel.loadTemplates()
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
        .environmentObject(ExecutionViewModel())
        .frame(width: 300, height: 600)
}
