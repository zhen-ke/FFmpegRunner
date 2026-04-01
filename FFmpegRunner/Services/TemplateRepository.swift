//
//  TemplateRepository.swift
//  FFmpegRunner
//
//  工业级模板仓库 - 统一入口
//  整合所有模板来源、校验、排序
//

import Foundation

enum TemplateRepositoryError: LocalizedError {
    case notUserTemplate
    case invalidImportedTemplate(String)

    var errorDescription: String? {
        switch self {
        case .notUserTemplate:
            return "只有用户模板才能直接重命名或删除"
        case .invalidImportedTemplate(let reason):
            return reason
        }
    }
}

struct TemplateImportSummary {
    let importedTemplates: [Template]
    let errors: [String]

    var importedCount: Int {
        importedTemplates.count
    }

    var hasFailures: Bool {
        !errors.isEmpty
    }
}

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

        // 2. 从所有来源并行加载（避免串行 IO）
        let results = await withTaskGroup(of: Result<[Template], TemplateLoadError>.self) { group in
            for source in sources {
                group.addTask {
                    await source.loadTemplates()
                }
            }

            var collected: [Result<[Template], TemplateLoadError>] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for result in results {
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
            AppLogger.error(AppLogger.template, "Failed to delete template: \(error)")
            return false
        }
    }

    /// 判断模板是否可删除
    func canDeleteTemplate(_ template: Template) -> Bool {
        if template.isBuiltInRawCommand {
            return false
        }

        let fileURL = userTemplatesDirectory.appendingPathComponent("\(template.id).json")
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// 保存用户模板到应用支持目录
    func saveUserTemplate(_ template: Template) throws {
        try FileManager.default.createDirectory(
            at: userTemplatesDirectory,
            withIntermediateDirectories: true
        )

        let fileURL = userTemplatesDirectory.appendingPathComponent("\(template.id).json")
        try writeTemplate(template, to: fileURL)
    }

    /// 导入模板文件
    func importTemplates(from urls: [URL]) async -> TemplateImportSummary {
        let existingTemplates = await loadAllTemplates()
        var usedIDs = Set(existingTemplates.map(\.id))
        var importedTemplates: [Template] = []
        var errors: [String] = []

        for url in urls {
            let imported: Template
            switch await TemplateFileLoader.loadSingle(from: url) {
            case .success(let template):
                imported = template
            case .failure(let error):
                errors.append(error.localizedDescription)
                continue
            }

            let warnings = validator.validate(imported)
            let fatalWarnings = warnings.filter(\.isFatal)
            if !fatalWarnings.isEmpty {
                let reasons = fatalWarnings.map(\.description).joined(separator: "，")
                errors.append("\(url.lastPathComponent)：\(reasons)")
                continue
            }

            let normalized = normalizedImportedTemplate(imported, usedIDs: &usedIDs)

            do {
                try saveUserTemplate(normalized)
                importedTemplates.append(normalized)
            } catch {
                errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        return TemplateImportSummary(
            importedTemplates: importedTemplates,
            errors: errors
        )
    }

    /// 导出模板到指定位置
    @discardableResult
    func exportTemplate(_ template: Template, to destinationURL: URL) throws -> URL {
        let finalURL: URL
        if destinationURL.pathExtension.isEmpty {
            finalURL = destinationURL.appendingPathExtension("json")
        } else {
            finalURL = destinationURL
        }

        try writeTemplate(template, to: finalURL)
        return finalURL
    }

    /// 复制模板到用户目录
    func duplicateTemplate(_ template: Template, named name: String? = nil) throws -> Template {
        let duplicated = Template(
            id: "user-\(UUID().uuidString)",
            name: normalizedTemplateName(name ?? "\(template.name) 副本"),
            description: template.description,
            commandTemplate: template.commandTemplate,
            parameters: template.parameters,
            category: template.category ?? "用户模板",
            icon: template.icon
        )

        try saveUserTemplate(duplicated)
        return duplicated
    }

    /// 重命名用户模板
    func renameUserTemplate(_ template: Template, to newName: String) throws -> Template {
        guard canDeleteTemplate(template) else {
            throw TemplateRepositoryError.notUserTemplate
        }

        let renamed = Template(
            id: template.id,
            name: normalizedTemplateName(newName),
            description: template.description,
            commandTemplate: template.commandTemplate,
            parameters: template.parameters,
            category: template.category,
            icon: template.icon
        )

        try saveUserTemplate(renamed)
        return renamed
    }

    /// 判断模板是否可重命名
    func canRenameTemplate(_ template: Template) -> Bool {
        canDeleteTemplate(template)
    }

    /// 判断模板是否可复制
    func canDuplicateTemplate(_ template: Template) -> Bool {
        !template.isBuiltInRawCommand
    }

    /// 判断模板是否可导出
    func canExportTemplate(_ template: Template) -> Bool {
        !template.isBuiltInRawCommand
    }

    /// 判断模板是否来自用户目录
    func isUserTemplate(_ template: Template) -> Bool {
        canDeleteTemplate(template)
    }

    // MARK: - Private

    private func writeTemplate(_ template: Template, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(template)
        try data.write(to: url, options: .atomic)
    }

    private func normalizedImportedTemplate(
        _ template: Template,
        usedIDs: inout Set<String>
    ) -> Template {
        var resolvedID = template.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedID.isEmpty || resolvedID == Template.rawCommandId || usedIDs.contains(resolvedID) {
            resolvedID = "user-\(UUID().uuidString)"
        }
        usedIDs.insert(resolvedID)

        return Template(
            id: resolvedID,
            name: normalizedTemplateName(template.name),
            description: template.description.isEmpty ? "导入的模板" : template.description,
            commandTemplate: template.commandTemplate,
            parameters: template.parameters,
            category: template.category ?? "用户模板",
            icon: template.icon
        )
    }

    private func normalizedTemplateName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名模板" : trimmed
    }

    /// 创建内置的 RawCommandTemplate
    private func createRawCommandTemplate() -> Template {
        Template.makeRawCommandTemplate(
            id: Template.rawCommandId,
            name: "自定义命令",
            description: "直接输入并执行完整 FFmpeg 命令",
            defaultCommand: "ffmpeg -i input.mp4 -c:v libx264 output.mp4",
            placeholder: "在此输入完整命令...",
            category: "高级",
            icon: "terminal.fill"
        )
    }
}
