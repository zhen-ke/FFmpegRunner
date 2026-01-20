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

    @StateObject private var listViewModel = TemplateListViewModel()
    @StateObject private var detailViewModel = TemplateDetailViewModel()
    @StateObject private var previewViewModel = CommandPreviewViewModel()
    @StateObject private var executionViewModel = ExecutionViewModel()
    @StateObject private var historyViewModel = HistoryViewModel()

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environmentObject(listViewModel)
                .environmentObject(detailViewModel)
                .environmentObject(previewViewModel)
                .environmentObject(executionViewModel)
                .environmentObject(historyViewModel)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
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
                listViewModel: listViewModel,
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

    let listViewModel: TemplateListViewModel
    let previewViewModel: CommandPreviewViewModel
    let executionViewModel: ExecutionViewModel

    // MARK: - Body

    var body: some Commands {
        // 侧边栏控制 (显示在 View 菜单中)
        SidebarCommands()

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
                        await executionViewModel.execute(command: previewViewModel.renderedCommand)
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
