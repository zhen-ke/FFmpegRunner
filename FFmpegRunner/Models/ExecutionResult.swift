//
//  ExecutionResult.swift
//  FFmpegRunner
//
//  命令执行结果
//

import Foundation

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
    var isStderr: Bool

    /// 初始化器
    init(timestamp: Date, level: LogLevel, message: String, isStderr: Bool = false) {
        self.id = UUID()
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.isStderr = isStderr
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

    /// 检测消息中是否包含错误关键字
    var containsErrorKeyword: Bool {
        let lowercased = message.lowercased()
        let errorKeywords = ["error", "failed", "invalid", "cannot", "no such", "not found", "denied", "fatal"]
        return errorKeywords.contains { lowercased.contains($0) }
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
