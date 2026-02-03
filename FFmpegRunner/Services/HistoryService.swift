import Foundation

// MARK: - History Error

/// 历史记录服务错误
enum HistoryError: LocalizedError {
    case directoryCreationFailed(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case fileWriteFailed(String)
    case fileReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let msg): return "无法创建目录: \(msg)"
        case .encodingFailed(let msg): return "编码失败: \(msg)"
        case .decodingFailed(let msg): return "解码失败: \(msg)"
        case .fileWriteFailed(let msg): return "写入文件失败: \(msg)"
        case .fileReadFailed(let msg): return "读取文件失败: \(msg)"
        }
    }
}

// MARK: - History Service

/// 历史记录服务 - 负责持久化命令执行历史
/// 使用 actor 模型保证并发安全
actor HistoryService {

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

    /// 上次文件修改时间（用于检测外部变更）
    private var lastFileModificationDate: Date?

    /// 历史记录存储目录
    nonisolated var historyDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FFmpegRunner/History", isDirectory: true)
    }

    /// 历史记录文件路径
    nonisolated private var historyFile: URL {
        historyDirectory.appendingPathComponent("command_history.json")
    }

    // MARK: - Initialization

    private init() {
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        // 确保目录存在 (非异步，构造时执行一次)
        try? fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public Methods

    /// 加载所有历史记录
    func loadHistory() async -> [CommandHistory] {
        // 检查文件是否有外部修改
        if let attributes = try? fileManager.attributesOfItem(atPath: historyFile.path),
           let modDate = attributes[.modificationDate] as? Date {

            if lastFileModificationDate != modDate {
                historyCache = nil // 缓存失效
                lastFileModificationDate = modDate
            }
        }

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
            AppLogger.notice(AppLogger.history, "Failed to load history: \(error)")
            // 发生错误时返回空数组，不中断流程
            return []
        }
    }

    /// 保存历史记录
    func saveHistory(_ history: [CommandHistory]) async throws {
        // 更新缓存
        historyCache = history

        do {
            let data = try encoder.encode(history)

            // 使用原子写入：先写临时文件，再重命名
            // 这能防止应用崩溃导致的文件损坏
            try data.write(to: historyFile, options: .atomic)

            // 更新最后修改时间
             if let attributes = try? fileManager.attributesOfItem(atPath: historyFile.path),
               let modDate = attributes[.modificationDate] as? Date {
                lastFileModificationDate = modDate
            }

        } catch {
            throw HistoryError.fileWriteFailed(error.localizedDescription)
        }
    }

    /// 添加新的历史记录
    func addEntry(_ entry: CommandHistory) async throws {
        var history = await loadHistory()

        // 检查是否有相同命令，避免连续重复
        // 同时支持智能去重：如果是曾经执行过的命令，移到最前并更新时间
        if let index = history.firstIndex(where: { $0.command == entry.command }) {
            var existing = history.remove(at: index)
            // 更新时间、状态和显示名称
            let updated = CommandHistory(
                id: existing.id, // 保持原有 ID
                command: entry.command,
                executedAt: entry.executedAt,
                wasSuccessful: entry.wasSuccessful,
                displayName: existing.displayName // 保持原有名称
            )
            history.insert(updated, at: 0)
        } else {
            // 添加新记录到开头
            history.insert(entry, at: 0)
        }

        // 限制记录数量
        if history.count > maxHistoryCount {
            history = Array(history.prefix(maxHistoryCount))
        }

        try await saveHistory(history)
    }

    /// 删除历史记录
    func deleteEntry(_ entryId: UUID) async throws {
        var history = await loadHistory()
        history.removeAll { $0.id == entryId }
        try await saveHistory(history)
    }

    /// 更新历史记录（重命名）
    func updateEntry(_ entryId: UUID, displayName: String?) async throws {
        var history = await loadHistory()
        if let index = history.firstIndex(where: { $0.id == entryId }) {
            var entry = history[index]
            entry.displayName = displayName

            // 结构体是值类型，必须替换数组中的元素
            history[index] = entry

            try await saveHistory(history)
        }
    }

    /// 清空所有历史记录
    func clearHistory() async throws {
        try await saveHistory([])
    }

    /// 将历史记录转换为模板 (非异步，纯逻辑转换)
    nonisolated func convertToTemplate(_ entry: CommandHistory, name: String, category: String?) -> Template {
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
                    escapeStrategy: .raw, // 命令整体不转义
                    uiHint: ParameterUIHint(multiline: true, monospace: true)
                )
            ],
            category: category ?? "用户模板",
            icon: "clock.arrow.circlepath"
        )
    }
}
