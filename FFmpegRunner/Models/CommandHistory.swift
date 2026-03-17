//
//  CommandHistory.swift
//  FFmpegRunner
//
//  最近使用命令模型
//

import Foundation

struct RecentCommandTemplateSnapshot: Codable, Hashable, Sendable {
    let templateId: String
    let templateName: String?
    let parameterValues: [String: String]
}

/// 最近使用的命令。
///
/// 语义上这是一个“最近使用”条目，而不是不可变的执行历史：
/// - 同一条结构化命令会被提升到列表顶部
/// - 只保留最近一次使用时间和最近一次执行结果
/// - 用于快速回填、复制与保存为模板
struct RecentCommand: Identifiable, Codable, Hashable, Sendable {
    /// 唯一标识符
    let id: UUID

    /// 目标可执行文件
    let executable: CommandExecutable

    /// 执行参数数组（不包含可执行文件本身）
    let arguments: [String]

    /// 用于 UI 展示与回填的命令字符串
    let displayCommand: String

    /// 最近一次使用时间
    let lastUsedAt: Date

    /// 最近一次执行是否成功
    let wasSuccessful: Bool

    /// 被使用的次数
    let useCount: Int

    /// 用户自定义名称（可选）
    var displayName: String?

    /// 模板恢复快照（可选）
    let templateSnapshot: RecentCommandTemplateSnapshot?

    /// 兼容旧调用点：返回用于显示的完整命令字符串。
    var command: String {
        displayCommand
    }

    /// 兼容旧调用点：返回最近一次使用时间。
    var executedAt: Date {
        lastUsedAt
    }

    /// 用于显示的名称（优先使用 displayName，否则使用命令摘要）
    var title: String {
        if let name = displayName, !name.isEmpty {
            return name
        }
        if let templateName = templateSnapshot?.templateName, !templateName.isEmpty {
            return templateName
        }
        let trimmed = displayCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 50 {
            return String(trimmed.prefix(50)) + "..."
        }
        return trimmed
    }

    /// 格式化的最近使用时间
    var formattedDate: String {
        Self.dateFormatter.string(from: lastUsedAt)
    }

    /// 相对时间描述
    var relativeDate: String {
        Self.relativeDateFormatter.localizedString(for: lastUsedAt, relativeTo: Date())
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter
    }()

    /// 用于结构化去重的签名。
    var signature: Signature {
        Signature(executable: executable, arguments: arguments)
    }

    var restorableTemplateId: String? {
        templateSnapshot?.templateId
    }

    var restorableParameterValues: [String: String]? {
        templateSnapshot?.parameterValues
    }

    var detectedOutputPath: String? {
        CommandPathDetector.detectOutputPath(from: arguments)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        executable: CommandExecutable = .ffmpeg,
        arguments: [String] = [],
        displayCommand: String,
        lastUsedAt: Date = Date(),
        wasSuccessful: Bool,
        useCount: Int = 1,
        displayName: String? = nil,
        templateSnapshot: RecentCommandTemplateSnapshot? = nil
    ) {
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.displayCommand = displayCommand
        self.lastUsedAt = lastUsedAt
        self.wasSuccessful = wasSuccessful
        self.useCount = useCount
        self.displayName = displayName
        self.templateSnapshot = templateSnapshot
    }

    init(
        id: UUID = UUID(),
        command: String,
        executedAt: Date = Date(),
        wasSuccessful: Bool,
        displayName: String? = nil,
        useCount: Int = 1,
        templateSnapshot: RecentCommandTemplateSnapshot? = nil
    ) {
        let parsed = Self.parse(command: command)
        self.init(
            id: id,
            executable: parsed.executable,
            arguments: parsed.arguments,
            displayCommand: command,
            lastUsedAt: executedAt,
            wasSuccessful: wasSuccessful,
            useCount: useCount,
            displayName: displayName,
            templateSnapshot: templateSnapshot
        )
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: RecentCommand, rhs: RecentCommand) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Parsing

    private static func parse(command: String) -> (executable: CommandExecutable, arguments: [String]) {
        let tokens = (try? CommandRenderer.splitCommandStrict(command)) ?? CommandRenderer.splitCommand(command)
        guard !tokens.isEmpty else {
            return (.ffmpeg, [])
        }

        return CommandExecutable.stripExecutableIfPresent(from: tokens)
    }
}

extension RecentCommand {
    /// 结构化去重键：忽略 displayCommand 的格式差异，只比较语义执行单元。
    struct Signature: Hashable, Sendable {
        let executable: CommandExecutable
        let arguments: [String]
    }
}

// MARK: - Backward Compatibility

typealias CommandHistory = RecentCommand

// MARK: - 示例数据

extension RecentCommand {
    static let example = RecentCommand(
        displayCommand: "ffmpeg -i input.mp4 -c:v libx264 -crf 23 output.mp4",
        wasSuccessful: true
    )

    static let examples: [RecentCommand] = [
        RecentCommand(
            displayCommand: "ffmpeg -i video.mov -c:v libx265 output.mp4",
            lastUsedAt: Date().addingTimeInterval(-3600),
            wasSuccessful: true,
            useCount: 3,
            displayName: "HEVC 转码"
        ),
        RecentCommand(
            displayCommand: "ffmpeg -i audio.wav -c:a libmp3lame -b:a 192k output.mp3",
            lastUsedAt: Date().addingTimeInterval(-7200),
            wasSuccessful: true
        ),
        RecentCommand(
            displayCommand: "ffmpeg -i broken.mp4 -c:v copy output.mp4",
            lastUsedAt: Date().addingTimeInterval(-86400),
            wasSuccessful: false
        )
    ]
}
