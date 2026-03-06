//
//  CommandPreviewViewModel.swift
//  FFmpegRunner
//
//  命令预览 ViewModel
//

import Combine
import Foundation
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
final class CommandPreviewViewModel: ObservableObject {

    // MARK: - Constants

    /// 自动换行的字符阈值
    private let autoWrapThreshold = 80

    // MARK: - Published Properties

    /// 当前渲染的命令（包含参数数组和显示字符串）
    @Published private(set) var currentCommand: RenderedCommand?

    /// 当前展示给 UI 的命令文本（根据显示模式格式化）
    @Published private(set) var previewText = ""

    /// 高亮后的命令（缓存，避免频繁重算）
    @Published private(set) var highlightedCommand = AttributedString("")

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
    @Published var displayMode: DisplayMode = .auto {
        didSet {
            rebuildPresentation()
        }
    }

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

    private var sourceCancellable: AnyCancellable?
    private let formatter = CommandPreviewFormatter()
    private let highlighter = CommandPreviewHighlighter()

    // MARK: - Initialization

    init(detailViewModel: TemplateDetailViewModel? = nil) {
        if let detailViewModel {
            bind(to: detailViewModel)
        }
    }

    deinit {
        sourceCancellable?.cancel()
    }

    // MARK: - Public Methods

    /// 绑定详情 ViewModel，后续预览由详情状态自动派生
    func bind(to detailViewModel: TemplateDetailViewModel) {
        sourceCancellable?.cancel()

        sourceCancellable = detailViewModel.$state
            .sink { [weak self, weak detailViewModel] _ in
                Task { @MainActor [weak self, weak detailViewModel] in
                    self?.refresh(state: detailViewModel?.state ?? .empty)
                }
            }

        refresh(state: detailViewModel.state)
    }

    /// 切换显示模式
    func toggleDisplayMode() {
        displayMode = displayMode.next
    }

    /// 复制命令到剪贴板
    func copyToClipboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(previewText, forType: .string)
        #endif
    }

    private func refresh(state: TemplateDetailState) {
        guard let binding = state.templateBinding else {
            clearPreview()
            return
        }

        currentCommand = CommandPlanner.preview(binding: binding)
        rebuildPresentation()
    }

    /// 重新计算展示文本和高亮（仅在命令或显示模式变化时触发）
    private func rebuildPresentation() {
        guard !renderedCommand.isEmpty else {
            previewText = ""
            highlightedCommand = AttributedString("")
            return
        }

        previewText = shouldWrap ? formatter.format(renderedCommand) : renderedCommand
        highlightedCommand = highlighter.highlight(previewText)
    }

    private func clearPreview() {
        currentCommand = nil
        previewText = ""
        highlightedCommand = AttributedString("")
    }
}

// MARK: - Formatting

private struct CommandPreviewFormatter {
    private let indentation = "       " // 7 空格，对齐 "ffmpeg "

    /// 格式化命令为多行显示（在选项前换行）
    func format(_ command: String) -> String {
        var formatted = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        let chars = Array(command)

        for index in chars.indices {
            let char = chars[index]

            if isEscaped {
                formatted.append(char)
                isEscaped = false
                continue
            }

            if char == "\\" {
                formatted.append(char)
                isEscaped = true
                continue
            }

            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                formatted.append(char)
                continue
            }

            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                formatted.append(char)
                continue
            }

            if char == " " && !inSingleQuote && !inDoubleQuote {
                let nextIndex = chars.index(after: index)
                if nextIndex < chars.endIndex && chars[nextIndex] == "-" {
                    formatted.append(" \\\n\(indentation)")
                    continue
                }
            }

            formatted.append(char)
        }

        return formatted
    }
}

// MARK: - Highlighting

private struct CommandPreviewHighlighter {
    private struct RegexPatterns {
        static let program = try? NSRegularExpression(pattern: "(?:^|\\n)\\s*(ffmpeg|ffprobe)", options: [])
        static let input = try? NSRegularExpression(pattern: "\\s(-i)(?:\\s|$)", options: [])
        static let filter = try? NSRegularExpression(pattern: "\\s(-(?:vf|af|filter_complex|filter:v|filter:a))(?:\\s|$)", options: [])
        static let codec = try? NSRegularExpression(pattern: "\\s(-(?:c:[va]|codec:[va]|b:[va]|crf|preset|profile:[va]|level|tune|pix_fmt|r|g|bf|refs))(?:\\s|$)", options: [])
        static let format = try? NSRegularExpression(pattern: "\\s(-(?:f|movflags|map|metadata|t|ss|to|shortest|y|n|nostdin))(?:\\s|$)", options: [])
        static let number = try? NSRegularExpression(pattern: "(?<=\\s|:)([0-9]+(?:x[0-9]+)?[kKmMgG]?)(?=\\s|$|\\\\)", options: [])
        static let quote = try? NSRegularExpression(pattern: "[\"'][^\"']*[\"']", options: [])
        static let placeholder = try? NSRegularExpression(pattern: "\\{\\{[^}]+\\}\\}", options: [])
    }

    func highlight(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.font = .system(size: 13, weight: .regular, design: .monospaced)
        attributed.foregroundColor = .white

        applyColor(to: &attributed, text: text, regex: RegexPatterns.program, color: Color(red: 0.8, green: 0.4, blue: 0.9), weight: .bold)
        applyColor(to: &attributed, text: text, regex: RegexPatterns.input, color: Color(red: 0.4, green: 0.85, blue: 0.85))
        applyColor(to: &attributed, text: text, regex: RegexPatterns.filter, color: Color(red: 0.4, green: 0.85, blue: 0.5))
        applyColor(to: &attributed, text: text, regex: RegexPatterns.codec, color: Color(red: 0.4, green: 0.6, blue: 1.0))
        applyColor(to: &attributed, text: text, regex: RegexPatterns.format, color: Color(red: 0.95, green: 0.8, blue: 0.3))
        applyColor(to: &attributed, text: text, regex: RegexPatterns.number, color: Color(red: 0.6, green: 0.8, blue: 1.0))
        applyColor(to: &attributed, text: text, regex: RegexPatterns.quote, color: Color(red: 1.0, green: 0.7, blue: 0.3))
        applyHighlight(to: &attributed, text: text, regex: RegexPatterns.placeholder, fgColor: .white, bgColor: Color(red: 0.9, green: 0.3, blue: 0.3))

        return attributed
    }

    private func applyColor(
        to attributed: inout AttributedString,
        text: String,
        regex: NSRegularExpression?,
        color: Color,
        weight: Font.Weight? = nil
    ) {
        guard let regex else { return }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)

        for match in matches.reversed() {
            let targetRangeIndex = match.numberOfRanges > 1 ? 1 : 0

            if let stringRange = Range(match.range(at: targetRangeIndex), in: text),
               let attributedRange = Range(stringRange, in: attributed) {
                attributed[attributedRange].foregroundColor = color
                if let weight {
                    attributed[attributedRange].font = .system(size: 13, weight: weight, design: .monospaced)
                }
            }
        }
    }

    private func applyHighlight(
        to attributed: inout AttributedString,
        text: String,
        regex: NSRegularExpression?,
        fgColor: Color,
        bgColor: Color
    ) {
        guard let regex else { return }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)

        for match in matches.reversed() {
            if let stringRange = Range(match.range, in: text),
               let attributedRange = Range(stringRange, in: attributed) {
                attributed[attributedRange].foregroundColor = fgColor
                attributed[attributedRange].backgroundColor = bgColor
            }
        }
    }
}

// MARK: - macOS Pasteboard

#if os(macOS)
import AppKit
#endif
