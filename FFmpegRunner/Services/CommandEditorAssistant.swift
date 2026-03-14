//
//  CommandEditorAssistant.swift
//  FFmpegRunner
//
//  自定义命令编辑辅助：Lexer + Knowledge Base + HW 探测集成 + Conflict 诊断
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
// 不做任何跨 token 关联，不做"这个值属于哪个 flag"的判断——那是 Parser 的事。

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

    /// flag 的原始字面量（含流限定符，若有）
    var rawText: String {
        switch self {
        case .executable(let s), .flag(let s), .informational(let s), .word(let s):
            return s
        case .streamSpecifier(let f, let s):
            return "\(f):\(s)"
        }
    }

    var isAnyFlag: Bool {
        switch self {
        case .flag, .streamSpecifier, .informational: return true
        default: return false
        }
    }
}

// MARK: - Lexer

/// 将原始 token 字符串数组转为 [Token]。
/// 输入来自 CommandRenderer.splitCommandStrict，每个元素已是完整 token。
private enum Lexer {

    private static let informationalFlags: Set<String> = [
        "-version", "-buildconf", "-formats", "-muxers", "-demuxers",
        "-codecs", "-encoders", "-decoders", "-filters", "-pix_fmts",
        "-sample_fmts", "-layouts", "-colors", "-hwaccels", "-protocols",
        "-bsfs", "-help", "-h", "-L"
    ]

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

            // 流限定符检测："-c:v", "-filter:a" 等
            if let colonIndex = raw.firstIndex(of: ":") {
                let specifier = String(raw[raw.index(after: colonIndex)...])
                let baseName  = String(raw[..<colonIndex])
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

/// 格式知识条目。
struct FormatProfile {
    let videoCodecs: [String]
    let audioCodecs: [String]
    let recommendedMovflags: [String]
}

/// 静态知识库：格式兼容性、编解码器、preset 等。
/// 硬件加速编解码器由 HardwareAccelerationProbe 在运行时动态注入到补全层，
/// 不直接修改此结构体，保持纯静态、无副作用。
struct KnowledgeBase {

    // MARK: Format Profiles

    static let formatProfiles: [String: FormatProfile] = [
        "mp4": FormatProfile(
            videoCodecs: ["libx264", "libx265", "copy"],
            audioCodecs: ["aac", "libopus", "copy"],
            recommendedMovflags: ["+faststart"]
        ),
        "mov": FormatProfile(
            videoCodecs: ["libx264", "libx265", "prores_ks", "copy"],
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

    // MARK: Fallback Codec Lists（无格式上下文时使用，不含 HW 加速器）

    static let baseVideoCodecs = [
        "libx264", "libx265", "libvpx-vp9", "av1", "prores_ks", "copy"
    ]

    static let baseAudioCodecs = [
        "aac", "libopus", "libvorbis", "pcm_s16le", "pcm_s24le", "flac", "copy"
    ]

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

    // MARK: Static Codec Lookup（不含 HW，供 HardwareAccelerationProbe 注入前使用）

    /// 纯静态查询，不感知硬件加速器。
    /// 补全层应通过 `CommandEditorAssistant.codecSuggestions(...)` 调用，
    /// 后者会自动合并 HW 探测结果。
    static func staticCodecs(format: String?, stream: String?) -> [String] {
        guard let format, let profile = formatProfiles[format] else {
            switch stream {
            case "v", "V": return baseVideoCodecs
            case "a":      return baseAudioCodecs
            default:       return baseVideoCodecs + baseAudioCodecs
            }
        }
        switch stream {
        case "v", "V": return profile.videoCodecs
        case "a":      return profile.audioCodecs
        default:       return profile.videoCodecs + profile.audioCodecs
        }
    }

    // MARK: Conflict Rules

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

struct ParsedCommand {
    let executable: CommandExecutable?
    let tokens: [Token]
    let flagValues: [String: String]
    let inputPaths: [String]
    let outputPath: String?
    let lastExplicitFormat: String?
    let trailingFlagMissingValue: String?
    let presentFlags: Set<String>

    func isCopy(flag: String) -> Bool {
        flagValues[flag]?.lowercased() == "copy"
    }
}

// MARK: - Parser

private enum ParserState {
    case expectToken
    case expectValue(for: Token)
}

private struct CommandParser {

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
        case .flag(let name):            return baseFlagsRequiringValue.contains(name)
        case .streamSpecifier(let b, _): return baseFlagsRequiringValue.contains(b)
        default:                         return false
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

        var state:        ParserState     = .expectToken
        var flagValues:   [String: String] = [:]
        var inputPaths:   [String]         = []
        var positionals:  [String]         = []
        var lastFormat:   String?
        var trailingFlag: String?
        var presentFlags: Set<String>      = []

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
                    if requiresValue(token) { state = .expectValue(for: token) }
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
        if prefixTokens.isEmpty { return .executableName(partial: partial) }

        if let lastRaw = prefixTokens.last {
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

        let isInfo = parsed.tokens.contains { if case .informational = $0 { return true }; return false }

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

    // MARK: Completions（同步，立即返回当前快照）

    /// 同步版本：立即返回当前内存中的补全列表。
    /// HardwareAccelerationProbe 在后台更新后，下一次调用自动获得最新数据。
    /// UI 层无需感知异步，不存在"等待探测完成才能补全"的卡顿。
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
            let suggestions = codecSuggestions(flag: flag, stream: stream, format: activeFormat)
            #if DEBUG
            print("[Completion] flag=\(flag) stream=\(stream ?? "nil") format=\(activeFormat ?? "nil") → \(suggestions.prefix(5))")
            #endif
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
            // -c:v 冲突只在值确实为 copy 时报告
            if rule.a == "-c:v" { guard parsed.isCopy(flag: "-c:v") else { continue } }
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

    /// 编解码器补全：静态知识库 + 运行时 HW 探测结果合并。
    ///
    /// HW 加速器插在列表**最前面**，因为在有硬件的机器上它们是最优选择。
    /// 若探测尚未完成（videoCodecNames 为空），静默退化到纯静态列表。
    static func codecSuggestions(flag: String, stream: String?, format: String?) -> [String] {
        let baseName: String = {
            if let colon = flag.firstIndex(of: ":") { return String(flag[..<colon]) }
            return flag
        }()

        switch baseName {
        case "-c":
            // 静态基础列表
            var base = KnowledgeBase.staticCodecs(format: format, stream: stream)

            // 从最近一次成功探测的缓存中同步读取快照，避免在补全同步 API 中跨 actor 访问。
            let hwNames = HardwareAccelerationProbe.cachedVideoCodecNames()

            // 按流类型过滤 HW 编解码器，再与格式过滤合并
            let relevantHW: [String]
            switch stream {
            case "a":
                // 目前无音频 HW 加速器，直接跳过
                relevantHW = []
            default:
                // 视频或未指定流：注入视频 HW 加速器
                if let format, let profile = KnowledgeBase.formatProfiles[format] {
                    // 有格式上下文：只保留该格式静态列表中存在的 HW 编解码器
                    // （即知识库明确声明该格式支持的 HW 编解码器）
                    // 同时接受探测到但知识库中尚未登记的新编解码器（向前兼容）
                    let profileSet = Set(profile.videoCodecs)
                    relevantHW = hwNames.filter { hw in
                        profileSet.contains(hw) || !KnowledgeBase.formatProfiles.values
                            .flatMap(\.videoCodecs).contains(hw)
                    }
                } else {
                    relevantHW = hwNames
                }
            }

            // HW 加速器去重后插到最前面
            let baseSet = Set(base)
            let newHW   = relevantHW.filter { !baseSet.contains($0) }
            base.insert(contentsOf: newHW, at: 0)
            return base

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
