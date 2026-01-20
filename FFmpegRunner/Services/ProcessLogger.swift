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

    /// 待处理的行缓冲
    private var lineBuffer = ""

    /// 串行队列 - 确保日志按顺序处理
    private let logQueue = DispatchQueue(label: "com.ffmpegrunner.processlogger.queue")

    /// 线程安全锁
    private let lock = NSLock()

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

    // MARK: - Public Methods

    /// 处理进程输出
    func processOutput(_ text: String, isError: Bool) {
        // 使用串行队列确保日志按顺序处理
        logQueue.async { [weak self] in
            guard let self = self else { return }

            self.lock.lock()
            defer { self.lock.unlock() }

            // 将文本按行分割
            self.lineBuffer += text
            let lines = self.lineBuffer.components(separatedBy: CharacterSet.newlines)

            // 保留最后一个不完整的行
            if !text.hasSuffix("\n") && !text.hasSuffix("\r") {
                self.lineBuffer = lines.last ?? ""
            } else {
                self.lineBuffer = ""
            }

            // 处理完整的行
            let completeLines = lines.dropLast()
            for line in completeLines {
                self.processLine(String(line), isError: isError)
            }

            // 如果缓冲区为空，也处理最后一行
            if self.lineBuffer.isEmpty, let lastLine = lines.last, !lastLine.isEmpty {
                self.processLine(lastLine, isError: isError)
            }
        }
    }

    /// 处理单行输出
    private func processLine(_ line: String, isError: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // 检测日志级别
        let level = detectLogLevel(trimmed, isError: isError)

        // 创建日志条目
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            message: trimmed
        )

        onLog?(entry)
    }

    /// 检测日志级别
    private func detectLogLevel(_ line: String, isError: Bool) -> LogLevel {
        let lowercased = line.lowercased()

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
        if lowercased.contains("frame=") ||
           lowercased.contains("size=") ||
           lowercased.contains("time=") {
            return .debug
        }

        // 默认
        return isError ? .warning : .info
    }

    /// 解析 FFmpeg 进度行
    func parseProgress(_ line: String) -> Progress? {
        guard line.contains("frame=") || line.contains("size=") else { return nil }

        var progress = Progress()

        // 解析 frame
        if let range = line.range(of: "frame=\\s*(\\d+)", options: .regularExpression) {
            let match = line[range]
            if let numRange = match.range(of: "\\d+", options: .regularExpression) {
                progress.frame = Int(match[numRange]) ?? 0
            }
        }

        // 解析 fps
        if let range = line.range(of: "fps=\\s*([\\d.]+)", options: .regularExpression) {
            let match = line[range]
            if let numRange = match.range(of: "[\\d.]+", options: .regularExpression) {
                progress.fps = Double(match[numRange]) ?? 0
            }
        }

        // 解析 size
        if let range = line.range(of: "size=\\s*(\\S+)", options: .regularExpression) {
            let match = line[range]
            progress.size = String(match.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }

        // 解析 time
        if let range = line.range(of: "time=\\s*(\\S+)", options: .regularExpression) {
            let match = line[range]
            progress.time = String(match.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }

        // 解析 bitrate
        if let range = line.range(of: "bitrate=\\s*(\\S+)", options: .regularExpression) {
            let match = line[range]
            progress.bitrate = String(match.dropFirst(8)).trimmingCharacters(in: .whitespaces)
        }

        // 解析 speed
        if let range = line.range(of: "speed=\\s*(\\S+)", options: .regularExpression) {
            let match = line[range]
            progress.speed = String(match.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }

        return progress
    }

    /// 清空缓冲区
    func clear() {
        lineBuffer = ""
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
