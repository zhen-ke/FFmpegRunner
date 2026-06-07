//
//  CommandPathDetector.swift
//  FFmpegRunner
//

import Foundation

enum CommandPathDetector {
    private static let exactSpecialOutputs: Set<String> = [
        "-",
        "null",
        "nullsink",
        "/dev/null"
    ]

    private static let specialOutputPrefixes: [String] = [
        "pipe:",
        "fd:",
        "md5:"
    ]

    static func detectOutputURL(from arguments: [String]) -> URL? {
        guard let rawPath = extractLastPositionalArg(from: arguments) else { return nil }
        guard isFileSystemPath(rawPath) else { return nil }

        let expandedPath = (rawPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }

    static func detectOutputPath(from arguments: [String]) -> String? {
        detectOutputURL(from: arguments)?.displayPath
    }

    static func detectOutputDirectory(from arguments: [String]) -> URL? {
        detectOutputURL(from: arguments)?.deletingLastPathComponent()
    }

    static func detectOutputDirectoryPath(from arguments: [String]) -> String? {
        detectOutputDirectory(from: arguments)?.displayPath
    }

    static func detectOutputFileName(from arguments: [String]) -> String? {
        detectOutputURL(from: arguments)?.lastPathComponent
    }

    static func detectInputURL(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "-i"),
              index + 1 < arguments.count else {
            return nil
        }
        let rawPath = arguments[index + 1]
        guard isFileSystemPath(rawPath) else { return nil }
        
        let expandedPath = (rawPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }

    static func detectInputFileName(from arguments: [String]) -> String? {
        detectInputURL(from: arguments)?.lastPathComponent
    }

    private static func extractLastPositionalArg(from arguments: [String]) -> String? {
        arguments
            .filter { !$0.isEmpty }
            .last { !$0.hasPrefix("-") }
    }

    private static func isFileSystemPath(_ value: String) -> Bool {
        guard value.hasPrefix("/") || value.hasPrefix("~") else { return false }
        return !isSpecialOutput(value)
    }

    private static func isSpecialOutput(_ value: String) -> Bool {
        let normalized = value.lowercased()

        if exactSpecialOutputs.contains(normalized) {
            return true
        }

        if specialOutputPrefixes.contains(where: normalized.hasPrefix) {
            return true
        }

        return normalized.range(
            of: #"^[a-z][a-z0-9+.\-]*://"#,
            options: .regularExpression
        ) != nil
    }
}

private extension URL {
    var displayPath: String {
        (path(percentEncoded: false) as NSString).standardizingPath
    }
}

extension RenderedCommand {
    var outputURL: URL? {
        CommandPathDetector.detectOutputURL(from: arguments)
    }

    var outputPath: String? {
        outputURL?.displayPath
    }

    var outputFileName: String? {
        outputURL?.lastPathComponent
    }
}

extension ExecutionPlan {
    var outputURL: URL? {
        CommandPathDetector.detectOutputURL(from: arguments)
    }

    var outputPath: String? {
        outputURL?.displayPath
    }

    var outputDirectoryURL: URL? {
        outputURL?.deletingLastPathComponent()
    }

    var outputDirectoryPath: String? {
        outputDirectoryURL?.displayPath
    }
}
