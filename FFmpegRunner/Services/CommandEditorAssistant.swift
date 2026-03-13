//
//  CommandEditorAssistant.swift
//  FFmpegRunner
//
//  自定义命令编辑辅助：基础诊断与常用补全（重构版）
//

import Foundation

// MARK: - Diagnostic

struct CommandEditorDiagnostic: Equatable, Identifiable {
    enum Severity: Equatable {
        case error
        case warning

        var symbolName: String {
            switch self {
            case .error:   return "xmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }
    }

    let id = UUID()
    let severity: Severity
    let message: String

    static func == (lhs: CommandEditorDiagnostic, rhs: CommandEditorDiagnostic) -> Bool {
        lhs.severity == rhs.severity && lhs.message == rhs.message
    }
}

// MARK: - Parsed Command

/// 单次解析结果，诊断与补全共享，避免重复遍历。
struct ParsedCommand {
    let executable: CommandExecutable?

    /// 解析后的 token 序列，区分语义角色
    let tokens: [ParsedToken]

    /// 输出路径（ffmpeg positional 语义下的最后一个非输入 positional）
    let outputPath: String?

    /// 输入路径列表（-i 的值）
    let inputPaths: [String]

    /// 所有 -f 的最后一次赋值
    let lastExplicitFormat: String?

    /// 末尾 flag 缺少值（解析结束时仍处于 expectValue 状态）
    let trailingFlagMissingValue: String?
}

enum ParsedToken {
    case executable(String)
    case flag(String)
    case value(String, for: String)   // value, 所属 flag
    case positional(String)           // 不属于任何 flag 的裸 token
    case informational(String)        // -version / -help 等
}

// MARK: - Parser (State Machine)

private enum ParseState {
    case expectToken
    case expectValue(for: String)
}

private struct CommandParser {

    static let flagsRequiringValue: Set<String> = [
        "-i", "-vf", "-af", "-filter_complex", "-c", "-c:v", "-c:a",
        "-preset", "-crf", "-pix_fmt", "-movflags", "-map",
        "-ss", "-to", "-t", "-r", "-s", "-b:v", "-b:a",
        "-f", "-profile:v", "-profile:a", "-level", "-tune", "-metadata",
        "-frames:v", "-frames:a", "-vframes", "-aframes",
        "-aspect", "-vbsf", "-absf", "-threads", "-pass", "-passlogfile",
        "-filter:v", "-filter:a", "-bufsize", "-maxrate", "-minrate"
    ]

    private static let informationalFlags: Set<String> = [
        "-version", "-buildconf", "-formats", "-muxers", "-demuxers",
        "-codecs", "-encoders", "-decoders", "-filters", "-pix_fmts",
        "-sample_fmts", "-layouts", "-colors", "-hwaccels", "-protocols",
        "-bsfs", "-help", "-h", "-L"
    ]

    /// 将原始 token 数组解析为 `ParsedCommand`。
    static func parse(_ rawArgs: [String]) -> ParsedCommand {
        guard !rawArgs.isEmpty else {
            return ParsedCommand(
                executable: nil, tokens: [], outputPath: nil,
                inputPaths: [], lastExplicitFormat: nil, trailingFlagMissingValue: nil
            )
        }

        let executable = CommandExecutable.from(token: rawArgs[0])
        var tokens: [ParsedToken] = [.executable(rawArgs[0])]
        var state: ParseState = .expectToken

        var inputPaths: [String] = []
        var positionals: [String] = []
        var lastFormat: String?
        var trailingFlag: String?

        for token in rawArgs.dropFirst() {
            switch state {
            case .expectValue(let flag):
                tokens.append(.value(token, for: flag))
                // 记录特殊值
                if flag == "-i" { inputPaths.append(token) }
                if flag == "-f" { lastFormat = token.lowercased() }
                state = .expectToken

            case .expectToken:
                if informationalFlags.contains(token) {
                    tokens.append(.informational(token))
                } else if flagsRequiringValue.contains(token) {
                    tokens.append(.flag(token))
                    state = .expectValue(for: token)
                } else if token.hasPrefix("-") {
                    // boolean flag（无值）
                    tokens.append(.flag(token))
                } else {
                    tokens.append(.positional(token))
                    positionals.append(token)
                }
            }
        }

        // 末尾 flag 缺少值
        if case .expectValue(let flag) = state {
            trailingFlag = flag
        }

        // 输出路径：positionals 中排除所有 -i 的值，取最后一个
        let inputSet = Set(inputPaths)
        let outputPath = positionals.last(where: { !inputSet.contains($0) })

        return ParsedCommand(
            executable: executable,
            tokens: tokens,
            outputPath: outputPath,
            inputPaths: inputPaths,
            lastExplicitFormat: lastFormat,
            trailingFlagMissingValue: trailingFlag
        )
    }
}

// MARK: - Completion Context

/// 光标所在语义位置，用于精确补全。
enum CompletionContext {
    case executableName(partial: String)
    case flagName(partial: String)
    case flagValue(flag: String, partial: String)
    case unknown
}

private struct CompletionContextResolver {

    /// 根据光标前的 token 流与当前 partial token 确定补全语义。
    static func resolve(
        prefixTokens: [String],
        partial: String
    ) -> CompletionContext {
        // 第一个 token 位置 → 补全可执行文件名
        if prefixTokens.isEmpty {
            return .executableName(partial: partial)
        }

        // 前一个 token 是需要值的 flag → 补全该 flag 的值
        if let last = prefixTokens.last,
           CommandParser.flagsRequiringValue.contains(last) {
            return .flagValue(flag: last, partial: partial)
        }

        // partial 以 "-" 开头 → 补全 flag 名
        if partial.hasPrefix("-") {
            return .flagName(partial: partial)
        }

        // partial 为空且处于 token 边界 → 补全 flag 名（默认）
        if partial.isEmpty {
            return .flagName(partial: "")
        }

        return .unknown
    }
}

// MARK: - Suggestion Registry

/// 所有补全建议的单一来源，便于后续扩展为运行时加载。
struct SuggestionRegistry {

    static let executableNames = CommandExecutable.allCases.map(\.binaryName)

    static let flags = [
        "-i", "-vf", "-af", "-filter_complex", "-c:v", "-c:a",
        "-preset", "-crf", "-pix_fmt", "-movflags", "-map",
        "-ss", "-to", "-t", "-r", "-s", "-b:v", "-b:a",
        "-an", "-vn", "-shortest", "-y", "-n", "-f",
        "-frames:v", "-threads", "-pass", "-passlogfile",
        "-aspect", "-bufsize", "-maxrate", "-minrate",
        "-version", "-buildconf", "-formats", "-codecs", "-encoders",
        "-decoders", "-filters", "-pix_fmts", "-help"
    ]

    static func values(for flag: String) -> [String]? {
        switch flag {
        case "-c", "-c:v", "-c:a":
            return ["libx264", "libx265", "h264_videotoolbox", "hevc_videotoolbox",
                    "copy", "aac", "libopus", "pcm_s16le", "libvpx-vp9", "av1"]
        case "-preset":
            return ["ultrafast", "superfast", "veryfast", "faster",
                    "fast", "medium", "slow", "slower", "veryslow"]
        case "-pix_fmt":
            return ["yuv420p", "yuv422p", "yuv444p", "nv12", "p010le", "yuv420p10le"]
        case "-f":
            return ["mp4", "mov", "matroska", "mpegts", "image2", "gif", "null", "rawvideo", "wav", "flac"]
        case "-movflags":
            return ["+faststart", "+frag_keyframe", "+empty_moov", "+default_base_moof"]
        case "-profile:v":
            return ["baseline", "main", "high", "high10", "high422", "high444"]
        case "-tune":
            return ["film", "animation", "grain", "stillimage", "fastdecode", "zerolatency"]
        case "-pass":
            return ["1", "2"]
        default:
            return nil
        }
    }
}

// MARK: - Main Assistant

struct CommandEditorAssistant {

    // MARK: Diagnostics

    static func diagnostics(for command: String) -> [CommandEditorDiagnostic] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 前置校验（使用项目已有的 CommandValidator）
        switch CommandValidator.validate(trimmed) {
        case .emptyCommand:
            return []
        case .malformedCommand(let message):
            return [CommandEditorDiagnostic(severity: .error, message: message)]
        case .notFFmpegCommand:
            return [CommandEditorDiagnostic(severity: .error, message: "仅支持补全和执行 ffmpeg / ffprobe 命令")]
        case .valid:
            break
        }

        guard let rawArgs = try? CommandRenderer.splitCommandStrict(trimmed) else { return [] }

        let parsed = CommandParser.parse(rawArgs)
        var result: [CommandEditorDiagnostic] = []

        // 1. 末尾 flag 缺少值
        if let flag = parsed.trailingFlagMissingValue {
            result.append(.init(severity: .error, message: "参数 \(flag) 缺少取值"))
        }

        // 2. ffmpeg 命令缺少输出目标
        if parsed.executable == .ffmpeg,
           !isInformational(parsed),
           parsed.outputPath == nil {
            result.append(.init(severity: .warning, message: "未检测到输出目标，执行时大概率会失败"))
        }

        // 3. 输出扩展名与 -f 不一致
        if let mismatch = outputFormatMismatch(parsed) {
            result.append(.init(severity: .warning, message: mismatch))
        }

        // 4. 无输入源（有输出但没有 -i）
        if parsed.executable == .ffmpeg,
           !isInformational(parsed),
           parsed.outputPath != nil,
           parsed.inputPaths.isEmpty {
            result.append(.init(severity: .warning, message: "未检测到输入源（-i）"))
        }

        return Array(result.prefix(3))
    }

    // MARK: Completions

    static func completions(
        for command: String,
        selectedRange: NSRange,
        partialRange: NSRange
    ) -> [String] {
        let partial = utf16Substring(in: command, range: partialRange)
        let prefixText = utf16Substring(
            in: command,
            range: NSRange(location: 0, length: max(0, partialRange.location))
        )
        let prefixTokens = (try? CommandRenderer.splitCommandStrict(prefixText)) ?? []

        let context = CompletionContextResolver.resolve(
            prefixTokens: prefixTokens,
            partial: partial
        )

        switch context {
        case .executableName(let partial):
            return filter(SuggestionRegistry.executableNames, matching: partial)

        case .flagName(let partial):
            return filter(SuggestionRegistry.flags, matching: partial)

        case .flagValue(let flag, let partial):
            let suggestions = SuggestionRegistry.values(for: flag) ?? []
            return filter(suggestions, matching: partial)

        case .unknown:
            return []
        }
    }
}

// MARK: - Private Helpers

private extension CommandEditorAssistant {

    static func isInformational(_ parsed: ParsedCommand) -> Bool {
        parsed.tokens.contains {
            if case .informational = $0 { return true }
            return false
        }
    }

    static func outputFormatMismatch(_ parsed: ParsedCommand) -> String? {
        guard let output = parsed.outputPath,
              let format = parsed.lastExplicitFormat,
              let ext = (output as NSString).pathExtension.lowercased().nonEmpty,
              format != ext else {
            return nil
        }
        return "输出格式 (-f \(format)) 与扩展名 (.\(ext)) 可能不一致"
    }

    static func filter(_ suggestions: [String], matching partial: String) -> [String] {
        guard !partial.isEmpty else { return suggestions }
        let lowered = partial.lowercased()
        return suggestions.filter { $0.lowercased().hasPrefix(lowered) }
    }

    static func utf16Substring(in text: String, range: NSRange) -> String {
        guard let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }
}

// MARK: - Minor Extensions

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
