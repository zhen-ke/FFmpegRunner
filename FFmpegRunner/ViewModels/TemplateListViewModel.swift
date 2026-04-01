//
//  TemplateListViewModel.swift
//  FFmpegRunner
//
//  模板列表 ViewModel
//

import Foundation
import Combine

/// 模板列表 ViewModel
@MainActor
class TemplateListViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 所有模板
    @Published private(set) var templates: [Template] = []

    /// 当前选中的模板
    @Published var selectedTemplate: Template? {
        didSet {
            UserSettings.shared.lastTemplateId = selectedTemplate?.id ?? ""
        }
    }

    /// 搜索关键词
    @Published var searchText = ""

    /// 加载状态
    @Published private(set) var isLoading = false

    /// 错误信息
    @Published var errorMessage: String?

    // MARK: - Computed Properties

    /// 过滤后的模板列表
    var filteredTemplates: [Template] {
        if searchText.isEmpty {
            return templates
        }

        let lowercased = searchText.lowercased()
        return templates.filter { template in
            template.name.lowercased().contains(lowercased) ||
            template.description.lowercased().contains(lowercased) ||
            (template.category?.lowercased().contains(lowercased) ?? false)
        }
    }

    /// 按分类分组的模板
    var groupedTemplates: [String: [Template]] {
        Dictionary(grouping: filteredTemplates) { template in
            template.category ?? "其他"
        }
    }

    /// 分类列表（排序）
    var categories: [String] {
        groupedTemplates.keys.sorted()
    }

    // MARK: - Dependencies

    private let templateRepository: TemplateRepository

    // MARK: - Initialization

    init(templateRepository: TemplateRepository = .shared) {
        self.templateRepository = templateRepository
    }

    // MARK: - Public Methods

    /// 加载模板
    func loadTemplates() async {
        isLoading = true
        errorMessage = nil

        let report = await templateRepository.loadTemplates()
        templates = report.templates

        let preferredTemplateId = selectedTemplate?.id ?? UserSettings.shared.lastTemplateId
        selectedTemplate = templates.first(where: { $0.id == preferredTemplateId }) ?? templates.first

        if !report.errors.isEmpty {
            errorMessage = Self.makeTemplateIssueMessage(from: report.errors)
        }

        isLoading = false
    }

    /// 选择模板
    func select(_ template: Template) {
        selectedTemplate = template
    }

    /// 本地移除模板（不触发完整重新加载）
    func removeTemplate(_ template: Template) {
        templates.removeAll { $0.id == template.id }
    }

    func canRename(_ template: Template) -> Bool {
        templateRepository.canRenameTemplate(template)
    }

    func canDelete(_ template: Template) -> Bool {
        templateRepository.canDeleteTemplate(template)
    }

    func canDuplicate(_ template: Template) -> Bool {
        templateRepository.canDuplicateTemplate(template)
    }

    func canExport(_ template: Template) -> Bool {
        templateRepository.canExportTemplate(template)
    }

    func importTemplates(from urls: [URL]) async -> TemplateImportSummary {
        let summary = await templateRepository.importTemplates(from: urls)
        await loadTemplates()
        return summary
    }

    @discardableResult
    func duplicateTemplate(_ template: Template, named name: String? = nil) throws -> Template {
        let duplicated = try templateRepository.duplicateTemplate(template, named: name)
        templates.append(duplicated)
        templates = TemplateSorter.sort(templates)
        selectedTemplate = duplicated
        return duplicated
    }

    @discardableResult
    func renameTemplate(_ template: Template, to newName: String) throws -> Template {
        let renamed = try templateRepository.renameUserTemplate(template, to: newName)
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = renamed
        }
        selectedTemplate = renamed
        return renamed
    }

    @discardableResult
    func exportTemplate(_ template: Template, to url: URL) throws -> URL {
        try templateRepository.exportTemplate(template, to: url)
    }

    private static func makeTemplateIssueMessage(from errors: [TemplateLoadError]) -> String? {
        let descriptions = errors
            .compactMap(\.errorDescription)
            .reduce(into: [String]()) { result, message in
                if !result.contains(message) {
                    result.append(message)
                }
            }

        guard !descriptions.isEmpty else {
            return nil
        }

        let header = "发现 \(descriptions.count) 个模板问题："
        let details = descriptions.enumerated().map { index, message in
            "\(index + 1). \(message)"
        }

        return ([header] + details).joined(separator: "\n")
    }
}
