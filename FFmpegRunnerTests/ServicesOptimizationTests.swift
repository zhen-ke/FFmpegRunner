//
//  ServicesOptimizationTests.swift
//  FFmpegRunnerTests
//
//  Created for verification of Service Layer optimizations.
//

import XCTest
@testable import FFmpegRunner

final class ServicesOptimizationTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        HistoryService.shared.clearHistory()
    }

    // MARK: - HistoryService Caching Tests

    func testHistoryServiceCaching() throws {
        let historyService = HistoryService.shared
        historyService.clearHistory()

        // 1. Initial State: Empty
        XCTAssertTrue(historyService.loadHistory().isEmpty)

        // 2. Add Entry
        let entry = CommandHistory(command: "ffmpeg -version", executedAt: Date(), wasSuccessful: true)
        historyService.addEntry(entry)

        // 3. Verify it's in memory (immediate load)
        let loaded = historyService.loadHistory()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.command, "ffmpeg -version")

        // 4. Verify persistence (simulated by checking if file exists, though we trust the service implementation)
        // Ideally we would inspect the private cache property via Mirror, but functional test is better.
        // We can verify that calling loadHistory() again doesn't crash or fail.
        let loadedAgain = historyService.loadHistory()
        XCTAssertEqual(loadedAgain.count, 1)
    }

    // MARK: - HardwareAccelerationProbe Tests (Level 1)

    /// 测试解析器：喂假输出，验证提取结果
    func testParseEncoders_extractsVideoToolbox() async {
        let fakeOutput = """
         V..... libx264          H.264 / AVC
         V....D h264_videotoolbox VideoToolbox H.264 Encoder
         V....D hevc_videotoolbox VideoToolbox H.265 Encoder
         A..... aac              AAC (Advanced Audio Coding)
        """

        let probe = HardwareAccelerationProbe.shared
        let result = await probe.parseEncoders(fakeOutput)

        XCTAssertEqual(result.map(\.name).sorted(),
                       ["h264_videotoolbox", "hevc_videotoolbox"])
        XCTAssertTrue(result.allSatisfy { $0.stream == .video })
    }

    /// 测试缓存往返：写入 UserDefaults 再调用恢复，验证数据一致
    func testCachePersistence() async throws {
        let probe = HardwareAccelerationProbe.shared

        // 1. 准备测试数据
        let testCodecs = [HardwareCodec(name: "h264_videotoolbox", stream: .video)]
        let data = try JSONEncoder().encode(testCodecs)

        // 2. 直接操作 UserDefaults (模拟持久化层)
        UserDefaults.standard.set(data, forKey: HardwareAccelerationProbe.CacheKey.codecs)
        UserDefaults.standard.set(Date(), forKey: HardwareAccelerationProbe.CacheKey.probedAt)

        // 3. 调用恢复方法
        let restored = await probe.restoreFromCache()
        XCTAssertTrue(restored)

        let names = await probe.videoCodecNames
        XCTAssertEqual(names, ["h264_videotoolbox"])

        // 清理
        UserDefaults.standard.removeObject(forKey: HardwareAccelerationProbe.CacheKey.codecs)
        UserDefaults.standard.removeObject(forKey: HardwareAccelerationProbe.CacheKey.probedAt)
    }
}
