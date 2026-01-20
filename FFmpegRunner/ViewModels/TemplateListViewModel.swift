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
    @Published var selectedTemplate: Template?

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

    private let templateLoader: TemplateLoader

    // MARK: - Initialization

    init(templateLoader: TemplateLoader = .shared) {
        self.templateLoader = templateLoader
    }

    // MARK: - Public Methods

    /// 加载模板
    func loadTemplates() async {
        isLoading = true
        errorMessage = nil

        do {
            templates = try await templateLoader.loadAllTemplates()

            // 默认选中第一个模板
            if selectedTemplate == nil, let first = templates.first {
                selectedTemplate = first
            }
        } catch {
            errorMessage = "加载模板失败: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// 选择模板
    func select(_ template: Template) {
        selectedTemplate = template
    }

    /// 刷新模板列表
    func refresh() async {
        await loadTemplates()
    }

    /// 导入模板
    func importTemplate(from url: URL) async {
        do {
            // 1. 读取文件数据
            let startAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if startAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)

            // 2. 尝试解析以验证格式
            let decoder = JSONDecoder()
            let template = try decoder.decode(Template.self, from: data)

            // 3. 准备目标路径
            let userTemplatesDir = templateLoader.userTemplatesDirectory
            try FileManager.default.createDirectory(at: userTemplatesDir, withIntermediateDirectories: true, attributes: nil)

            // 使用模板 ID 作为文件名
            let destinationURL = userTemplatesDir.appendingPathComponent("\(template.id).json")

            // 4. 写入文件
            try data.write(to: destinationURL)

            // 5. 刷新列表
            await refresh()

            // 6. 选中新导入的模板
            if let imported = templates.first(where: { $0.id == template.id }) {
                selectedTemplate = imported
            }

        } catch let decodingError as DecodingError {
            // 提取详细的解码错误信息
            switch decodingError {
            case .keyNotFound(let key, let context):
                errorMessage = "导入模板失败: 缺少字段 '\(key.stringValue)' (路径: \(context.codingPath.map { $0.stringValue }.joined(separator: ".")))"
            case .typeMismatch(let type, let context):
                errorMessage = "导入模板失败: 字段类型不匹配，期望 \(type) (路径: \(context.codingPath.map { $0.stringValue }.joined(separator: ".")))"
            case .valueNotFound(let type, let context):
                errorMessage = "导入模板失败: 字段值为空，期望 \(type) (路径: \(context.codingPath.map { $0.stringValue }.joined(separator: ".")))"
            case .dataCorrupted(let context):
                errorMessage = "导入模板失败: 数据格式错误 (路径: \(context.codingPath.map { $0.stringValue }.joined(separator: ".")))"
            @unknown default:
                errorMessage = "导入模板失败: \(decodingError.localizedDescription)"
            }
        } catch {
            errorMessage = "导入模板失败: \(error.localizedDescription)"
        }
    }
}
