//
//  TemplateLoader.swift
//  FFmpegRunner
//
//  模板加载服务
//

import Foundation

/// 模板加载服务
/// 负责从 Bundle 和用户目录加载模板
class TemplateLoader {

    // MARK: - Singleton

    static let shared = TemplateLoader()

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()

    /// 用户模板目录
    var userTemplatesDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FFmpegRunner/Templates", isDirectory: true)
    }

    // MARK: - Public Methods

    /// 加载所有模板（Bundle + 用户）
    /// 如果有相同 ID 的模板，用户模板会覆盖 Bundle 模板
    func loadAllTemplates() async throws -> [Template] {
        // 使用字典按 ID 去重
        var templateDict: [String: Template] = [:]

        // 1. 注入 RawCommandTemplate (始终存在)
        let rawCommand = createRawCommandTemplate()
        templateDict[rawCommand.id] = rawCommand

        // 2. 加载 Bundle 模板
        let bundleTemplates = try await loadBundleTemplates()
        for template in bundleTemplates {
            templateDict[template.id] = template
        }

        // 3. 加载用户模板（后加载，会覆盖同 ID 的 Bundle 模板）
        let userTemplates = try await loadUserTemplates()
        for template in userTemplates {
            templateDict[template.id] = template
        }

        // 4. 转换为数组，按分类和名称排序
        let templates = Array(templateDict.values).sorted { t1, t2 in
            // RawCommand 始终在第一位
            if t1.id == "raw-command" { return true }
            if t2.id == "raw-command" { return false }
            // 按分类排序
            let cat1 = t1.category ?? "其他"
            let cat2 = t2.category ?? "其他"
            if cat1 != cat2 { return cat1 < cat2 }
            // 同分类按名称排序
            return t1.name < t2.name
        }

        return templates
    }

    /// 加载 Bundle 内的模板
    func loadBundleTemplates() async throws -> [Template] {
        guard let templatesURL = Bundle.main.url(forResource: "Templates", withExtension: nil) else {
            return []
        }

        return try await loadTemplates(from: templatesURL)
    }

    /// 加载用户自定义模板
    func loadUserTemplates() async throws -> [Template] {
        // 确保目录存在
        try? fileManager.createDirectory(at: userTemplatesDirectory, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: userTemplatesDirectory.path) else {
            return []
        }

        return try await loadTemplates(from: userTemplatesDirectory)
    }

    /// 删除用户模板
    /// - Returns: 是否删除成功
    func deleteUserTemplate(_ template: Template) -> Bool {
        let fileURL = userTemplatesDirectory.appendingPathComponent("\(template.id).json")

        // 检查文件是否存在于用户目录
        guard fileManager.fileExists(atPath: fileURL.path) else {
            print("Template file not found in user directory: \(fileURL.path)")
            return false
        }

        do {
            try fileManager.removeItem(at: fileURL)
            return true
        } catch {
            print("Failed to delete template: \(error)")
            return false
        }
    }

    /// 判断模板是否可删除（用户目录中存在该模板文件）
    func canDeleteTemplate(_ template: Template) -> Bool {
        // 不允许删除 RawCommand 模板
        if template.id == "raw-command" {
            return false
        }

        let fileURL = userTemplatesDirectory.appendingPathComponent("\(template.id).json")
        return fileManager.fileExists(atPath: fileURL.path)
    }

    // MARK: - Private Methods

    /// 从指定目录加载模板
    private func loadTemplates(from directory: URL) async throws -> [Template] {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        let jsonFiles = contents.filter { $0.pathExtension == "json" }

        var templates: [Template] = []

        for fileURL in jsonFiles {
            do {
                let template = try await loadTemplate(from: fileURL)
                if validate(template) {
                    templates.append(template)
                }
            } catch {
                print("Failed to load template from \(fileURL.lastPathComponent): \(error)")
            }
        }

        return templates
    }

    /// 加载单个模板文件
    private func loadTemplate(from url: URL) async throws -> Template {
        let data = try Data(contentsOf: url)
        return try decoder.decode(Template.self, from: data)
    }

    /// 验证模板合法性
    private func validate(_ template: Template) -> Bool {
        // 检查必要字段
        guard !template.id.isEmpty,
              !template.name.isEmpty,
              !template.commandTemplate.isEmpty else {
            return false
        }

        // 检查所有参数的占位符是否在命令模板中存在
        for param in template.parameters {
            let placeholder = "{{\(param.key)}}"
            if !template.commandTemplate.contains(placeholder) {
                print("Warning: Parameter '\(param.key)' not found in command template")
            }
        }

        return true
    }



    /// 创建内置的 RawCommandTemplate
    private func createRawCommandTemplate() -> Template {
        Template(
            id: "raw-command",
            name: "自定义命令",
            description: "直接输入并执行完整 FFmpeg 命令",
            commandTemplate: "{{command}}",
            parameters: [
                TemplateParameter(
                    key: "command",
                    label: "FFmpeg 命令",
                    type: .string,
                    defaultValue: "ffmpeg -i input.mp4 -c:v libx264 output.mp4",
                    placeholder: "在此输入完整命令...",
                    isRequired: true,
                    constraints: nil,
                    role: .raw,
                    escapeStrategy: .raw,
                    uiHint: ParameterUIHint(multiline: true, monospace: true)
                )
            ],
            category: "高级",
            icon: "terminal.fill"
        )
    }
}
