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

// MARK: - Split Errors

/// 命令分词错误（严格模式）
enum CommandSplitError: LocalizedError, Equatable {
    case unclosedSingleQuote
    case unclosedDoubleQuote
    case danglingEscape

    var errorDescription: String? {
        switch self {
        case .unclosedSingleQuote:
            return "命令包含未闭合的单引号"
        case .unclosedDoubleQuote:
            return "命令包含未闭合的双引号"
        case .danglingEscape:
            return "命令以反斜杠结尾，转义不完整"
        }
    }
}

// MARK: - Render Context Protocol

/// 渲染上下文协议
/// 统一不同值来源的渲染逻辑，消除重复代码
protocol RenderContext {
    /// 获取指定 key 的值
    /// - Parameter key: 参数键名
    /// - Returns: 参数值，如果不存在返回 nil
    func value(forKey key: String) -> String?

    /// 判断指定 key 是否需要跳过转义
    /// - Parameter key: 参数键名
    /// - Returns: 是否跳过转义
    func shouldSkipEscape(forKey key: String) -> Bool

    /// 判断指定 key 是否是“原始命令”类型（需要作为完整命令行拆分）
    /// - Parameter key: 参数键名
    /// - Returns: 是否是 raw command
    func isRawCommand(forKey key: String) -> Bool

    /// 获取指定 key 的拼接模式
    /// - Parameter key: 参数键名
    /// - Returns: 拼接模式（token/inline）
    func argumentMode(forKey key: String) -> ArgumentMode
}

// MARK: - Context Implementations

/// 基于 TemplateValueDict 的渲染上下文
struct TemplateValueContext: RenderContext {
    let values: TemplateValueDict
    let skipEscapeKeys: Set<String>
    let rawCommandKeys: Set<String>
    let argumentModes: [String: ArgumentMode]

    func value(forKey key: String) -> String? {
        values[key]?.rawValue
    }

    func shouldSkipEscape(forKey key: String) -> Bool {
        skipEscapeKeys.contains(key)
    }

    func isRawCommand(forKey key: String) -> Bool {
        rawCommandKeys.contains(key)
    }

    func argumentMode(forKey key: String) -> ArgumentMode {
        argumentModes[key] ?? .token // 默认是 token 模式
    }
}

/// 基于 ParameterBinding 的渲染上下文（语义闭环路径）
struct ParameterBindingContext: RenderContext {
    let bindingDict: [String: ParameterBinding]
    let skipEscapeKeys: Set<String>
    let rawCommandKeys: Set<String>

    init(bindings: [ParameterBinding], skipEscapeKeys: Set<String>, rawCommandKeys: Set<String>) {
        self.bindingDict = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key, $0) })
        self.skipEscapeKeys = skipEscapeKeys
        self.rawCommandKeys = rawCommandKeys
    }

    func value(forKey key: String) -> String? {
        // 优先使用 renderValue（来自 ParsedValue）
        bindingDict[key]?.renderValue
    }

    func shouldSkipEscape(forKey key: String) -> Bool {
        skipEscapeKeys.contains(key)
    }

    func isRawCommand(forKey key: String) -> Bool {
        rawCommandKeys.contains(key)
    }

    func argumentMode(forKey key: String) -> ArgumentMode {
        bindingDict[key]?.parameter.argumentMode ?? .token // 默认是 token 模式
    }
}

/// 基于简单字典的渲染上下文
struct SimpleValueContext: RenderContext {
    let values: [String: String]

    func value(forKey key: String) -> String? {
        values[key]
    }

    func shouldSkipEscape(forKey key: String) -> Bool {
        false // 简单字典始终需要转义
    }

    func isRawCommand(forKey key: String) -> Bool {
        false // 简单字典不支持 raw command
    }

    func argumentMode(forKey key: String) -> ArgumentMode {
        .token // 简单字典默认为 token 模式
    }
}

// MARK: - Rendered Command

/// 渲染后的命令
/// 同时包含用于执行的参数数组和用于显示的字符串
struct RenderedCommand: Sendable {
    /// 目标可执行文件（ffmpeg / ffprobe）
    let executable: CommandExecutable

    /// 用于 Process.arguments 的参数数组（不包含 ffmpeg 本身）
    let arguments: [String]

    /// 用于 UI 展示的命令字符串（带 shell 转义）
    let displayString: String

    /// 缺失的占位符（基于模板 + 值判断）
    let missingPlaceholders: [String]

    /// 命令是否完整（所有占位符都已替换）
    var isComplete: Bool {
        missingPlaceholders.isEmpty
    }
}

// MARK: - Command Renderer

/// 命令渲染器
/// 负责将模板 + 参数值渲染为可执行命令
struct CommandRenderer {

    // MARK: - 占位符正则

    /// 匹配 {{key}} 格式的占位符
    private static let placeholderPattern = "\\{\\{([a-zA-Z_][a-zA-Z0-9_]*)\\}\\}"
    private static let placeholderRegex = try! NSRegularExpression(pattern: placeholderPattern)

    // MARK: - Shell 元字符集

    /// 需要转义的 shell 元字符
    /// 包括：空白符、引号、变量替换、命令替换、重定向、管道、后台执行等
    private static let shellMetaCharacters = CharacterSet(charactersIn: " \t\n\r\"'`$\\(){}[]<>|;&!?*#~^")

    // MARK: - Public Methods

    /// 渲染命令
    /// - Parameters:
    ///   - template: 模板
    ///   - values: 参数值列表
    /// - Returns: 渲染后的命令字符串
    static func render(template: Template, values: [TemplateValue]) -> String {
        let valueDict = values.asDictionary
        let skipEscapeKeys = collectKeys(from: template.parameters, where: { $0.skipEscape == true }, key: \.key)
        let context = TemplateValueContext(values: valueDict, skipEscapeKeys: skipEscapeKeys, rawCommandKeys: [], argumentModes: [:])
        return render(commandTemplate: template.commandTemplate, context: context, forDisplay: true)
    }

    /// 渲染命令（使用字典）
    /// - Parameters:
    ///   - commandTemplate: 命令模板
    ///   - values: 参数值字典
    ///   - skipEscapeKeys: 不需要转义的参数 key 集合
    /// - Returns: 渲染后的命令字符串
    static func render(commandTemplate: String, values: TemplateValueDict, skipEscapeKeys: Set<String> = []) -> String {
        let context = TemplateValueContext(values: values, skipEscapeKeys: skipEscapeKeys, rawCommandKeys: [], argumentModes: [:])
        return render(commandTemplate: commandTemplate, context: context, forDisplay: true)
    }

    /// 渲染命令（使用简单字典）
    /// - Parameters:
    ///   - commandTemplate: 命令模板
    ///   - values: 简单键值字典
    /// - Returns: 渲染后的命令字符串
    static func render(commandTemplate: String, simpleValues: [String: String]) -> String {
        let context = SimpleValueContext(values: simpleValues)
        return render(commandTemplate: commandTemplate, context: context, forDisplay: true)
    }

    // MARK: - Arguments-First Rendering (推荐执行路径)

    /// 渲染命令为 RenderedCommand（推荐用于执行）
    /// - Parameters:
    ///   - template: 模板
    ///   - values: 参数值列表
    /// - Returns: 包含参数数组和显示字符串的 RenderedCommand
    /// - Note: 这是执行命令的推荐路径，直接生成参数数组，避免 shell escaping 的不可逆问题
    static func renderToCommand(template: Template, values: [TemplateValue]) -> RenderedCommand {
        let binding = TemplateBinding.bind(template: template, values: values)
        return renderToCommand(binding: binding)
    }

    /// 渲染命令（使用 TemplateBinding，语义闭环路径）
    /// - Parameter binding: 模板绑定（包含已解析的 ParsedValue）
    /// - Returns: 包含参数数组和显示字符串的 RenderedCommand
    /// - Note: 这是"语义闭环"路径，优先消费 ParsedValue 而非 rawValue
    static func renderToCommand(binding: TemplateBinding) -> RenderedCommand {
        let skipEscapeKeys = collectKeys(from: binding.bindings, where: { $0.escapeStrategy == .raw }, key: \.key)
        let rawCommandKeys = collectKeys(from: binding.bindings, where: { $0.role == .raw }, key: \.key)
        let context = ParameterBindingContext(
            bindings: binding.bindings,
            skipEscapeKeys: skipEscapeKeys,
            rawCommandKeys: rawCommandKeys
        )

        // ✅ 单次正则匹配，同时生成 arguments、displayString、missingPlaceholders
        return renderAll(commandTemplate: binding.template.commandTemplate, context: context)
    }

    // MARK: - Unified Render (Single-Pass)

    /// 统一渲染：单次正则匹配同时生成 arguments、displayString、missingPlaceholders
    /// - Parameters:
    ///   - commandTemplate: 命令模板
    ///   - context: 渲染上下文
    /// - Returns: RenderedCommand 包含所有渲染结果
    /// - Note: 🔥 性能优化：合并原来的 3 次正则匹配为 1 次
    private static func renderAll(
        commandTemplate: String,
        context: RenderContext
    ) -> RenderedCommand {
        let range = NSRange(commandTemplate.startIndex..., in: commandTemplate)
        let matches = placeholderRegex.matches(in: commandTemplate, range: range)

        var args: [String] = []
        var display = ""
        var missing: [String] = []
        var seenKeys: Set<String> = []
        var currentIndex = commandTemplate.startIndex
        var currentTokenBuffer = ""

        // 提交当前缓冲区为一个 argument
        func flushBuffer() {
            if !currentTokenBuffer.isEmpty {
                args.append(currentTokenBuffer)
                currentTokenBuffer = ""
            }
        }

        /// 处理静态文本片段（用于 arguments 路径）
        func handleStaticForArgs(_ text: Substring) {
            let staticText = String(text)
            if staticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 只有空白符：结束当前 buffer
                flushBuffer()
                return
            }

            // 使用简单空白分隔（不处理引号），适用于模板静态文本
            let parts = splitStaticText(staticText)

            if !currentTokenBuffer.isEmpty {
                let hasLeadingWhitespace = staticText.first?.isWhitespace ?? false
                if hasLeadingWhitespace {
                    flushBuffer()
                    args.append(contentsOf: parts)
                } else if let firstPart = parts.first {
                    currentTokenBuffer += firstPart
                    if parts.count > 1 {
                        flushBuffer()
                        args.append(contentsOf: parts.dropFirst())
                    }
                }
            } else {
                let hasTrailingWhitespace = staticText.last?.isWhitespace ?? false
                if hasTrailingWhitespace {
                    args.append(contentsOf: parts)
                } else if !parts.isEmpty {
                    if parts.count > 1 {
                        args.append(contentsOf: parts.dropLast())
                    }
                    if let last = parts.last {
                        currentTokenBuffer = last
                    }
                }
            }
        }

        for match in matches {
            guard
                let keyRange = Range(match.range(at: 1), in: commandTemplate),
                let fullRange = Range(match.range, in: commandTemplate)
            else { continue }

            let staticPart = commandTemplate[currentIndex..<fullRange.lowerBound]
            let key = String(commandTemplate[keyRange])
            let value = context.value(forKey: key) ?? ""
            let isEmpty = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            // ① Display 路径：追加静态文本
            display.append(contentsOf: staticPart)

            // ② Args 路径：处理静态文本
            if !staticPart.isEmpty {
                handleStaticForArgs(staticPart)
            }

            // ③ Missing 检查（去重）
            if seenKeys.insert(key).inserted && isEmpty {
                missing.append(key)
            }

            // ④ Display 路径：处理占位符值
            if isEmpty {
                // 空值保留原始占位符，与执行语义对齐
                display.append("{{\(key)}}")
            } else if !context.shouldSkipEscape(forKey: key) {
                display.append(escapeForDisplay(value))
            } else {
                display.append(value)
            }

            // ⑤ Args 路径：处理占位符值
            if !isEmpty {
                let mode = context.argumentMode(forKey: key)
                let isRaw = context.isRawCommand(forKey: key)

                if isRaw {
                    flushBuffer()
                    args.append(contentsOf: splitCommand(value))
                } else {
                    switch mode {
                    case .inline:
                        currentTokenBuffer += value
                    case .token:
                        flushBuffer()
                        args.append(value)
                    }
                }
            }

            currentIndex = fullRange.upperBound
        }

        // 尾部静态文本
        let remaining = commandTemplate[currentIndex...]
        display.append(contentsOf: remaining)
        if !remaining.isEmpty {
            handleStaticForArgs(remaining)
        }
        flushBuffer()

        let normalized = CommandExecutable.stripExecutableIfPresent(from: args)

        return RenderedCommand(
            executable: normalized.executable,
            arguments: normalized.arguments,
            displayString: display,
            missingPlaceholders: missing
        )
    }


    // MARK: - Core Render Logic (Display String Only)

    /// 统一的渲染核心逻辑（仅用于生成显示字符串）
    /// - Parameters:
    ///   - commandTemplate: 命令模板
    ///   - context: 渲染上下文
    ///   - forDisplay: 是否用于显示（true 则转义，false 则不转义）
    /// - Returns: 渲染后的字符串
    private static func render(
        commandTemplate: String,
        context: RenderContext,
        forDisplay: Bool
    ) -> String {
        let range = NSRange(commandTemplate.startIndex..., in: commandTemplate)
        let matches = placeholderRegex.matches(in: commandTemplate, range: range)

        // 使用正序构建，避免多次 replaceSubrange 的性能问题
        var result = ""
        var currentIndex = commandTemplate.startIndex

        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: commandTemplate),
                  let fullRange = Range(match.range, in: commandTemplate) else { continue }

            // 追加占位符前的文本
            result.append(contentsOf: commandTemplate[currentIndex..<fullRange.lowerBound])

            // 获取值并处理
            let key = String(commandTemplate[keyRange])
            let value = context.value(forKey: key) ?? ""

            // 根据模式决定是否转义
            let finalValue: String
            if forDisplay && !context.shouldSkipEscape(forKey: key) {
                finalValue = escapeForDisplay(value)
            } else {
                finalValue = value
            }

            result.append(finalValue)
            currentIndex = fullRange.upperBound
        }

        // 追加剩余文本
        result.append(contentsOf: commandTemplate[currentIndex...])
        return result
    }

    // MARK: - Helper Methods

    /// 通用的 key 收集方法（消除重复代码）
    /// - Parameters:
    ///   - items: 要筛选的元素数组
    ///   - predicate: 筛选条件
    ///   - keyPath: 提取 key 的路径
    /// - Returns: 符合条件的 key 集合
    private static func collectKeys<T>(
        from items: [T],
        where predicate: (T) -> Bool,
        key keyPath: KeyPath<T, String>
    ) -> Set<String> {
        Set(items.filter(predicate).map { $0[keyPath: keyPath] })
    }

    /// 从模板参数中收集 ArgumentMode
    private static func collectArgumentModes(from parameters: [TemplateParameter]) -> [String: ArgumentMode] {
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.key, $0.argumentMode) })
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
    ///
    /// 使用 POSIX 标准的单引号转义策略：
    /// - 空值返回 ''
    /// - 包含元字符的值用单引号包裹
    /// - 单引号内部的单引号转义为 '\''
    private static func escapeForDisplay(_ value: String) -> String {
        // 空值：不应该到达这里，调用方应该已经处理
        // 但作为防御性编程，返回空字符串而非 ''
        if value.isEmpty {
            return ""
        }

        // 检查是否需要转义
        // 使用 Unicode scalars 检查以正确处理所有字符
        let needsQuoting = value.unicodeScalars.contains { shellMetaCharacters.contains($0) }

        if needsQuoting {
            // 使用 POSIX 标准的单引号转义
            // 单引号内部的单引号转义为 '\''（结束引用、添加转义单引号、重新开始引用）
            let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }

        return value
    }

    /// 拆分静态模板文本（简单空白分隔，不处理引号）
    /// - Note: 用于模板静态文本，避免 splitCommand 的引号处理逻辑干扰
    private static func splitStaticText(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: true) { $0.isWhitespace }
            .map(String.init)
    }

    /// 将命令分割为参数数组（宽松模式）
    /// - Note: ⚠️ 仅用于导入/粘贴用户命令或 raw command 值。不要对模板静态文本使用。
    /// - Warning: 宽松模式会容错未闭合引号；规划/验证路径请使用 `splitCommandStrict()`
    static func splitCommand(_ command: String) -> [String] {
        (try? splitCommandInternal(command, strict: false)) ?? []
    }

    /// 将命令分割为参数数组（严格模式）
    /// - Throws: CommandSplitError 当命令存在未闭合引号或悬空转义
    static func splitCommandStrict(_ command: String) throws -> [String] {
        try splitCommandInternal(command, strict: true)
    }

    /// 统一分词实现（严格/宽松模式）
    private static func splitCommandInternal(_ command: String, strict: Bool) throws -> [String] {
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

        if strict {
            if inSingleQuote {
                throw CommandSplitError.unclosedSingleQuote
            }
            if inDoubleQuote {
                throw CommandSplitError.unclosedDoubleQuote
            }
            if escapeNext {
                throw CommandSplitError.danglingEscape
            }
        }

        return args
    }
}
