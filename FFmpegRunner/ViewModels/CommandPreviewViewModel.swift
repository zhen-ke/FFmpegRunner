//
//  CommandPreviewViewModel.swift
//  FFmpegRunner
//
//  命令预览 ViewModel
//

import Foundation
import Combine
import SwiftUI

/// 显示模式枚举
enum DisplayMode: CaseIterable {
    case auto      // 智能自动切换
    case wrap      // 强制换行
    case single    // 强制单行

    var next: DisplayMode {
        switch self {
        case .auto: return .wrap
        case .wrap: return .single
        case .single: return .auto
        }
    }

    var label: String {
        switch self {
        case .auto: return "自动"
        case .wrap: return "换行"
        case .single: return "单行"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .wrap: return "text.alignleft"
        case .single: return "arrow.right.to.line"
        }
    }
}

/// 命令预览 ViewModel
@MainActor
class CommandPreviewViewModel: ObservableObject {

    // MARK: - Constants

    /// 自动换行的字符阈值
    private let autoWrapThreshold = 80

    // MARK: - Published Properties

    /// 当前渲染的命令（包含参数数组和显示字符串）
    @Published private(set) var currentCommand: RenderedCommand?

    /// 渲染后的命令（用于 UI 显示）
    var renderedCommand: String {
        currentCommand?.displayString ?? ""
    }

    /// 命令是否完整（所有占位符已替换）
    var isComplete: Bool {
        currentCommand?.isComplete ?? false
    }

    /// 未替换的占位符
    var missingPlaceholders: [String] {
        currentCommand?.missingPlaceholders ?? []
    }

    /// 显示模式
    @Published var displayMode: DisplayMode = .auto

    /// 命令字符数
    var commandLength: Int {
        renderedCommand.count
    }

    /// 是否应该显示换行（根据模式和命令长度计算）
    var shouldWrap: Bool {
        switch displayMode {
        case .auto:
            return commandLength > autoWrapThreshold
        case .wrap:
            return true
        case .single:
            return false
        }
    }

    // 兼容旧代码
    var isMultiline: Bool {
        get { shouldWrap }
        set { displayMode = newValue ? .wrap : .single }
    }

    // MARK: - Properties

    // (Removed unused cancellables)

    // MARK: - Initialization

    init() {}

    // MARK: - Public Methods

    /// 更新命令预览
    func update(template: Template?, values: [TemplateValue]) {
        guard let template = template else {
            currentCommand = nil
            return
        }

        // 使用 arguments-first 路径渲染命令
        currentCommand = CommandRenderer.renderToCommand(template: template, values: values)
    }

    /// 从模板和详情 ViewModel 更新
    func update(from detailViewModel: TemplateDetailViewModel) {
        update(template: detailViewModel.template, values: detailViewModel.values)
    }

    /// 切换显示模式
    func toggleDisplayMode() {
        displayMode = displayMode.next
    }

    /// 复制命令到剪贴板
    func copyToClipboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        // 复制时根据当前显示状态决定是否多行
        let textToCopy = shouldWrap ? formatCommand(renderedCommand) : renderedCommand
        NSPasteboard.general.setString(textToCopy, forType: .string)
        #endif
    }

    /// 获取命令的高亮版本（用于显示）
    func highlightedCommand() -> AttributedString {
        let textToDisplay = shouldWrap ? formatCommand(renderedCommand) : renderedCommand
        var attributed = AttributedString(textToDisplay)

        // 基础样式
        attributed.font = .system(size: 13, weight: .regular, design: .monospaced)
        attributed.foregroundColor = .white

        // 1. 高亮程序名 (ffmpeg, ffprobe) - 紫色加粗
        applyColor(to: &attributed, regex: RegexPatterns.program, color: Color(red: 0.8, green: 0.4, blue: 0.9), weight: .bold)

        // 2. 高亮输入参数 (-i) - 青色
        applyColor(to: &attributed, regex: RegexPatterns.input, color: Color(red: 0.4, green: 0.85, blue: 0.85))

        // 3. 高亮滤镜参数 (-vf, -af, -filter_complex) - 绿色
        applyColor(to: &attributed, regex: RegexPatterns.filter, color: Color(red: 0.4, green: 0.85, blue: 0.5))

        // 4. 高亮编码参数 (-c:v, -c:a, -b:v, -b:a, -crf, -preset, -profile:v 等) - 蓝色
        applyColor(to: &attributed, regex: RegexPatterns.codec, color: Color(red: 0.4, green: 0.6, blue: 1.0))

        // 5. 高亮格式参数 (-f, -movflags, -map 等) - 黄色
        applyColor(to: &attributed, regex: RegexPatterns.format, color: Color(red: 0.95, green: 0.8, blue: 0.3))

        // 6. 高亮数值 (纯数字、分辨率如 1920x1080、比特率如 192k) - 浅蓝色
        applyColor(to: &attributed, regex: RegexPatterns.number, color: Color(red: 0.6, green: 0.8, blue: 1.0))

        // 7. 高亮引号内容 (文件路径等) - 橙色
        applyColor(to: &attributed, regex: RegexPatterns.quote, color: Color(red: 1.0, green: 0.7, blue: 0.3))

        // 8. 高亮未替换的占位符 - 红底白字
        applyHighlight(to: &attributed, regex: RegexPatterns.placeholder, fgColor: .white, bgColor: Color(red: 0.9, green: 0.3, blue: 0.3))

        return attributed
    }

    // MARK: - Private Helpers

    /// 格式化命令为多行显示（FFmpeg 语义换行）
    private func formatCommand(_ command: String) -> String {
        var formatted = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false
        var currentLineLength = 0
        let indentation = "       " // 8 空格缩进，对齐 "ffmpeg "

        let chars = Array(command)

        for i in 0..<chars.count {
            let char = chars[i]

            if isEscaped {
                formatted.append(char)
                currentLineLength += 1
                isEscaped = false
                continue
            }

            if char == "\\" {
                formatted.append(char)
                currentLineLength += 1
                isEscaped = true
                continue
            }

            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                formatted.append(char)
                currentLineLength += 1
                continue
            }

            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                formatted.append(char)
                currentLineLength += 1
                continue
            }

            // 检查是否是选项前的空格 (" -")，且不在引号内
            if char == " " && !inSingleQuote && !inDoubleQuote {
                // 检查下一个字符是否是 -
                if i + 1 < chars.count && chars[i+1] == "-" {
                    // 插入换行和缩进 (使用 Shell 续行符 \)
                    formatted.append(" \\\n\(indentation)")
                    currentLineLength = indentation.count
                    continue
                }
            }

            formatted.append(char)
            currentLineLength += 1
        }

        return formatted
    }

    // MARK: - Highlighting Helpers

    private struct RegexPatterns {
        static let program = try? NSRegularExpression(pattern: "(?:^|\\n)\\s*(ffmpeg|ffprobe)", options: [])
        static let input = try? NSRegularExpression(pattern: "\\s(-i)(?:\\s|$)", options: [])
        static let filter = try? NSRegularExpression(pattern: "\\s(-(?:vf|af|filter_complex|filter:v|filter:a))(?:\\s|$)", options: [])
        static let codec = try? NSRegularExpression(pattern: "\\s(-(?:c:[va]|codec:[va]|b:[va]|crf|preset|profile:[va]|level|tune|pix_fmt|r|g|bf|refs))(?:\\s|$)", options: [])
        static let format = try? NSRegularExpression(pattern: "\\s(-(?:f|movflags|map|metadata|t|ss|to|shortest|y|n|nostdin))(?:\\s|$)", options: [])
        static let number = try? NSRegularExpression(pattern: "(?<=\\s|:)([0-9]+(?:x[0-9]+)?[kKmMgG]?)(?=\\s|$|\\\\)", options: [])
        static let quote = try? NSRegularExpression(pattern: "[\"'][^\"']*[\"']", options: [])
        static let placeholder = try? NSRegularExpression(pattern: "\\{\\{[^}]+\\}\\}" , options: [])
    }

    private func applyColor(to attributed: inout AttributedString, regex: NSRegularExpression?, color: Color, weight: Font.Weight? = nil) {
        guard let regex = regex else { return }
        let string = String(attributed.characters)
        let nsRange = NSRange(string.startIndex..., in: string)
        let matches = regex.matches(in: string, options: [], range: nsRange)

        for match in matches.reversed() {
            // 如果有捕获组，取 range(at: 1)，否则取 range(at: 0)
            let targetRangeIdx = match.numberOfRanges > 1 ? 1 : 0

            if let stringRange = Range(match.range(at: targetRangeIdx), in: string),
               let attrRange = Range(stringRange, in: attributed) {
                attributed[attrRange].foregroundColor = color
                if let weight = weight {
                    attributed[attrRange].font = .system(size: 13, weight: weight, design: .monospaced)
                }
            }
        }
    }

    private func applyHighlight(to attributed: inout AttributedString, regex: NSRegularExpression?, fgColor: Color, bgColor: Color) {
        guard let regex = regex else { return }
        let string = String(attributed.characters)
        let nsRange = NSRange(string.startIndex..., in: string)
        let matches = regex.matches(in: string, range: nsRange)

        for match in matches.reversed() {
            if let stringRange = Range(match.range, in: string),
               let attrRange = Range(stringRange, in: attributed) {
                attributed[attrRange].foregroundColor = fgColor
                attributed[attrRange].backgroundColor = bgColor
            }
        }
    }
}

// MARK: - macOS Pasteboard

#if os(macOS)
import AppKit
#endif
