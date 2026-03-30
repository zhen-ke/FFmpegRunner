//
//  LogPersistenceService.swift
//  FFmpegRunner
//
//  日志持久化服务
//

import Foundation

/// 负责将 FFmpeg 执行日志持久化到磁盘的 actor 服务
actor LogPersistenceService {

    /// 单例实例
    static let shared = LogPersistenceService()

    private let fileManager = FileManager.default
    private static let logDirectoryName = "Logs"
    private static let appDirectoryName = "FFmpegRunner"
    private let customLogDirectoryURL: URL?

    private let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter
    }()

    private let headerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(logDirectoryURL: URL? = nil) {
        self.customLogDirectoryURL = logDirectoryURL
    }

    // MARK: - 公共方法

    /// 保存日志到文件
    /// - Parameters:
    ///   - logs: 日志条目数组
    ///   - command: 执行的完整命令
    ///   - templateName: 模板名称（如果有）
    ///   - exitCode: 进程退出码（如果有）
    func saveLogs(
        _ logs: [LogEntry],
        command: String,
        templateName: String?,
        exitCode: Int32?,
        date: Date = Date()
    ) throws {
        let logDir = try ensureLogDirectory()

        let fileURL = nextLogFileURL(in: logDir, date: date, templateName: templateName)

        var content = ""

        // 写入文件头
        content += "════════════════════════════════════════\n"
        content += "FFmpegRunner 执行日志\n"
        content += "时间: \(headerDateFormatter.string(from: date))\n"
        content += "命令: \(command)\n"
        content += "════════════════════════════════════════\n\n"
        
        // 写入日志内容，过滤掉进度信息
        for entry in logs where !entry.isProgress {
            // 根据要求格式: [HH:mm:ss.SSS] [LEVEL] message
            // 使用 LogEntry 已有的 formattedTimestamp 和 LogLevel 的 displayName
            content += "[\(entry.formattedTimestamp)] [\(entry.level.displayName)] \(entry.message)\n"
        }
        
        content += "\n"
        
        // 写入文件尾
        content += "════════════════════════════════════════\n"
        let resultStr = (exitCode == 0) ? "成功" : "失败"
        let codeStr = exitCode != nil ? "\(exitCode!)" : "未知"
        content += "执行结果: \(resultStr) (退出码: \(codeStr))\n"
        content += "════════════════════════════════════════\n"

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// 获取所有已保存的日志文件列表，按时间倒序排列
    func listSavedLogs() throws -> [SavedLogInfo] {
        let logDir = try ensureLogDirectory()
        let fileURLs = try fileManager.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles)

        var logs: [SavedLogInfo] = []

        for url in fileURLs where url.pathExtension == "log" {
            let fileName = url.lastPathComponent
            let nameWithoutExtension = url.deletingPathExtension().lastPathComponent

            // 获取文件属性
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

            let metadata = parseFilenameMetadata(nameWithoutExtension)

            // 如果解析失败，回退到文件修改日期
            let resolvedDate = metadata.date ?? (attributes[.modificationDate] as? Date) ?? Date()

            logs.append(SavedLogInfo(
                id: url,
                fileName: fileName,
                date: resolvedDate,
                templateName: metadata.templateName,
                fileSize: fileSize
            ))
        }

        return logs.sorted()
    }

    /// 加载日志文件内容
    func loadLog(at url: URL) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else {
            throw NSError(domain: "LogPersistenceService", code: 404, userInfo: [NSLocalizedDescriptionKey: "日志文件不存在"])
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
    
    /// 删除特定日志文件
    func deleteLog(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
    
    /// 删除所有日志文件
    func deleteAllLogs() throws {
        let logDir = try ensureLogDirectory()
        let fileURLs = try fileManager.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil)
        for url in fileURLs where url.pathExtension == "log" {
            try fileManager.removeItem(at: url)
        }
    }

    /// 清理旧日志，仅保留最近的 maxCount 个
    func cleanupOldLogs(keeping maxCount: Int) throws {
        guard maxCount > 0 else {
            try deleteAllLogs()
            return
        }
        let logs = try listSavedLogs()
        if logs.count > maxCount {
            let logsToDelete = logs.suffix(logs.count - maxCount)
            for log in logsToDelete {
                try deleteLog(at: log.id)
            }
        }
    }
    
    /// 获取日志目录 URL
    nonisolated var logDirectoryURL: URL {
        if let customLogDirectoryURL {
            return customLogDirectoryURL
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(Self.appDirectoryName).appendingPathComponent(Self.logDirectoryName)
    }

    // MARK: - 私有辅助方法

    /// 确保日志目录存在
    private func ensureLogDirectory() throws -> URL {
        let logDir = logDirectoryURL
        if !fileManager.fileExists(atPath: logDir.path) {
            try fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        }
        return logDir
    }

    private func nextLogFileURL(in directory: URL, date: Date, templateName: String?) -> URL {
        let timestamp = filenameDateFormatter.string(from: date)
        let sanitizedTemplate = sanitizeTemplateName(templateName ?? "no_template")
        let baseName = "\(timestamp)_\(sanitizedTemplate)"
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension("log")
        var suffix = 1

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName)_\(suffix)")
                .appendingPathExtension("log")
            suffix += 1
        }

        return candidate
    }

    private func parseFilenameMetadata(_ nameWithoutExtension: String) -> (date: Date?, templateName: String?) {
        let prefixes: [(length: Int, separatorIndex: Int)] = [
            (19, 20), // yyyyMMdd_HHmmss_SSS + "_"
            (15, 16)  // yyyyMMdd_HHmmss + "_"
        ]

        for prefix in prefixes where nameWithoutExtension.count >= prefix.length {
            let datePart = String(nameWithoutExtension.prefix(prefix.length))
            let parsedDate = filenameDateFormatter.date(from: datePart) ?? parseLegacyDate(datePart)
            guard let parsedDate else { continue }

            var templateName: String?
            if nameWithoutExtension.count > prefix.separatorIndex {
                let start = nameWithoutExtension.index(nameWithoutExtension.startIndex, offsetBy: prefix.separatorIndex)
                templateName = String(nameWithoutExtension[start...])
                if templateName?.hasPrefix("no_template") == true {
                    templateName = nil
                }
            }

            return (parsedDate, templateName)
        }

        return (nil, nil)
    }

    private func parseLegacyDate(_ datePart: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.date(from: datePart)
    }

    /// 规范化模板名称以便用于文件名
    private func sanitizeTemplateName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let sanitized = name.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }.joined(separator: "_")
        return sanitized.isEmpty ? "no_template" : sanitized
    }
}

/// 已保存日志的信息结构
struct SavedLogInfo: Identifiable, Comparable {
    let id: URL  // 文件 URL
    let fileName: String
    let date: Date
    let templateName: String?
    let fileSize: Int64
    
    static func < (lhs: SavedLogInfo, rhs: SavedLogInfo) -> Bool {
        lhs.date > rhs.date  // newest first (按时间降序)
    }
}
