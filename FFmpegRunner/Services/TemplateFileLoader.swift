//
//  TemplateFileLoader.swift
//  FFmpegRunner
//
//  真正的异步文件加载器
//  使用 Task.detached 将磁盘 IO 移出主线程
//

import Foundation

/// 异步模板文件加载器
enum TemplateFileLoader {

    /// 从指定目录异步加载所有模板文件
    /// - Parameter directory: 模板目录 URL
    /// - Returns: 成功加载的模板，以及读取过程中遇到的问题
    static func load(from directory: URL) async -> TemplateSourceLoadResult {
        // 使用 Task.detached 确保文件 IO 不阻塞当前线程
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default

            // 检查目录是否存在
            guard fm.fileExists(atPath: directory.path) else {
                return TemplateSourceLoadResult(
                    templates: [],
                    errors: [.directoryNotFound(directory)]
                )
            }

            // 获取目录内容
            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            } catch {
                return TemplateSourceLoadResult(
                    templates: [],
                    errors: [.directoryReadFailed(directory, error.localizedDescription)]
                )
            }

            // 过滤 JSON 文件
            let jsonFiles = contents.filter { $0.pathExtension == "json" }

            // 加载每个模板文件
            let decoder = JSONDecoder()
            var templates: [Template] = []
            var errors: [TemplateLoadError] = []

            for fileURL in jsonFiles {
                do {
                    let data = try Data(contentsOf: fileURL)
                    let template = try decoder.decode(Template.self, from: data)
                    templates.append(template)
                } catch let decodingError as DecodingError {
                    let reason = userFriendlyReason(for: decodingError)
                    AppLogger.notice(AppLogger.template, "Decoding failed for \(fileURL.lastPathComponent): \(reason)")
                    errors.append(.decodingFailed(fileURL, reason))
                } catch {
                    AppLogger.notice(AppLogger.template, "Read failed for \(fileURL.lastPathComponent): \(error)")
                    errors.append(.fileReadFailed(fileURL, error.localizedDescription))
                }
            }

            let loadedIds = templates.map { $0.id }.sorted()
            if loadedIds.isEmpty {
                AppLogger.debug(AppLogger.template, "Loaded 0 templates from \(directory.path)")
            } else {
                AppLogger.debug(
                    AppLogger.template,
                    "Loaded \(loadedIds.count) templates from \(directory.path): \(loadedIds.joined(separator: ", "))"
                )
            }

            return TemplateSourceLoadResult(templates: templates, errors: errors)
        }.value
    }

    /// 加载单个模板文件
    /// - Parameter url: 模板文件 URL
    /// - Returns: 加载结果
    static func loadSingle(from url: URL) async -> Result<Template, TemplateLoadError> {
        return await Task.detached(priority: .utility) {
            do {
                let data = try Data(contentsOf: url)
                let template = try JSONDecoder().decode(Template.self, from: data)
                return .success(template)
            } catch let decodingError as DecodingError {
                return .failure(.decodingFailed(url, userFriendlyReason(for: decodingError)))
            } catch {
                return .failure(.fileReadFailed(url, error.localizedDescription))
            }
        }.value
    }

    private static func userFriendlyReason(for error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context):
            let location = codingPathDescription(context.codingPath)
            return location.isEmpty ? "JSON 格式不正确" : "字段内容不正确（\(location)）"
        case .keyNotFound(let key, let context):
            let location = codingPathDescription(context.codingPath + [key])
            return "缺少必要字段（\(location)）"
        case .typeMismatch(_, let context):
            let location = codingPathDescription(context.codingPath)
            return location.isEmpty ? "字段类型不正确" : "字段类型不正确（\(location)）"
        case .valueNotFound(_, let context):
            let location = codingPathDescription(context.codingPath)
            return location.isEmpty ? "字段值为空" : "字段值为空（\(location)）"
        @unknown default:
            return "模板内容格式不正确"
        }
    }

    private static func codingPathDescription(_ codingPath: [CodingKey]) -> String {
        codingPath
            .map { key in
                if let intValue = key.intValue {
                    return "[\(intValue)]"
                }
                return key.stringValue
            }
            .filter { !$0.isEmpty }
            .joined(separator: ".")
    }
}
