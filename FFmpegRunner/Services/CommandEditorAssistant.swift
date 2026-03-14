//
//  CommandEditorAssistant.swift
//  FFmpegRunner
//
//  自定义命令编辑辅助：Lexer + Knowledge Base + Conflict 诊断
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

// MARK: - Lexer Token
//
// Lexer 的职责：将原始字符串序列转为带语义标注的 Token 序列。
// 不做任何跨 token 关联，不做 "这个值属于哪个 flag" 的判断——那是 Parser 的事。

enum Token: Equatable {
    /// 可执行文件名，例如 "ffmpeg"
    case executable(String)

    /// 普通 flag，例如 "-y", "-an"
    case flag(String)

    /// 带流限定符的 flag，例如 "-c:v", "-filter:a"
    /// - flag: 基础 flag 名，如 "-c"
    /// - stream: 流限定符，如 "v" / "a" / "s" / "V"
    case streamSpecifier(flag: String, stream: String)

    /// 信息性 flag，执行后直接输出信息并退出，如 "-version", "-help"
    case informational(String)

    /// 裸字符串，尚未确定语义（可能是 flag 的值，也可能是 positional）
    case word(String)

    /// flag 的原始字面量（含流限定符前缀，若有）
    var rawText: String {
        switch self {
        case .executable(let s), .flag(let s), .informational(let s), .word(let s):
            return s
        case .streamSpecifier(let f, let s):
            return "\(f):\(s)"
        }
    }

    /// 是否是任意形式的 flag（flag / streamSpecifier / informational）
    var isAnyFlag: Bool {
        switch self {
        case .flag, .streamSpecifier, .informational: return true
        default: return false
        }
    }
}

// MARK: - Lexer

/// 将一个原始 token 字符串数组转为 [Token]。
/// 输入来自 CommandRenderer.splitCommandStrict，每个元素已是完整 token（无需处理引号）。
private enum Lexer {

    private static let informationalFlags: Set<String> = [
        "-version", "-buildconf", "-formats", "-muxers", "-demuxers",
        "-codecs", "-encoders", "-decoders", "-filters", "-pix_fmts",
        "-sample_fmts", "-layouts", "-colors", "-hwaccels", "-protocols",
        "-bsfs", "-help", "-h", "-L"
    ]

    /// 合法流限定符
    private static let streamSpecifiers: Set<String> = ["v", "V", "a", "s", "d", "t"]

    static func lex(_ rawArgs: [String]) -> [Token] {
        guard !rawArgs.isEmpty else { return [] }

        var tokens: [Token] = []

        for (index, raw) in rawArgs.enumerated() {
            if index == 0 {
                tokens.append(.executable(raw))
                continue
            }

            guard raw.hasPrefix("-"), raw.count > 1 else {
                tokens.append(.word(raw))
                continue
            }

            if informationalFlags.contains(raw) {
                tokens.append(.informational(raw))
                continue
            }

            // 检测流限定符："-c:v", "-filter:a" 等
            // 格式：-<name>:<specifier>
            if let colonIndex = raw.firstIndex(of: ":") {
                let specifier = String(raw[raw.index(after: colonIndex)...])
                let baseName  = String(raw[..<colonIndex])   // 含 "-"
                if streamSpecifiers.contains(specifier) {
                    tokens.append(.streamSpecifier(flag: baseName, stream: specifier))
                    continue
                }
            }

            tokens.append(.flag(raw))
        }

        return tokens
    }
}

// MARK: - Knowledge Base

/// 格式知识条目：记录某种容器格式支持的编解码器与相关约束。
struct FormatProfile {
    let videoCodecs: [String]
    let audioCodecs: [String]
    let recommendedMovflags: [String]
}

/// FFmpeg 知识库：格式、编解码器、preset 等静态知识的单一来源。
/// 设计为值类型 + 静态数据，后续可替换为从 JSON / plist 动态加载。
struct KnowledgeBase {

    // MARK: Format Profiles

    static let formatProfiles: [String: FormatProfile] = [
        "mp4": FormatProfile(
            videoCodecs: ["libx264", "libx265", "h264_videotoolbox", "hevc_videotoolbox", "copy"],
            audioCodecs: ["aac", "libopus", "copy"],
            recommendedMovflags: ["+faststart"]
        ),
        "mov": FormatProfile(
            videoCodecs: ["libx264", "libx265", "h264_videotoolbox", "hevc_videotoolbox",
                          "prores_ks", "copy"],
            audioCodecs: ["aac", "pcm_s16le", "pcm_s24le", "copy"],
            recommendedMovflags: []
        ),
        "matroska": FormatProfile(
            videoCodecs: ["libx264", "libx265", "libvpx-vp9", "av1", "copy"],
            audioCodecs: ["aac", "libopus", "libvorbis", "flac", "copy"],
            recommendedMovflags: []
        ),
        "webm": FormatProfile(
            videoCodecs: ["libvpx-vp9", "av1"],
            audioCodecs: ["libopus", "libvorbis"],
            recommendedMovflags: []
        ),
        "mpegts": FormatProfile(
            videoCodecs: ["libx264", "libx265", "copy"],
            audioCodecs: ["aac", "libopus", "copy"],
            recommendedMovflags: []
        ),
        "flv": FormatProfile(
            videoCodecs: ["libx264", "copy"],
            audioCodecs: ["aac", "copy"],
            recommendedMovflags: []
        ),
    ]

    // MARK: Codec Suggestions (fallback，无格式上下文时使用)

    static let allVideoCodecs = [
        "libx264", "libx265", "h264_videotoolbox", "hevc_videotoolbox",
        "libvpx-vp9", "av1", "prores_ks", "copy"
    ]

    static let allAudioCodecs = [
        "aac", "libopus", "libvorbis", "pcm_s16le", "pcm_s24le", "flac", "copy"
    ]

    static let allCodecs = allVideoCodecs + allAudioCodecs

    // MARK: Other Value Lists

    static let genericPresets = [
        "ultrafast", "superfast", "veryfast", "faster",
        "fast", "medium", "slow", "slower", "veryslow"
    ]

    static let pixelFormats = [
        "yuv420p", "yuv422p", "yuv444p", "nv12", "p010le", "yuv420p10le"
    ]

    static let containerFormats = [
        "mp4", "mov", "matroska", "webm", "mpegts", "flv",
        "image2", "gif", "null", "rawvideo", "wav", "flac"
    ]

    static let movflagsValues = [
        "+faststart", "+frag_keyframe", "+empty_moov", "+default_base_moof"
    ]

    static let profilesH264 = ["baseline", "main", "high", "high10", "high422", "high444"]
    static let tuneValues    = ["film", "animation", "grain", "stillimage", "fastdecode", "zerolatency"]

    // MARK: Context-Aware Codec Lookup

    /// 根据当前已知格式和流类型返回推荐编解码器。
    /// - Parameters:
    ///   - format: -f 的值（如 "mp4"），为 nil 时返回全量列表
    ///   - stream: 流限定符（"v" / "a"），为 nil 时合并视频+音频
    static func codecs(format: String?, stream: String?) -> [String] {
        guard let format, let profile = formatProfiles[format] else {
            switch stream {
            case "v", "V": return allVideoCodecs
            case "a":      return allAudioCodecs
            default:       return allCodecs
            }
        }
        switch stream {
        case "v", "V": return profile.videoCodecs
        case "a":      return profile.audioCodecs
        default:       return profile.videoCodecs + profile.audioCodecs
        }
    }

    // MARK: Conflict Rules

    /// 已知冲突规则：(flagA, flagB, 诊断消息)
    /// flagA / flagB 均为 rawText，支持精确匹配。
    /// 特殊情况：a == "-c:v" 时，只在值确实为 "copy" 时触发（由诊断层负责检查）。
    static let conflictRules: [(a: String, b: String, message: String)] = [
        (
            a: "-c:v",
            b: "-vf",
            message: "-c:v copy 与 -vf 不能同时使用：copy 模式跳过解码，无法应用视频滤镜"
        ),
        (
            a: "-c:v",
            b: "-filter_complex",
            message: "-c:v copy 与 -filter_complex 不能同时使用：copy 模式跳过解码，无法应用滤镜"
        ),
        (
            a: "-an",
            b: "-c:a",
            message: "-an（禁用音频）与 -c:a 同时出现，-c:a 将被忽略"
        ),
        (
            a: "-an",
            b: "-b:a",
            message: "-an（禁用音频）与 -b:a 同时出现，-b:a 将被忽略"
        ),
        (
            a: "-vn",
            b: "-c:v",
            message: "-vn（禁用视频）与 -c:v 同时出现，-c:v 将被忽略"
        ),
        (
            a: "-vn",
            b: "-vf",
            message: "-vn（禁用视频）与 -vf 同时出现，-vf 将被忽略"
        ),
    ]
}

// MARK: - Parsed Command
//
// Parser 的职责：消费 Lexer 产出的 [Token]，建立 flag→value 的关联，
// 提取 inputPaths / outputPath / format 等高层语义，供诊断和补全使用。

struct ParsedCommand {
    let executable: CommandExecutable?
    let tokens: [Token]

    /// flag rawText → 对应的值
    let flagValues: [String: String]

    /// 输入路径列表（-i 的所有值）
    let inputPaths: [String]

    /// 输出路径（最后一个非 -i 值的 positional）
    let outputPath: String?

    /// -f 最后一次赋的值（lowercased）
    let lastExplicitFormat: String?

    /// 末尾 flag 还未取到值（命令不完整）
    let trailingFlagMissingValue: String?

    /// 所有出现过的 flag rawText 集合（含 streamSpecifier 形式）
    let presentFlags: Set<String>

    /// 便捷：某 flag 的值是否为 "copy"
    func isCopy(flag: String) -> Bool {
        flagValues[flag]?.lowercased() == "copy"
    }
}

// MARK: - Parser

private enum ParserState {
    case expectToken
    case expectValue(for: Token)    // 持有完整 Token 以保留 stream 信息
}

private struct CommandParser {

    /// 需要紧跟一个值的 flag 基础名（不含流限定符）
    static let baseFlagsRequiringValue: Set<String> = [
        "-i", "-vf", "-af", "-filter_complex", "-c", "-preset", "-crf",
        "-pix_fmt", "-movflags", "-map", "-ss", "-to", "-t", "-r",
        "-s", "-b", "-f", "-profile", "-level", "-tune", "-metadata",
        "-frames", "-vframes", "-aframes", "-aspect", "-vbsf", "-absf",
        "-threads", "-pass", "-passlogfile", "-filter", "-bufsize",
        "-maxrate", "-minrate"
    ]

    private static func requiresValue(_ token: Token) -> Bool {
        switch token {
        case .flag(let name):
            return baseFlagsRequiringValue.contains(name)
        case .streamSpecifier(let base, _):
            return baseFlagsRequiringValue.contains(base)
        default:
            return false
        }
    }

    static func parse(_ lexedTokens: [Token]) -> ParsedCommand {
        guard !lexedTokens.isEmpty else {
            return ParsedCommand(
                executable: nil, tokens: [], flagValues: [:],
                inputPaths: [], outputPath: nil, lastExplicitFormat: nil,
                trailingFlagMissingValue: nil, presentFlags: []
            )
        }

        let executable: CommandExecutable?
        if case .executable(let name) = lexedTokens[0] {
            executable = CommandExecutable.from(token: name)
        } else {
            executable = nil
        }

        var state: ParserState = .expectToken
        var flagValues:   [String: String] = [:]
        var inputPaths:   [String] = []
        var positionals:  [String] = []
        var lastFormat:   String?
        var trailingFlag: String?
        var presentFlags: Set<String> = []

        for token in lexedTokens.dropFirst() {
            switch state {
            case .expectValue(let flagToken):
                if case .word(let val) = token {
                    let key = flagToken.rawText
                    flagValues[key] = val
                    if key == "-i" { inputPaths.append(val) }
                    if key == "-f" { lastFormat = val.lowercased() }
                }
                state = .expectToken

            case .expectToken:
                switch token {
                case .informational:
                    presentFlags.insert(token.rawText)

                case .flag, .streamSpecifier:
                    presentFlags.insert(token.rawText)
                    if requiresValue(token) {
                        state = .expectValue(for: token)
                    }

                case .word(let val):
                    positionals.append(val)

                case .executable:
                    break
                }
            }
        }

        if case .expectValue(let flagToken) = state {
            trailingFlag = flagToken.rawText
        }

        let inputSet   = Set(inputPaths)
        let outputPath = positionals.last(where: { !inputSet.contains($0) })

        return ParsedCommand(
            executable: executable,
            tokens: lexedTokens,
            flagValues: flagValues,
            inputPaths: inputPaths,
            outputPath: outputPath,
            lastExplicitFormat: lastFormat,
            trailingFlagMissingValue: trailingFlag,
            presentFlags: presentFlags
        )
    }
}

// MARK: - Completion Context

enum CompletionContext {
    case executableName(partial: String)
    case flagName(partial: String)
    case flagValue(flag: String, stream: String?, partial: String)
    case unknown
}

private struct CompletionContextResolver {

    static func resolve(prefixTokens: [String], partial: String) -> CompletionContext {
        if prefixTokens.isEmpty {
            return .executableName(partial: partial)
        }

        if let lastRaw = prefixTokens.last {
            // 借用 Lexer 对最后一个 token 做类型识别（传入哑 executable 以满足 index==0 规则）
            let lastLexed = Lexer.lex(["_", lastRaw]).last

            switch lastLexed {
            case .flag(let name)
                where CommandParser.baseFlagsRequiringValue.contains(name):
                return .flagValue(flag: lastRaw, stream: nil, partial: partial)

            case .streamSpecifier(let base, let stream)
                where CommandParser.baseFlagsRequiringValue.contains(base):
                return .flagValue(flag: lastRaw, stream: stream, partial: partial)

            default:
                break
            }
        }

        if partial.hasPrefix("-") { return .flagName(partial: partial) }
        if partial.isEmpty        { return .flagName(partial: "") }

        return .unknown
    }
}

// MARK: - Main Assistant

struct CommandEditorAssistant {

    // MARK: Diagnostics

    static func diagnostics(for command: String) -> [CommandEditorDiagnostic] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

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

        let lexed  = Lexer.lex(rawArgs)
        let parsed = CommandParser.parse(lexed)

        var result: [CommandEditorDiagnostic] = []

        // 1. 末尾 flag 缺少值
        if let flag = parsed.trailingFlagMissingValue {
            result.append(.init(severity: .error, message: "参数 \(flag) 缺少取值"))
        }

        let isInfo = parsed.tokens.contains {
            if case .informational = $0 { return true }
            return false
        }

        // 2. 缺少输出目标
        if parsed.executable == .ffmpeg, !isInfo, parsed.outputPath == nil {
            result.append(.init(severity: .warning, message: "未检测到输出目标，执行时大概率会失败"))
        }

        // 3. 缺少输入源
        if parsed.executable == .ffmpeg, !isInfo,
           parsed.outputPath != nil, parsed.inputPaths.isEmpty {
            result.append(.init(severity: .warning, message: "未检测到输入源（-i）"))
        }

        // 4. 输出扩展名与 -f 不一致
        if let mismatch = outputFormatMismatch(parsed) {
            result.append(.init(severity: .warning, message: mismatch))
        }

        // 5. Conflict 诊断
        result.append(contentsOf: conflictDiagnostics(parsed))

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

        // 解析前缀以获取格式上下文（Knowledge Base 过滤用）
        let prefixLexed  = Lexer.lex(prefixTokens.isEmpty ? ["_"] : prefixTokens)
        let prefixParsed = CommandParser.parse(prefixLexed)
        let activeFormat = prefixParsed.lastExplicitFormat

        let context = CompletionContextResolver.resolve(
            prefixTokens: prefixTokens,
            partial: partial
        )

        switch context {
        case .executableName(let partial):
            return filter(CommandExecutable.allCases.map(\.binaryName), matching: partial)

        case .flagName(let partial):
            return filter(flagSuggestions, matching: partial)

        case .flagValue(let flag, let stream, let partial):
            let suggestions = valueSuggestions(flag: flag, stream: stream, format: activeFormat)
            return filter(suggestions, matching: partial)

        case .unknown:
            return []
        }
    }
}

// MARK: - Private: Diagnostic Helpers

private extension CommandEditorAssistant {

    static func outputFormatMismatch(_ parsed: ParsedCommand) -> String? {
        guard let output = parsed.outputPath,
              let format = parsed.lastExplicitFormat,
              let ext    = (output as NSString).pathExtension.lowercased().nonEmpty,
              format != ext else { return nil }
        return "输出格式 (-f \(format)) 与扩展名 (.\(ext)) 可能不一致"
    }

    static func conflictDiagnostics(_ parsed: ParsedCommand) -> [CommandEditorDiagnostic] {
        var result: [CommandEditorDiagnostic] = []

        for rule in KnowledgeBase.conflictRules {
            guard parsed.presentFlags.contains(rule.a),
                  parsed.presentFlags.contains(rule.b) else { continue }

            // -c:v 冲突只在值确实为 copy 时报告，避免 "-c:v libx264 -vf scale" 误报
            if rule.a == "-c:v" {
                guard parsed.isCopy(flag: "-c:v") else { continue }
            }

            result.append(.init(severity: .error, message: rule.message))
        }

        return result
    }
}

// MARK: - Private: Completion Helpers

private extension CommandEditorAssistant {

    static let flagSuggestions: [String] = [
        "-i", "-vf", "-af", "-filter_complex", "-c:v", "-c:a",
        "-preset", "-crf", "-pix_fmt", "-movflags", "-map",
        "-ss", "-to", "-t", "-r", "-s", "-b:v", "-b:a",
        "-an", "-vn", "-shortest", "-y", "-n", "-f",
        "-frames:v", "-threads", "-pass", "-passlogfile",
        "-aspect", "-bufsize", "-maxrate", "-minrate",
        "-profile:v", "-tune", "-level",
        "-version", "-buildconf", "-formats", "-codecs",
        "-encoders", "-decoders", "-filters", "-pix_fmts", "-help"
    ]

    /// 根据 flag 类型、流限定符、当前格式上下文返回建议列表。
    static func valueSuggestions(flag: String, stream: String?, format: String?) -> [String] {
        let baseName: String
        if let colon = flag.firstIndex(of: ":") {
            baseName = String(flag[..<colon])
        } else {
            baseName = flag
        }

        switch baseName {
        case "-c":
            // 核心：结合格式上下文 + 流类型，只返回兼容的编解码器
            return KnowledgeBase.codecs(format: format, stream: stream)
        case "-preset":
            return KnowledgeBase.genericPresets
        case "-pix_fmt":
            return KnowledgeBase.pixelFormats
        case "-f":
            return KnowledgeBase.containerFormats
        case "-movflags":
            return KnowledgeBase.movflagsValues
        case "-profile":
            return KnowledgeBase.profilesH264
        case "-tune":
            return KnowledgeBase.tuneValues
        case "-pass":
            return ["1", "2"]
        default:
            return []
        }
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

// MARK: - Extensions

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
