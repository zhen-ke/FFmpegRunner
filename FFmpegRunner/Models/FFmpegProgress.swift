//
//  FFmpegProgress.swift
//  FFmpegRunner
//
//  FFmpeg 转码进度模型
//
//  设计说明：
//  - 从 FFmpeg stderr 实时解析进度信息（frame=, time=, speed= 等）
//  - 结合 Duration 头计算百分比进度
//  - 纯值类型，线程安全，可直接用于 UI 绑定
//

import Foundation

// MARK: - FFmpegProgress

/// FFmpeg 转码进度快照
/// 解析自 FFmpeg 的 stderr 进度行，例如：
/// `frame=  100 fps= 30 q=28.0 size=    1024kB time=00:00:03.33 bitrate= 2514.7kbits/s speed=1.00x`
struct FFmpegProgress: Equatable, Sendable {

    // MARK: - 解析字段

    /// 已处理帧数
    let frame: Int

    /// 当前帧率
    let fps: Double

    /// 已输出文件大小（字节）
    let sizeBytes: Int64

    /// 已处理时间（秒）
    let timeSeconds: TimeInterval

    /// 当前比特率（kbits/s），nil 表示 N/A
    let bitrateKbps: Double?

    /// 处理速度倍数（如 1.5x），nil 表示 N/A
    let speed: Double?

    // MARK: - 进度计算

    /// 总时长（秒），来自 FFmpeg 输出的 Duration 头
    let totalDuration: TimeInterval?

    /// 进度百分比 (0.0 ~ 1.0)
    /// 仅当 totalDuration 已知且 > 0 时有值
    var fractionCompleted: Double? {
        guard let total = totalDuration, total > 0 else { return nil }
        return min(timeSeconds / total, 1.0)
    }

    /// 预计剩余时间（秒）
    var estimatedTimeRemaining: TimeInterval? {
        guard let total = totalDuration, total > 0,
              let speed = speed, speed > 0 else {
            return nil
        }
        let remaining = total - timeSeconds
        guard remaining > 0 else { return 0 }
        return remaining / speed
    }

    /// 格式化的已处理时间
    var formattedTime: String {
        Self.formatTime(timeSeconds)
    }

    /// 格式化的总时长
    var formattedTotalDuration: String? {
        guard let total = totalDuration else { return nil }
        return Self.formatTime(total)
    }

    /// 格式化的预计剩余时间
    var formattedETA: String? {
        guard let eta = estimatedTimeRemaining else { return nil }
        if eta < 1 { return "即将完成" }
        return Self.formatTime(eta)
    }

    /// 格式化的文件大小
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// 格式化的速度
    var formattedSpeed: String? {
        guard let speed = speed else { return nil }
        if speed >= 10 {
            return String(format: "%.0fx", speed)
        }
        return String(format: "%.1fx", speed)
    }

    /// 格式化的比特率
    var formattedBitrate: String? {
        guard let bitrate = bitrateKbps else { return nil }
        if bitrate >= 1000 {
            return String(format: "%.1f Mbps", bitrate / 1000)
        }
        return String(format: "%.0f kbps", bitrate)
    }

    // MARK: - 时间格式化

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60

        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - FFmpegProgressParser

/// FFmpeg 进度解析器
/// 从 stderr 输出中提取结构化进度信息
///
/// 使用方式：
/// 1. 每收到一行 FFmpeg 输出时调用 `parseLine(_:)`
/// 2. Duration 行会被自动捕获，用于后续进度百分比计算
/// 3. 进度行（frame=xxx time=xxx）返回 FFmpegProgress 快照
enum FFmpegProgressParser {

    // MARK: - Duration 解析

    // Duration: 00:05:30.12, start: 0.000000, bitrate: 1234 kb/s
    private static let durationPattern = try! NSRegularExpression(
        pattern: #"Duration:\s*(\d{2}):(\d{2}):(\d{2})\.(\d{2,3})"#,
        options: []
    )

    /// 从 FFmpeg 输出行中提取总时长
    /// - Returns: 总时长（秒），或 nil（非 Duration 行）
    static func parseDuration(from line: String) -> TimeInterval? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = durationPattern.firstMatch(in: line, options: [], range: range) else {
            return nil
        }

        guard let hours = extractInt(from: line, match: match, group: 1),
              let minutes = extractInt(from: line, match: match, group: 2),
              let seconds = extractInt(from: line, match: match, group: 3),
              let centiseconds = extractInt(from: line, match: match, group: 4) else {
            return nil
        }

        let totalSeconds = Double(hours * 3600 + minutes * 60 + seconds)
        let fraction = Double(centiseconds) / (centiseconds >= 100 ? 1000.0 : 100.0)
        return totalSeconds + fraction
    }

    // MARK: - 进度行解析

    /// 从 FFmpeg 进度行解析结构化进度信息
    /// - Parameters:
    ///   - line: FFmpeg stderr 输出行
    ///   - totalDuration: 已知的总时长（来自之前解析的 Duration 头）
    /// - Returns: 解析后的进度信息，非进度行返回 nil
    static func parseProgress(from line: String, totalDuration: TimeInterval?) -> FFmpegProgress? {
        let lowercased = line.lowercased()

        // 快速排除：至少包含 time= 才可能是进度行
        guard lowercased.contains("time=") else { return nil }

        // 提取 time= 字段（核心字段，必须存在）
        guard let timeSeconds = parseTimeField(from: line) else { return nil }

        // 提取其它字段（可选）
        let frame = parseIntField(from: line, key: "frame=") ?? 0
        let fps = parseDoubleField(from: line, key: "fps=") ?? 0
        let sizeBytes = parseSizeField(from: line)
        let bitrateKbps = parseBitrateField(from: line)
        let speed = parseSpeedField(from: line)

        return FFmpegProgress(
            frame: frame,
            fps: fps,
            sizeBytes: sizeBytes,
            timeSeconds: timeSeconds,
            bitrateKbps: bitrateKbps,
            speed: speed,
            totalDuration: totalDuration
        )
    }

    // MARK: - 字段提取

    /// 解析 time=HH:MM:SS.ss 字段
    private static let timeFieldPattern = try! NSRegularExpression(
        pattern: #"time=\s*(-?)(\d{2}):(\d{2}):(\d{2})\.(\d{2,3})"#,
        options: []
    )

    private static func parseTimeField(from line: String) -> TimeInterval? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = timeFieldPattern.firstMatch(in: line, options: [], range: range) else {
            return nil
        }

        // 检查负号（FFmpeg 有时在开头输出 time=-00:00:00.xx）
        let isNegative: Bool
        if let signRange = Range(match.range(at: 1), in: line) {
            isNegative = line[signRange] == "-"
        } else {
            isNegative = false
        }

        guard let hours = extractInt(from: line, match: match, group: 2),
              let minutes = extractInt(from: line, match: match, group: 3),
              let seconds = extractInt(from: line, match: match, group: 4),
              let centiseconds = extractInt(from: line, match: match, group: 5) else {
            return nil
        }

        let total = Double(hours * 3600 + minutes * 60 + seconds)
        let fraction = Double(centiseconds) / (centiseconds >= 100 ? 1000.0 : 100.0)
        let result = total + fraction

        return isNegative ? 0 : result  // 负时间视为 0
    }

    /// 解析整数字段（如 frame= 123）
    private static func parseIntField(from line: String, key: String) -> Int? {
        guard let valueStr = extractFieldValue(from: line, key: key) else { return nil }
        return Int(valueStr)
    }

    /// 解析浮点字段（如 fps= 29.97）
    private static func parseDoubleField(from line: String, key: String) -> Double? {
        guard let valueStr = extractFieldValue(from: line, key: key) else { return nil }
        return Double(valueStr)
    }

    /// 解析 size 字段（如 size= 1024KiB 或 size= 1024kB → 字节数）
    /// FFmpeg 不同版本可能输出 kB/KiB/mB/MiB/gB/GiB
    private static func parseSizeField(from line: String) -> Int64 {
        guard let valueStr = extractFieldValue(from: line, key: "size=") else { return 0 }

        let lowercased = valueStr.lowercased()
        let numberStr = lowercased
            .replacingOccurrences(of: "kib", with: "")
            .replacingOccurrences(of: "mib", with: "")
            .replacingOccurrences(of: "gib", with: "")
            .replacingOccurrences(of: "kb", with: "")
            .replacingOccurrences(of: "mb", with: "")
            .replacingOccurrences(of: "gb", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let number = Double(numberStr) else { return 0 }

        if lowercased.hasSuffix("gib") || lowercased.hasSuffix("gb") {
            return Int64(number * 1024 * 1024 * 1024)
        } else if lowercased.hasSuffix("mib") || lowercased.hasSuffix("mb") {
            return Int64(number * 1024 * 1024)
        } else {
            // 默认 kB / KiB
            return Int64(number * 1024)
        }
    }

    /// 解析 bitrate 字段（如 bitrate= 2514.7kbits/s → kbps）
    private static func parseBitrateField(from line: String) -> Double? {
        guard let valueStr = extractFieldValue(from: line, key: "bitrate=") else { return nil }

        let cleaned = valueStr
            .lowercased()
            .replacingOccurrences(of: "kbits/s", with: "")
            .replacingOccurrences(of: "kbit/s", with: "")
            .replacingOccurrences(of: "mbits/s", with: "")
            .trimmingCharacters(in: .whitespaces)

        if cleaned == "n/a" { return nil }

        guard let value = Double(cleaned) else { return nil }

        // 如果原始包含 mbits，转换为 kbits
        if valueStr.lowercased().contains("mbits") {
            return value * 1000
        }
        return value
    }

    /// 解析 speed 字段（如 speed= 1.5x → 1.5）
    private static func parseSpeedField(from line: String) -> Double? {
        guard let valueStr = extractFieldValue(from: line, key: "speed=") else { return nil }

        let cleaned = valueStr
            .lowercased()
            .replacingOccurrences(of: "x", with: "")
            .trimmingCharacters(in: .whitespaces)

        if cleaned == "n/a" { return nil }

        return Double(cleaned)
    }

    /// 从行中提取 key=value 形式的值部分
    /// FFmpeg 格式：`key= value` 或 `key=value`，值以空格或行尾结束
    private static func extractFieldValue(from line: String, key: String) -> String? {
        guard let keyRange = line.range(of: key, options: .caseInsensitive) else {
            return nil
        }

        let valueStart = keyRange.upperBound
        let remaining = line[valueStart...]

        // 值从第一个非空白字符开始，到空格分隔的下一个 key= 或行尾结束
        let trimmed = remaining.drop(while: { $0 == " " })
        guard !trimmed.isEmpty else { return nil }

        // 查找值的结束位置：下一个 key= 模式之前的空格
        // FFmpeg 字段格式：`key=value key2=value2`
        var endIndex = trimmed.endIndex
        var i = trimmed.startIndex
        while i < trimmed.endIndex {
            if trimmed[i] == " " {
                // 检查空格后是否跟着 xxx= 模式
                let afterSpace = trimmed.index(after: i)
                if afterSpace < trimmed.endIndex {
                    let rest = trimmed[afterSpace...]
                    if rest.contains("=") {
                        let possibleKey = rest.prefix(while: { $0 != "=" && $0 != " " })
                        if !possibleKey.isEmpty {
                            endIndex = i
                            break
                        }
                    }
                }
            }
            i = trimmed.index(after: i)
        }

        let value = String(trimmed[trimmed.startIndex..<endIndex])
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    // MARK: - Helpers

    private static func extractInt(
        from string: String,
        match: NSTextCheckingResult,
        group: Int
    ) -> Int? {
        guard let range = Range(match.range(at: group), in: string) else { return nil }
        return Int(string[range])
    }
}

// MARK: - FFmpegProgressTracker

/// 转码进度追踪器
/// 管理单次执行的进度状态（线程安全，供 ProcessLogger 使用）
///
/// 职责：
/// - 捕获首次出现的 Duration 头
/// - 将每条进度行转换为 FFmpegProgress 快照
/// - 通过回调通知外部（ViewModel）
final class FFmpegProgressTracker: @unchecked Sendable {

    /// 进度更新回调（在主线程调用）
    var onProgress: ((FFmpegProgress) -> Void)?

    /// 已知总时长（从 Duration 头解析）
    private var totalDuration: TimeInterval?

    /// 串行队列保证线程安全
    private let queue = DispatchQueue(label: "com.ffmpegrunner.progress-tracker")

    /// 处理一行 FFmpeg 输出，提取进度信息
    /// - Parameter line: FFmpeg 的 stderr/stdout 输出行
    func processLine(_ line: String) {
        queue.async { [weak self] in
            guard let self else { return }

            // 1. 尝试捕获 Duration（仅首次）
            if self.totalDuration == nil {
                if let duration = FFmpegProgressParser.parseDuration(from: line) {
                    self.totalDuration = duration
                }
            }

            // 2. 尝试解析进度行
            if let progress = FFmpegProgressParser.parseProgress(
                from: line,
                totalDuration: self.totalDuration
            ) {
                let callback = self.onProgress
                DispatchQueue.main.async {
                    callback?(progress)
                }
            }
        }
    }

    /// 重置追踪器状态（新执行开始前调用）
    func reset() {
        queue.async { [weak self] in
            self?.totalDuration = nil
        }
    }
}
