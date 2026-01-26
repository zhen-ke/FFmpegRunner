//
//  TemplateRepository.swift
//  FFmpegRunner
//
//  工业级模板仓库 - 统一入口
//  整合所有模板来源、校验、排序
//

import Foundation

/// 模板仓库 - 新的统一入口
/// 整合所有模板来源、校验器、排序器
@MainActor
final class TemplateRepository {

    // MARK: - Singleton

    static let shared = TemplateRepository()

    // MARK: - Dependencies

    private let sources: [TemplateSource]
    private let validator: TemplateValidator

    /// 用户模板目录（供外部访问，如删除/保存操作）
    let userTemplatesDirectory: URL

    // MARK: - Initialization

    init(sources: [TemplateSource]? = nil, userDirectory: URL? = nil) {
        let userDir = userDirectory ?? {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            return appSupport.appendingPathComponent("FFmpegRunner/Templates", isDirectory: true)
        }()

        self.userTemplatesDirectory = userDir
        self.validator = TemplateValidator()

        if let customSources = sources {
            self.sources = customSources
        } else {
            self.sources = [
                BundleTemplateSource(),
                UserTemplateSource(directory: userDir)
            ]
        }
    }

    // MARK: - Public API

    /// 加载所有模板并返回详细报告
    /// - Returns: 包含模板、警告、错误的完整报告
    func loadTemplates() async -> TemplateLoadReport {
        var templateDict: [String: Template] = [:]
        var allWarnings: [String: [TemplateValidationWarning]] = [:]
        var allErrors: [TemplateLoadError] = []

        // 1. 注入 RawCommand (始终存在)
        let rawCommand = createRawCommandTemplate()
        templateDict[rawCommand.id] = rawCommand

        // 2. 从所有来源加载
        for source in sources {
            let result = await source.loadTemplates()

            switch result {
            case .success(let templates):
                for template in templates {
                    // 验证模板
                    let warnings = validator.validate(template)

                    // 只添加有效模板（无致命错误）
                    if validator.isValid(template) {
                        templateDict[template.id] = template

                        // 记录警告
                        if !warnings.isEmpty {
                            allWarnings[template.id] = warnings
                        }
                    } else {
                        // 记录致命警告但不添加模板
                        allWarnings[template.id] = warnings
                    }
                }

            case .failure(let error):
                allErrors.append(error)
            }
        }

        // 3. 排序
        let sortedTemplates = TemplateSorter.sort(templateDict.values)

        return TemplateLoadReport(
            templates: sortedTemplates,
            warnings: allWarnings,
            errors: allErrors
        )
    }

    /// 便捷方法：只获取模板数组（忽略警告和错误）
    func loadAllTemplates() async -> [Template] {
        await loadTemplates().templates
    }

    // MARK: - User Template Management

    /// 删除用户模板
    /// - Returns: 是否删除成功
    func deleteUserTemplate(_ template: Template) -> Bool {
        let fileURL = userTemplatesDirectory.appendingPathComponent("\(template.id).json")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }

        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            print("[TemplateRepository] Failed to delete template: \(error)")
            return false
        }
    }

    /// 判断模板是否可删除
    func canDeleteTemplate(_ template: Template) -> Bool {
        if template.id == Template.rawCommandId {
            return false
        }

        let fileURL = userTemplatesDirectory.appendingPathComponent("\(template.id).json")
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Private

    /// 创建内置的 RawCommandTemplate
    private func createRawCommandTemplate() -> Template {
        Template(
            id: Template.rawCommandId,
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
