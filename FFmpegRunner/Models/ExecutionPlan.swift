//
//  ExecutionPlan.swift
//

import Foundation

// MARK: - CommandExecutable

enum CommandExecutable: String, Codable, CaseIterable, Sendable {
    case ffmpeg
    case ffprobe

    var binaryName: String { rawValue }

    static func from(token: String) -> CommandExecutable? {
        let name = (token as NSString).lastPathComponent.lowercased()
        return CommandExecutable(rawValue: name)
    }

    static func stripExecutableIfPresent(
        from tokens: [String],
        defaultExecutable: CommandExecutable = .ffmpeg
    ) -> (executable: CommandExecutable, arguments: [String]) {
        guard let first = tokens.first,
              let executable = from(token: first) else {
            return (defaultExecutable, tokens)
        }

        return (executable, Array(tokens.dropFirst()))
    }
}

// MARK: - ExecutionPlan

struct ExecutionPlan: Equatable, Sendable {

    let executable: CommandExecutable
    let arguments: [String]
    let displayCommand: String
    let templateId: String?
    let templateName: String?
    let validatedBindings: [ParameterBinding]?
    let createdAt: Date

    // MARK: - Init（模板路径）

    init(
        arguments: [String],
        displayCommand: String,
        executable: CommandExecutable = .ffmpeg,
        templateId: String? = nil,
        templateName: String? = nil,
        validatedBindings: [ParameterBinding]? = nil,
        createdAt: Date = Date()
    ) {
        self.executable = executable
        self.arguments = arguments
        self.displayCommand = displayCommand
        self.templateId = templateId
        self.templateName = templateName
        self.validatedBindings = validatedBindings
        self.createdAt = createdAt
    }

    // MARK: - Init（原始命令字符串）

    /// - Parameter command: 完整命令字符串，首 token 须为 ffmpeg/ffprobe（含绝对路径）
    /// - Parameter fallbackExecutable: 当首 token 无法识别时使用；
    ///   **注意**：若首 token 能被识别，此参数被忽略——这是预期行为。
    ///   若需强制覆盖，请直接使用另一个 init。
    init(command: String, fallbackExecutable: CommandExecutable = .ffmpeg) throws {
        let tokens = try CommandRenderer.splitCommandStrict(command)
        let normalized = CommandExecutable.stripExecutableIfPresent(
            from: tokens,
            defaultExecutable: fallbackExecutable
        )
        self.executable = normalized.executable
        self.arguments = normalized.arguments
        self.displayCommand = command
        self.templateId = nil
        self.templateName = nil
        self.validatedBindings = nil
        self.createdAt = Date()
    }

    // MARK: - Computed

    var isFromTemplate: Bool { templateId != nil }

    var hasValidatedBindings: Bool {
        !(validatedBindings?.isEmpty ?? true)   // ✅ Opt: 简化 nil + empty 的双重判断
    }

    func fullArguments(executablePath: String) -> [String] {
        [executablePath] + arguments
    }
}

// MARK: - Equatable

extension ExecutionPlan {
    static func == (lhs: ExecutionPlan, rhs: ExecutionPlan) -> Bool {
        lhs.executable == rhs.executable &&
        lhs.arguments == rhs.arguments &&
        lhs.displayCommand == rhs.displayCommand &&
        lhs.templateId == rhs.templateId &&
        lhs.templateName == rhs.templateName &&
        lhs.validatedBindings == rhs.validatedBindings
        // 注：刻意排除 createdAt，两个内容相同但创建时间不同的 plan 视为相等
    }
}

// MARK: - Factory

extension ExecutionPlan {
    static func from(
        binding: TemplateBinding,
        renderedCommand: RenderedCommand
    ) -> ExecutionPlan {
        ExecutionPlan(
            arguments: renderedCommand.arguments,
            displayCommand: renderedCommand.displayString,
            executable: renderedCommand.executable,
            templateId: binding.template.id,
            templateName: binding.template.name,
            validatedBindings: binding.bindings
        )
    }
}
