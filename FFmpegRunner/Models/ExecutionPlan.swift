//
//  ExecutionPlan.swift
//  FFmpegRunner
//
//  执行计划 - 语义闭环的核心结构
//
//  设计说明：
//  - 统一 command vs arguments 分裂问题
//  - 确保执行路径的单一入口
//  - 携带足够的上下文供追溯和调试
//

import Foundation

// MARK: - Command Executable

/// 允许执行的可执行文件类型
enum CommandExecutable: String, Codable, CaseIterable, Sendable {
    case ffmpeg
    case ffprobe

    /// 二进制文件名
    var binaryName: String { rawValue }

    /// 从命令首 token 解析可执行文件类型（支持绝对路径）
    static func from(token: String) -> CommandExecutable? {
        let executableName = (token as NSString).lastPathComponent.lowercased()
        return CommandExecutable(rawValue: executableName)
    }
}

// MARK: - Execution Plan

/// 执行计划：将模板渲染结果封装为可执行的语义完整单元
///
/// 这是"语义闭环"的关键结构，解决了以下问题：
/// - command vs arguments 分裂
/// - validate vs render 分裂
/// - history vs execution 分裂
struct ExecutionPlan: Equatable {

    /// 目标可执行文件（ffmpeg / ffprobe）
    let executable: CommandExecutable

    /// 执行参数数组（用于 Process.arguments，不包含 ffmpeg 本身）
    let arguments: [String]

    /// 显示命令（用于 UI/日志/历史记录）
    let displayCommand: String

    /// 来源模板 ID（可选，用于追溯）
    let templateId: String?

    /// 来源模板名称（可选，用于显示）
    let templateName: String?

    /// 已验证的参数绑定（可选，用于调试和审计）
    let validatedBindings: [ParameterBinding]?

    /// 创建时间
    let createdAt: Date

    // MARK: - Initialization

    /// 从参数数组创建（Template 路径）
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

    /// 从原始命令字符串创建（手动输入路径）
    /// - Parameters:
    ///   - command: 完整的命令字符串（包含 ffmpeg / ffprobe）
    ///   - executable: 可选兜底可执行文件类型（当首 token 无法识别时使用）
    /// - Throws: CommandSplitError 当命令存在未闭合引号或悬空转义
    init(command: String, executable fallbackExecutable: CommandExecutable? = nil) throws {
        let args = try CommandRenderer.splitCommandStrict(command)
        let detectedExecutable = args.first.flatMap(CommandExecutable.from(token:))

        self.executable = detectedExecutable ?? fallbackExecutable ?? .ffmpeg
        self.arguments = detectedExecutable == nil ? args : Array(args.dropFirst())
        self.displayCommand = command
        self.templateId = nil
        self.templateName = nil
        self.validatedBindings = nil
        self.createdAt = Date()
    }

    // MARK: - Computed Properties

    /// 是否来自模板
    var isFromTemplate: Bool {
        templateId != nil
    }

    /// 是否有验证的绑定信息
    var hasValidatedBindings: Bool {
        validatedBindings != nil && !(validatedBindings?.isEmpty ?? true)
    }

    /// 完整的执行命令（包含可执行文件路径）
    /// - Parameter executablePath: 可执行文件路径
    /// - Returns: 完整的参数数组
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
    }
}

// MARK: - Factory Methods

extension ExecutionPlan {

    /// 从模板绑定创建执行计划
    /// - Parameters:
    ///   - binding: 模板绑定（已验证）
    ///   - renderedCommand: 渲染后的命令结构
    /// - Returns: 执行计划
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
