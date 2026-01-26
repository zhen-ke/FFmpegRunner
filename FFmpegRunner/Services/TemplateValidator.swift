//
//  TemplateValidator.swift
//  FFmpegRunner
//
//  结构化模板校验器，返回明确的警告列表
//

import Foundation

/// 模板验证器
struct TemplateValidator {

    /// 验证模板并返回所有警告
    /// - Parameter template: 要验证的模板
    /// - Returns: 警告列表（空列表表示无问题）
    func validate(_ template: Template) -> [TemplateValidationWarning] {
        var warnings: [TemplateValidationWarning] = []

        // 检查 ID
        if template.id.isEmpty {
            warnings.append(.missingId)
        }

        // 检查名称
        if template.name.isEmpty {
            warnings.append(.emptyName)
        }

        // 检查命令模板
        if template.commandTemplate.isEmpty {
            warnings.append(.emptyCommandTemplate)
        }

        // 检查参数是否在命令模板中有对应占位符
        for param in template.parameters {
            let placeholder = "{{\(param.key)}}"
            if !template.commandTemplate.contains(placeholder) {
                warnings.append(.unusedParameter(param.key))
            }
        }

        return warnings
    }

    /// 验证模板是否可用（无致命错误）
    /// - Parameter template: 要验证的模板
    /// - Returns: 是否可用
    func isValid(_ template: Template) -> Bool {
        let warnings = validate(template)
        return !warnings.contains { $0.isFatal }
    }

    /// 批量验证模板
    /// - Parameter templates: 模板数组
    /// - Returns: 每个模板 ID 对应的警告字典
    func validateAll(_ templates: [Template]) -> [String: [TemplateValidationWarning]] {
        var result: [String: [TemplateValidationWarning]] = [:]

        for template in templates {
            let warnings = validate(template)
            if !warnings.isEmpty {
                result[template.id] = warnings
            }
        }

        return result
    }

    /// 过滤出有效的模板（无致命错误）
    /// - Parameter templates: 模板数组
    /// - Returns: 有效模板数组
    func filterValid(_ templates: [Template]) -> [Template] {
        templates.filter { isValid($0) }
    }
}
