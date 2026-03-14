//
//  HardwareAccelerationProbe.swift
//  FFmpegRunner
//
//  运行时探测本机可用的硬件加速编解码器。
//
//  设计原则
//  ─────────
//  • 只探测"因硬件而异"的编解码器（VideoToolbox / NVENC / VAAPI 等），
//    通用软件编解码器由 KnowledgeBase 静态内置，不需要动态拉取。
//  • 首次探测结果写入 UserDefaults，后续启动直接读缓存，零延迟。
//  • 用 actor 做隔离，补全线程可安全地直接 await 读取，无需手动加锁。
//  • Process 通过 terminationHandler 驱动，不阻塞任何线程。
//

import Foundation

// MARK: - Hardware Codec Descriptor

/// 一个硬件加速编解码器条目。
struct HardwareCodec: Codable, Equatable {
    /// ffmpeg 内部名称，如 "h264_videotoolbox"
    let name: String
    /// 流类型：视频 or 音频（目前所有 HW 加速器均为视频）
    let stream: CodecStream

    enum CodecStream: String, Codable {
        case video
        case audio
    }
}

// MARK: - Probe Error

enum ProbeError: Error, LocalizedError {
    case executableNotFound(URL)
    case processFailed(terminationStatus: Int32)
    case outputDecodingFailed

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let url):
            return "找不到可执行文件：\(url.path)"
        case .processFailed(let code):
            return "ffmpeg 进程退出码：\(code)"
        case .outputDecodingFailed:
            return "无法解码 ffmpeg 输出"
        }
    }
}

// MARK: - Hardware Acceleration Probe

/// 探测本机 ffmpeg 支持的硬件加速编解码器。
///
/// 使用方式（App 启动时调用一次）：
/// ```swift
/// .task {
///     if let url = CommandExecutable.ffmpeg.resolvedURL {
///         await HardwareAccelerationProbe.shared.probeIfNeeded(executableURL: url)
///     }
/// }
/// ```
actor HardwareAccelerationProbe {

    static let shared = HardwareAccelerationProbe()

    // MARK: State

    /// 探测到的硬件加速编解码器，按流类型分组。
    /// 在探测完成前为空集合；补全层调用时若为空则退化到静态列表。
    private(set) var videoCodecs: [HardwareCodec] = []
    private(set) var audioCodecs: [HardwareCodec] = []

    /// 探测状态
    private(set) var state: ProbeState = .idle

    enum ProbeState: Equatable {
        case idle
        case running
        case succeeded(Date)
        case failed(String)
    }

    // MARK: UserDefaults Keys

    enum CacheKey {
        static let codecs    = "FFmpegRunner.hwCodecs.v1"
        static let probedAt  = "FFmpegRunner.hwCodecs.probedAt.v1"
        /// 缓存有效期：7 天（硬件不会经常变）
        static let ttl: TimeInterval = 7 * 24 * 3600
    }

    // MARK: - Public API

    /// 探测入口。若缓存有效则直接恢复，否则后台运行 ffmpeg。
    /// 幂等：多次调用只会触发一次实际探测。
    func probeIfNeeded(executableURL: URL) async {
        guard state == .idle else { return }

        // 优先从缓存恢复
        if restoreFromCache() {
            state = .succeeded(Date())
            return
        }

        state = .running
        do {
            try await runProbe(executableURL: executableURL)
            persistToCache()
            state = .succeeded(Date())
        } catch {
            state = .failed(error.localizedDescription)
            // 失败静默降级：补全层检测到 videoCodecs 为空时自动使用静态列表
        }
    }

    /// 强制重新探测（用于用户手动刷新场景）。
    func forceProbe(executableURL: URL) async {
        state = .idle
        clearCache()
        await probeIfNeeded(executableURL: executableURL)
    }

    /// 视频硬件加速编解码器名称列表（已排序）。
    var videoCodecNames: [String] {
        videoCodecs.map(\.name).sorted()
    }

    /// 同步快照读取，供补全层在非 async 上下文中使用。
    /// 数据来源于最近一次成功探测写入的缓存；若暂无缓存则返回空数组。
    static func cachedVideoCodecNames() -> [String] {
        guard
            let data = UserDefaults.standard.data(forKey: CacheKey.codecs),
            let cached = try? JSONDecoder().decode([HardwareCodec].self, from: data)
        else { return [] }

        return cached
            .filter { $0.stream == .video }
            .map(\.name)
            .sorted()
    }

    // MARK: - Probe Implementation

    private func runProbe(executableURL: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProbeError.executableNotFound(executableURL)
        }

        let output = try await execute(
            executableURL: executableURL,
            // -hide_banner 抑制版本头，-encoders 列出所有编码器
            arguments: ["-hide_banner", "-encoders"]
        )

        let found = parseEncoders(output)
        videoCodecs = found.filter { $0.stream == .video }
        audioCodecs = found.filter { $0.stream == .audio }
    }

    // MARK: - Parser

    /// 解析 `ffmpeg -encoders` 输出，提取硬件加速编解码器。
    ///
    /// 输出格式（固定列宽，不依赖 split）：
    /// ```
    ///  V..... libx264          H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10
    ///  V....D h264_videotoolbox VideoToolbox H.264 Encoder
    /// ```
    /// 第 0 列（offset 1）：流类型字符 V/A/S/D/T
    /// 第 1 列（offset 2-7）：能力标记
    /// 名称列（offset 8 起）：编解码器名，直到第一个空白字符
    func parseEncoders(_ output: String) -> [HardwareCodec] {
        /// 只关心这些关键词，其他编解码器由静态知识库覆盖
        let hwKeywords = ["videotoolbox", "nvenc", "vaapi", "qsv", "amf", "cuda", "vt_"]

        var result: [HardwareCodec] = []

        for line in output.components(separatedBy: .newlines) {
            // 最短合法行：" V..... name"，至少 10 个字符
            guard line.count >= 10 else { continue }

            // 流类型在固定偏移 1
            let typeIndex = line.index(line.startIndex, offsetBy: 1)
            let streamChar = line[typeIndex]

            let stream: HardwareCodec.CodecStream
            switch streamChar {
            case "V": stream = .video
            case "A": stream = .audio
            default:  continue   // 跳过字幕、数据等类型
            }

            // 编解码器名从偏移 8 开始，到第一个空白字符结束
            let nameStartOffset = 8
            guard line.count > nameStartOffset else { continue }
            let nameStart = line.index(line.startIndex, offsetBy: nameStartOffset)
            let name = String(line[nameStart...].prefix(while: { !$0.isWhitespace }))

            guard !name.isEmpty,
                  hwKeywords.contains(where: { name.contains($0) }) else { continue }

            result.append(HardwareCodec(name: name, stream: stream))
        }

        return result
    }

    // MARK: - Process Execution

    /// 异步执行子进程，通过 terminationHandler 驱动，不阻塞任何线程。
    private func execute(executableURL: URL, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe   // 静默丢弃 stderr

            // terminationHandler 在进程退出后由系统回调，不占用线程
            process.terminationHandler = { finished in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

                if finished.terminationStatus == 0 || !data.isEmpty {
                    // ffmpeg -encoders 退出码为 1 但仍有有效输出，需容错
                    if let string = String(data: data, encoding: .utf8) {
                        continuation.resume(returning: string)
                    } else {
                        continuation.resume(throwing: ProbeError.outputDecodingFailed)
                    }
                } else {
                    continuation.resume(
                        throwing: ProbeError.processFailed(
                            terminationStatus: finished.terminationStatus
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Cache

    func restoreFromCache() -> Bool {
        guard
            let probedAt = UserDefaults.standard.object(forKey: CacheKey.probedAt) as? Date,
            Date().timeIntervalSince(probedAt) < CacheKey.ttl,
            let data = UserDefaults.standard.data(forKey: CacheKey.codecs),
            let cached = try? JSONDecoder().decode([HardwareCodec].self, from: data)
        else { return false }

        videoCodecs = cached.filter { $0.stream == .video }
        audioCodecs = cached.filter { $0.stream == .audio }
        return true
    }

    func persistToCache() {
        let all = videoCodecs + audioCodecs
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: CacheKey.codecs)
        UserDefaults.standard.set(Date(), forKey: CacheKey.probedAt)
    }

    private func clearCache() {
        UserDefaults.standard.removeObject(forKey: CacheKey.codecs)
        UserDefaults.standard.removeObject(forKey: CacheKey.probedAt)
    }
}
