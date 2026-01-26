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
    /// - Returns: 加载结果，成功时返回模板数组
    static func load(from directory: URL) async -> Result<[Template], TemplateLoadError> {
        // 使用 Task.detached 确保文件 IO 不阻塞当前线程
        await Task.detached(priority: .utility) {
            do {
                let fm = FileManager.default

                // 检查目录是否存在
                guard fm.fileExists(atPath: directory.path) else {
                    return .failure(.directoryNotFound(directory))
                }

                // 获取目录内容
                let contents = try fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )

                // 过滤 JSON 文件
                let jsonFiles = contents.filter { $0.pathExtension == "json" }

                // 加载每个模板文件
                let decoder = JSONDecoder()
                var templates: [Template] = []

                for fileURL in jsonFiles {
                    do {
                        let data = try Data(contentsOf: fileURL)
                        let template = try decoder.decode(Template.self, from: data)
                        templates.append(template)
                    } catch let decodingError as DecodingError {
                        // 解码错误记录但继续处理
                        print("[TemplateFileLoader] Decoding failed for \(fileURL.lastPathComponent): \(decodingError)")
                        // 可以选择收集错误而不是中断
                        continue
                    } catch {
                        // 文件读取错误记录但继续
                        print("[TemplateFileLoader] Read failed for \(fileURL.lastPathComponent): \(error)")
                        continue
                    }
                }

                return .success(templates)

            } catch {
                return .failure(.unknown(error.localizedDescription))
            }
        }.value
    }

    /// 加载单个模板文件
    /// - Parameter url: 模板文件 URL
    /// - Returns: 加载结果
    static func loadSingle(from url: URL) async -> Result<Template, TemplateLoadError> {
        await Task.detached(priority: .utility) {
            do {
                let data = try Data(contentsOf: url)
                let template = try JSONDecoder().decode(Template.self, from: data)
                return .success(template)
            } catch let decodingError as DecodingError {
                return .failure(.decodingFailed(url, decodingError.localizedDescription))
            } catch {
                return .failure(.fileReadFailed(url, error.localizedDescription))
            }
        }.value
    }
}
