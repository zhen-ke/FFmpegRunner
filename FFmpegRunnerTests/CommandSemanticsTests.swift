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

    func testConcatListBuilderResolvesFileList() throws {
        // Create mock files
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        let file1 = tempDir.appendingPathComponent("test1'file.ts")
        let file2 = tempDir.appendingPathComponent("test2.ts")
        
        try "test1".write(to: file1, atomically: true, encoding: .utf8)
        try "test2".write(to: file2, atomically: true, encoding: .utf8)
        
        defer {
            try? fm.removeItem(at: file1)
            try? fm.removeItem(at: file2)
        }
        
        // Define parameter and binding
        let parameter = TemplateParameter(
            key: "inputsList",
            label: "待合并视频列表",
            type: .files,
            isRequired: true
        )
        
        let rawPaths = "\(file1.path)\n\(file2.path)"
        let value = TemplateValue(key: "inputsList", rawValue: rawPaths).validated(with: parameter)
        
        let template = Template(
            id: "concat_test",
            name: "Concat Test",
            description: "Test Concat",
            commandTemplate: "ffmpeg -f concat -safe 0 -i {{inputsList}} -c copy output.mp4",
            parameters: [parameter],
            category: "Test",
            icon: "video.fill"
        )
        
        let binding = TemplateBinding.bind(template: template, values: [value])
        
        // Resolve concat list
        let (resolvedBinding, tempFiles) = try ConcatListBuilder.resolve(binding: binding)
        
        XCTAssertEqual(tempFiles.count, 1)
        let tempFile = tempFiles[0]
        defer {
            try? fm.removeItem(at: tempFile)
        }
        
        XCTAssertTrue(fm.fileExists(atPath: tempFile.path))
        
        // Check temporary file content
        let content = try String(contentsOf: tempFile, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "file '\(file1.path.replacingOccurrences(of: "'", with: "'\\''"))'")
        XCTAssertEqual(lines[1], "file '\(file2.path)'")
        
        // Check resolved binding
        let resolvedParamBinding = resolvedBinding.binding(for: "inputsList")
        XCTAssertNotNil(resolvedParamBinding)
        XCTAssertEqual(resolvedParamBinding?.rawValue, tempFile.path)
        XCTAssertEqual(resolvedParamBinding?.parameter.type, .files) // The original parameter definition remains .files
        XCTAssertEqual(resolvedParamBinding?.renderValue, tempFile.path)
    }

    func testFileListOrderingSortsConcatSegmentsNaturalAscending() {
        let directory = URL(fileURLWithPath: "/tmp/ffmpegrunner-segments")
        let urls = [
            "output_109.ts",
            "output_108.ts",
            "output_100.ts",
            "output_099.ts",
            "output_10.ts",
            "output_2.ts"
        ].map { directory.appendingPathComponent($0) }

        let sortedNames = FileListOrdering.naturalAscending(urls).map(\.lastPathComponent)

        XCTAssertEqual(sortedNames, [
            "output_2.ts",
            "output_10.ts",
            "output_099.ts",
            "output_100.ts",
            "output_108.ts",
            "output_109.ts"
        ])
    }

    func testFileListOrderingAppendsUniqueFilesThenSortsWholeList() {
        let directory = URL(fileURLWithPath: "/tmp/ffmpegrunner-segments")
        let existing = [
            "output_100.ts",
            "output_101.ts"
        ].map { directory.appendingPathComponent($0) }
        let incoming = [
            "output_099.ts",
            "output_101.ts",
            "output_102.ts"
        ].map { directory.appendingPathComponent($0) }

        let sortedNames = FileListOrdering
            .appendingUniqueNaturalAscending(existing: existing, incoming: incoming)
            .map(\.lastPathComponent)

        XCTAssertEqual(sortedNames, [
            "output_099.ts",
            "output_100.ts",
            "output_101.ts",
            "output_102.ts"
        ])
    }
}
