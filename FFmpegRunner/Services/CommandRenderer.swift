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
struct RenderedCommand {
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
        let skipEscapeKeys = collectSkipEscapeKeys(from: template.parameters)
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
        let valueDict = values.asDictionary
        let skipEscapeKeys = collectSkipEscapeKeys(from: template.parameters)
        let rawCommandKeys = collectRawCommandKeys(from: template.parameters)
        let argumentModes = collectArgumentModes(from: template.parameters)
        let context = TemplateValueContext(
            values: valueDict,
            skipEscapeKeys: skipEscapeKeys,
            rawCommandKeys: rawCommandKeys,
            argumentModes: argumentModes
        )

        let missingPlaceholders = collectMissingPlaceholders(
            commandTemplate: template.commandTemplate,
            context: context
        )

        // UI 展示字符串（允许 shell escaping）
        let displayString = render(
            commandTemplate: template.commandTemplate,
            context: context,
            forDisplay: true
        )

        // ✅ 执行参数数组（arguments-first，不经过字符串拼接和转义）
        let arguments = renderArguments(
            commandTemplate: template.commandTemplate,
            context: context
        )

        return RenderedCommand(
            arguments: arguments,
            displayString: displayString,
            missingPlaceholders: missingPlaceholders
        )
    }

    /// 渲染命令（使用 TemplateBinding，语义闭环路径）
    /// - Parameter binding: 模板绑定（包含已解析的 ParsedValue）
    /// - Returns: 包含参数数组和显示字符串的 RenderedCommand
    /// - Note: 这是"语义闭环"路径，优先消费 ParsedValue 而非 rawValue
    static func renderToCommand(binding: TemplateBinding) -> RenderedCommand {
        let skipEscapeKeys = collectSkipEscapeKeysFromBindings(binding.bindings)
        let rawCommandKeys = collectRawCommandKeysFromBindings(binding.bindings)
        let context = ParameterBindingContext(
            bindings: binding.bindings,
            skipEscapeKeys: skipEscapeKeys,
            rawCommandKeys: rawCommandKeys
        )

        let missingPlaceholders = collectMissingPlaceholders(
            commandTemplate: binding.template.commandTemplate,
            context: context
        )

        // UI 展示字符串（允许 shell escaping）
        let displayString = render(
            commandTemplate: binding.template.commandTemplate,
            context: context,
            forDisplay: true
        )

        // ✅ 执行参数数组（arguments-first，使用 ParsedValue）
        let arguments = renderArguments(
            commandTemplate: binding.template.commandTemplate,
            context: context
        )

        return RenderedCommand(
            arguments: arguments,
            displayString: displayString,
            missingPlaceholders: missingPlaceholders
        )
    }

    // MARK: - Arguments Builder (Execution-Only)

    /// 直接生成参数数组的核心函数（执行路径）
    /// - Parameters:
    ///   - commandTemplate: 命令模板
    ///   - context: 渲染上下文
    /// - Returns: 参数数组（不包含 ffmpeg 本身）
    /// - Note: 🔥 关键设计：
    ///   - 不生成字符串，不做 shell escaping
    ///   - 模板中的静态文本按空白拆分
    ///   - 占位符 {{key}} 的值直接成为一个完整的 argument
    ///   - 这从根本上解决了特殊字符（中文、空格、?、emoji）导致的问题
    private static func renderArguments(
        commandTemplate: String,
        context: RenderContext
    ) -> [String] {
        var args: [String] = []
        var currentIndex = commandTemplate.startIndex

        // 当前正在构建的参数缓冲区（用于处理 inline 模式）
        var currentTokenBuffer = ""

        // 提交当前缓冲区为一个 argument
        func flushBuffer() {
            if !currentTokenBuffer.isEmpty {
                args.append(currentTokenBuffer)
                currentTokenBuffer = ""
            }
        }

        let range = NSRange(commandTemplate.startIndex..., in: commandTemplate)
        let matches = placeholderRegex.matches(in: commandTemplate, range: range)

        /// 处理静态文本片段
        func handleStatic(_ text: Substring) {
            let staticText = String(text)

            // 如果缓冲区不为空（说明之前有 inline 参数），静态文本紧接在后面
            // 需要判断是否包含空白符来决定是否截断 buffer
            if !currentTokenBuffer.isEmpty {
                // 只要包含空白符，Buffer 必须截断（Argument 结束）
                // 但要注意：如果 staticText 以非空白开头，它应该拼接到 Buffer 上吗？
                // 策略：splitCommand 会处理空白，我们先用 splitCommand 拆

                let parts = splitCommand(staticText) // 这里的 splitCommand 实现会处理引号

                if let firstPart = parts.first {
                     // 检查 staticText 开头是否有空白
                    let hasLeadingWhitespace = staticText.first?.isWhitespace ?? false

                    if hasLeadingWhitespace {
                         // 有空白 -> Buffer 结束
                        flushBuffer()
                        args.append(contentsOf: parts)
                    } else {
                         // 无空白 -> 紧接 Buffer
                        currentTokenBuffer += firstPart
                        if parts.count > 1 {
                             flushBuffer()
                             args.append(contentsOf: parts.dropFirst())
                        }
                    }
                } else if !staticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                     // 只有空白符的情况（splitCommand 返回空但 raw 不空 -> 全是空白）
                     flushBuffer()
                }
            } else {
                 // 缓冲区为空，直接拆分
                let parts = splitCommand(staticText)
                if !parts.isEmpty {
                     // 如果最后一个 part 是不完整的（比如 "scale="）?
                     // splitCommand 目前是完整拆分。
                     // 关键点：我们无法知道 "scale=" 是否应该是 buffer 的开始。
                     // 假设：如果 staticText 末尾没有空白，且下一个是 inline 占位符，那么最后一个 part 应该进入 Buffer。

                     // 我们需要知道"后面紧跟着什么"。
                     // 但在这里我们只处理 static。

                     // 简化策略：
                     // 既然我们正在引入 inline 模式，那么模板编写者应该注意。
                     // 任何静态文本，如果是 splitCommand 拆出来的，除了最后一个元素外，都肯定是完整的 args。
                     // 最后一个元素，如果 staticText 末尾没有空白，则进入 Buffer。

                    let hasTrailingWhitespace = staticText.last?.isWhitespace ?? false

                    if hasTrailingWhitespace {
                        args.append(contentsOf: parts)
                    } else {
                        // 将最后一个放入 buffer
                        if parts.count > 1 {
                            args.append(contentsOf: parts.dropLast())
                        }
                        if let last = parts.last {
                            currentTokenBuffer = last
                        }
                    }
                }
            }
        }

        for match in matches {
            guard
                let keyRange = Range(match.range(at: 1), in: commandTemplate),
                let fullRange = Range(match.range, in: commandTemplate)
            else { continue }

            // ① 占位符前的静态部分
            let staticPart = commandTemplate[currentIndex..<fullRange.lowerBound]
            if !staticPart.isEmpty {
                handleStatic(staticPart)
            }

            // ② 占位符本身
            let key = String(commandTemplate[keyRange])
            if let value = context.value(forKey: key), !value.isEmpty {
                let mode = context.argumentMode(forKey: key)
                let isRaw = context.isRawCommand(forKey: key)

                if isRaw {
                     // Raw command: 必须独立（或者我们允许 inline raw? 暂不建议）
                     flushBuffer()
                     let splitArgs = splitCommand(value)
                     args.append(contentsOf: splitArgs)
                } else {
                    switch mode {
                    case .inline:
                         // Inline: 追加到 Buffer
                        currentTokenBuffer += value
                    case .token:
                         // Token:
                         // 1. 先提交之前的 Buffer
                        flushBuffer()
                         // 2. 添加当前值为独立 Argument
                        args.append(value)
                    }
                }
            } else {
                 // 值为空的情况：
                 // 如果是 token 模式 -> 忽略
                 // 如果是 inline 模式 -> 相当于插入空字符串，Buffer 保持不变
            }

            currentIndex = fullRange.upperBound
        }

        // ③ 尾部静态文本
        let remaining = commandTemplate[currentIndex...]
        if !remaining.isEmpty {
            handleStatic(remaining)
        }

        // 最后提交 Buffer
        flushBuffer()

        return removeFFmpegIfNeeded(from: args)
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

    /// 从模板参数中收集需要跳过转义的 key
    private static func collectSkipEscapeKeys(from parameters: [TemplateParameter]) -> Set<String> {
        var skipEscapeKeys: Set<String> = []
        for param in parameters {
            if param.skipEscape == true {
                skipEscapeKeys.insert(param.key)
            }
        }
        return skipEscapeKeys
    }

    /// 从绑定中收集需要跳过转义的 key
    private static func collectSkipEscapeKeysFromBindings(_ bindings: [ParameterBinding]) -> Set<String> {
        var skipEscapeKeys: Set<String> = []
        for binding in bindings {
            if binding.escapeStrategy == .raw {
                skipEscapeKeys.insert(binding.key)
            }
        }
        return skipEscapeKeys
    }

    /// 从模板参数中收集"原始命令"类型的 key（role == .raw）
    private static func collectRawCommandKeys(from parameters: [TemplateParameter]) -> Set<String> {
        var rawCommandKeys: Set<String> = []
        for param in parameters {
            if param.role == .raw {
                rawCommandKeys.insert(param.key)
            }
        }
        return rawCommandKeys
    }

    /// 从模板参数中收集 ArgumentMode
    private static func collectArgumentModes(from parameters: [TemplateParameter]) -> [String: ArgumentMode] {
        var modes: [String: ArgumentMode] = [:]
        for param in parameters {
            modes[param.key] = param.argumentMode
        }
        return modes
    }

    /// 从绑定中收集"原始命令"类型的 key
    private static func collectRawCommandKeysFromBindings(_ bindings: [ParameterBinding]) -> Set<String> {
        var rawCommandKeys: Set<String> = []
        for binding in bindings {
            if binding.role == .raw {
                rawCommandKeys.insert(binding.key)
            }
        }
        return rawCommandKeys
    }

    /// 从参数数组中移除 ffmpeg 本身
    private static func removeFFmpegIfNeeded(from args: [String]) -> [String] {
        if let first = args.first, (first as NSString).lastPathComponent == "ffmpeg" {
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

    /// 收集缺失占位符（值为空或不存在）
    private static func collectMissingPlaceholders(
        commandTemplate: String,
        context: RenderContext
    ) -> [String] {
        let range = NSRange(commandTemplate.startIndex..., in: commandTemplate)
        let matches = placeholderRegex.matches(in: commandTemplate, range: range)

        var missing: [String] = []
        var seen: Set<String> = []

        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: commandTemplate) else { continue }
            let key = String(commandTemplate[keyRange])
            if seen.contains(key) { continue }
            seen.insert(key)

            let value = context.value(forKey: key) ?? ""
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missing.append(key)
            }
        }

        return missing
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
        // 空值特殊处理
        if value.isEmpty {
            return "''"
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

    /// 将命令分割为参数数组
    /// - Note: ⚠️ 仅用于导入/粘贴用户命令或 Legacy 兼容。不要在主执行路径使用。
    /// - Warning: 已软废弃，建议使用 renderToCommand()
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

        if inSingleQuote || inDoubleQuote {
             // ⚠️ 检测到未闭合引号
             // 在实际项目中，这里应该抛出错误或记录日志。
             // 为了保持行为兼容，暂且将剩余部分作为一个参数，但最好能通知调用者。
             // print("Warning: Unclosed quote detected in command: \(command)")
        }

        return args
    }
}
