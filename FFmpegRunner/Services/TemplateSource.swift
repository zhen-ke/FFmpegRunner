//
//  TemplateSource.swift
//  FFmpegRunner
//
//  可插拔的模板来源协议及其实现
//

import Foundation

// MARK: - Protocol

/// 模板来源协议
/// 可扩展支持：Bundle / User / Remote / GitHub 等来源
protocol TemplateSource: Sendable {
    /// 来源标识符（用于日志和调试）
    var identifier: String { get }

    /// 加载该来源的所有模板
    func loadTemplates() async -> Result<[Template], TemplateLoadError>
}

// MARK: - Bundle Template Source

/// 从 App Bundle 加载内置模板
struct BundleTemplateSource: TemplateSource {

    let identifier = "bundle"

    func loadTemplates() async -> Result<[Template], TemplateLoadError> {
        guard let url = Bundle.main.url(forResource: "Templates", withExtension: nil) else {
            // Bundle 模板目录不存在是正常情况（可能没有内置模板）
            return .success([])
        }

        return await TemplateFileLoader.load(from: url)
    }
}

// MARK: - User Template Source

/// 从用户 Application Support 目录加载自定义模板
struct UserTemplateSource: TemplateSource {

    let identifier = "user"

    /// 用户模板目录
    let directory: URL

    init(directory: URL? = nil) {
        if let directory = directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directory = appSupport.appendingPathComponent("FFmpegRunner/Templates", isDirectory: true)
        }
    }

    func loadTemplates() async -> Result<[Template], TemplateLoadError> {
        // 确保目录存在
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        guard FileManager.default.fileExists(atPath: directory.path) else {
            return .success([])
        }

        return await TemplateFileLoader.load(from: directory)
    }
}
