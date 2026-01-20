//
//  CommandPlanner.swift
//  FFmpegRunner
//
//  Domain Layer - 命令规划器
//
//  设计说明：
//  - 这是"命令语义层"的核心
//  - 负责将"用户输入"转换为"可执行命令语义"
//  - 纯逻辑，无副作用，不持有状态
//  - ExecutionController 只调用此层，不直接操作 Template/Binding/Renderer
//

import Foundation

// MARK: - Command Planner Error

/// 命令规划错误
enum CommandPlannerError: LocalizedError {
    case validationFailed(String)
    case renderingFailed(String)
    case emptyCommand

    var errorDescription: String? {
        switch self {
        case .validationFailed(let message):
            return "验证失败: \(message)"
        case .renderingFailed(let message):
            return "渲染失败: \(message)"
        case .emptyCommand:
            return "命令为空"
        }
    }
}

// MARK: - Command Planner

/// 命令规划器
/// Domain Layer 的核心，负责命令语义处理
///
/// 职责：
/// - 模板 + 参数 → ExecutionPlan
/// - 原始命令 → ExecutionPlan
/// - 命令验证
/// - 渲染检查
///
/// 设计原则：
/// - 纯函数，无副作用
/// - 不持有状态
/// - 不依赖 Service 层
struct CommandPlanner {

    // MARK: - Template → ExecutionPlan

    /// 从模板和值创建执行计划
    /// - Parameters:
    ///   - template: 模板定义
    ///   - values: 参数值列表
    /// - Returns: 执行计划
    /// - Throws: CommandPlannerError 如果验证或渲染失败
    static func prepare(template: Template, values: [TemplateValue]) throws -> ExecutionPlan {
        // 1. 创建绑定并验证
        let binding = TemplateBinding.bind(template: template, values: values)

        // 2. 检查验证结果
        guard binding.isValid else {
            let errorMessages = binding.errorMessages.joined(separator: "; ")
            throw CommandPlannerError.validationFailed(errorMessages)
        }

        // 3. 渲染命令
        let renderedCommand = CommandRenderer.renderToCommand(binding: binding)

        // 4. 检查渲染结果
        guard renderedCommand.isComplete else {
            let missing = renderedCommand.missingPlaceholders.joined(separator: ", ")
            throw CommandPlannerError.renderingFailed("缺少参数: \(missing)")
        }

        // 5. 创建执行计划
        return ExecutionPlan.from(binding: binding, renderedCommand: renderedCommand)
    }

    /// 从模板绑定创建执行计划（已验证的绑定）
    /// - Parameter binding: 模板绑定
    /// - Returns: 执行计划
    /// - Throws: CommandPlannerError 如果验证或渲染失败
    static func prepare(binding: TemplateBinding) throws -> ExecutionPlan {
        // 检查验证结果
        guard binding.isValid else {
            let errorMessages = binding.errorMessages.joined(separator: "; ")
            throw CommandPlannerError.validationFailed(errorMessages)
        }

        // 渲染命令
        let renderedCommand = CommandRenderer.renderToCommand(binding: binding)

        // 检查渲染结果
        guard renderedCommand.isComplete else {
            let missing = renderedCommand.missingPlaceholders.joined(separator: ", ")
            throw CommandPlannerError.renderingFailed("缺少参数: \(missing)")
        }

        return ExecutionPlan.from(binding: binding, renderedCommand: renderedCommand)
    }

    // MARK: - Raw Command → ExecutionPlan

    /// 从原始命令创建执行计划
    /// - Parameter command: 原始命令字符串
    /// - Returns: 执行计划
    /// - Throws: CommandPlannerError 如果验证失败
    static func prepare(command: String) throws -> ExecutionPlan {
        // 1. 验证命令非空
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CommandPlannerError.emptyCommand
        }

        // 2. 验证命令安全性
        let validation = CommandValidator.validate(command)
        guard validation.isValid else {
            let error = validation.errorMessage ?? "命令验证失败"
            throw CommandPlannerError.validationFailed(error)
        }

        // 3. 创建执行计划
        return ExecutionPlan(command: command)
    }

    // MARK: - Validation Only

    /// 仅验证命令，不创建计划
    /// - Parameter command: 原始命令字符串
    /// - Returns: 验证结果
    static func validate(command: String) -> CommandValidationResult {
        CommandValidator.validate(command)
    }

    /// 验证模板参数是否有效
    /// - Parameters:
    ///   - template: 模板定义
    ///   - values: 参数值列表
    /// - Returns: 是否有效，以及错误消息列表
    static func validateTemplate(template: Template, values: [TemplateValue]) -> (isValid: Bool, errors: [String]) {
        let binding = TemplateBinding.bind(template: template, values: values)
        return (binding.isValid, binding.errorMessages)
    }

    // MARK: - Preview (Dry Run)

    /// 预览命令（不执行，仅渲染）
    /// - Parameters:
    ///   - template: 模板定义
    ///   - values: 参数值列表
    /// - Returns: 渲染后的命令结构
    static func preview(template: Template, values: [TemplateValue]) -> RenderedCommand {
        let binding = TemplateBinding.bind(template: template, values: values)
        return CommandRenderer.renderToCommand(binding: binding)
    }
}
