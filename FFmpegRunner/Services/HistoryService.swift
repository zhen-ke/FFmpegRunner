import Foundation

// MARK: - Recent Commands Error

/// 最近使用服务错误
enum RecentCommandsError: LocalizedError {
    case fileWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileWriteFailed(let msg):
            return "写入最近使用失败: \(msg)"
        }
    }
}

typealias HistoryError = RecentCommandsError

// MARK: - Recent Command Usage

struct RecentCommandUsage: Sendable {
    let executable: CommandExecutable
    let arguments: [String]
    let displayCommand: String
    let usedAt: Date
    let wasSuccessful: Bool
    let templateSnapshot: RecentCommandTemplateSnapshot?

    init(
        executable: CommandExecutable,
        arguments: [String],
        displayCommand: String,
        usedAt: Date,
        wasSuccessful: Bool,
        templateSnapshot: RecentCommandTemplateSnapshot? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.displayCommand = displayCommand
        self.usedAt = usedAt
        self.wasSuccessful = wasSuccessful
        self.templateSnapshot = templateSnapshot
    }
}

// MARK: - Recent Commands Service

/// 最近使用服务。
///
/// 设计目标：
/// - 只保留“最近使用”的唯一命令集合，而不是完整历史
/// - 用结构化执行单元（executable + arguments）做去重
/// - 保持 JSON + actor 的轻量实现，适合当前项目规模
actor RecentCommandsService {

    // MARK: - Singleton

    static let shared = RecentCommandsService()

    // MARK: - Properties

    nonisolated let recentCommandsDirectory: URL
    nonisolated let recentCommandsFile: URL
    nonisolated let legacyHistoryFile: URL

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxRecentCommandCount: Int

    /// 缓存的最近使用列表
    private var recentCommandsCache: [RecentCommand]?

    /// 上次文件修改时间（用于检测外部变更）
    private var lastFileModificationDate: Date?

    // MARK: - Initialization

    init(
        fileManager: FileManager = .default,
        recentCommandsDirectory: URL? = nil,
        legacyHistoryDirectory: URL? = nil,
        maxRecentCommandCount: Int = 100
    ) {
        self.fileManager = fileManager
        self.maxRecentCommandCount = maxRecentCommandCount

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let resolvedRecentDirectory = recentCommandsDirectory
            ?? appSupport.appendingPathComponent("FFmpegRunner/RecentCommands", isDirectory: true)
        let resolvedLegacyDirectory = legacyHistoryDirectory
            ?? appSupport.appendingPathComponent("FFmpegRunner/History", isDirectory: true)

        self.recentCommandsDirectory = resolvedRecentDirectory
        self.recentCommandsFile = resolvedRecentDirectory.appendingPathComponent("recent_commands.json")
        self.legacyHistoryFile = resolvedLegacyDirectory.appendingPathComponent("command_history.json")

        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        try? fileManager.createDirectory(at: resolvedRecentDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public Methods

    /// 加载所有最近使用记录
    func loadRecentCommands() async -> [RecentCommand] {
        invalidateCacheIfFileChanged()

        if let cache = recentCommandsCache {
            return cache
        }

        do {
            if fileManager.fileExists(atPath: recentCommandsFile.path) {
                return try loadCurrentFile()
            }

            if fileManager.fileExists(atPath: legacyHistoryFile.path) {
                let migrated = try migrateLegacyHistory()
                try await saveRecentCommands(migrated)
                return migrated
            }
        } catch {
            AppLogger.notice(AppLogger.history, "Failed to load recent commands: \(error)")
        }

        recentCommandsCache = []
        lastFileModificationDate = nil
        return []
    }

    /// 保存最近使用记录
    func saveRecentCommands(_ recentCommands: [RecentCommand]) async throws {
        recentCommandsCache = recentCommands

        do {
            let data = try encoder.encode(recentCommands)
            try data.write(to: recentCommandsFile, options: .atomic)
            lastFileModificationDate = fileModificationDate(for: recentCommandsFile)
        } catch {
            throw RecentCommandsError.fileWriteFailed(error.localizedDescription)
        }
    }

    /// 记录一次命令使用。
    func recordUsage(_ usage: RecentCommandUsage) async throws {
        var recentCommands = await loadRecentCommands()

        if let index = recentCommands.firstIndex(where: { $0.signature == RecentCommand.Signature(executable: usage.executable, arguments: usage.arguments) }) {
            let existing = recentCommands.remove(at: index)
            let updated = RecentCommand(
                id: existing.id,
                executable: usage.executable,
                arguments: usage.arguments,
                displayCommand: usage.displayCommand,
                lastUsedAt: usage.usedAt,
                wasSuccessful: usage.wasSuccessful,
                useCount: existing.useCount + 1,
                isFavorite: existing.isFavorite,
                displayName: existing.displayName,
                templateSnapshot: usage.templateSnapshot ?? existing.templateSnapshot
            )
            recentCommands.append(updated)
        } else {
            recentCommands.append(
                RecentCommand(
                    executable: usage.executable,
                    arguments: usage.arguments,
                    displayCommand: usage.displayCommand,
                    lastUsedAt: usage.usedAt,
                    wasSuccessful: usage.wasSuccessful,
                    templateSnapshot: usage.templateSnapshot
                )
            )
        }

        // 统一排序：与 loadCurrentFile() 语义一致
        recentCommands = sortRecentCommands(recentCommands)

        if recentCommands.count > maxRecentCommandCount {
            recentCommands.removeLast(recentCommands.count - maxRecentCommandCount)
        }

        try await saveRecentCommands(recentCommands)
    }

    /// 删除最近使用
    func deleteRecentCommand(_ entryId: UUID) async throws {
        var recentCommands = await loadRecentCommands()
        recentCommands.removeAll { $0.id == entryId }
        try await saveRecentCommands(recentCommands)
    }

    /// 更新最近使用名称
    func updateRecentCommand(_ entryId: UUID, displayName: String?) async throws {
        var recentCommands = await loadRecentCommands()
        if let index = recentCommands.firstIndex(where: { $0.id == entryId }) {
            var entry = recentCommands[index]
            entry.displayName = displayName
            recentCommands[index] = entry
            try await saveRecentCommands(sortRecentCommands(recentCommands))
        }
    }

    /// 更新收藏状态
    func updateFavoriteState(_ entryId: UUID, isFavorite: Bool) async throws {
        var recentCommands = await loadRecentCommands()
        if let index = recentCommands.firstIndex(where: { $0.id == entryId }) {
            var entry = recentCommands[index]
            entry.isFavorite = isFavorite
            recentCommands[index] = entry
            try await saveRecentCommands(sortRecentCommands(recentCommands))
        }
    }

    /// 清空最近使用
    func clearRecentCommands() async throws {
        try await saveRecentCommands([])
    }

    /// 将最近使用转换为模板 (非异步，纯逻辑转换)
    nonisolated func convertToTemplate(_ entry: RecentCommand, name: String, category: String?) -> Template {
        Template.makeRawCommandTemplate(
            id: "user-\(UUID().uuidString)",
            name: name,
            description: "从最近使用创建于 \(entry.formattedDate)",
            defaultCommand: entry.command,
            placeholder: "FFmpeg 命令",
            category: category ?? "用户模板",
            icon: "clock.arrow.circlepath"
        )
    }

    // MARK: - Backward Compatibility

    nonisolated var historyDirectory: URL {
        recentCommandsDirectory
    }

    func loadHistory() async -> [RecentCommand] {
        await loadRecentCommands()
    }

    func addEntry(_ entry: RecentCommand) async throws {
        try await recordUsage(
            RecentCommandUsage(
                executable: entry.executable,
                arguments: entry.arguments,
                displayCommand: entry.displayCommand,
                usedAt: entry.lastUsedAt,
                wasSuccessful: entry.wasSuccessful,
                templateSnapshot: entry.templateSnapshot
            )
        )
    }

    func deleteEntry(_ entryId: UUID) async throws {
        try await deleteRecentCommand(entryId)
    }

    func clearHistory() async throws {
        try await clearRecentCommands()
    }

    // MARK: - Private Helpers

    private struct LegacyCommandHistory: Codable {
        let id: UUID
        let command: String
        let executedAt: Date
        let wasSuccessful: Bool
        let displayName: String?
    }

    private func invalidateCacheIfFileChanged() {
        guard let modDate = fileModificationDate(for: recentCommandsFile) else {
            if !fileManager.fileExists(atPath: recentCommandsFile.path) {
                recentCommandsCache = nil
                lastFileModificationDate = nil
            }
            return
        }

        if lastFileModificationDate != modDate {
            recentCommandsCache = nil
            lastFileModificationDate = modDate
        }
    }

    private func loadCurrentFile() throws -> [RecentCommand] {
        let data = try Data(contentsOf: recentCommandsFile)
        let recentCommands = try decoder.decode([RecentCommand].self, from: data)
        let sorted = sortRecentCommands(recentCommands)
        recentCommandsCache = sorted
        lastFileModificationDate = fileModificationDate(for: recentCommandsFile)
        return sorted
    }

    private func migrateLegacyHistory() throws -> [RecentCommand] {
        let data = try Data(contentsOf: legacyHistoryFile)
        let legacyEntries = try decoder.decode([LegacyCommandHistory].self, from: data)

        return legacyEntries
            .map {
                RecentCommand(
                    id: $0.id,
                    command: $0.command,
                    executedAt: $0.executedAt,
                    wasSuccessful: $0.wasSuccessful,
                    displayName: $0.displayName
                )
            }
            .sorted { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite {
                    return lhs.isFavorite && !rhs.isFavorite
                }
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
    }

    private func sortRecentCommands(_ recentCommands: [RecentCommand]) -> [RecentCommand] {
        recentCommands.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite && !rhs.isFavorite
            }
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
            return lhs.useCount > rhs.useCount
        }
    }

    private func fileModificationDate(for url: URL) -> Date? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }
}

typealias HistoryService = RecentCommandsService
