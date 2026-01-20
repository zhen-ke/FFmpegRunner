//
//  ParameterBinding.swift
//  FFmpegRunner
//
//  参数绑定 - 将 TemplateParameter + TemplateValue 绑定为语义完整的单元
//
//  设计说明：
//  - 这是"语义闭环"的关键结构
//  - 将参数定义 + 运行时值 + 解析值绑定在一起
//  - 确保 Renderer 消费的是 ParsedValue，而不是 rawValue
//

import Foundation

// MARK: - Parameter Binding

/// 参数绑定：将参数定义和运行时值绑定为语义完整的单元
/// 这是"语义闭环"的核心结构
struct ParameterBinding: Identifiable, Hashable {
    /// 参数定义
    let parameter: TemplateParameter

    /// 运行时值（包含 rawValue 和 parsedValue）
    let value: TemplateValue

    // MARK: - Identifiable

    var id: String { parameter.key }

    // MARK: - Computed Properties

    /// 参数键名
    var key: String { parameter.key }

    /// 参数类型
    var type: ParameterType { parameter.type }

    /// 参数角色
    var role: ParameterRole? { parameter.role }

    /// 转义策略
    var escapeStrategy: EscapeStrategy { parameter.escapeStrategy }

    /// 是否必填
    var isRequired: Bool { parameter.isRequired }

    /// 原始值
    var rawValue: String { value.rawValue }

    /// 解析后的值（可选）
    var parsedValue: ParsedValue? { value.parsedValue }

    /// 验证结果
    var validationResult: ValidationResult { value.validationResult }

    /// 是否有效
    var isValid: Bool { value.isValid }

    /// 错误消息
    var errorMessage: String? { value.errorMessage }

    // MARK: - Value Access

    /// 获取用于渲染的字符串值
    /// 优先使用 parsedValue，fallback 到 rawValue
    var renderValue: String {
        parsedValue?.stringValue ?? rawValue
    }

    /// 是否有解析后的值
    var hasParsedValue: Bool {
        parsedValue != nil
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(rawValue)
    }

    static func == (lhs: ParameterBinding, rhs: ParameterBinding) -> Bool {
        lhs.key == rhs.key && lhs.rawValue == rhs.rawValue
    }
}

// MARK: - Template Binding

/// 模板绑定：将整个模板和所有参数值绑定在一起
struct TemplateBinding {
    /// 模板定义
    let template: Template

    /// 所有参数绑定
    let bindings: [ParameterBinding]

    // MARK: - Computed Properties

    /// 所有绑定是否有效
    var isValid: Bool {
        bindings.allSatisfy { $0.isValid }
    }

    /// 获取所有错误消息
    var errorMessages: [String] {
        bindings.compactMap { $0.errorMessage }
    }

    /// 通过 key 获取绑定
    func binding(for key: String) -> ParameterBinding? {
        bindings.first { $0.key == key }
    }

    /// 转换为值字典（用于 Renderer 兼容）
    var valueDict: TemplateValueDict {
        Dictionary(uniqueKeysWithValues: bindings.map { ($0.key, $0.value) })
    }
}

// MARK: - Factory

extension TemplateBinding {
    /// 从模板和值数组创建绑定
    /// - Parameters:
    ///   - template: 模板定义
    ///   - values: 运行时值数组
    /// - Returns: 模板绑定（所有值已验证并解析）
    static func bind(template: Template, values: [TemplateValue]) -> TemplateBinding {
        let valueDict = values.asDictionary

        let bindings = template.parameters.map { param -> ParameterBinding in
            // 获取对应的值，如果没有则使用默认值
            var value = valueDict[param.key] ?? TemplateValue(key: param.key, rawValue: param.defaultValue)

            // 验证并解析
            value = value.validated(with: param)

            return ParameterBinding(parameter: param, value: value)
        }

        return TemplateBinding(template: template, bindings: bindings)
    }
}
