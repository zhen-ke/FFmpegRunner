//
//  HardwareAccelerationIntegrationTests.swift
//  FFmpegRunnerIntegrationTests
//
//  集成测试：依赖真实环境中的 ffmpeg 二进制文件。
//  本 target 在 CI 环境下默认跳过，仅供本地手动触发。
//

import XCTest
@testable import FFmpegRunner

final class HardwareAccelerationIntegrationTests: XCTestCase {

    /// 验证真实 ffmpeg 路径可达、解析结果合理
    func testRealProbe_onMachineWithFFmpeg() async throws {
        // 找不到 ffmpeg 就跳过
        guard let url = findFFmpeg() else {
            throw XCTSkip("本机未安装 ffmpeg，跳过集成测试")
        }

        let probe = HardwareAccelerationProbe.shared
        await probe.forceProbe(executableURL: url)

        let names = await probe.videoCodecNames

        // Apple Silicon Mac 上 videotoolbox 必须存在
        #if arch(arm64)
        XCTAssertTrue(names.contains("h264_videotoolbox") || names.contains("hevc_videotoolbox"),
                      "Apple Silicon 应支持 videotoolbox，实际得到：\(names)")
        #endif

        // 探测到的编解码器名不应包含空格（说明列偏移解析正确）
        XCTAssertTrue(names.allSatisfy { !$0.contains(" ") },
                      "编解码器名包含空格，列偏移解析可能有误：\(names)")
    }

    /// 验证 FFmpegService 能够获取真实版本号
    func testFFmpegServiceVersionCaching_Integration() async throws {
        let service = FFmpegService.shared

        if !service.isFFmpegAvailable() {
            throw XCTSkip("FFmpeg not available, skipping integration test")
        }

        let v1 = try await service.getFFmpegVersion()
        XCTAssertFalse(v1.isEmpty)

        let v2 = try await service.getFFmpegVersion()
        XCTAssertEqual(v1, v2, "Version caching should work")
    }

    private func findFFmpeg() -> URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
