//
//  TemplateLoadError.swift
//  FFmpegRunner
//
//  统一的模板加载错误模型
//

import Foundation

/// 模板加载过程中可能发生的错误
enum TemplateLoadError: Error, LocalizedError, Equatable {
    /// 目录不存在
    case directoryNotFound(URL)

    /// 文件读取失败
    case fileReadFailed(URL, String)

    /// JSON 解码失败
    case decodingFailed(URL, String)

    /// 未知错误
    case unknown(String)

    // MARK: - LocalizedError

    var errorDescription: String? {
        switch self {
        case .directoryNotFound(let url):
            return "模板目录不存在: \(url.path)"
        case .fileReadFailed(let url, let reason):
            return "读取模板文件失败 \(url.lastPathComponent): \(reason)"
        case .decodingFailed(let url, let reason):
            return "解析模板失败 \(url.lastPathComponent): \(reason)"
        case .unknown(let reason):
            return "未知错误: \(reason)"
        }
    }

    // MARK: - Equatable

    static func == (lhs: TemplateLoadError, rhs: TemplateLoadError) -> Bool {
        switch (lhs, rhs) {
        case let (.directoryNotFound(l), .directoryNotFound(r)):
            return l == r
        case let (.fileReadFailed(lUrl, lReason), .fileReadFailed(rUrl, rReason)):
            return lUrl == rUrl && lReason == rReason
        case let (.decodingFailed(lUrl, lReason), .decodingFailed(rUrl, rReason)):
            return lUrl == rUrl && lReason == rReason
        case let (.unknown(l), .unknown(r)):
            return l == r
        default:
            return false
        }
    }
}
