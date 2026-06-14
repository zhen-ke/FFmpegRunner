//
//  MediaDurationResolver.swift
//  FFmpegRunner
//
//  媒体时长读取服务
//

import AVFoundation
import Foundation

typealias MediaDurationResolving = @Sendable (URL) async -> TimeInterval?

enum MediaDurationResolver {
    static func resolveDuration(for url: URL) async -> TimeInterval? {
        if let duration = await resolveWithAVFoundation(url) {
            return duration
        }

        return await resolveWithFFprobe(url)
    }

    static func parseFFprobeDurationOutput(_ output: String) -> TimeInterval? {
        output
            .split(whereSeparator: \.isNewline)
            .lazy
            .compactMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first { $0.isFinite && $0 > 0 }
    }

    private static func resolveWithAVFoundation(_ url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            return nil
        }
    }

    private static func resolveWithFFprobe(_ url: URL) async -> TimeInterval? {
        guard let ffprobePath = ffprobePath() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return parseFFprobeDurationOutput(output)
    }

    private static func ffprobePath() -> String? {
        let fileManager = FileManager.default
        let configuredPath = UserSettings.shared.ffprobePath
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !configuredPath.isEmpty,
           fileManager.isExecutableFile(atPath: configuredPath) {
            return configuredPath
        }

        let fallbackPaths = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe",
            "/opt/local/bin/ffprobe"
        ]

        return fallbackPaths.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
