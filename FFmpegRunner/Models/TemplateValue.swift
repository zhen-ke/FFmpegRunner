//
//  TemplateValue.swift
//  FFmpegRunner
//
//  运行时参数值容器（Raw String 形式）
//
//  设计说明：
//  - 此模型用于存储参数的运行时值
//  - `rawValue` 是用户输入的原始字符串
//  - `parsedValue` 是解析后的类型安全值（可选）
//  - 后续可能完全迁移到 ParsedValue 体系
//

import Foundation

// MARK: - Parsed Value

/// 解析后的类型安全参数值
/// 用于类型安全的值传递和渲染
enum ParsedValue: Hashable {
    /// 字符串值
    case string(String)
    /// 数字值
    case number(Double)
    /// 布尔值
    case bool(Bool)
    /// 文件路径
    case file(URL)

    /// 转换为字符串表示
    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .file(let url): return url.path
        }
    }
}

// MARK: - Template Value

/// 参数当前值的容器
/// 注意：不要把"值"直接写进 Template
struct TemplateValue: Identifiable, Hashable {
    /// 参数键名
    let key: String

    /// 原始值（用户输入的字符串）
    var rawValue: String

    /// 解析后的类型安全值（可选）
    /// 由 validate + parse 流程填充
    var parsedValue: ParsedValue?

    /// 验证状态
    var validationResult: ValidationResult = .valid

    // MARK: - Identifiable

    var id: String { key }

    // MARK: - Computed Properties

    /// 值是否为空
    var isEmpty: Bool {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 值是否有效
    var isValid: Bool {
        validationResult.isValid
    }

    /// 错误消息
    var errorMessage: String? {
        validationResult.errorMessage
    }

    /// 错误代码
    var errorCode: ValidationError? {
        validationResult.errorCode
    }

    // MARK: - Deprecated Compatibility

    /// 当前值（deprecated: use rawValue）
    @available(*, deprecated, renamed: "rawValue")
    var currentValue: String {
        get { rawValue }
        set { rawValue = newValue }
    }
}

// MARK: - Hashable

extension TemplateValue {
    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(rawValue)
    }

    static func == (lhs: TemplateValue, rhs: TemplateValue) -> Bool {
        lhs.key == rhs.key && lhs.rawValue == rhs.rawValue
    }
}

// MARK: - Factory

extension TemplateValue {
    /// 从模板参数创建初始值
    static func from(parameter: TemplateParameter) -> TemplateValue {
        TemplateValue(
            key: parameter.key,
            rawValue: parameter.defaultValue
        )
    }

    /// 从模板创建所有参数的初始值
    static func from(template: Template) -> [TemplateValue] {
        template.parameters.map { from(parameter: $0) }
    }
}

// MARK: - Parsing

extension TemplateValue {
    /// 根据参数类型解析值
    /// - Parameter parameter: 对应的参数定义
    /// - Returns: 更新后的 TemplateValue（包含 parsedValue）
    func parsed(with parameter: TemplateParameter) -> TemplateValue {
        var result = self

        switch parameter.type {
        case .string:
            result.parsedValue = .string(rawValue)

        case .number:
            if let number = Double(rawValue) {
                result.parsedValue = .number(number)
            }

        case .boolean:
            let lowercased = rawValue.lowercased()
            result.parsedValue = .bool(lowercased == "true" || lowercased == "1" || lowercased == "yes")

        case .file:
            if !rawValue.isEmpty {
                result.parsedValue = .file(URL(fileURLWithPath: rawValue))
            }

        case .select:
            result.parsedValue = .string(rawValue)
        }

        return result
    }

    /// 验证并解析值
    /// - Parameter parameter: 对应的参数定义
    /// - Returns: 更新后的 TemplateValue（包含验证结果和 parsedValue）
    func validated(with parameter: TemplateParameter) -> TemplateValue {
        var result = self
        result.validationResult = parameter.validate(rawValue)

        // 如果验证通过，解析值
        if result.validationResult.isValid {
            result = result.parsed(with: parameter)
        }

        return result
    }
}

// MARK: - 值字典

/// 用于参数值的便捷访问
typealias TemplateValueDict = [String: TemplateValue]

extension Array where Element == TemplateValue {
    /// 转换为字典
    var asDictionary: TemplateValueDict {
        Dictionary(uniqueKeysWithValues: map { ($0.key, $0) })
    }

    /// 检查是否所有值都有效
    var allValid: Bool {
        allSatisfy { $0.isValid }
    }

    /// 获取所有错误消息
    var errorMessages: [String] {
        compactMap { $0.errorMessage }
    }
}
