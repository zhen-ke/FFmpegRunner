//
//  ExecutionResult.swift
//  FFmpegRunner
//
//  命令执行结果
//

import Foundation
import SwiftUI

/// FFmpeg 命令执行结果
struct ExecutionResult {
    /// 执行的完整命令
    let command: String

    /// 退出码
    let exitCode: Int32

    /// 标准输出
    let standardOutput: String

    /// 标准错误
    let standardError: String

    /// 执行开始时间
    let startTime: Date

    /// 执行结束时间
    let endTime: Date

    /// 执行是否成功
    var isSuccess: Bool {
        exitCode == 0
    }

    /// 是否被取消
    /// - FFmpeg 收到 `q` 退出通常为 255
    /// - 被 SIGINT (Ctrl-C) 终止: 128 + 2 = 130
    /// - 被 SIGTERM 终止: 128 + 15 = 143
    /// - 被 SIGKILL 终止: 128 + 9 = 137
    var isCancelled: Bool {
        exitCode == 255 || exitCode == 130 || exitCode == 143 || exitCode == 137
    }

    /// 执行耗时（秒）
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    /// 格式化的执行耗时
    var formattedDuration: String {
        let seconds = Int(duration)
        if seconds < 60 {
            return "\(seconds) 秒"
        } else if seconds < 3600 {
            let minutes = seconds / 60
            let secs = seconds % 60
            return "\(minutes) 分 \(secs) 秒"
        } else {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            let secs = seconds % 60
            return "\(hours) 时 \(minutes) 分 \(secs) 秒"
        }
    }
}

// MARK: - 执行状态

/// 命令执行状态
enum ExecutionState: Equatable {
    /// 空闲
    case idle
    /// 准备中（校验/生成命令）
    case preparing
    /// 正在运行
    case running
    /// 取消中（SIGINT → SIGKILL 之间）
    case cancelling
    /// 已完成
    case completed(ExecutionResult)
    /// 已取消
    case cancelled
    /// 错误
    case error(String)

    /// 是否在执行流程中（preparing/running/cancelling）
    var isRunning: Bool {
        switch self {
        case .preparing, .running, .cancelling:
            return true
        default:
            return false
        }
    }

    /// 是否正在取消
    var isCancelling: Bool {
        if case .cancelling = self { return true }
        return false
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    /// 是否为终态（idle/completed/cancelled/error）
    var isTerminal: Bool {
        switch self {
        case .idle, .completed, .cancelled, .error:
            return true
        default:
            return false
        }
    }

    /// 状态显示文本
    var displayText: String {
        switch self {
        case .idle: return "就绪"
        case .preparing: return "准备中"
        case .running: return "执行中"
        case .cancelling: return "取消中"
        case .completed(let result): return result.isSuccess ? "完成" : "失败"
        case .cancelled: return "已取消"
        case .error: return "错误"
        }
    }

    /// 状态显示颜色
    var displayColor: Color {
        switch self {
        case .idle: return .secondary
        case .preparing, .running: return .blue
        case .cancelling, .cancelled: return .orange
        case .completed(let result): return result.isSuccess ? .green : .red
        case .error: return .red
        }
    }
}

// MARK: - Equatable for ExecutionResult

extension ExecutionResult: Equatable {
    static func == (lhs: ExecutionResult, rhs: ExecutionResult) -> Bool {
        lhs.command == rhs.command &&
        lhs.exitCode == rhs.exitCode &&
        lhs.startTime == rhs.startTime
    }
}

// MARK: - 日志条目

/// 日志条目
struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String

    /// 是否来自 stderr（用于颜色区分）
    let isStderr: Bool

    /// 是否为进度日志（frame= / time= 等）
    let isProgress: Bool

    /// 是否包含错误关键字（构造时预计算，避免重复字符串搜索）
    let containsErrorKeyword: Bool

    /// 错误关键字列表
    private static let errorKeywords = ["error", "failed", "invalid", "cannot", "no such", "not found", "denied", "fatal"]

    /// 初始化器
    init(
        id: UUID = UUID(),
        timestamp: Date,
        level: LogLevel,
        message: String,
        isStderr: Bool = false,
        isProgress: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.isStderr = isStderr
        self.isProgress = isProgress
        // 预计算错误关键字检测，避免每次 View 刷新都重新搜索
        let lowercased = message.lowercased()
        self.containsErrorKeyword = Self.errorKeywords.contains { lowercased.contains($0) }
    }

    /// 格式化的时间戳
    var formattedTimestamp: String {
        Self.timestampFormatter.string(from: timestamp)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// 是否为重要日志（错误/警告）
    var isImportant: Bool {
        level == .error || level == .warning
    }

    /// 使用指定 ID 创建副本（用于合并进度日志）
    /// - Note: 使用私有初始化器保留预计算的 containsErrorKeyword
    func withId(_ id: UUID) -> LogEntry {
        LogEntry(
            id: id,
            timestamp: timestamp,
            level: level,
            message: message,
            isStderr: isStderr,
            isProgress: isProgress,
            containsErrorKeyword: containsErrorKeyword
        )
    }

    /// 私有初始化器：用于 withId 等内部复制，直接传入预计算值
    private init(
        id: UUID,
        timestamp: Date,
        level: LogLevel,
        message: String,
        isStderr: Bool,
        isProgress: Bool,
        containsErrorKeyword: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.isStderr = isStderr
        self.isProgress = isProgress
        self.containsErrorKeyword = containsErrorKeyword
    }
}

/// 日志级别
enum LogLevel: String {
    case info
    case warning
    case error
    case debug

    var displayName: String {
        switch self {
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .debug: return "DEBUG"
        }
    }
}
