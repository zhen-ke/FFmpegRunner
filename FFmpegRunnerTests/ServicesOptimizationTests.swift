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

    // MARK: - FFmpegService Version Caching Tests

    func testFFmpegServiceVersionCaching() async throws {
        let service = FFmpegService.shared

        // Ensure we have a valid source (bundled or system)
        if !service.isFFmpegAvailable() {
            try XCTSkipIf(true, "FFmpeg not available, skipping version test")
        }

        // 1. Get version first time
        let v1 = try await service.getFFmpegVersion()
        XCTAssertFalse(v1.isEmpty)

        // 2. Get version second time (should use cache)
        let v2 = try await service.getFFmpegVersion()
        XCTAssertEqual(v1, v2)

        // 3. Change source (should invalidate cache)
        // We just toggle to the same source to trigger validation logic if possible,
        // or toggle between system and bundled if available.
        // Since we can't easily guarantee multiple sources in test env, we just call setSource with current source.
        let currentSource = service.ffmpegSource
        // Assuming custom path is empty or valid
        service.setSource(currentSource, customPath: service.customFFmpegPath)

        // 4. Get version again (should re-fetch)
        let v3 = try await service.getFFmpegVersion()
        XCTAssertEqual(v1, v3)
    }

    // MARK: - FFmpegPathResolver Caching Tests

    func testFFmpegPathResolverCaching() {
        // Can't easily test private property `cachedSystemPath`, but we can verify consistent returns.
        // And ensure it doesn't crash on repeated calls.

        let resolver = FFmpegPathResolver() // New instance

        // 1. First call
        let path1 = resolver.systemPath

        // 2. Second call
        let path2 = resolver.systemPath

        XCTAssertEqual(path1, path2)
    }
}
