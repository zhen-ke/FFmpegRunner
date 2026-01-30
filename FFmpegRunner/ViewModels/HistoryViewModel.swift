//
//  HistoryViewModel.swift
//  FFmpegRunner
//
//  历史记录 ViewModel
//

import Foundation
import Combine

/// 历史记录 ViewModel
@MainActor
class HistoryViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 历史记录列表
    @Published private(set) var history: [CommandHistory] = []

    /// 是否正在加载
    @Published private(set) var isLoading = false

    /// 错误信息
    @Published var errorMessage: String?

    /// 选中的历史记录
    @Published var selectedHistory: CommandHistory?

    // MARK: - Dependencies

    private let historyService: HistoryService

    // MARK: - Initialization

    init(historyService: HistoryService = .shared) {
        self.historyService = historyService
        loadHistory()
    }

    // MARK: - Public Methods

    /// 加载历史记录
    func loadHistory() {
        isLoading = true
        Task {
            let items = await historyService.loadHistory()
            self.history = items
            self.isLoading = false
        }
    }

    /// 添加历史记录
    func addEntry(command: String, wasSuccessful: Bool) {
        let entry = CommandHistory(
            command: command,
            wasSuccessful: wasSuccessful
        )
        Task {
            do {
                try await historyService.addEntry(entry)
                loadHistory()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 删除历史记录
    func deleteEntry(_ entry: CommandHistory) {
        Task {
            do {
                try await historyService.deleteEntry(entry.id)
                if self.selectedHistory?.id == entry.id {
                    self.selectedHistory = nil
                }
                loadHistory()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 重命名历史记录
    func renameEntry(_ entry: CommandHistory, to newName: String) {
        let name = newName.isEmpty ? nil : newName
        Task {
            do {
                try await historyService.updateEntry(entry.id, displayName: name)
                loadHistory()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 清空所有历史
    func clearAll() {
        Task {
            do {
                try await historyService.clearHistory()
                self.selectedHistory = nil
                loadHistory()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 将历史记录保存为模板
    func saveAsTemplate(_ entry: CommandHistory, name: String, category: String?) -> Template {
        historyService.convertToTemplate(entry, name: name, category: category)
    }

    /// 历史记录是否为空
    var isEmpty: Bool {
        history.isEmpty
    }

    /// 成功的历史记录数
    var successCount: Int {
        history.filter { $0.wasSuccessful }.count
    }

    /// 失败的历史记录数
    var failureCount: Int {
        history.filter { !$0.wasSuccessful }.count
    }
}
