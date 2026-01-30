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
protocol FFmpegPathProviding: Sendable {
    /// 内置 FFmpeg 路径（在 App Bundle 中）
    /// - Note: 同步属性，仅查找 Bundle，无 I/O 操作
    var bundledPath: String? { get }

    /// 系统安装的 FFmpeg 路径
    /// - Note: 异步属性，可能执行 `which` 子进程
    var systemPath: String? { get async }

    /// 根据来源解析 FFmpeg 路径
    /// - Parameters:
    ///   - source: FFmpeg 来源类型
    ///   - customPath: 自定义路径（仅当 source 为 .custom 时使用）
    /// - Returns: 解析后的路径，如果无法解析则返回 nil
    func resolvePath(for source: FFmpegSource, customPath: String?) async -> String?

    /// 检查路径是否为可执行文件
    func isExecutable(at path: String) -> Bool

    /// 使缓存失效，强制下次访问时重新扫描
    func invalidateCache() async
}

// MARK: - Default Implementation

/// FFmpeg 路径解析器
/// 负责定位内置、系统或自定义 FFmpeg 可执行文件
/// - Note: 使用 Actor 保证线程安全，systemPath 使用异步方式避免阻塞主线程
actor FFmpegPathResolver: FFmpegPathProviding {

    // MARK: - Cache Entry

    /// 缓存条目，包含路径和时间戳
    private struct CacheEntry {
        let path: String?
        let timestamp: Date

        /// 缓存是否已过期（5分钟 TTL）
        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > 300
        }
    }

    // MARK: - Properties

    /// 搜索系统 FFmpeg 的路径列表
    private let systemSearchPaths = [
        "/opt/homebrew/bin/ffmpeg",      // Apple Silicon Homebrew
        "/usr/local/bin/ffmpeg",          // Intel Homebrew
        "/usr/bin/ffmpeg",                // System
        "/opt/local/bin/ffmpeg"           // MacPorts
    ]

    /// 缓存的系统路径
    private var systemCache: CacheEntry?

    // MARK: - FFmpegPathProviding

    /// 内置 FFmpeg 路径
    /// - Note: 使用 nonisolated 因为只访问 Bundle，无共享状态
    nonisolated var bundledPath: String? {
        // 首先检查 Resources/ffmpeg
        if let path = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            return path
        }

        // 检查 Resources/bin/ffmpeg
        if let path = Bundle.main.path(forResource: "ffmpeg", ofType: nil, inDirectory: "bin") {
            return path
        }

        // 检查 Frameworks 目录
        if let frameworksURL = Bundle.main.privateFrameworksURL {
            let ffmpegURL = frameworksURL.appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: ffmpegURL.path) {
                return ffmpegURL.path
            }
        }

        // 检查 MacOS 目录
        if let executableURL = Bundle.main.executableURL {
            let ffmpegURL = executableURL.deletingLastPathComponent().appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: ffmpegURL.path) {
                return ffmpegURL.path
            }
        }

        return nil
    }

    /// 系统 FFmpeg 路径（异步，带缓存）
    var systemPath: String? {
        get async {
            // 1. 检查缓存是否有效
            if let cache = systemCache, !cache.isExpired {
                // 惰性验证：确认文件仍然存在
                if let path = cache.path,
                   FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
                // 缓存的路径不再有效，继续重新扫描
            }

            // 2. 重新扫描系统路径
            let path = await performSystemSearch()
            systemCache = CacheEntry(path: path, timestamp: Date())
            return path
        }
    }

    func resolvePath(for source: FFmpegSource, customPath: String?) async -> String? {
        switch source {
        case .bundled:
            return bundledPath
        case .system:
            return await systemPath
        case .custom:
            return customPath
        }
    }

    nonisolated func isExecutable(at path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func invalidateCache() {
        systemCache = nil
    }

    // MARK: - Private Methods

    /// 执行系统路径搜索
    private func performSystemSearch() async -> String? {
        // 首先检查常见路径（快速路径，无需子进程）
        for path in systemSearchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 尝试 which 命令（异步执行）
        return await runWhichCommand()
    }

    /// 异步执行 which 命令
    /// - Note: 使用 terminationHandler 避免阻塞，支持任务取消
    private func runWhichCommand() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let path = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: path?.isEmpty == false ? path : nil)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
