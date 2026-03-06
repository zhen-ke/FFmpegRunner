//
//  FFmpegRunnerApp.swift
//  FFmpegRunner
//
//  应用入口
//

import SwiftUI
import AppKit

@main
struct FFmpegRunnerApp: App {

    // MARK: - State Objects

    @StateObject private var listViewModel: TemplateListViewModel
    @StateObject private var detailViewModel: TemplateDetailViewModel
    @StateObject private var previewViewModel: CommandPreviewViewModel
    @StateObject private var executionViewModel: ExecutionViewModel
    @StateObject private var historyViewModel: HistoryViewModel
    @StateObject private var headerViewModel: TemplateHeaderViewModel
    @StateObject private var navigationState: NavigationState

    @MainActor
    init() {
        let listViewModel = TemplateListViewModel()
        let detailViewModel = TemplateDetailViewModel()
        let previewViewModel = CommandPreviewViewModel(detailViewModel: detailViewModel)
        let executionViewModel = ExecutionViewModel()
        let historyViewModel = HistoryViewModel()
        let headerViewModel = TemplateHeaderViewModel()
        let navigationState = NavigationState()

        _listViewModel = StateObject(wrappedValue: listViewModel)
        _detailViewModel = StateObject(wrappedValue: detailViewModel)
        _previewViewModel = StateObject(wrappedValue: previewViewModel)
        _executionViewModel = StateObject(wrappedValue: executionViewModel)
        _historyViewModel = StateObject(wrappedValue: historyViewModel)
        _headerViewModel = StateObject(wrappedValue: headerViewModel)
        _navigationState = StateObject(wrappedValue: navigationState)
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environmentObject(listViewModel)
                .environmentObject(detailViewModel)
                .environmentObject(previewViewModel)
                .environmentObject(executionViewModel)
                .environmentObject(historyViewModel)
                .environmentObject(headerViewModel)
                .environmentObject(navigationState)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    NotificationService.shared.configure()
                    // 设置历史记录变更回调
                    executionViewModel.onHistoryChanged = { [weak historyViewModel] in
                        historyViewModel?.loadHistory()
                    }
                }
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(
                navigationState: navigationState,
                listViewModel: listViewModel,
                detailViewModel: detailViewModel,
                previewViewModel: previewViewModel,
                executionViewModel: executionViewModel
            )
        }

        // 设置窗口
        Settings {
            SettingsView()
                .environmentObject(executionViewModel)
        }
    }
}

// MARK: - App Commands

/// 应用菜单命令
struct AppCommands: Commands {

    // MARK: - Properties

    let navigationState: NavigationState
    let listViewModel: TemplateListViewModel
    let detailViewModel: TemplateDetailViewModel
    let previewViewModel: CommandPreviewViewModel
    let executionViewModel: ExecutionViewModel

    // MARK: - Body

    var body: some Commands {
        // 侧边栏控制 (自定义，避免系统 toggleSidebar 触发约束崩溃)
        CommandGroup(replacing: .sidebar) {
            Button("切换侧边栏") {
                navigationState.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }

        // 文件菜单
        CommandGroup(after: .newItem) {
            Button("刷新模板") {
                Task {
                    await listViewModel.refresh()
                }
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("导入模板...") {
                importTemplate()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        // 编辑菜单
        CommandGroup(after: .pasteboard) {
            Button("复制命令") {
                previewViewModel.copyToClipboard()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(previewViewModel.renderedCommand.isEmpty)
        }

        // 执行菜单
        CommandMenu("执行") {
            Button("运行") {
                if !executionViewModel.isRunning {
                    Task {
                        if let template = detailViewModel.template {
                            await executionViewModel.execute(
                                template: template,
                                values: detailViewModel.values
                            )
                        } else {
                            await executionViewModel.execute(command: previewViewModel.renderedCommand)
                        }
                    }
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(executionViewModel.isRunning || !previewViewModel.isComplete)

            Button("停止") {
                executionViewModel.cancel()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!executionViewModel.isRunning)

            Divider()

            Button("清空日志") {
                executionViewModel.clearLogs()
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }

    // MARK: - Private Methods

    private func importTemplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "导入"
        panel.message = "选择一个 JSON 格式的模板文件"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await listViewModel.importTemplate(from: url)
            }
        }
    }
}
