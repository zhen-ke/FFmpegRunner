//
//  CommandValidator.swift
//  FFmpegRunner
//
//  命令验证器 - 执行安全沙箱
//

import Foundation

/// 命令验证结果
enum CommandValidationResult: Equatable {
    /// 有效命令
    case valid
    /// 空命令
    case emptyCommand
    /// 非 FFmpeg 命令
    case notFFmpegCommand

    // 注意：不再使用 dangerousCommand，因为我们采用了更安全的 Tokenize + Process 执行方式
    // 这种方式天然免疫 shell 注入风险

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var errorMessage: String? {
        switch self {
        case .valid:
            return nil
        case .emptyCommand:
            return "命令不能为空"
        case .notFFmpegCommand:
            return "只允许执行 ffmpeg 或 ffprobe 命令"
        }
    }
}

/// 命令验证器
/// 确保只执行安全的 FFmpeg 命令
struct CommandValidator {

    // MARK: - Configuration

    /// 允许的命令可执行文件名
    private static let allowedExecutables = ["ffmpeg", "ffprobe"]

    // MARK: - Public Methods

    /// 验证命令是否安全
    ///
    /// 这里采用的是基于 Token 的验证策略：
    /// 1. 解析命令为参数数组 (Tokenize)
    /// 2. 检查第一个 Token（可执行文件）是否在允许名单中
    ///
    /// 相比于之前的字符串黑名单模式，这种方式：
    /// - 更安全：准确识别可执行文件，不受参数内容干扰
    /// - 更兼容：支持分号（滤镜链）、管道符（文件名中）、系统路径等合法参数
    static func validate(_ command: String) -> CommandValidationResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // 检查空命令
        guard !trimmed.isEmpty else {
            return .emptyCommand
        }

        // 使用 CommandRenderer 的分词逻辑，它能正确处理引号和转义
        let args = CommandRenderer.splitCommand(trimmed)

        guard let executablePath = args.first else {
            return .emptyCommand
        }

        // 提取文件名 (处理绝对路径情况，如 /usr/local/bin/ffmpeg)
        let executableName = (executablePath as NSString).lastPathComponent

        // 检查是否在允许名单中
        guard allowedExecutables.contains(executableName) else {
            return .notFFmpegCommand
        }

        return .valid
    }

    /// 验证输入文件是否存在
    static func validateInputFile(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 判断命令是否需要首次运行警告
    static func needsFirstRunWarning(hasAcknowledged: Bool) -> Bool {
        return !hasAcknowledged
    }
}
