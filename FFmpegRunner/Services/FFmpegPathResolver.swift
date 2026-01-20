//
//  FFmpegPathResolver.swift
//  FFmpegRunner
//
//  FFmpeg 路径解析器
//

import Foundation

// MARK: - Protocol

/// FFmpeg 路径提供者协议
/// 用于解析和定位 FFmpeg 可执行文件
protocol FFmpegPathProviding {
    /// 内置 FFmpeg 路径（在 App Bundle 中）
    var bundledPath: String? { get }

    /// 系统安装的 FFmpeg 路径
    var systemPath: String? { get }

    /// 根据来源解析 FFmpeg 路径
    /// - Parameters:
    ///   - source: FFmpeg 来源类型
    ///   - customPath: 自定义路径（仅当 source 为 .custom 时使用）
    /// - Returns: 解析后的路径，如果无法解析则返回 nil
    func resolvePath(for source: FFmpegSource, customPath: String?) -> String?

    /// 检查路径是否为可执行文件
    func isExecutable(at path: String) -> Bool
}

// MARK: - Default Implementation

/// FFmpeg 路径解析器
/// 负责定位内置、系统或自定义 FFmpeg 可执行文件
final class FFmpegPathResolver: FFmpegPathProviding {

    // MARK: - Properties

    /// 搜索系统 FFmpeg 的路径列表
    private let systemSearchPaths = [
        "/opt/homebrew/bin/ffmpeg",      // Apple Silicon Homebrew
        "/usr/local/bin/ffmpeg",          // Intel Homebrew
        "/usr/bin/ffmpeg",                // System
        "/opt/local/bin/ffmpeg"           // MacPorts
    ]

    // MARK: - FFmpegPathProviding

    var bundledPath: String? {
        // 首先检查 Resources/ffmpeg
        if let path = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            return path
        }

        // 检查 Resources/bin/ffmpeg
        if let path = Bundle.main.path(forResource: "ffmpeg", ofType: nil, inDirectory: "bin") {
            return path
        }

        // 检查 Frameworks 目录
        if let frameworksPath = Bundle.main.privateFrameworksPath {
            let ffmpegPath = (frameworksPath as NSString).appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: ffmpegPath) {
                return ffmpegPath
            }
        }

        // 检查 MacOS 目录
        if let executablePath = Bundle.main.executablePath {
            let dir = (executablePath as NSString).deletingLastPathComponent
            let ffmpegPath = (dir as NSString).appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: ffmpegPath) {
                return ffmpegPath
            }
        }

        return nil
    }

    var systemPath: String? {
        // 首先检查常见路径
        for path in systemSearchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 尝试 which 命令
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["ffmpeg"]

        let pipe = Pipe()
        whichProcess.standardOutput = pipe

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {
            print("Failed to run which: \(error)")
        }

        return nil
    }

    func resolvePath(for source: FFmpegSource, customPath: String?) -> String? {
        switch source {
        case .bundled:
            return bundledPath
        case .system:
            return systemPath
        case .custom:
            return customPath
        }
    }

    func isExecutable(at path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
