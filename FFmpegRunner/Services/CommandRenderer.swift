//
//  CommandRenderer.swift
//  FFmpegRunner
//
//  命令渲染器 - 纯函数，无状态
//
//  设计说明：
//  - `renderToCommand()` 是主执行路径，直接生成参数数组，用于 Process.arguments
//  - `render()` 方法生成带 shell 转义的字符串，仅用于 UI 展示
//  - `splitCommand()` 仅用于导入/粘贴用户命令，不应用于 Template → Execute 主路径
//

import Foundation

/// 渲染后的命令
/// 同时包含用于执行的参数数组和用于显示的字符串
struct RenderedCommand {
    /// 用于 Process.arguments 的参数数组（不包含 ffmpeg 本身）
    let arguments: [String]

    /// 用于 UI 展示的命令字符串（带 shell 转义）
    let displayString: String

    /// 命令是否完整（所有占位符都已替换）
    var isComplete: Bool {
        CommandRenderer.isComplete(displayString)
    }

    /// 未替换的占位符
    var missingPlaceholders: [String] {
        CommandRenderer.getMissingPlaceholders(displayString)
    }
}

/// 命令渲染器
/// 负责将模板 + 参数值渲染为可执行命令
struct CommandRenderer {

    // MARK: - 占位符正则

    /// 匹配 {{key}} 格式的占位符
    private static let placeholderPattern = "\\{\\{([a-zA-Z_][a-zA-Z0-9_]*)\\}\\}"
    private static let placeholderRegex = try! NSRegularExpression(pattern: placeholderPattern)

    // MARK: - Public Methods

    /// 渲染命令
    /// - Parameters:
    ///   - template: 模板
    ///   - values: 参数值列表
    /// - Returns: 渲染后的命令字符串
    static func render(template: Template, values: [TemplateValue]) -> String {
        let valueDict = values.asDictionary

        // 创建跳过转义的 key 集合
        var skipEscapeKeys: Set<String> = []
        for param in template.parameters {
            if param.skipEscape == true {
                skipEscapeKeys.insert(param.key)
            }
        }

        return render(commandTemplate: template.commandTemplate, values: valueDict, skipEscapeKeys: skipEscapeKeys)
    }

    /// 渲染命令（使用字典）
    /// - Parameters:
    ///   - commandTemplate: 命令模板
    ///   - values: 参数值字典
    ///   - skipEscapeKeys: 不需要转义的参数 key 集合
    /// - Returns: 渲染后的命令字符串
    static func render(commandTemplate: String, values: TemplateValueDict, skipEscapeKeys: Set<String> = []) -> String {
        var result = commandTemplate

        let range = NSRange(commandTemplate.startIndex..., in: commandTemplate)
        let matches = placeholderRegex.matches(in: commandTemplate, range: range)

        // 倒序替换，避免位置偏移
        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: commandTemplate) else { continue }
            let key = String(commandTemplate[keyRange])

            // 获取值并替换
            let value = values[key]?.rawValue ?? ""
            let finalValue = skipEscapeKeys.contains(key) ? value : escapeForDisplay(value)

            if let fullRange = Range(match.range, in: result) {
                result.replaceSubrange(fullRange, with: finalValue)
            }
        }

        return result
    }

    /// 渲染命令（使用简单字典）
    /// - Parameters:
    ///   - commandTemplate: 命令模板
    ///   - values: 简单键值字典
    /// - Returns: 渲染后的命令字符串
    static func render(commandTemplate: String, simpleValues: [String: String]) -> String {
        var result = commandTemplate

        for (key, value) in simpleValues {
            let placeholder = "{{\(key)}}"
            let escapedValue = escapeForDisplay(value)
            result = result.replacingOccurrences(of: placeholder, with: escapedValue)
        }

        return result
    }

    // MARK: - Arguments-First Rendering (推荐执行路径)

    /// 渲染命令为 RenderedCommand（推荐用于执行）
    /// - Parameters:
    ///   - template: 模板
    ///   - values: 参数值列表
    /// - Returns: 包含参数数组和显示字符串的 RenderedCommand
    /// - Note: 这是执行命令的推荐路径，直接生成参数数组，避免 shell escaping 的不可逆问题
    static func renderToCommand(template: Template, values: [TemplateValue]) -> RenderedCommand {
        let valueDict = values.asDictionary

        // 创建跳过转义的 key 集合
        var skipEscapeKeys: Set<String> = []
        for param in template.parameters {
            if param.skipEscape == true {
                skipEscapeKeys.insert(param.key)
            }
        }

        // 生成用于显示的命令字符串（带 shell 转义）
        let displayString = render(commandTemplate: template.commandTemplate, values: valueDict, skipEscapeKeys: skipEscapeKeys)

        // 生成用于执行的参数数组（不经过 shell 转义）
        let arguments = renderArguments(commandTemplate: template.commandTemplate, values: valueDict)

        return RenderedCommand(arguments: arguments, displayString: displayString)
    }

    /// 渲染命令（使用 TemplateBinding，语义闭环路径）
    /// - Parameter binding: 模板绑定（包含已解析的 ParsedValue）
    /// - Returns: 包含参数数组和显示字符串的 RenderedCommand
    /// - Note: 这是"语义闭环"路径，优先消费 ParsedValue 而非 rawValue
    static func renderToCommand(binding: TemplateBinding) -> RenderedCommand {
        // 创建跳过转义的 key 集合
        var skipEscapeKeys: Set<String> = []
        for b in binding.bindings {
            if b.escapeStrategy == .raw {
                skipEscapeKeys.insert(b.key)
            }
        }

        // 生成用于显示的命令字符串（带 shell 转义）
        let displayString = renderWithBinding(
            commandTemplate: binding.template.commandTemplate,
            bindings: binding.bindings,
            skipEscapeKeys: skipEscapeKeys,
            forDisplay: true
        )

        // 生成用于执行的参数数组（不经过 shell 转义，使用 ParsedValue）
        let rawCommand = renderWithBinding(
            commandTemplate: binding.template.commandTemplate,
            bindings: binding.bindings,
            skipEscapeKeys: skipEscapeKeys,
            forDisplay: false
        )
        let arguments = splitCommand(rawCommand)

        // 移除 ffmpeg 本身（如果存在）
        if let first = arguments.first, first == "ffmpeg" || first.hasSuffix("ffmpeg") {
            return RenderedCommand(arguments: Array(arguments.dropFirst()), displayString: displayString)
        }

        return RenderedCommand(arguments: arguments, displayString: displayString)
    }

    /// 使用 ParameterBinding 渲染命令模板
    private static func renderWithBinding(
        commandTemplate: String,
        bindings: [ParameterBinding],
        skipEscapeKeys: Set<String>,
        forDisplay: Bool
    ) -> String {
        var result = commandTemplate
        let bindingDict = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key, $0) })

        let range = NSRange(commandTemplate.startIndex..., in: commandTemplate)
        let matches = placeholderRegex.matches(in: commandTemplate, range: range)

        // 倒序替换，避免位置偏移
        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: commandTemplate) else { continue }
            let key = String(commandTemplate[keyRange])

            // 优先使用 renderValue（来自 ParsedValue）
            let value = bindingDict[key]?.renderValue ?? ""
            let finalValue: String

            if forDisplay && !skipEscapeKeys.contains(key) {
                finalValue = escapeForDisplay(value)
            } else {
                finalValue = value
            }

            if let fullRange = Range(match.range, in: result) {
                result.replaceSubrange(fullRange, with: finalValue)
            }
        }

        return result
    }

    /// 渲染命令为参数数组（内部方法）
    /// - Parameters:
    ///   - commandTemplate: 命令模板
    ///   - values: 参数值字典
    /// - Returns: 参数数组（不包含 ffmpeg 本身）
    private static func renderArguments(commandTemplate: String, values: TemplateValueDict) -> [String] {
        var result = commandTemplate

        let range = NSRange(commandTemplate.startIndex..., in: commandTemplate)
        let matches = placeholderRegex.matches(in: commandTemplate, range: range)

        // 倒序替换，避免位置偏移
        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: commandTemplate) else { continue }
            let key = String(commandTemplate[keyRange])

            // 获取值并直接替换（不做 shell 转义）
            let value = values[key]?.rawValue ?? ""

            if let fullRange = Range(match.range, in: result) {
                result.replaceSubrange(fullRange, with: value)
            }
        }

        // 使用 splitCommand 将结果分割为参数数组
        let args = splitCommand(result)

        // 移除 ffmpeg 本身（如果存在）
        if let first = args.first, first == "ffmpeg" || first.hasSuffix("ffmpeg") {
            return Array(args.dropFirst())
        }

        return args
    }

    // MARK: - Validation

    /// 检查命令是否完整（所有占位符都已替换）
    static func isComplete(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return placeholderRegex.firstMatch(in: command, range: range) == nil
    }

    /// 获取未替换的占位符
    static func getMissingPlaceholders(_ command: String) -> [String] {
        let range = NSRange(command.startIndex..., in: command)
        let matches = placeholderRegex.matches(in: command, range: range)

        return matches.compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: command) else { return nil }
            return String(command[keyRange])
        }
    }

    /// 提取模板中的所有占位符
    static func extractPlaceholders(from template: String) -> [String] {
        getMissingPlaceholders(template)
    }

    // MARK: - Display Escaping

    /// 为 UI 显示转义值（仅用于显示，不用于执行）
    /// - Note: 此方法生成的字符串仅供 UI 展示，看起来像 shell 命令。
    ///         实际执行时应使用 renderToCommand() 返回的 arguments 数组。
    private static func escapeForDisplay(_ value: String) -> String {
        // 如果值包含空格或特殊字符，需要用引号包裹
        let needsQuoting = value.contains(" ") ||
                          value.contains("\"") ||
                          value.contains("'") ||
                          value.contains("$") ||
                          value.contains("`") ||
                          value.contains("\\") ||
                          value.contains("(") ||
                          value.contains(")")

        if needsQuoting {
            // 使用单引号包裹，并转义单引号
            let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }

        return value
    }

    /// 将命令分割为参数数组
    /// - Note: ⚠️ 此方法仅应用于以下场景：
    ///   1. 用户粘贴/导入的手动命令
    ///   2. 从历史记录恢复命令
    ///   3. Legacy command 兼容
    ///
    ///   对于 Template → Execute 的主路径，请使用 `renderToCommand()` 方法，
    ///   它会直接生成正确的参数数组，避免 shell escaping 的不可逆问题。
    static func splitCommand(_ command: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escapeNext = false

        for char in command {
            if escapeNext {
                // 处理行继续符：反斜杠后跟换行符，应忽略（连接两行）
                if char == "\n" || char == "\r" {
                    escapeNext = false
                    continue
                }

                current.append(char)
                escapeNext = false
                continue
            }

            switch char {
            case "\\":
                if inSingleQuote {
                    current.append(char)
                } else {
                    escapeNext = true
                }

            case "'":
                if inDoubleQuote {
                    current.append(char)
                } else {
                    inSingleQuote.toggle()
                }

            case "\"":
                if inSingleQuote {
                    current.append(char)
                } else {
                    inDoubleQuote.toggle()
                }

            // 将换行符和制表符也视为分隔符
            case " ", "\t", "\n", "\r":
                if inSingleQuote || inDoubleQuote {
                    current.append(char)
                } else if !current.isEmpty {
                    args.append(current)
                    current = ""
                }

            default:
                current.append(char)
            }
        }

        if !current.isEmpty {
            args.append(current)
        }

        return args
    }
}
