//
//  TemplateParameter.swift
//  FFmpegRunner
//
//  参数定义 - 描述一个 UI 控件及其 CLI 语义
//
//  设计说明：
//  - 此模型描述"模板参数"的 UI + 基础校验
//  - 不直接等价于 FFmpeg CLI 参数语义，而是提供语义提示
//  - `role` 字段用于标识参数在命令中的语义角色
//  - `escapeStrategy` 用于控制渲染时的转义策略
//

import Foundation

// MARK: - Parameter Type

/// 模板参数类型（UI 控件类型）
enum ParameterType: String, Codable, CaseIterable {
    /// 文本输入
    case string
    /// 数字输入
    case number
    /// 布尔开关
    case boolean
    /// 文件选择器
    case file
    /// 下拉选择
    case select
}

// MARK: - Parameter Role

/// 参数在命令中的语义角色
/// 用于标识参数如何映射到 CLI token
enum ParameterRole: String, Codable {
    /// 位置参数（如 input/output 文件）
    case positional
    /// 布尔 flag（如 -y）
    case flag
    /// flag + value 组合（如 -crf 23）
    case flagValue
    /// 原始命令文本，不做任何处理
    case raw
}

// MARK: - Escape Strategy

/// 参数值的转义策略
/// 控制渲染器如何处理参数值
enum EscapeStrategy: String, Codable {
    /// Shell 转义（默认行为）
    case shell
    /// 不转义（用于 raw command）
    case raw
}

// MARK: - UI Hint

/// 参数 UI 显示提示
/// 控制参数在 UI 中的展示方式
struct ParameterUIHint: Codable, Hashable {
    /// 是否多行输入
    var multiline: Bool = false

    /// 是否等宽字体
    var monospace: Bool = false

    /// 占位符文本
    var placeholder: String? = nil

    init(
        multiline: Bool = false,
        monospace: Bool = false,
        placeholder: String? = nil
    ) {
        self.multiline = multiline
        self.monospace = monospace
        self.placeholder = placeholder
    }
}

// MARK: - Template Parameter

/// 模板参数定义
/// 决定了 UI 该生成什么类型的控件，以及该参数在命令中的语义角色
struct TemplateParameter: Codable, Identifiable, Hashable {
    /// 参数键名（对应占位符名）
    let key: String

    /// UI 显示标签
    let label: String

    /// 参数类型（UI 控件类型）
    let type: ParameterType

    /// 默认值（可选，默认为空字符串）
    var defaultValue: String = ""

    /// 是否必填（可选，默认为 false）
    var isRequired: Bool = false

    /// 约束条件
    var constraints: Constraints? = nil

    /// 参数语义角色（用于 CLI 生成）
    var role: ParameterRole? = nil

    /// 转义策略
    var escapeStrategy: EscapeStrategy = .shell

    /// UI 显示提示
    var uiHint: ParameterUIHint? = nil

    // MARK: - Legacy Properties (deprecated, use uiHint)

    /// 占位符文本（deprecated: use uiHint.placeholder）
    var placeholder: String? = nil

    /// 是否多行输入（deprecated: use uiHint.multiline）
    var multiline: Bool? = nil

    /// 是否等宽字体（deprecated: use uiHint.monospace）
    var monospace: Bool? = nil

    // MARK: - Identifiable

    var id: String { key }

    // MARK: - Computed Properties

    /// 获取有效的占位符（优先使用 uiHint）
    var effectivePlaceholder: String? {
        uiHint?.placeholder ?? placeholder
    }

    /// 获取有效的多行设置（优先使用 uiHint）
    var effectiveMultiline: Bool {
        uiHint?.multiline ?? multiline ?? false
    }

    /// 获取有效的等宽设置（优先使用 uiHint）
    var effectiveMonospace: Bool {
        uiHint?.monospace ?? monospace ?? false
    }

    /// 是否跳过转义（基于 escapeStrategy）
    var skipEscape: Bool {
        escapeStrategy == .raw
    }

    // MARK: - Custom Decoding

    enum CodingKeys: String, CodingKey {
        case key, label, type, defaultValue, placeholder, isRequired, constraints
        case multiline, monospace, role, escapeStrategy, uiHint
        // Legacy key for backward compatibility
        case skipEscape
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // 必需字段
        key = try container.decode(String.self, forKey: .key)
        label = try container.decode(String.self, forKey: .label)
        type = try container.decode(ParameterType.self, forKey: .type)

        // 可选字段（使用默认值）
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
        constraints = try container.decodeIfPresent(Constraints.self, forKey: .constraints)
        multiline = try container.decodeIfPresent(Bool.self, forKey: .multiline)
        monospace = try container.decodeIfPresent(Bool.self, forKey: .monospace)
        role = try container.decodeIfPresent(ParameterRole.self, forKey: .role)
        uiHint = try container.decodeIfPresent(ParameterUIHint.self, forKey: .uiHint)

        // EscapeStrategy: 优先读取 escapeStrategy，fallback 到 skipEscape
        if let strategy = try container.decodeIfPresent(EscapeStrategy.self, forKey: .escapeStrategy) {
            escapeStrategy = strategy
        } else if let skip = try container.decodeIfPresent(Bool.self, forKey: .skipEscape), skip {
            escapeStrategy = .raw
        } else {
            escapeStrategy = .shell
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(key, forKey: .key)
        try container.encode(label, forKey: .label)
        try container.encode(type, forKey: .type)
        try container.encode(defaultValue, forKey: .defaultValue)
        try container.encodeIfPresent(placeholder, forKey: .placeholder)
        try container.encode(isRequired, forKey: .isRequired)
        try container.encodeIfPresent(constraints, forKey: .constraints)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encode(escapeStrategy, forKey: .escapeStrategy)
        try container.encodeIfPresent(uiHint, forKey: .uiHint)
        try container.encodeIfPresent(multiline, forKey: .multiline)
        try container.encodeIfPresent(monospace, forKey: .monospace)
    }

    // MARK: - Memberwise Init (for code usage)

    init(
        key: String,
        label: String,
        type: ParameterType,
        defaultValue: String = "",
        placeholder: String? = nil,
        isRequired: Bool = false,
        constraints: Constraints? = nil,
        role: ParameterRole? = nil,
        escapeStrategy: EscapeStrategy = .shell,
        uiHint: ParameterUIHint? = nil,
        multiline: Bool? = nil,
        monospace: Bool? = nil
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.isRequired = isRequired
        self.constraints = constraints
        self.role = role
        self.escapeStrategy = escapeStrategy
        self.uiHint = uiHint
        self.multiline = multiline
        self.monospace = monospace
    }

    // MARK: - Constraints

    /// 参数约束条件
    struct Constraints: Codable, Hashable {
        /// 数字最小值
        let min: Double?

        /// 数字最大值
        let max: Double?

        /// 选项列表（用于 select 类型）
        let options: [String]?

        /// 允许的文件类型（用于 file 类型）
        let fileTypes: [String]?

        /// 是否为输出文件（用于 file 类型）
        let isOutputFile: Bool?

        init(
            min: Double? = nil,
            max: Double? = nil,
            options: [String]? = nil,
            fileTypes: [String]? = nil,
            isOutputFile: Bool? = nil
        ) {
            self.min = min
            self.max = max
            self.options = options
            self.fileTypes = fileTypes
            self.isOutputFile = isOutputFile
        }
    }
}

// MARK: - Validation Error

/// 验证错误类型
enum ValidationError: String, Codable {
    case empty
    case invalidNumber
    case outOfRange
    case invalidOption
    case fileNotFound
    case invalidFileType
}

/// 验证结果
enum ValidationResult: Equatable {
    case valid
    case invalid(code: ValidationError, message: String)

    // Legacy case for backward compatibility
    static func invalid(message: String) -> ValidationResult {
        .invalid(code: .empty, message: message)
    }

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .invalid(_, let message) = self { return message }
        return nil
    }

    var errorCode: ValidationError? {
        if case .invalid(let code, _) = self { return code }
        return nil
    }
}

// MARK: - Validation

extension TemplateParameter {
    /// 验证值是否有效
    func validate(_ value: String) -> ValidationResult {
        // 检查必填
        if isRequired && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalid(code: .empty, message: "\(label) 不能为空")
        }

        // 空值且非必填，视为有效
        if value.isEmpty && !isRequired {
            return .valid
        }

        // 根据类型验证
        switch type {
        case .number:
            guard let number = Double(value) else {
                return .invalid(code: .invalidNumber, message: "\(label) 必须是数字")
            }
            if let min = constraints?.min, number < min {
                return .invalid(code: .outOfRange, message: "\(label) 不能小于 \(Int(min))")
            }
            if let max = constraints?.max, number > max {
                return .invalid(code: .outOfRange, message: "\(label) 不能大于 \(Int(max))")
            }

        case .select:
            if let options = constraints?.options, !options.contains(value) {
                return .invalid(code: .invalidOption, message: "\(label) 的值无效")
            }

        case .file:
            if isRequired && !FileManager.default.fileExists(atPath: value) {
                // 输出文件不需要存在
                if constraints?.isOutputFile != true {
                    return .invalid(code: .fileNotFound, message: "文件不存在")
                }
            }

            // Check file extensions
            if let allowedTypes = constraints?.fileTypes, !allowedTypes.isEmpty, !value.isEmpty {
                let fileExtension = (value as NSString).pathExtension.lowercased()
                let allowedLowercased = allowedTypes.map { $0.lowercased() }

                if !allowedLowercased.contains(fileExtension) {
                    let typesString = allowedTypes.joined(separator: ", ")
                    return .invalid(code: .invalidFileType, message: "文件类型错误 (仅支持: \(typesString))")
                }
            }

        case .string, .boolean:
            break
        }

        return .valid
    }
}
