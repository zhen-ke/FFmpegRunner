//
//  CommandSemanticsTests.swift
//  FFmpegRunnerTests
//

import XCTest
@testable import FFmpegRunner

final class CommandSemanticsTests: XCTestCase {

    func testStripExecutableIfPresentWithAbsolutePath() {
        let normalized = CommandExecutable.stripExecutableIfPresent(
            from: ["/opt/homebrew/bin/ffprobe", "-show_streams", "input.mp4"]
        )

        XCTAssertEqual(normalized.executable, .ffprobe)
        XCTAssertEqual(normalized.arguments, ["-show_streams", "input.mp4"])
    }

    func testExecutionPlanRawCommandStripsLeadingExecutable() throws {
        let plan = try ExecutionPlan(
            command: "/opt/homebrew/bin/ffmpeg -i input.mp4 /tmp/output.mp4"
        )

        XCTAssertEqual(plan.executable, .ffmpeg)
        XCTAssertEqual(plan.arguments, ["-i", "input.mp4", "/tmp/output.mp4"])
    }

    func testDetectOutputPathExpandsTildePath() {
        let detectedPath = CommandPathDetector.detectOutputPath(
            from: ["-i", "input.mp4", "~/Movies/output.mp4"]
        )

        XCTAssertEqual(
            detectedPath,
            ("~/Movies/output.mp4" as NSString).expandingTildeInPath
        )
    }

    func testDetectOutputPathIgnoresRelativeOutputs() {
        XCTAssertNil(
            CommandPathDetector.detectOutputPath(from: ["-i", "input.mp4", "output.mp4"])
        )
    }

    func testDetectOutputPathIgnoresSpecialOutputs() {
        XCTAssertNil(
            CommandPathDetector.detectOutputPath(from: ["-i", "input.mp4", "pipe:1"])
        )
        XCTAssertNil(
            CommandPathDetector.detectOutputPath(from: ["-i", "input.mp4", "udp://127.0.0.1:1234"])
        )
        XCTAssertNil(
            CommandPathDetector.detectOutputPath(from: ["-i", "input.mp4", "/dev/null"])
        )
    }

    func testExecutionPlanOutputDirectoryPathUsesNormalizedPath() {
        let plan = ExecutionPlan(
            arguments: ["-i", "input.mp4", "~/Movies/output.mp4"],
            displayCommand: "ffmpeg -i input.mp4 ~/Movies/output.mp4"
        )

        XCTAssertEqual(
            plan.outputDirectoryPath,
            (("~/Movies" as NSString).expandingTildeInPath)
        )
    }
}
