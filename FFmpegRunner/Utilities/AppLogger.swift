//
//  AppLogger.swift
//  FFmpegRunner
//
//  Centralized logging utilities
//

import Foundation
import OSLog

enum AppLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "FFmpegRunner"

    static let ffmpeg = Logger(subsystem: subsystem, category: "ffmpeg")
    static let process = Logger(subsystem: subsystem, category: "process")
    static let template = Logger(subsystem: subsystem, category: "template")
    static let history = Logger(subsystem: subsystem, category: "history")
    static let general = Logger(subsystem: subsystem, category: "general")

    static var isVerboseEnabled: Bool {
        UserDefaults.standard.bool(forKey: "enableVerboseLogging")
    }

    static func debug(_ logger: Logger, _ message: @autoclosure () -> String) {
        guard isVerboseEnabled else { return }
        let value = message()
        logger.debug("\(value, privacy: .public)")
    }

    static func info(_ logger: Logger, _ message: @autoclosure () -> String) {
        let value = message()
        logger.info("\(value, privacy: .public)")
    }

    static func notice(_ logger: Logger, _ message: @autoclosure () -> String) {
        let value = message()
        logger.notice("\(value, privacy: .public)")
    }

    static func error(_ logger: Logger, _ message: @autoclosure () -> String) {
        let value = message()
        logger.error("\(value, privacy: .public)")
    }
}
