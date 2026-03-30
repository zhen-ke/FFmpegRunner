//
//  HistoryViewModel.swift
//  FFmpegRunner
//
//  最近使用 ViewModel
//

import Foundation
import Combine

enum HistoryTimeFilter: String, CaseIterable {
    case all = "全部"
    case today = "今天"
    case thisWeek = "本周"
    case thisMonth = "本月"

    func includes(_ date: Date, referenceDate: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: referenceDate)
        case .thisWeek:
            return calendar.isDate(date, equalTo: referenceDate, toGranularity: .weekOfYear)
        case .thisMonth:
            return calendar.isDate(date, equalTo: referenceDate, toGranularity: .month)
        }
    }
}

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
    private let templateRepository: TemplateRepository

    // MARK: - Initialization

    init(
        recentCommandsService: RecentCommandsService = .shared,
        templateRepository: TemplateRepository = .shared
    ) {
        self.recentCommandsService = recentCommandsService
        self.templateRepository = templateRepository
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
                        wasSuccessful: entry.wasSuccessful,
                        templateSnapshot: entry.templateSnapshot
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

    /// 切换收藏状态
    func toggleFavorite(_ entry: RecentCommand) {
        Task {
            do {
                try await recentCommandsService.updateFavoriteState(entry.id, isFavorite: !entry.isFavorite)
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
    func saveAsTemplate(_ entry: RecentCommand, name: String, category: String?) async -> Bool {
        let template = await makeTemplateForSaving(entry, name: name, category: category)

        do {
            try templateRepository.saveUserTemplate(template)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "保存模板失败: \(error.localizedDescription)"
            return false
        }
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

    func filteredCommands(
        searchText: String,
        timeFilter: HistoryTimeFilter,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> [RecentCommand] {
        Self.filterCommands(
            recentCommands,
            searchText: searchText,
            timeFilter: timeFilter,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    static func filterCommands(
        _ commands: [RecentCommand],
        searchText: String,
        timeFilter: HistoryTimeFilter,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> [RecentCommand] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return commands.filter { entry in
            guard timeFilter.includes(entry.lastUsedAt, referenceDate: referenceDate, calendar: calendar) else {
                return false
            }

            guard !trimmedSearch.isEmpty else { return true }

            return entry.title.localizedCaseInsensitiveContains(trimmedSearch) ||
                entry.command.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    private func makeTemplateForSaving(_ entry: RecentCommand, name: String, category: String?) async -> Template {
        let description = "从最近使用创建于 \(entry.formattedDate)"

        if let templateId = entry.restorableTemplateId {
            let templates = await templateRepository.loadAllTemplates()
            if let sourceTemplate = templates.first(where: { $0.id == templateId && !$0.isBuiltInRawCommand }) {
                return sourceTemplate.makeUserCopy(
                    name: name,
                    description: description,
                    category: category,
                    defaultValuesByKey: entry.restorableParameterValues ?? [:]
                )
            }
        }

        return recentCommandsService.convertToTemplate(entry, name: name, category: category)
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
