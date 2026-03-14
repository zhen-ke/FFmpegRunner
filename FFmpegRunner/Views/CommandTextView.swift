//
//  CommandTextView.swift
//  FFmpegRunner
//
//  工业级命令输入视图 - 支持拖拽插入、插入按钮、路径检测
//
//  核心功能：
//  ① 拖拽文件 → 光标位置插入带引号路径（自动补空格）
//  ② 插入文件/目录按钮（-i 后高亮提示）
//  ③ 路径右键菜单（Reveal in Finder / Copy Path）
//  ④ 路径 hover 高亮
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers



// MARK: - String Extension (智能空格处理)

extension String {
    /// 智能包裹路径并添加必要空格
    /// - Parameters:
    ///   - range: 插入位置的范围 (NSRange, UTF-16 编码)
    ///   - text: 原始文本
    /// - Returns: 带有适当前后空格的字符串
    func withSmartSpacing(at range: NSRange, in text: String) -> String {
        var result = self

        // 将 NSRange (UTF-16) 转换为 Swift String.Index 范围
        guard let swiftRange = Range(range, in: text) else { return result }

        // 检查前一个字符，需要添加前导空格
        if swiftRange.lowerBound > text.startIndex {
            let prevChar = text[text.index(before: swiftRange.lowerBound)]
            if !prevChar.isWhitespace {
                result = " " + result
            }
        }

        // 检查后一个字符，需要添加后缀空格
        if swiftRange.upperBound < text.endIndex {
            let nextChar = text[swiftRange.upperBound]
            if !nextChar.isWhitespace {
                result = result + " "
            }
        }

        return result
    }
}
// MARK: - CommandTextView

/// 专业级命令输入视图（支持拖拽插入路径）
struct CommandTextView: View {
    @Binding var text: String
    var placeholder: String?

    /// Coordinator 引用（用于直接调用插入方法，避免 async closure 时序问题）
    @State private var coordinator: CommandTextViewRepresentable.Coordinator?
    /// coordinator 尚未就绪时暂存插入请求，避免首次点击丢失
    @State private var pendingInsertions: [String] = []

    /// 是否悬停或聚焦（显示工具入口）
    @State private var isHovering = false
    @State private var isFocused = false

    /// 是否正在拖拽文件到输入区域
    @State private var isDragging = false

    /// 是否应该高亮工具入口（-i 后缀检测）
    @State private var shouldHighlightMenu = false

    /// 光标选区（用于更精准的 -i 提示）
    @State private var selectionRange: NSRange = NSRange(location: 0, length: 0)

    /// 路径校验提示
    @State private var diagnostics: [CommandEditorDiagnostic] = []
    @State private var inlineCompletionSuffix = ""
    @State private var completionReplacementRange = NSRange(location: NSNotFound, length: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                // 主文本输入区域
                ZStack(alignment: .topLeading) {
                    CommandTextViewRepresentable(
                        text: $text,
                        coordinator: $coordinator,
                        isFocused: $isFocused,
                        isDragging: $isDragging,
                        selectionRange: $selectionRange,
                        inlineCompletionSuffix: inlineCompletionSuffix,
                        onRequestCompletion: { handleCompletionRequest() },
                        onInsertFile: { insertFile(isDirectory: false) },
                        onInsertDirectory: { insertFile(isDirectory: true) }
                    )
                    .frame(minHeight: 100)

                    // Placeholder
                    if text.isEmpty, let placeholder = placeholder {
                        Text(placeholder)
                            .foregroundColor(.secondary.opacity(0.5))
                            .font(.system(.body, design: .monospaced))
                            .padding(.top, 8)
                            .padding(.leading, 8)
                            .allowsHitTesting(false)
                    }
                }

                // 右下角插入按钮（仅在 hover / focus 时显示）
                if isHovering || isFocused {
                    CommandInsertButtons(
                        highlightFile: shouldHighlightMenu,
                        insertFile: { insertFile(isDirectory: false) },
                        insertDirectory: { insertFile(isDirectory: true) }
                    )
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isDragging ? Color.accentColor : Color.secondary.opacity(0.2),
                        lineWidth: isDragging ? 2 : 1
                    )
            )
            .animation(.easeInOut(duration: 0.15), value: isDragging)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }

            if !diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(diagnostics) { diagnostic in
                        Label(diagnostic.message, systemImage: diagnostic.severity.symbolName)
                            .font(.caption)
                            .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .onAppear {
            updateMenuHint(for: text, selection: selectionRange)
            flushPendingInsertionsIfPossible()
            refreshCompletionSuggestions()
        }
        .onChange(of: text) { newValue in
            updateMenuHint(for: newValue, selection: selectionRange)
            refreshCompletionSuggestions()
        }
        .onChange(of: selectionRange) { newRange in
            updateMenuHint(for: text, selection: newRange)
            refreshCompletionSuggestions()
        }
        .onChange(of: isFocused) { newValue in
            if !newValue {
                inlineCompletionSuffix = ""
            } else {
                refreshCompletionSuggestions()
            }
        }
        .task(id: coordinator != nil) {
            await MainActor.run {
                flushPendingInsertionsIfPossible()
            }
        }
        .task(id: text) {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            diagnostics = CommandEditorAssistant.diagnostics(for: text)
        }
    }

    // MARK: - Insert File Action

    private func insertFile(isDirectory: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = isDirectory
        panel.canChooseFiles = !isDirectory
        panel.canCreateDirectories = false
        panel.prompt = isDirectory ? "选择目录" : "选择文件"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                insertPathAtCursor(url.path)
            }
        }
    }

    private func insertPathAtCursor(_ path: String) {
        let escapedPath = path.shellQuotedPathForCommand
        pendingInsertions.append(escapedPath)
        flushPendingInsertionsIfPossible()
    }

    private func flushPendingInsertionsIfPossible() {
        guard let coordinator, !pendingInsertions.isEmpty else { return }
        let insertions = pendingInsertions
        pendingInsertions.removeAll(keepingCapacity: true)
        for insertion in insertions {
            coordinator.insertAtCursor(insertion)
        }
    }

    /// 检测是否在 -i 后（高亮按钮）
    private func updateMenuHint(for text: String, selection: NSRange) {
        guard selection.location != NSNotFound else {
            shouldHighlightMenu = false
            return
        }
        let caretUTF16Offset = min(max(selection.location, 0), text.utf16.count)
        let caretIndex = stringIndexForUTF16Offset(caretUTF16Offset, in: text)
        let prefix = text[..<caretIndex]
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsWithInputFlag = trimmed.hasSuffix("-i")

        withAnimation(.easeInOut(duration: 0.2)) {
            shouldHighlightMenu = endsWithInputFlag
        }
    }

    private func handleCompletionRequest() -> Bool {
        let result = currentCompletionContext(force: true)
        completionReplacementRange = result.range

        guard let suggestion = result.suggestion else {
            inlineCompletionSuffix = ""
            return false
        }

        applyCompletion(suggestion)
        return true
    }

    private func applyCompletion(_ suggestion: String) {
        guard completionReplacementRange.location != NSNotFound else { return }
        coordinator?.applyCompletion(suggestion, replacing: completionReplacementRange)
        inlineCompletionSuffix = ""
    }

    private func refreshCompletionSuggestions() {
        let result = currentCompletionContext(force: false)
        completionReplacementRange = result.range
        inlineCompletionSuffix = result.inlineSuffix
    }

    private func currentCompletionContext(force: Bool) -> (suggestion: String?, range: NSRange, inlineSuffix: String) {
        guard isFocused else {
            return (nil, NSRange(location: NSNotFound, length: 0), "")
        }

        let range = completionRange(in: text, selection: selectionRange)
        let partial = substring(in: text, range: range)
        let suggestions = CommandEditorAssistant.completions(
            for: text,
            selectedRange: selectionRange,
            partialRange: range
        )
        guard let suggestion = suggestions.first else {
            return (nil, range, "")
        }

        let isCursorAtTokenEnd = selectionRange.location != NSNotFound &&
            selectionRange.length == 0 &&
            selectionRange.location == range.location + range.length

        let shouldShowInline: Bool
        if partial.isEmpty {
            // 光标在空格后：直接展示完整建议作为 ghost text
            shouldShowInline = !force && isCursorAtTokenEnd
        } else {
            // 光标在已输入前缀中间/末尾：展示剩余部分
            shouldShowInline = !force &&
                isCursorAtTokenEnd &&
                suggestion.hasPrefix(partial) &&
                suggestion.count > partial.count
        }

        let inlineSuffix: String
        if shouldShowInline {
            inlineSuffix = partial.isEmpty
                ? suggestion                                    // 完整单词作为 ghost text
                : String(suggestion.dropFirst(partial.count))   // 剩余部分
        } else {
            inlineSuffix = ""
        }

        return (suggestion, range, inlineSuffix)
    }

    private func completionRange(in text: String, selection: NSRange) -> NSRange {
        guard selection.location != NSNotFound else {
            return NSRange(location: text.utf16.count, length: 0)
        }

        let nsText = text as NSString
        let length = nsText.length
        let cursor = min(max(selection.location, 0), length)

        var start = cursor
        while start > 0 {
            let scalar = UnicodeScalar(nsText.character(at: start - 1))
            guard let scalar,
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) else {
                break
            }
            start -= 1
        }

        var end = cursor
        while end < length {
            let scalar = UnicodeScalar(nsText.character(at: end))
            guard let scalar,
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) else {
                break
            }
            end += 1
        }

        return NSRange(location: start, length: end - start)
    }

    private func substring(in text: String, range: NSRange) -> String {
        guard let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }

    private func stringIndexForUTF16Offset(_ offset: Int, in text: String) -> String.Index {
        let clampedOffset = min(max(offset, 0), text.utf16.count)
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: clampedOffset)
        return String.Index(utf16Index, within: text) ?? text.endIndex
    }
}

// MARK: - Insert Buttons (右下角工具)

private struct CommandInsertButtons: View {
    var highlightFile: Bool = false
    let insertFile: () -> Void
    let insertDirectory: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: insertFile) {
                Label("插入文件", systemImage: "doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(highlightFile ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(highlightFile ? Color.accentColor.opacity(0.5) : Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .pointingHandCursor()
            .help(highlightFile ? "检测到 -i，建议插入输入文件" : "插入文件路径")

            Button(action: insertDirectory) {
                Label("插入目录", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .pointingHandCursor()
            .help("插入目录路径")
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - Cursor Helper

private extension View {
    func pointingHandCursor() -> some View {
        onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private extension String {
    var pathExtensionLowercased: String? {
        let ext = (self as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    /// 用于命令字符串展示/编辑：双引号包裹并转义内部反斜杠与双引号
    var shellQuotedPathForCommand: String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - NSViewRepresentable

struct CommandTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var coordinator: Coordinator?
    @Binding var isFocused: Bool
    @Binding var isDragging: Bool
    @Binding var selectionRange: NSRange
    var inlineCompletionSuffix: String
    var onRequestCompletion: (() -> Bool)?
    var onInsertFile: (() -> Void)?
    var onInsertDirectory: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = CommandNSTextView()
        textView.onDragStateChanged = { [self] dragging in
            DispatchQueue.main.async {
                self.isDragging = dragging
            }
        }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)

        // 启用自动换行
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )

        // 注册拖拽类型
        textView.registerForDraggedTypes([.fileURL])

        // 设置代理
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.inlineCompletionSuffix = inlineCompletionSuffix
        textView.onRequestCompletion = onRequestCompletion
        textView.onInsertFile = onInsertFile
        textView.onInsertDirectory = onInsertDirectory

        scrollView.documentView = textView

        // 同步设置 coordinator 引用（避免 async 时序问题）
        DispatchQueue.main.async {
            self.coordinator = context.coordinator
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // 仅在内容不同时更新，避免光标跳动
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            let clampedRange = clampedUTF16Range(selectedRange, for: text)
            textView.setSelectedRange(clampedRange)
            (textView as? CommandNSTextView)?.invalidatePathCacheExternally()
        }
        if let commandTextView = textView as? CommandNSTextView {
            commandTextView.inlineCompletionSuffix = inlineCompletionSuffix
            commandTextView.onRequestCompletion = onRequestCompletion
            commandTextView.onInsertFile = onInsertFile
            commandTextView.onInsertDirectory = onInsertDirectory
        }
    }

    private func clampedUTF16Range(_ range: NSRange, for text: String) -> NSRange {
        let maxLength = text.utf16.count
        guard range.location != NSNotFound else {
            return NSRange(location: maxLength, length: 0)
        }

        let location = min(max(range.location, 0), maxLength)
        let maxLengthAtLocation = max(0, maxLength - location)
        let length = min(max(range.length, 0), maxLengthAtLocation)
        return NSRange(location: location, length: length)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CommandTextViewRepresentable
        weak var textView: NSTextView?

        init(_ parent: CommandTextViewRepresentable) {
            self.parent = parent
            super.init()
        }

        // MARK: - Focus Tracking

        func textDidBeginEditing(_ notification: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = true
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CommandNSTextView else { return }
            // 主动失效路径缓存（避免 mouseMoved 中做 O(n) 字符串比较）
            textView.invalidatePathCacheExternally()
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            DispatchQueue.main.async {
                self.parent.selectionRange = textView.selectedRange()
            }
        }

        /// 在光标位置插入文本（带智能空格）
        func insertAtCursor(_ path: String) {
            guard let textView = textView else {
                #if DEBUG
                print("[CommandTextView] insertAtCursor: textView 已释放，跳过插入")
                #endif
                return
            }

            let range = textView.selectedRange()
            let textWithSpacing = path.withSmartSpacing(at: range, in: textView.string)

            textView.insertText(textWithSpacing, replacementRange: range)
            parent.text = textView.string
        }

        func applyCompletion(_ suggestion: String, replacing range: NSRange) {
            guard let textView = textView else { return }

            let nsText = textView.string as NSString
            let nextLocation = range.location + range.length
            let needsTrailingSpace: Bool
            if nextLocation >= nsText.length {
                needsTrailingSpace = true
            } else {
                let nextScalar = UnicodeScalar(nsText.character(at: nextLocation))
                needsTrailingSpace = nextScalar.map { !CharacterSet.whitespacesAndNewlines.contains($0) } ?? true
            }

            let replacement = needsTrailingSpace ? "\(suggestion) " : suggestion
            textView.insertText(replacement, replacementRange: range)
            parent.text = textView.string
        }
    }
}

// MARK: - Custom NSTextView with Drag Support

final class CommandNSTextView: NSTextView {
    var inlineCompletionSuffix = "" {
        didSet {
            if oldValue != inlineCompletionSuffix {
                setNeedsDisplay(bounds)
            }
        }
    }

    var onRequestCompletion: (() -> Bool)?

    var onInsertFile: (() -> Void)?
    var onInsertDirectory: (() -> Void)?

    /// 当前 hover 的路径范围（用于高亮）
    private var hoveredPathRange: NSRange?

    /// hover 高亮的背景颜色
    private let pathHighlightColor = NSColor.controlAccentColor.withAlphaComponent(0.1)

    /// 路径检测缓存（文本变化时失效）
    private var cachedPaths: [PathInfo] = []
    private var isPathCacheDirty = true

    /// 拖拽状态变化回调（通知 SwiftUI 层显示高亮边框）
    var onDragStateChanged: ((Bool) -> Void)?

    /// 拖拽过程中计算的插入字符索引（performDragOperation 使用）
    private var dragInsertionIndex: Int?

    /// 拖拽开始前的原始选区（用于取消拖拽时恢复）
    private var dragOriginalSelectionRange: NSRange?

    /// 当前拖拽是否已经执行了插入
    private var didPerformDragInsertion = false

    /// 自己管理的 tracking area（避免移除系统管理的）
    private var mouseTrackingArea: NSTrackingArea?

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // 只移除自己管理的 tracking area，不影响 NSTextView 系统管理的
        if let existing = mouseTrackingArea {
            removeTrackingArea(existing)
        }

        // 添加新的 tracking area
        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        // 1. 优先命中测试：如果鼠标当前不在本视图（或其子视图）上（例如在覆盖的按钮上），则直接返回
        // 这样可以避免 super.mouseMoved 设置 I-Beam 光标，覆盖上层 SwiftUI 视图手型光标
        if let window = self.window,
           let hitView = window.contentView?.hitTest(event.locationInWindow) {

            // 如果命中的视图不是自己且不是自己的子视图，说明是在更上层的视图上
            if hitView !== self && !hitView.isDescendant(of: self) {
                return
            }
        }

        super.mouseMoved(with: event)

        // 直接处理（不再节流，避免光标闪烁）
        handleMouseMove(with: event)
    }

    /// 鼠标移动处理
    private func handleMouseMove(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let pathInfo = detectPathInfoAt(point) {
            // 在路径上 → pointingHand + 高亮
            NSCursor.pointingHand.set()

            if hoveredPathRange != pathInfo.range {
                hoveredPathRange = pathInfo.range
                setNeedsDisplay(bounds)
            }
        } else {
            // 不在路径上 → 恢复默认
            NSCursor.iBeam.set()

            if hoveredPathRange != nil {
                hoveredPathRange = nil
                setNeedsDisplay(bounds)
            }
        }
    }

    // MARK: - Mouse Click

    override func mouseDown(with event: NSEvent) {
        // 双击路径时在 Finder 中显示
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if let pathInfo = detectPathInfoAt(point) {
                let expanded = (pathInfo.path as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expanded) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: expanded)]
                    )
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.iBeam.set()

        if hoveredPathRange != nil {
            hoveredPathRange = nil
            setNeedsDisplay(bounds)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 绘制路径高亮背景（在文字下层）
        if let range = hoveredPathRange, let layoutManager = layoutManager, let textContainer = textContainer {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textContainerInset.width
            rect.origin.y += textContainerInset.height

            pathHighlightColor.setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.fill()
        }

        super.draw(dirtyRect)

        drawInlineCompletionIfNeeded()
    }

    // MARK: - Keyboard Shortcuts

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 使用 ⌘O 插入文件，⌘⇧O 插入目录（避免与系统 ⌘I 冲突）
        if flags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased(),
           key == "o" {
            if flags.contains(.shift) {
                onInsertDirectory?()
            } else {
                onInsertFile?()
            }
            return
        }

        if flags.isEmpty, event.keyCode == 48, onRequestCompletion?() == true {
            return
        }

        super.keyDown(with: event)
    }

    private func drawInlineCompletionIfNeeded() {
        guard !inlineCompletionSuffix.isEmpty,
              let font,
              let rect = inlineCompletionRect() else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        NSAttributedString(string: inlineCompletionSuffix, attributes: attributes)
            .draw(at: rect.origin)
    }

    private func inlineCompletionRect() -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }

        let selection = selectedRange()
        guard selection.location != NSNotFound, selection.length == 0 else { return nil }

        let lineHeight = layoutManager.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular))

        if string.isEmpty {
            return NSRect(
                x: textContainerInset.width,
                y: textContainerInset.height,
                width: 0,
                height: lineHeight
            )
        }

        let maxCharacterIndex = string.utf16.count
        let characterIndex = min(selection.location, maxCharacterIndex)

        if characterIndex == 0 {
            return NSRect(
                x: textContainerInset.width,
                y: textContainerInset.height,
                width: 0,
                height: lineHeight
            )
        }

        let anchorIndex = min(characterIndex - 1, maxCharacterIndex - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: anchorIndex)
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height

        if characterIndex == maxCharacterIndex {
            rect.origin.x += rect.width
        }

        rect.size.width = 0
        rect.size.height = lineHeight
        return rect
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) {
            beginDragSessionIfNeeded()
            // 让 NSTextView 初始化内部拖拽状态（显示原生插入光标）
            let _ = super.draggingEntered(sender)
            updateDragInsertionPoint(with: sender)
            onDragStateChanged?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 调用 super 让 NSTextView 显示原生拖拽插入光标
        let _ = super.draggingUpdated(sender)

        // 实时更新插入位置并同步显示光标
        updateDragInsertionPoint(with: sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragStateChanged?(false)
        endDragSession(restoreSelection: true)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        onDragStateChanged?(false)
        guard dragOriginalSelectionRange != nil else { return }
        endDragSession(restoreSelection: !didPerformDragInsertion)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragStateChanged?(false)

        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            endDragSession(restoreSelection: true)
            return super.performDragOperation(sender)
        }

        // 使用拖拽过程中计算的插入位置，而非当前光标选区
        let insertionIndex: Int
        if let savedIndex = dragInsertionIndex {
            insertionIndex = savedIndex
        } else {
            // fallback: 从 drop 坐标重新计算
            let point = convert(sender.draggingLocation, from: nil)
            insertionIndex = getInsertionCharacterIndex(at: point)
        }
        dragInsertionIndex = nil

        let range = NSRange(location: insertionIndex, length: 0)

        // 拖拽文件：统一用引号包裹，不自动添加 -i（让用户自行组织）
        let escapedPaths = urls.map { $0.path.shellQuotedPathForCommand }.joined(separator: " ")

        let textWithSpacing = escapedPaths.withSmartSpacing(at: range, in: string)

        // 在拖拽位置插入
        insertText(textWithSpacing, replacementRange: range)
        didPerformDragInsertion = true

        // 将光标放到插入内容末尾，保持后续输入连续
        let insertedUTF16Length = (textWithSpacing as NSString).length
        let caretLocation = min(range.location + insertedUTF16Length, string.utf16.count)
        setSelectedRange(NSRange(location: caretLocation, length: 0))
        scrollRangeToVisible(NSRange(location: caretLocation, length: 0))
        endDragSession(restoreSelection: false)

        return true
    }

    /// 获取插入位置的字符索引
    ///
    /// 使用 `characterIndex(for:in:fractionOfDistanceBetweenInsertionPoints:)` 代替
    /// `glyphIndex(for:in:)` + `characterIndexForGlyph(at:)` 来获取准确的插入边界位置。
    /// 前者会根据鼠标在字符左半/右半来决定返回该字符还是下一个字符的索引，
    /// 后者只返回最近的 glyph 索引，不区分字符边界。
    func getInsertionCharacterIndex(at point: NSPoint) -> Int {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return string.utf16.count
        }

        // 调整坐标以考虑文本容器的边距
        var adjustedPoint = point
        adjustedPoint.x -= textContainerInset.width
        adjustedPoint.y -= textContainerInset.height

        // 使用 fractionOfDistanceBetweenInsertionPoints 精确判断插入点
        var fraction: CGFloat = 0
        let characterIndex = layoutManager.characterIndex(
            for: adjustedPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )

        // fraction > 0.5 表示鼠标在字符的右半部分，应插入到下一个字符位置
        let insertionIndex = fraction > 0.5 ? characterIndex + 1 : characterIndex

        return min(insertionIndex, string.utf16.count)
    }

    private func beginDragSessionIfNeeded() {
        if dragOriginalSelectionRange == nil {
            dragOriginalSelectionRange = selectedRange()
        }
        didPerformDragInsertion = false
        window?.makeFirstResponder(self)
    }

    private func updateDragInsertionPoint(with sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        let insertionIndex = getInsertionCharacterIndex(at: point)
        dragInsertionIndex = insertionIndex

        let insertionRange = NSRange(location: insertionIndex, length: 0)
        if !NSEqualRanges(selectedRange(), insertionRange) {
            setSelectedRange(insertionRange)
            scrollRangeToVisible(insertionRange)
        }
    }

    private func endDragSession(restoreSelection: Bool) {
        if restoreSelection, let originalRange = dragOriginalSelectionRange {
            let clampedRange = clamp(range: originalRange, maxUTF16Length: string.utf16.count)
            setSelectedRange(clampedRange)
            scrollRangeToVisible(clampedRange)
        }
        dragOriginalSelectionRange = nil
        dragInsertionIndex = nil
        didPerformDragInsertion = false
    }

    private func clamp(range: NSRange, maxUTF16Length: Int) -> NSRange {
        let location = min(max(range.location, 0), maxUTF16Length)
        let maxLengthAtLocation = max(0, maxUTF16Length - location)
        let length = min(max(range.length, 0), maxLengthAtLocation)
        return NSRange(location: location, length: length)
    }


    // MARK: - Path Cache Management

    /// 外部调用的缓存失效方法（在 textDidChange 时调用）
    func invalidatePathCacheExternally() {
        cachedPaths.removeAll(keepingCapacity: true)
        isPathCacheDirty = true
    }

    /// 获取缓存的路径列表，如果缓存失效则重新扫描
    private func getCachedPaths() -> [PathInfo] {
        guard !string.isEmpty else {
            cachedPaths.removeAll(keepingCapacity: true)
            isPathCacheDirty = false
            return []
        }

        if isPathCacheDirty {
            cachedPaths = scanAllPaths(in: string)
            isPathCacheDirty = false
        }

        return cachedPaths
    }

    /// 扫描文本中的所有路径
    private func scanAllPaths(in text: String) -> [PathInfo] {
        guard !text.isEmpty else { return [] }

        var paths: [PathInfo] = []
        let nsText = text as NSString
        let length = nsText.length
        var i = 0

        while i < length {
            // 检查引号包裹的路径
            if nsText.character(at: i) == UTF16Code.doubleQuote {
                if let info = findQuotedPathInfo(in: nsText, startingAtUTF16: i) {
                    paths.append(info)
                    i = info.range.location + info.range.length
                    continue
                }
            }

            // 检查 / 开头的路径（未被引号包裹）
            if nsText.character(at: i) == UTF16Code.slash,
               (i == 0 || isWhitespace(nsText.character(at: i - 1))) {
                if let info = findSlashPathInfo(in: nsText, startingAtUTF16: i) {
                    paths.append(info)
                    i = info.range.location + info.range.length
                    continue
                }
            }

            i += 1
        }

        return paths
    }

    // MARK: - Context Menu (路径右键菜单)

    override func menu(for event: NSEvent) -> NSMenu? {
        let baseMenu = super.menu(for: event) ?? NSMenu()

        // 检测点击位置是否在路径上
        let point = convert(event.locationInWindow, from: nil)
        if let pathInfo = detectPathInfoAt(point) {
            let pathExists = FileManager.default.fileExists(atPath: (pathInfo.path as NSString).expandingTildeInPath)

            // 添加分隔符
            baseMenu.insertItem(.separator(), at: 0)

            // 复制路径（始终可用）
            let copyItem = NSMenuItem(
                title: "复制路径",
                action: #selector(copyDetectedPath(_:)),
                keyEquivalent: ""
            )
            copyItem.representedObject = pathInfo.path
            copyItem.target = self
            baseMenu.insertItem(copyItem, at: 0)

            // 在 Finder 中显示（路径不存在时置灰）
            let revealItem = NSMenuItem(
                title: pathExists ? "在 Finder 中显示" : "在 Finder 中显示（路径不存在）",
                action: pathExists ? #selector(revealInFinder(_:)) : nil,
                keyEquivalent: ""
            )
            revealItem.representedObject = pathInfo.path
            revealItem.target = self
            revealItem.isEnabled = pathExists
            if !pathExists {
                revealItem.toolTip = "路径不存在：\(pathInfo.path)"
            }
            baseMenu.insertItem(revealItem, at: 0)
        }

        return baseMenu
    }

    // MARK: - Path Detection

    /// 路径信息（包含路径字符串和范围）
    private struct PathInfo {
        let path: String
        let range: NSRange
    }

    /// 检测点击位置的路径（带范围信息）- 使用缓存优化
    private func detectPathInfoAt(_ point: NSPoint) -> PathInfo? {
        guard let layoutManager = layoutManager,
              textContainer != nil else {
            return nil
        }

        // 获取字符索引
        var adjustedPoint = point
        adjustedPoint.x -= textContainerInset.width
        adjustedPoint.y -= textContainerInset.height

        let glyphIndex = layoutManager.glyphIndex(for: adjustedPoint, in: textContainer!)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        guard characterIndex < string.utf16.count else { return nil }

        // 使用缓存的路径列表进行 O(n) 查找（n = 路径数量，通常很小）
        let paths = getCachedPaths()
        return paths.first { NSLocationInRange(characterIndex, $0.range) }
    }

    /// 查找引号包裹的路径 "..."
    /// - Parameters:
    ///   - text: 完整文本
    ///   - quoteStart: 开始引号的位置（chars[quoteStart] == '"'）
    /// - Returns: 路径信息，包含路径字符串和完整范围（含引号）
    private func findQuotedPathInfo(in text: NSString, startingAtUTF16 quoteStart: Int) -> PathInfo? {
        guard quoteStart < text.length, text.character(at: quoteStart) == UTF16Code.doubleQuote else {
            return nil
        }

        // 向后查找结束引号
        var endQuote = quoteStart + 1
        while endQuote < text.length {
            if text.character(at: endQuote) == UTF16Code.doubleQuote {
                break
            }
            endQuote += 1
        }

        // 确保引号配对且内容非空
        guard endQuote < text.length, endQuote > quoteStart + 1 else { return nil }

        let pathRange = NSRange(location: quoteStart + 1, length: endQuote - quoteStart - 1)
        let path = text.substring(with: pathRange)

        // 验证是否像路径
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return nil }

        let range = NSRange(location: quoteStart, length: endQuote - quoteStart + 1)
        return PathInfo(path: path, range: range)
    }

    /// 查找以 / 开头的非引号包裹路径
    /// - Parameters:
    ///   - text: 完整文本
    ///   - slashStart: 路径起始位置（chars[slashStart] == '/'）
    /// - Returns: 路径信息，包含路径字符串和范围
    private func findSlashPathInfo(in text: NSString, startingAtUTF16 slashStart: Int) -> PathInfo? {
        guard slashStart < text.length, text.character(at: slashStart) == UTF16Code.slash else {
            return nil
        }

        // 向后查找路径结束（遇到空格、引号或文本结束）
        var end = slashStart
        while end < text.length {
            let c = text.character(at: end)
            if isWhitespace(c) || c == UTF16Code.doubleQuote || c == UTF16Code.singleQuote {
                break
            }
            end += 1
        }

        guard end > slashStart else { return nil }

        let range = NSRange(location: slashStart, length: end - slashStart)
        let path = text.substring(with: range)
        return PathInfo(path: path, range: range)
    }

    private func isWhitespace(_ character: unichar) -> Bool {
        switch character {
        case UTF16Code.space, UTF16Code.tab, UTF16Code.newline, UTF16Code.carriageReturn:
            return true
        default:
            return false
        }
    }

    private enum UTF16Code {
        static let space: unichar = 32
        static let tab: unichar = 9
        static let newline: unichar = 10
        static let carriageReturn: unichar = 13
        static let slash: unichar = 47
        static let doubleQuote: unichar = 34
        static let singleQuote: unichar = 39
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyDetectedPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

// MARK: - Preview

#Preview {
    CommandTextView(
        text: .constant("ffmpeg -i \"/Users/test/video.mp4\" -c:v libx264 output.mp4"),
        placeholder: "输入 FFmpeg 命令..."
    )
    .frame(width: 500, height: 200)
    .padding()
}
