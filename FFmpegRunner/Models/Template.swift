//
//  Template.swift
//  FFmpegRunner
//
//  模板定义 - 描述一个 FFmpeg 命令的结构
//
//  设计说明：
//  - 这是整个 App 的"协议核心"，定义 UI 该生成什么控件
//  - commandTemplate 是"快速模板格式"（使用 {{param}} 占位符）
//  - 此格式专为简单命令设计，不保证支持复杂条件/结构化命令
//  - 未来如需支持高级模板（条件参数/filter_complex），将引入结构化命令模型
//

import Foundation

/// FFmpeg 命令模板
/// 这是整个 App 的"协议核心"，定义 UI 该生成什么控件
struct Template: Codable, Identifiable, Hashable {
    /// 唯一标识符
    let id: String

    /// Raw Command 模板 ID
    static let rawCommandId = "raw-command"

    /// 模板名称（显示在列表中）
    let name: String

    /// 模板描述
    let description: String

    /// 命令模板（带 {{param}} 占位符）
    /// 例如: "ffmpeg -i {{input}} -c:v libx264 -crf {{crf}} {{output}}"
    ///
    /// - Important: 这是 **Legacy/Display-Only** 格式，不是权威表示。
    ///
    /// - Warning: **不要依赖此字段做语义分析。**
    ///            它仅用于：
    ///            1. UI 展示（命令预览）
    ///            2. 快速模板导入
    ///            3. Legacy 兼容
    ///
    /// - Note: 未来的权威表示将是 `CommandNode` 结构化命令树。
    ///         渲染器应优先使用 `parameters` + `ParsedValue` 路径。
    @available(*, deprecated, message: "Use parameters + ParsedValue for execution path")
    let commandTemplate: String

    /// 参数定义列表
    let parameters: [TemplateParameter]

    /// 模板分类（可选）
    let category: String?

    /// 模板图标名称（SF Symbols）
    let icon: String?

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Template, rhs: Template) -> Bool {
        lhs.id == rhs.id
    }
}
