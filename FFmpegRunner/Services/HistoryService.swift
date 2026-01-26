//
//  HistoryService.swift
//  FFmpegRunner
//
//  历史记录服务 - 负责持久化命令执行历史
//

import Foundation

/// 历史记录服务
class HistoryService {

    // MARK: - Singleton

    static let shared = HistoryService()

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// 最大历史记录数量
    private let maxHistoryCount = 100

    /// 缓存的历史记录
    private var historyCache: [CommandHistory]?

    /// 历史记录存储目录
    var historyDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FFmpegRunner/History", isDirectory: true)
    }

    /// 历史记录文件路径
    private var historyFile: URL {
        historyDirectory.appendingPathComponent("command_history.json")
    }

    // MARK: - Initialization

    private init() {
        // 确保目录存在
        try? fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public Methods

    /// 加载所有历史记录
    func loadHistory() -> [CommandHistory] {
        // 如果有缓存，直接返回
        if let cache = historyCache {
            return cache
        }

        guard fileManager.fileExists(atPath: historyFile.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: historyFile)
            let history = try decoder.decode([CommandHistory].self, from: data)
            // 按时间倒序排列
            let sortedHistory = history.sorted { $0.executedAt > $1.executedAt }
            historyCache = sortedHistory
            return sortedHistory
        } catch {
            print("Failed to load history: \(error)")
            return []
        }
    }

    /// 保存历史记录
    func saveHistory(_ history: [CommandHistory]) {
        // 更新缓存
        historyCache = history

        do {
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(history)
            try data.write(to: historyFile, options: .atomic)
        } catch {
            print("Failed to save history: \(error)")
        }
    }

    /// 添加新的历史记录
    func addEntry(_ entry: CommandHistory) {
        var history = loadHistory()

        // 检查是否有相同命令，避免连续重复
        if let lastEntry = history.first, lastEntry.command == entry.command {
            // 如果最近的命令相同，只更新时间和状态
            history[0] = CommandHistory(
                id: lastEntry.id,
                command: entry.command,
                executedAt: entry.executedAt,
                wasSuccessful: entry.wasSuccessful,
                displayName: lastEntry.displayName
            )
        } else {
            // 添加新记录到开头
            history.insert(entry, at: 0)
        }

        // 限制记录数量
        if history.count > maxHistoryCount {
            history = Array(history.prefix(maxHistoryCount))
        }

        saveHistory(history)
    }

    /// 删除历史记录
    func deleteEntry(_ entryId: UUID) {
        var history = loadHistory()
        history.removeAll { $0.id == entryId }
        saveHistory(history)
    }

    /// 更新历史记录（重命名）
    func updateEntry(_ entryId: UUID, displayName: String?) {
        var history = loadHistory()
        if let index = history.firstIndex(where: { $0.id == entryId }) {
            var entry = history[index]
            entry.displayName = displayName
            history[index] = CommandHistory(
                id: entry.id,
                command: entry.command,
                executedAt: entry.executedAt,
                wasSuccessful: entry.wasSuccessful,
                displayName: displayName
            )
            saveHistory(history)
        }
    }

    /// 清空所有历史记录
    func clearHistory() {
        saveHistory([])
    }

    /// 将历史记录转换为模板
    func convertToTemplate(_ entry: CommandHistory, name: String, category: String?) -> Template {
        Template(
            id: "user-\(UUID().uuidString)",
            name: name,
            description: "从历史记录创建于 \(entry.formattedDate)",
            commandTemplate: "{{command}}",
            parameters: [
                TemplateParameter(
                    key: "command",
                    label: "FFmpeg 命令",
                    type: .string,
                    defaultValue: entry.command,
                    placeholder: "FFmpeg 命令",
                    isRequired: true,
                    constraints: nil,
                    role: .raw,
                    escapeStrategy: .raw,
                    uiHint: ParameterUIHint(multiline: true, monospace: true)
                )
            ],
            category: category ?? "用户模板",
            icon: "clock.arrow.circlepath"
        )
    }
}
