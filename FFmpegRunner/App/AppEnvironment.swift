//
//  AppEnvironment.swift
//  FFmpegRunner
//
//  全局环境配置
//

import Foundation

/// 应用环境配置
struct AppEnvironment {

    // MARK: - Shared Instance

    static let shared = AppEnvironment()

    // MARK: - App Info

    /// 应用名称
    var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "FFmpegRunner"
    }

    /// 应用版本
    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// 构建版本
    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    // MARK: - Directories

    /// 应用支持目录
    var applicationSupportDirectory: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("FFmpegRunner", isDirectory: true)

        // 确保目录存在
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)

        return appDir
    }

    /// 用户模板目录
    var userTemplatesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Templates", isDirectory: true)
    }

    /// 日志目录
    var logsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    /// 临时目录
    var tempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FFmpegRunner", isDirectory: true)
    }

    // MARK: - Methods

    /// 初始化应用目录
    func initializeDirectories() {
        let fm = FileManager.default

        let directories = [
            userTemplatesDirectory,
            logsDirectory,
            tempDirectory
        ]

        for dir in directories {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 清理临时目录
    func cleanupTempDirectory() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}

// MARK: - 系统信息

extension AppEnvironment {

    /// 操作系统版本
    var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// 是否为 Apple Silicon
    var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// 处理器架构
    var architecture: String {
        isAppleSilicon ? "Apple Silicon" : "Intel"
    }
}
