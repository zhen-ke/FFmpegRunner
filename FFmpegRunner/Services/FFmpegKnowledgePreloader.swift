//
//  FFmpegKnowledgePreloader.swift
//  FFmpegRunner
//
//  App 启动时的硬件探测接入点。
//
//  接入方式（在 App 结构体或根 View 中调用）：
//
//      @main
//      struct FFmpegRunnerApp: App {
//          var body: some Scene {
//              WindowGroup {
//                  ContentView()
//                      .task { await FFmpegKnowledgePreloader.preload() }
//              }
//          }
//      }
//
//  设计说明
//  ─────────
//  • preload() 是幂等的：多次调用只会触发一次实际探测。
//  • 探测在后台进行，不阻塞 UI 启动。
//  • 探测结果缓存 7 天，二次启动瞬间恢复，不会重新运行 ffmpeg。
//  • 探测失败静默降级：KnowledgeBase 的硬编码数据始终作为兜底。
//

import Foundation

enum FFmpegKnowledgePreloader {

    /// 在 App 启动的 .task 修饰符中调用此方法。
    static func preload() async {
        guard let executableURL = resolveFFmpegURL() else {
            // 找不到 ffmpeg：静默跳过，依赖静态知识库
            return
        }

        await HardwareAccelerationProbe.shared.probeIfNeeded(executableURL: executableURL)

        #if DEBUG
        let probe = HardwareAccelerationProbe.shared
        switch await probe.state {
        case .succeeded(let date):
            let names = await probe.videoCodecNames
            print("[HWProbe] ✅ 探测成功（\(date.formatted())），视频 HW 加速器：\(names)")
        case .failed(let reason):
            print("[HWProbe] ⚠️ 探测失败，将使用静态列表。原因：\(reason)")
        default:
            break
        }
        #endif
    }

    // MARK: - ffmpeg 路径解析

    /// 按优先级查找 ffmpeg 可执行文件：
    /// 1. 项目已有的路径解析层（最优先，遵从用户设置）
    /// 2. PATH 环境变量
    /// 3. 常见安装路径
    private static func resolveFFmpegURL() -> URL? {
        let resolver = FFmpegPathResolver()

        // 1. 项目已有的路径解析机制
        if let resolvedPath = resolveConfiguredFFmpegPath(using: resolver),
           FileManager.default.isExecutableFile(atPath: resolvedPath) {
            return URL(fileURLWithPath: resolvedPath)
        }

        // 2. PATH 中查找
        if let pathFromEnvironment = findInPATH("ffmpeg") {
            return pathFromEnvironment
        }

        // 3. 常见安装路径兜底
        let fallbackPaths = [
            "/opt/homebrew/bin/ffmpeg",   // Apple Silicon Homebrew
            "/usr/local/bin/ffmpeg",       // Intel Homebrew / 手动安装
            "/usr/bin/ffmpeg",             // 系统级
        ]

        return fallbackPaths
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func resolveConfiguredFFmpegPath(using resolver: FFmpegPathResolver) -> String? {
        switch UserSettings.shared.ffmpegSource {
        case .bundled:
            return resolver.bundledPath
        case .custom:
            let path = UserSettings.shared.customFFmpegPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        case .system:
            return nil
        }
    }

    private static func findInPATH(_ name: String) -> URL? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        return pathEnv.components(separatedBy: ":")
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
