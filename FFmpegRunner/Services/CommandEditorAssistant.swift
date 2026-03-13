//
//  CommandEditorAssistant.swift
//  FFmpegRunner
//
//  自定义命令编辑辅助：基础诊断与常用补全
//

import Foundation

struct CommandEditorDiagnostic: Equatable, Identifiable {
    enum Severity: Equatable {
        case error
        case warning

        var symbolName: String {
            switch self {
            case .error:
                return "xmark.octagon.fill"
            case .warning:
                return "exclamationmark.triangle.fill"
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

struct CommandEditorAssistant {
    private static let executableNames = CommandExecutable.allCases.map(\.binaryName)

    private static let flagSuggestions = [
        "-i", "-vf", "-af", "-filter_complex", "-c:v", "-c:a",
        "-preset", "-crf", "-pix_fmt", "-movflags", "-map",
        "-ss", "-to", "-t", "-r", "-s", "-b:v", "-b:a",
        "-an", "-vn", "-shortest", "-y", "-n", "-f"
    ]

    private static let flagsRequiringValue: Set<String> = [
        "-i", "-vf", "-af", "-filter_complex", "-c", "-c:v", "-c:a",
        "-preset", "-crf", "-pix_fmt", "-movflags", "-map", "-ss",
        "-to", "-t", "-r", "-s", "-b:v", "-b:a", "-f", "-profile:v",
        "-profile:a", "-level", "-tune", "-metadata"
    ]

    private static let informationalFlags: Set<String> = [
        "-version", "-buildconf", "-formats", "-muxers", "-demuxers",
        "-codecs", "-encoders", "-decoders", "-filters", "-pix_fmts",
        "-sample_fmts", "-layouts", "-colors", "-hwaccels", "-protocols",
        "-bsfs", "-help", "-h", "-L"
    ]

    private static let codecSuggestions = [
        "libx264", "libx265", "h264_videotoolbox", "hevc_videotoolbox",
        "copy", "aac", "libopus", "pcm_s16le"
    ]

    private static let presetSuggestions = [
        "ultrafast", "superfast", "veryfast", "faster",
        "fast", "medium", "slow", "slower", "veryslow"
    ]

    private static let pixelFormatSuggestions = [
        "yuv420p", "yuv422p", "yuv444p", "nv12", "p010le"
    ]

    private static let formatSuggestions = [
        "mp4", "mov", "matroska", "mpegts", "image2", "gif", "null"
    ]

    private static let movflagsSuggestions = [
        "+faststart", "+frag_keyframe", "+empty_moov"
    ]

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

        guard let args = try? CommandRenderer.splitCommandStrict(trimmed),
              let executable = args.first.flatMap(CommandExecutable.from(token:)) else {
            return []
        }

        var diagnostics: [CommandEditorDiagnostic] = []
        diagnostics.append(contentsOf: missingValueDiagnostics(in: args))

        if executable == .ffmpeg,
           !isInformationalCommand(args),
           !hasOutputTarget(in: args) {
            diagnostics.append(
                CommandEditorDiagnostic(
                    severity: .warning,
                    message: "未检测到输出目标，执行时大概率会失败"
                )
            )
        }

        if let mismatch = outputFormatMismatch(in: args) {
            diagnostics.append(CommandEditorDiagnostic(severity: .warning, message: mismatch))
        }

        if diagnostics.count > 3 {
            return Array(diagnostics.prefix(3))
        }

        return diagnostics
    }

    static func completions(
        for command: String,
        selectedRange: NSRange,
        partialRange: NSRange
    ) -> [String] {
        let cursor = selectedRange.location == NSNotFound ? command.utf16.count : selectedRange.location
        let partial = utf16Substring(in: command, range: partialRange)
        let prefixText = utf16Substring(
            in: command,
            range: NSRange(location: 0, length: max(0, partialRange.location))
        )

        let prefixTokens = (try? CommandRenderer.splitCommandStrict(prefixText)) ?? []
        let currentToken = partial.isEmpty ? tokenBeforeCursor(in: command, cursor: cursor) : partial

        if prefixTokens.isEmpty && (partialRange.location == 0 || !currentToken.hasPrefix("-")) {
            return filter(executableNames, matching: partial)
        }

        if let previousToken = prefixTokens.last,
           let contextual = contextualValueSuggestions(for: previousToken) {
            return filter(contextual, matching: partial)
        }

        if partial.isEmpty, isAtTokenBoundary(in: command, cursor: cursor) {
            return flagSuggestions
        }

        if partial.hasPrefix("-") {
            return filter(flagSuggestions, matching: partial)
        }

        return []
    }
}

private extension CommandEditorAssistant {
    static func missingValueDiagnostics(in args: [String]) -> [CommandEditorDiagnostic] {
        var diagnostics: [CommandEditorDiagnostic] = []

        for (index, token) in args.enumerated() {
            guard flagsRequiringValue.contains(token) else { continue }
            let nextIndex = index + 1
            if nextIndex >= args.count {
                diagnostics.append(
                    CommandEditorDiagnostic(
                        severity: .error,
                        message: "参数 \(token) 缺少取值"
                    )
                )
            }
        }

        return diagnostics
    }

    static func contextualValueSuggestions(for flag: String) -> [String]? {
        switch flag {
        case "-c", "-c:v", "-c:a":
            return codecSuggestions
        case "-preset":
            return presetSuggestions
        case "-pix_fmt":
            return pixelFormatSuggestions
        case "-f":
            return formatSuggestions
        case "-movflags":
            return movflagsSuggestions
        default:
            return nil
        }
    }

    static func isInformationalCommand(_ args: [String]) -> Bool {
        args.contains(where: informationalFlags.contains)
    }

    static func hasOutputTarget(in args: [String]) -> Bool {
        findOutputPath(in: args) != nil
    }

    static func outputFormatMismatch(in args: [String]) -> String? {
        guard let output = findOutputPath(in: args),
              let format = findLastFormat(in: args),
              let ext = output.pathExtensionLowercased,
              !ext.isEmpty,
              format != ext else {
            return nil
        }

        return "输出格式 (-f \(format)) 与扩展名 (.\(ext)) 可能不一致"
    }

    static func findOutputPath(in args: [String]) -> String? {
        var index = 1
        var lastPositional: String?

        while index < args.count {
            let token = args[index]
            if flagsRequiringValue.contains(token) {
                index += 2
                continue
            }

            if token.hasPrefix("-") {
                index += 1
                continue
            }

            lastPositional = token
            index += 1
        }

        return lastPositional
    }

    static func findLastFormat(in args: [String]) -> String? {
        var format: String?
        for index in args.indices where args[index] == "-f" {
            let nextIndex = index + 1
            if nextIndex < args.count {
                format = args[nextIndex].lowercased()
            }
        }
        return format
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

    static func isAtTokenBoundary(in text: String, cursor: Int) -> Bool {
        guard cursor > 0 else { return true }
        let nsText = text as NSString
        let previous = nsText.character(at: min(cursor - 1, nsText.length - 1))
        return CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(previous) ?? " ")
    }

    static func tokenBeforeCursor(in text: String, cursor: Int) -> String {
        guard !text.isEmpty else { return "" }
        let nsText = text as NSString
        let clampedCursor = min(max(cursor, 0), nsText.length)
        var start = clampedCursor
        while start > 0 {
            let candidate = nsText.character(at: start - 1)
            guard let scalar = UnicodeScalar(candidate),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) else {
                break
            }
            start -= 1
        }

        let range = NSRange(location: start, length: clampedCursor - start)
        return nsText.substring(with: range)
    }
}

private extension String {
    var pathExtensionLowercased: String? {
        let ext = (self as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}
