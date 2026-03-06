//
//  HistoryViewModel.swift
//  FFmpegRunner
//
//  最近使用 ViewModel
//

import Foundation
import Combine

/// 最近使用 ViewModel
@MainActor
class RecentCommandsViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 最近使用列表
    @Published private(set) var recentCommands: [RecentCommand] = []

    /// 是否正在加载
    @Published private(set) var isLoading = false

    /// 错误信息
    @Published var errorMessage: String?

    /// 选中的最近使用
    @Published var selectedRecentCommand: RecentCommand?

    // MARK: - Dependencies

    private let recentCommandsService: RecentCommandsService

    // MARK: - Initialization

    init(recentCommandsService: RecentCommandsService = .shared) {
        self.recentCommandsService = recentCommandsService
        loadRecentCommands()
    }

    // MARK: - Public Methods

    /// 加载最近使用
    func loadRecentCommands() {
        isLoading = true
        Task {
            let items = await recentCommandsService.loadRecentCommands()
            self.recentCommands = items
            self.isLoading = false
        }
    }

    /// 添加最近使用
    func addRecentCommand(command: String, wasSuccessful: Bool) {
        let entry = RecentCommand(
            displayCommand: command,
            wasSuccessful: wasSuccessful
        )
        Task {
            do {
                try await recentCommandsService.recordUsage(
                    RecentCommandUsage(
                        executable: entry.executable,
                        arguments: entry.arguments,
                        displayCommand: entry.displayCommand,
                        usedAt: entry.lastUsedAt,
                        wasSuccessful: entry.wasSuccessful
                    )
                )
                loadRecentCommands()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 删除最近使用
    func deleteEntry(_ entry: RecentCommand) {
        Task {
            do {
                try await recentCommandsService.deleteRecentCommand(entry.id)
                if self.selectedRecentCommand?.id == entry.id {
                    self.selectedRecentCommand = nil
                }
                loadRecentCommands()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 重命名最近使用
    func renameEntry(_ entry: RecentCommand, to newName: String) {
        let name = newName.isEmpty ? nil : newName
        Task {
            do {
                try await recentCommandsService.updateRecentCommand(entry.id, displayName: name)
                loadRecentCommands()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 清空所有最近使用
    func clearAll() {
        Task {
            do {
                try await recentCommandsService.clearRecentCommands()
                self.selectedRecentCommand = nil
                loadRecentCommands()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 将最近使用保存为模板
    func saveAsTemplate(_ entry: RecentCommand, name: String, category: String?) -> Template {
        recentCommandsService.convertToTemplate(entry, name: name, category: category)
    }

    /// 最近使用是否为空
    var isEmpty: Bool {
        recentCommands.isEmpty
    }

    /// 最近一次成功的命令数
    var successCount: Int {
        recentCommands.filter { $0.wasSuccessful }.count
    }

    /// 最近一次失败的命令数
    var failureCount: Int {
        recentCommands.filter { !$0.wasSuccessful }.count
    }

    // MARK: - Backward Compatibility

    var history: [RecentCommand] {
        recentCommands
    }

    var selectedHistory: RecentCommand? {
        get { selectedRecentCommand }
        set { selectedRecentCommand = newValue }
    }

    func loadHistory() {
        loadRecentCommands()
    }

    func addEntry(command: String, wasSuccessful: Bool) {
        addRecentCommand(command: command, wasSuccessful: wasSuccessful)
    }
}

typealias HistoryViewModel = RecentCommandsViewModel
