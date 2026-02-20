//
//  ProcessLogger.swift
//  FFmpegRunner
//
//  进程日志服务
//

import Foundation

// MARK: - Protocol

/// 进程日志提供者协议
/// 用于依赖注入和测试 mock
protocol ProcessLoggerProviding {
    var onLog: ((LogEntry) -> Void)? { get set }
    func processOutput(_ text: String, isError: Bool)
    func clear()
}

// MARK: - Implementation

/// 进程日志服务
/// 负责监听和处理进程输出
class ProcessLogger: ProcessLoggerProviding {

    // MARK: - Properties

    /// 日志回调
    var onLog: ((LogEntry) -> Void)?

    /// 回调队列（默认主线程，UI 友好）
    var callbackQueue: DispatchQueue = .main

    /// 待处理的行缓冲
    private var lineBuffer = ""

    /// 串行队列 - 确保日志按顺序处理且线程安全
    private let logQueue: DispatchQueue

    /// 队列标识 key（用于死锁检测）
    private static let queueKey = DispatchSpecificKey<Bool>()

    /// 缓冲区最大大小（防止内存溢出）
    private let maxBufferSize = 10_000

    // MARK: - FFmpeg 进度解析

    /// FFmpeg 进度信息
    struct Progress {
        var frame: Int = 0
        var fps: Double = 0
        var size: String = ""
        var time: String = ""
        var bitrate: String = ""
        var speed: String = ""
    }

    // MARK: - Initializer

    init() {
        logQueue = DispatchQueue(label: "com.ffmpegrunner.processlogger.queue")
        logQueue.setSpecific(key: Self.queueKey, value: true)
    }

    // MARK: - Public Methods

    /// 处理进程输出
    func processOutput(_ text: String, isError: Bool) {
        // 使用串行队列确保日志按顺序处理（队列本身提供线程安全，无需额外锁）
        logQueue.async { [weak self] in
            guard let self = self else { return }

            // 缓冲区溢出保护
            if self.lineBuffer.count + text.count > self.maxBufferSize {
                self.dropBufferDueToOverflow(isError: isError)
            }

            self.lineBuffer += text
            self.processBuffer(isError: isError)
        }
    }

    /// 清空缓冲区（线程安全）
    func clear() {
        logQueue.async { [weak self] in
            self?.lineBuffer.removeAll(keepingCapacity: true)
        }
    }

    /// 同步清空缓冲区（用于需要立即清空的场景）
    /// - Note: 内置死锁保护，在 logQueue 内部调用时直接执行而非 sync
    func clearSync() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            // 已在 logQueue 内，直接执行避免死锁
            lineBuffer.removeAll(keepingCapacity: true)
        } else {
            logQueue.sync {
                lineBuffer.removeAll(keepingCapacity: true)
            }
        }
    }

    /// 同步刷新缓冲区中的最后一行（即使没有换行符）
    /// - Parameter asError: 将尾行按 stderr 还是 stdout 语义处理
    func flushPendingLineSync(asError: Bool = false) {
        let flushBlock = {
            let trimmed = self.lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                self.lineBuffer.removeAll(keepingCapacity: true)
                return
            }
            self.lineBuffer.removeAll(keepingCapacity: true)
            self.processLine(trimmed, isError: asError)
        }

        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            flushBlock()
        } else {
            logQueue.sync(execute: flushBlock)
        }
    }

    // MARK: - Private Methods

    /// 处理缓冲区中的完整行（使用索引遍历，避免数组分配）
    private func processBuffer(isError: Bool) {
        var remaining = lineBuffer[...]

        while let newlineIndex = remaining.firstIndex(where: { $0.isNewline }) {
            let line = remaining[..<newlineIndex]
            let afterNewline = remaining.index(after: newlineIndex)

            if !line.isEmpty {
                processLine(String(line), isError: isError)
            }

            remaining = remaining[afterNewline...]
        }

        // 保留未处理的部分（不完整的行）
        lineBuffer = String(remaining)
    }

    /// 缓冲区溢出时丢弃内容并记录告警
    /// - Note: 不会处理不完整的行，而是直接丢弃整个缓冲区
    private func dropBufferDueToOverflow(isError: Bool) {
        guard !lineBuffer.isEmpty else { return }

        let droppedCount = lineBuffer.count
        let snippetLimit = 200
        let snippet = String(lineBuffer.prefix(snippetLimit))
        let snippetSuffix = snippet.isEmpty ? "" : "，示例: \(snippet)"

        let entry = LogEntry(
            timestamp: Date(),
            level: isError ? .warning : .info,
            message: "[缓冲区溢出] 日志输出过快，已丢弃 \(droppedCount) 字符\(snippetSuffix)",
            isStderr: isError
        )
        emit(entry)
        lineBuffer.removeAll()
    }

    /// 处理单行输出
    private func processLine(_ line: String, isError: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let lowercased = trimmed.lowercased()
        let isProgress = isProgressLine(lowercased)

        // 检测日志级别
        let level = detectLogLevel(lowercased, isError: isError, isProgress: isProgress)

        // 创建日志条目
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            message: trimmed,
            isStderr: isError,
            isProgress: isProgress
        )

        emit(entry)
    }

    /// 在指定队列上发送日志回调（默认主线程）
    private func emit(_ entry: LogEntry) {
        let callback = onLog
        callbackQueue.async {
            callback?(entry)
        }
    }

    /// 检测日志级别
    private func detectLogLevel(_ lowercased: String, isError: Bool, isProgress: Bool) -> LogLevel {
        // 错误
        if lowercased.contains("error") ||
           lowercased.contains("failed") ||
           lowercased.contains("invalid") ||
           lowercased.contains("no such file") {
            return .error
        }

        // 警告
        if lowercased.contains("warning") ||
           lowercased.contains("deprecated") ||
           lowercased.contains("discarding") {
            return .warning
        }

        // 进度信息（frame=, size=, time= 等）
        if isProgress {
            return .debug
        }

        // 默认
        return isError ? .warning : .info
    }

    /// 是否为 FFmpeg 进度行
    /// - Note: 需要至少匹配 2 个关键字段，减少误判率
    private func isProgressLine(_ lowercased: String) -> Bool {
        let progressKeywords = [
            "frame=",
            "fps=",
            "size=",
            "time=",
            "bitrate=",
            "speed="
        ]
        let matchCount = progressKeywords.filter { lowercased.contains($0) }.count
        return matchCount >= 2
    }

    /// 解析 FFmpeg 进度行（使用字符串分割，性能优于正则表达式）
    func parseProgress(_ line: String) -> Progress? {
        guard line.contains("frame=") || line.contains("size=") else { return nil }

        var progress = Progress()

        // 使用空格分割，然后解析 key=value 对
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)

        for part in parts {
            let keyValue = part.split(separator: "=", maxSplits: 1)
            guard keyValue.count == 2 else { continue }

            let key = String(keyValue[0]).trimmingCharacters(in: .whitespaces)
            let value = String(keyValue[1]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "frame":
                progress.frame = Int(value) ?? 0
            case "fps":
                progress.fps = Double(value) ?? 0
            case "size":
                progress.size = value
            case "time":
                progress.time = value
            case "bitrate":
                progress.bitrate = value
            case "speed":
                // 移除 "x" 后缀（如 "1.5x" -> "1.5"）
                progress.speed = value.replacingOccurrences(of: "x", with: "")
            default:
                break
            }
        }

        return progress
    }
}

// MARK: - 日志格式化

extension LogEntry {
    /// 格式化为显示字符串
    var displayString: String {
        "[\(formattedTimestamp)] [\(level.displayName)] \(message)"
    }

    /// 带颜色的属性字符串（用于 NSTextView）
    var colorCode: String {
        switch level {
        case .info: return "34"    // 蓝色
        case .warning: return "33" // 黄色
        case .error: return "31"   // 红色
        case .debug: return "90"   // 灰色
        }
    }
}
