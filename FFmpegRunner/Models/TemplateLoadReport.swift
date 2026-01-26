//
//  TemplateLoadReport.swift
//  FFmpegRunner
//
//  模板加载结果报告，让 UI 可以展示部分失败信息
//

import Foundation

/// 模板验证警告
enum TemplateValidationWarning: Equatable, CustomStringConvertible {
    /// 模板 ID 为空
    case missingId

    /// 模板名称为空
    case emptyName

    /// 命令模板为空
    case emptyCommandTemplate

    /// 未使用的参数（在 commandTemplate 中没有对应占位符）
    case unusedParameter(String)

    var description: String {
        switch self {
        case .missingId:
            return "模板 ID 为空"
        case .emptyName:
            return "模板名称为空"
        case .emptyCommandTemplate:
            return "命令模板为空"
        case .unusedParameter(let key):
            return "参数 '\(key)' 未在命令模板中使用"
        }
    }

    /// 警告级别：true = 致命（应拒绝模板），false = 警告（模板仍可用）
    var isFatal: Bool {
        switch self {
        case .missingId, .emptyName, .emptyCommandTemplate:
            return true
        case .unusedParameter:
            return false
        }
    }
}

/// 模板加载结果报告
struct TemplateLoadReport {
    /// 成功加载的模板
    let templates: [Template]

    /// 每个模板的验证警告（key = template.id）
    let warnings: [String: [TemplateValidationWarning]]

    /// 加载过程中发生的错误
    let errors: [TemplateLoadError]

    /// 是否有任何问题（警告或错误）
    var hasIssues: Bool {
        !warnings.isEmpty || !errors.isEmpty
    }

    /// 是否有致命错误
    var hasFatalWarnings: Bool {
        warnings.values.contains { $0.contains { $0.isFatal } }
    }

    /// 所有警告的扁平化列表
    var allWarnings: [(templateId: String, warning: TemplateValidationWarning)] {
        warnings.flatMap { id, warns in
            warns.map { (templateId: id, warning: $0) }
        }
    }

    // MARK: - Factory

    /// 创建空报告
    static var empty: TemplateLoadReport {
        TemplateLoadReport(templates: [], warnings: [:], errors: [])
    }

    /// 创建只有模板的成功报告
    static func success(_ templates: [Template]) -> TemplateLoadReport {
        TemplateLoadReport(templates: templates, warnings: [:], errors: [])
    }
}
