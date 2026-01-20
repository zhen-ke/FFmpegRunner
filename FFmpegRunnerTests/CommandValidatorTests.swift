//
//  CommandValidatorTests.swift
//  FFmpegRunnerTests
//
//  Level 3 补充测试：验证错误路径
//

import XCTest
@testable import FFmpegRunner

final class CommandValidatorTests: XCTestCase {

    // MARK: - Valid Commands

    func testValidFFmpegCommand() {
        let result = CommandValidator.validate("ffmpeg -version")
        XCTAssertEqual(result, .valid)
    }

    func testValidFFprobeCommand() {
        let result = CommandValidator.validate("ffprobe -version")
        XCTAssertEqual(result, .valid)
    }

    func testValidAbsolutePathFFmpeg() {
        let result = CommandValidator.validate("/usr/local/bin/ffmpeg -i input.mp4 output.mp4")
        XCTAssertEqual(result, .valid)
    }

    func testValidComplexCommand() {
        let command = "ffmpeg -i input.mp4 -vf \"scale=1280:720\" -c:v libx264 output.mp4"
        let result = CommandValidator.validate(command)
        XCTAssertEqual(result, .valid)
    }

    // MARK: - Invalid Commands

    func testEmptyCommand() {
        let result = CommandValidator.validate("")
        XCTAssertEqual(result, .emptyCommand)
        XCTAssertEqual(result.errorMessage, "命令不能为空")
    }

    func testWhitespaceOnlyCommand() {
        let result = CommandValidator.validate("   \t  ")
        XCTAssertEqual(result, .emptyCommand)
    }

    func testNonFFmpegCommand() {
        let result = CommandValidator.validate("rm -rf /")
        XCTAssertEqual(result, .notFFmpegCommand)
        XCTAssertEqual(result.errorMessage, "只允许执行 ffmpeg 或 ffprobe 命令")
    }

    func testCurlCommand() {
        let result = CommandValidator.validate("curl https://example.com")
        XCTAssertEqual(result, .notFFmpegCommand)
    }

    func testBashCommand() {
        let result = CommandValidator.validate("bash -c 'echo hello'")
        XCTAssertEqual(result, .notFFmpegCommand)
    }

    // MARK: - Edge Cases (命令注入尝试)

    /// 尝试注入 - 带分号
    /// 注意：由于使用 Token 解析，分号被视为参数的一部分而非 shell 操作符
    func testSemicolonInjectionAttempt() {
        // 这个会被解析为 ffmpeg 命令，但参数中包含分号
        // 由于不经过 shell，分号不会被解释为命令分隔符
        let result = CommandValidator.validate("ffmpeg; rm -rf /")
        // 第一个 token 是 "ffmpeg;" 不是 "ffmpeg"
        XCTAssertEqual(result, .notFFmpegCommand)
    }

    /// 管道符在参数中是安全的（不经过 shell）
    func testPipeInArgument() {
        let result = CommandValidator.validate("ffmpeg -i 'file|name.mp4' output.mp4")
        XCTAssertEqual(result, .valid)
    }

    // MARK: - isValid Property

    func testIsValidProperty() {
        XCTAssertTrue(CommandValidationResult.valid.isValid)
        XCTAssertFalse(CommandValidationResult.emptyCommand.isValid)
        XCTAssertFalse(CommandValidationResult.notFFmpegCommand.isValid)
    }

    // MARK: - Error Messages

    func testErrorMessages() {
        XCTAssertNil(CommandValidationResult.valid.errorMessage)
        XCTAssertNotNil(CommandValidationResult.emptyCommand.errorMessage)
        XCTAssertNotNil(CommandValidationResult.notFFmpegCommand.errorMessage)
    }
}
