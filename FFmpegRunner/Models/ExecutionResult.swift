//
//  ExecutionResult.swift
//

import Foundation
import SwiftUI

struct ExecutionResult {
    let command: String
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let startTime: Date
    let endTime: Date

    var isSuccess: Bool { exitCode == 0 }

    // 255 = FFmpeg 收到 'q' 主动退出（等价于 UInt8.max 截断为 Int32）
    // 130 = 128 + SIGINT(2)，143 = 128 + SIGTERM(15)，137 = 128 + SIGKILL(9)
    private static let cancelledExitCodes: Set<Int32> = [255, 130, 143, 137]

    var isCancelled: Bool {
        Self.cancelledExitCodes.contains(exitCode)
    }

    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }

    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = duration < 60 ? [.second]
            : duration < 3600 ? [.minute, .second]
            : [.hour, .minute, .second]
        return formatter.string(from: duration) ?? "\(Int(duration)) 秒"
    }
}

// MARK: - ExecutionState

enum ExecutionState {
    case idle
    case preparing
    case running
    case cancelling
    case completed(ExecutionResult)
    case cancelled
    case error(String)

    var isRunning: Bool {
        switch self {
        case .preparing, .running, .cancelling: return true
        default: return false
        }
    }

    var isCancelling: Bool {
        if case .cancelling = self { return true }
        return false
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    var isTerminal: Bool {
        switch self {
        case .idle, .completed, .cancelled, .error: return true
        default: return false
        }
    }

    var displayText: String {
        switch self {
        case .idle:                      return "就绪"
        case .preparing:                 return "准备中"
        case .running:                   return "执行中"
        case .cancelling:                return "取消中"
        case .completed(let r):          return r.isSuccess ? "完成" : "失败"
        case .cancelled:                 return "已取消"
        case .error:                     return "错误"
        }
    }

    var displayColor: Color {
        switch self {
        case .idle:                      return .secondary
        case .preparing, .running:       return .blue
        case .cancelling, .cancelled:    return .orange
        case .completed(let r):          return r.isSuccess ? .green : .red
        case .error:                     return .red
        }
    }
}

// 关联值类型变更时不会静默失效
extension ExecutionState: Equatable {
    static func == (lhs: ExecutionState, rhs: ExecutionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.preparing, .preparing),
             (.running, .running),
             (.cancelling, .cancelling),
             (.cancelled, .cancelled):
            return true
        case (.completed(let l), .completed(let r)):
            return l == r
        case (.error(let l), .error(let r)):
            return l == r
        default:
            return false
        }
    }
}

// MARK: - ExecutionResult + Equatable

extension ExecutionResult: Equatable {
    static func == (lhs: ExecutionResult, rhs: ExecutionResult) -> Bool {
        lhs.command == rhs.command &&
        lhs.exitCode == rhs.exitCode &&
        lhs.startTime == rhs.startTime
    }
}

// MARK: - LogEntry

struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String
    let isStderr: Bool
    let isProgress: Bool
    let containsErrorKeyword: Bool
    let formattedTimestamp: String

    private static let errorKeywords: Set<String> = [
        "error", "failed", "invalid", "cannot",
        "no such", "not found", "denied", "fatal"
    ]

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

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
        let lower = message.lowercased()
        self.containsErrorKeyword = Self.errorKeywords.contains { lower.contains($0) }
        self.formattedTimestamp = Self.timestampFormatter.string(from: timestamp)
    }

    var isImportant: Bool { level == .error || level == .warning }

    func withId(_ newId: UUID) -> LogEntry {
        return LogEntry(
            id: newId,
            timestamp: timestamp,
            level: level,
            message: message,
            isStderr: isStderr,
            isProgress: isProgress
        )
    }
}

enum LogLevel: String {
    case info, warning, error, debug

    var displayName: String {
        rawValue.uppercased()   // ✅ Opt: 消除重复 switch
    }
}
