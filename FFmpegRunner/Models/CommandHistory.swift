//
//  CommandHistory.swift
//  FFmpegRunner
//
//  命令历史记录模型
//

import Foundation

/// 命令历史记录
struct CommandHistory: Identifiable, Codable, Hashable {
    /// 唯一标识符
    let id: UUID

    /// 执行的命令
    let command: String

    /// 执行时间
    let executedAt: Date

    /// 是否成功
    let wasSuccessful: Bool

    /// 用户自定义名称（可选）
    var displayName: String?

    /// 用于显示的名称（优先使用 displayName，否则使用命令摘要）
    var title: String {
        if let name = displayName, !name.isEmpty {
            return name
        }
        // 返回命令的前 50 个字符作为摘要
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 50 {
            return String(trimmed.prefix(50)) + "..."
        }
        return trimmed
    }

    /// 格式化的执行时间
    var formattedDate: String {
        Self.dateFormatter.string(from: executedAt)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// 相对时间描述
    var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: executedAt, relativeTo: Date())
    }

    // MARK: - Initializers

    init(
        id: UUID = UUID(),
        command: String,
        executedAt: Date = Date(),
        wasSuccessful: Bool,
        displayName: String? = nil
    ) {
        self.id = id
        self.command = command
        self.executedAt = executedAt
        self.wasSuccessful = wasSuccessful
        self.displayName = displayName
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CommandHistory, rhs: CommandHistory) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 示例数据

extension CommandHistory {
    static let example = CommandHistory(
        command: "ffmpeg -i input.mp4 -c:v libx264 -crf 23 output.mp4",
        wasSuccessful: true
    )

    static let examples: [CommandHistory] = [
        CommandHistory(
            command: "ffmpeg -i video.mov -c:v libx265 output.mp4",
            executedAt: Date().addingTimeInterval(-3600),
            wasSuccessful: true,
            displayName: "HEVC 转码"
        ),
        CommandHistory(
            command: "ffmpeg -i audio.wav -c:a libmp3lame -b:a 192k output.mp3",
            executedAt: Date().addingTimeInterval(-7200),
            wasSuccessful: true
        ),
        CommandHistory(
            command: "ffmpeg -i broken.mp4 -c:v copy output.mp4",
            executedAt: Date().addingTimeInterval(-86400),
            wasSuccessful: false
        )
    ]
}
