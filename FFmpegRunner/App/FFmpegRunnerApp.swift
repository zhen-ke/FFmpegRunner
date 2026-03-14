//
//  FFmpegRunnerApp.swift
//  FFmpegRunner
//
//  应用入口
//

import SwiftUI

@main
struct FFmpegRunnerApp: App {

    // MARK: - State Objects

    @StateObject private var listViewModel: TemplateListViewModel
    @StateObject private var detailViewModel: TemplateDetailViewModel
    @StateObject private var previewViewModel: CommandPreviewViewModel
    @StateObject private var executionViewModel: ExecutionViewModel
    @StateObject private var recentCommandsViewModel: RecentCommandsViewModel
    @StateObject private var headerViewModel: TemplateHeaderViewModel
    @StateObject private var navigationState: NavigationState

    @MainActor
    init() {
        let listViewModel = TemplateListViewModel()
        let detailViewModel = TemplateDetailViewModel()
        let previewViewModel = CommandPreviewViewModel(detailViewModel: detailViewModel)
        let executionViewModel = ExecutionViewModel()
        let recentCommandsViewModel = RecentCommandsViewModel()
        let headerViewModel = TemplateHeaderViewModel()
        let navigationState = NavigationState()

        _listViewModel = StateObject(wrappedValue: listViewModel)
        _detailViewModel = StateObject(wrappedValue: detailViewModel)
        _previewViewModel = StateObject(wrappedValue: previewViewModel)
        _executionViewModel = StateObject(wrappedValue: executionViewModel)
        _recentCommandsViewModel = StateObject(wrappedValue: recentCommandsViewModel)
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
                .environmentObject(recentCommandsViewModel)
                .environmentObject(headerViewModel)
                .environmentObject(navigationState)
                .background(UndoManagerInstaller(undoManager: detailViewModel.undoManager))
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    NotificationService.shared.configure()
                    // 设置最近使用变更回调
                    executionViewModel.onRecentCommandsChanged = { [weak recentCommandsViewModel] in
                        recentCommandsViewModel?.loadRecentCommands()
                    }
                }
                .task {
                    await FFmpegKnowledgePreloader.preload()
                }
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(
                navigationState: navigationState,
                detailViewModel: detailViewModel,
                previewViewModel: previewViewModel,
                executionViewModel: executionViewModel,
                headerViewModel: headerViewModel
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
    let detailViewModel: TemplateDetailViewModel
    let previewViewModel: CommandPreviewViewModel
    let executionViewModel: ExecutionViewModel
    let headerViewModel: TemplateHeaderViewModel

    // MARK: - Body

    var body: some Commands {
        // 侧边栏控制 (自定义，避免系统 toggleSidebar 触发约束崩溃)
        CommandGroup(replacing: .sidebar) {
            Button("切换侧边栏") {
                navigationState.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
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
                Task {
                    await headerViewModel.requestExecution(
                        binding: detailViewModel.templateBinding,
                        currentCommand: previewViewModel.currentCommand,
                        executionViewModel: executionViewModel
                    )
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
}
