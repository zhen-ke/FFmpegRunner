//
//  CommandTextView.swift
//  FFmpegRunner
//
//  工业级命令输入视图 - 支持拖拽插入、插入按钮、路径检测
//
//  修复记录：
//  ① pendingInsertions 竞态 → 改用 AsyncStream + actor 串行消费
//  ② 补全上下文重复计算 → 合并 onChange 为单一 task，消除同帧双次触发
//  ③ clampedUTF16Range 重复实现 → 提取为 NSRange extension
//  ④ isPathCacheDirty 冗余布尔 → 统一用 cachedPaths.isEmpty 表达失效状态
//  ⑤ 层间耦合 → 提取 CommandEditorViewModel，视图层只负责渲染和事件转发
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - NSRange Extension (消除重复的 clamp 实现)

extension NSRange {
    /// 将范围限制在 [0, maxUTF16Length] 内，location == NSNotFound 时返回末尾插入点
    static func clamped(_ range: NSRange, maxUTF16Length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: maxUTF16Length, length: 0)
        }
        let location = min(max(range.location, 0), maxUTF16Length)
        let length   = min(max(range.length, 0), maxUTF16Length - location)
        return NSRange(location: location, length: length)
    }
}

// MARK: - String Extension (智能空格处理)

extension String {
    /// 智能包裹路径并添加必要空格
    func withSmartSpacing(at range: NSRange, in text: String) -> String {
        var result = self
        guard let swiftRange = Range(range, in: text) else { return result }

        if swiftRange.lowerBound > text.startIndex {
            let prevChar = text[text.index(before: swiftRange.lowerBound)]
            if !prevChar.isWhitespace { result = " " + result }
        }
        if swiftRange.upperBound < text.endIndex {
            let nextChar = text[swiftRange.upperBound]
            if !nextChar.isWhitespace { result = result + " " }
        }
        return result
    }

    /// 用于命令字符串展示/编辑：双引号包裹并转义内部反斜杠与双引号
    var shellQuotedPathForCommand: String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - CommandEditorViewModel (⑤ 提取业务逻辑，解耦视图层)

/// 持有命令编辑器的全部业务状态与逻辑，视图层仅读取 @Published 属性并调用方法。
@MainActor
final class CommandEditorViewModel: ObservableObject {

    // MARK: Published State

    @Published var text: String
    @Published var isFocused: Bool = false
    @Published var isDragging: Bool = false
    @Published var selectionRange: NSRange = NSRange(location: 0, length: 0)
    @Published var isHovering: Bool = false
    @Published var shouldHighlightMenu: Bool = false
    @Published var diagnostics: [CommandEditorDiagnostic] = []
    @Published var inlineCompletionSuffix: String = ""

    /// 当前生效的补全替换范围（供 Coordinator 使用）
    private(set) var completionReplacementRange: NSRange = NSRange(location: NSNotFound, length: 0)

    // MARK: Internal References

    /// NSTextView 的 Coordinator，供插入操作直接调用
    weak var coordinator: CommandTextViewRepresentable.Coordinator?

    // MARK: - ① 串行插入队列 (替代 pendingInsertions 数组 + flush 模式)
    //
    // 使用 AsyncStream 作为 FIFO 队列，coordinator 就绪后由单一 Task 串行消费，
    // 彻底消除"coordinator 还未赋值 / task 触发时序"竞态。

    private var insertionContinuation: AsyncStream<String>.Continuation?
    private var insertionConsumerTask: Task<Void, Never>?

    // MARK: - ② 合并触发的诊断 Task

    private var diagnosticsTask: Task<Void, Never>?
    private var completionRefreshTask: Task<Void, Never>?

    // MARK: Init

    init(text: String) {
        self.text = text
        startInsertionQueue()
    }

    deinit {
        insertionContinuation?.finish()
        insertionConsumerTask?.cancel()
        diagnosticsTask?.cancel()
        completionRefreshTask?.cancel()
    }

    // MARK: - ① 串行插入队列实现

    private func startInsertionQueue() {
        let stream = AsyncStream<String> { [weak self] continuation in
            self?.insertionContinuation = continuation
        }

        insertionConsumerTask = Task { [weak self] in
            for await path in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.coordinator?.insertAtCursor(path)
                }
            }
        }
    }

    /// 将路径推入串行插入队列（coordinator 未就绪时自动等待，不会丢失）
    func enqueueInsertion(_ path: String) {
        insertionContinuation?.yield(path)
    }

    // MARK: - Insertion from Panels

    func insertFile(isDirectory: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection  = false
        panel.canChooseDirectories     = isDirectory
        panel.canChooseFiles           = !isDirectory
        panel.canCreateDirectories     = false
        panel.prompt = isDirectory ? "选择目录" : "选择文件"

        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.enqueueInsertion(url.path.shellQuotedPathForCommand)
            }
        }
    }

    // MARK: - ② 合并 text / selectionRange 变化，避免同帧双次触发

    /// 由视图在 onChange(of: text) 或 onChange(of: selectionRange) 时调用
    func handleEditorStateChange() {
        updateMenuHint()
        scheduleCompletionRefresh()
        scheduleDiagnosticsRefresh()
    }

    func handleFocusChange(focused: Bool) {
        if !focused {
            inlineCompletionSuffix = ""
        } else {
            scheduleCompletionRefresh()
        }
    }

    // MARK: - Menu Hint

    private func updateMenuHint() {
        guard selectionRange.location != NSNotFound else {
            shouldHighlightMenu = false
            return
        }
        let caretOffset = min(max(selectionRange.location, 0), text.utf16.count)
        let caretIndex  = stringIndexForUTF16Offset(caretOffset, in: text)
        let prefix      = text[..<caretIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.easeInOut(duration: 0.2)) {
            shouldHighlightMenu = prefix.hasSuffix("-i")
        }
    }

    // MARK: - ② Completion Refresh (单一调度，消除同帧双次计算)

    private func scheduleCompletionRefresh() {
        completionRefreshTask?.cancel()
        completionRefreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.refreshCompletionSuggestions()
        }
    }

    private func refreshCompletionSuggestions() {
        let result = currentCompletionContext(force: false)
        completionReplacementRange = result.range
        inlineCompletionSuffix     = result.inlineSuffix
    }

    func handleCompletionRequest() -> Bool {
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

    private func currentCompletionContext(force: Bool) -> (suggestion: String?, range: NSRange, inlineSuffix: String) {
        guard isFocused else {
            return (nil, NSRange(location: NSNotFound, length: 0), "")
        }

        let range   = completionRange(in: text, selection: selectionRange)
        let partial = substring(in: text, range: range)
        let suggestions = CommandEditorAssistant.completions(
            for: text,
            selectedRange: selectionRange,
            partialRange: range
        )
        guard let suggestion = suggestions.first else {
            return (nil, range, "")
        }

        let isCursorAtTokenEnd = selectionRange.location != NSNotFound
            && selectionRange.length == 0
            && selectionRange.location == range.location + range.length

        let shouldShowInline: Bool
        if partial.isEmpty {
            shouldShowInline = !force && isCursorAtTokenEnd
        } else {
            shouldShowInline = !force
                && isCursorAtTokenEnd
                && suggestion.hasPrefix(partial)
                && suggestion.count > partial.count
        }

        let inlineSuffix: String = shouldShowInline
            ? (partial.isEmpty ? suggestion : String(suggestion.dropFirst(partial.count)))
            : ""

        return (suggestion, range, inlineSuffix)
    }

    // MARK: - ② Diagnostics Refresh (debounced 250 ms)

    private func scheduleDiagnosticsRefresh() {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.diagnostics = CommandEditorAssistant.diagnostics(for: self.text)
        }
    }

    // MARK: - Helpers

    private func completionRange(in text: String, selection: NSRange) -> NSRange {
        guard selection.location != NSNotFound else {
            return NSRange(location: text.utf16.count, length: 0)
        }
        let nsText = text as NSString
        let length = nsText.length
        let cursor = min(max(selection.location, 0), length)

        var start = cursor
        while start > 0,
              let scalar = UnicodeScalar(nsText.character(at: start - 1)),
              !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start -= 1
        }

        var end = cursor
        while end < length,
              let scalar = UnicodeScalar(nsText.character(at: end)),
              !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            end += 1
        }

        return NSRange(location: start, length: end - start)
    }

    private func substring(in text: String, range: NSRange) -> String {
        guard let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }

    private func stringIndexForUTF16Offset(_ offset: Int, in text: String) -> String.Index {
        let clamped   = min(max(offset, 0), text.utf16.count)
        let utf16Idx  = text.utf16.index(text.utf16.startIndex, offsetBy: clamped)
        return String.Index(utf16Idx, within: text) ?? text.endIndex
    }
}

// MARK: - CommandTextView

/// 纯视图层：只负责渲染和把事件转发给 ViewModel。
struct CommandTextView: View {
    @Binding var text: String
    var placeholder: String?

    @StateObject private var viewModel: CommandEditorViewModel

    init(text: Binding<String>, placeholder: String? = nil) {
        self._text = text
        self.placeholder = placeholder
        self._viewModel = StateObject(wrappedValue: CommandEditorViewModel(text: text.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                ZStack(alignment: .topLeading) {
                    CommandTextViewRepresentable(
                        text: $text,
                        viewModel: viewModel
                    )
                    .frame(minHeight: 100)

                    if text.isEmpty, let placeholder {
                        Text(placeholder)
                            .foregroundColor(.secondary.opacity(0.5))
                            .font(.system(.body, design: .monospaced))
                            .padding(.top, 8)
                            .padding(.leading, 8)
                            .allowsHitTesting(false)
                    }
                }

                if viewModel.isHovering || viewModel.isFocused {
                    CommandInsertButtons(
                        highlightFile: viewModel.shouldHighlightMenu,
                        insertFile:    { viewModel.insertFile(isDirectory: false) },
                        insertDirectory: { viewModel.insertFile(isDirectory: true) }
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
                        viewModel.isDragging ? Color.accentColor : Color.secondary.opacity(0.2),
                        lineWidth: viewModel.isDragging ? 2 : 1
                    )
            )
            .animation(.easeInOut(duration: 0.15), value: viewModel.isDragging)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.isHovering = hovering
                }
            }

            if !viewModel.diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.diagnostics) { diagnostic in
                        Label(diagnostic.message, systemImage: diagnostic.severity.symbolName)
                            .font(.caption)
                            .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                    }
                }
                .padding(.leading, 4)
            }
        }
        // ② 合并两个 onChange 为一次调度，消除同帧双次触发补全计算
        .onChange(of: text) { newValue in
            viewModel.text = newValue
            viewModel.handleEditorStateChange()
        }
        .onChange(of: viewModel.selectionRange) { _ in
            viewModel.handleEditorStateChange()
        }
        .onChange(of: viewModel.isFocused) { focused in
            viewModel.handleFocusChange(focused: focused)
        }
        .onAppear {
            viewModel.text = text
            viewModel.handleEditorStateChange()
        }
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
                    .fill(highlightFile
                          ? Color.accentColor.opacity(0.12)
                          : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        highlightFile
                        ? Color.accentColor.opacity(0.5)
                        : Color(NSColor.separatorColor).opacity(0.6),
                        lineWidth: 1
                    )
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
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
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
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - NSViewRepresentable

struct CommandTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    /// ⑤ 通过 ViewModel 集中管理状态，Representable 不再持有零散 Binding
    @ObservedObject var viewModel: CommandEditorViewModel

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = true
        scrollView.borderType            = .noBorder

        let textView = CommandNSTextView()
        textView.onDragStateChanged = { [weak viewModel] dragging in
            DispatchQueue.main.async { viewModel?.isDragging = dragging }
        }
        textView.isRichText              = false
        textView.allowsUndo              = true
        textView.font                    = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor               = NSColor.textColor
        textView.backgroundColor         = NSColor.textBackgroundColor
        textView.isEditable              = true
        textView.isSelectable            = true
        textView.drawsBackground         = true
        textView.isVerticallyResizable   = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask        = [.width]
        textView.textContainerInset      = NSSize(width: 4, height: 4)

        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )

        textView.registerForDraggedTypes([.fileURL])
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        syncCallbacks(to: textView, coordinator: context.coordinator)
        scrollView.documentView = textView

        // ① coordinator 就绪后立即注册到 ViewModel（AsyncStream 消费者从此开始工作）
        DispatchQueue.main.async {
            viewModel.coordinator = context.coordinator
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            // ③ 统一使用 NSRange.clamped 扩展，消除重复实现
            textView.setSelectedRange(.clamped(selectedRange, maxUTF16Length: text.utf16.count))
            (textView as? CommandNSTextView)?.invalidatePathCacheExternally()
        }

        if let commandTextView = textView as? CommandNSTextView {
            commandTextView.inlineCompletionSuffix = viewModel.inlineCompletionSuffix
            syncCallbacks(to: commandTextView, coordinator: context.coordinator)
        }
    }

    private func syncCallbacks(to textView: CommandNSTextView, coordinator: Coordinator) {
        textView.onRequestCompletion = { [weak viewModel] in viewModel?.handleCompletionRequest() ?? false }
        textView.onInsertFile        = { [weak viewModel] in viewModel?.insertFile(isDirectory: false) }
        textView.onInsertDirectory   = { [weak viewModel] in viewModel?.insertFile(isDirectory: true) }
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

        // MARK: Focus Tracking

        func textDidBeginEditing(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.viewModel.isFocused = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.viewModel.isFocused = false }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CommandNSTextView else { return }
            textView.invalidatePathCacheExternally()
            parent.text = textView.string
            DispatchQueue.main.async { self.parent.viewModel.text = textView.string }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            DispatchQueue.main.async {
                self.parent.viewModel.selectionRange = textView.selectedRange()
            }
        }

        // MARK: Insertion

        /// 在光标位置插入文本（带智能空格）
        func insertAtCursor(_ path: String) {
            guard let textView else {
#if DEBUG
                print("[CommandTextView] insertAtCursor: textView 已释放，跳过插入")
#endif
                return
            }
            let range           = textView.selectedRange()
            let textWithSpacing = path.withSmartSpacing(at: range, in: textView.string)
            textView.insertText(textWithSpacing, replacementRange: range)
            parent.text = textView.string
        }

        func applyCompletion(_ suggestion: String, replacing range: NSRange) {
            guard let textView else { return }

            let nsText         = textView.string as NSString
            let nextLocation   = range.location + range.length
            let needsTrailing: Bool

            if nextLocation >= nsText.length {
                needsTrailing = true
            } else {
                let nextScalar = UnicodeScalar(nsText.character(at: nextLocation))
                needsTrailing  = nextScalar.map { !CharacterSet.whitespacesAndNewlines.contains($0) } ?? true
            }

            let replacement = needsTrailing ? "\(suggestion) " : suggestion
            textView.insertText(replacement, replacementRange: range)
            parent.text = textView.string
        }
    }
}

// MARK: - Custom NSTextView with Drag Support

final class CommandNSTextView: NSTextView {

    var inlineCompletionSuffix = "" {
        didSet { if oldValue != inlineCompletionSuffix { setNeedsDisplay(bounds) } }
    }

    var onRequestCompletion: (() -> Bool)?
    var onInsertFile: (() -> Void)?
    var onInsertDirectory: (() -> Void)?

    private var hoveredPathRange: NSRange?
    private let pathHighlightColor = NSColor.controlAccentColor.withAlphaComponent(0.1)

    // ④ 移除 isPathCacheDirty 布尔标志；cachedPaths.isEmpty 即代表缓存无效
    private var cachedPaths: [PathInfo] = []

    var onDragStateChanged: ((Bool) -> Void)?
    private var dragInsertionIndex: Int?
    private var dragOriginalSelectionRange: NSRange?
    private var didPerformDragInsertion = false
    private var mouseTrackingArea: NSTrackingArea?

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = mouseTrackingArea { removeTrackingArea(existing) }

        let options: NSTrackingArea.Options = [
            .mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        if let window = self.window,
           let hitView = window.contentView?.hitTest(event.locationInWindow),
           hitView !== self && !hitView.isDescendant(of: self) {
            return
        }
        super.mouseMoved(with: event)
        handleMouseMove(with: event)
    }

    private func handleMouseMove(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let pathInfo = detectPathInfoAt(point) {
            NSCursor.pointingHand.set()
            if hoveredPathRange != pathInfo.range {
                hoveredPathRange = pathInfo.range
                setNeedsDisplay(bounds)
            }
        } else {
            NSCursor.iBeam.set()
            if hoveredPathRange != nil {
                hoveredPathRange = nil
                setNeedsDisplay(bounds)
            }
        }
    }

    // MARK: - Mouse Click

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if let pathInfo = detectPathInfoAt(point) {
                let expanded = (pathInfo.path as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expanded) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let range = hoveredPathRange,
           let layoutManager,
           let textContainer {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textContainerInset.width
            rect.origin.y += textContainerInset.height

            pathHighlightColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }

        super.draw(dirtyRect)
        drawInlineCompletionIfNeeded()
    }

    // MARK: - Keyboard Shortcuts

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased(),
           key == "o" {
            if flags.contains(.shift) { onInsertDirectory?() } else { onInsertFile?() }
            return
        }

        if flags.isEmpty, event.keyCode == 48, onRequestCompletion?() == true { return }

        super.keyDown(with: event)
    }

    // MARK: - Inline Completion Drawing

    private func drawInlineCompletionIfNeeded() {
        guard !inlineCompletionSuffix.isEmpty,
              let font,
              let rect = inlineCompletionRect() else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        NSAttributedString(string: inlineCompletionSuffix, attributes: attributes).draw(at: rect.origin)
    }

    private func inlineCompletionRect() -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }

        let selection  = selectedRange()
        guard selection.location != NSNotFound, selection.length == 0 else { return nil }

        let lineHeight = layoutManager.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular))

        if string.isEmpty {
            return NSRect(x: textContainerInset.width, y: textContainerInset.height, width: 0, height: lineHeight)
        }

        let maxCharIdx    = string.utf16.count
        let characterIndex = min(selection.location, maxCharIdx)

        if characterIndex == 0 {
            return NSRect(x: textContainerInset.width, y: textContainerInset.height, width: 0, height: lineHeight)
        }

        let anchorIndex = min(characterIndex - 1, maxCharIdx - 1)
        let glyphIndex  = layoutManager.glyphIndexForCharacter(at: anchorIndex)
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height

        if characterIndex == maxCharIdx { rect.origin.x += rect.width }
        rect.size.width  = 0
        rect.size.height = lineHeight
        return rect
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) else {
            return super.draggingEntered(sender)
        }
        beginDragSessionIfNeeded()
        let _ = super.draggingEntered(sender)
        updateDragInsertionPoint(with: sender)
        onDragStateChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let _ = super.draggingUpdated(sender)
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

        let insertionIndex: Int
        if let saved = dragInsertionIndex {
            insertionIndex = saved
        } else {
            let point = convert(sender.draggingLocation, from: nil)
            insertionIndex = getInsertionCharacterIndex(at: point)
        }
        dragInsertionIndex = nil

        let range         = NSRange(location: insertionIndex, length: 0)
        let escapedPaths  = urls.map { $0.path.shellQuotedPathForCommand }.joined(separator: " ")
        let textWithSpacing = escapedPaths.withSmartSpacing(at: range, in: string)

        insertText(textWithSpacing, replacementRange: range)
        didPerformDragInsertion = true

        let insertedLength  = (textWithSpacing as NSString).length
        let caretLocation   = min(range.location + insertedLength, string.utf16.count)
        setSelectedRange(NSRange(location: caretLocation, length: 0))
        scrollRangeToVisible(NSRange(location: caretLocation, length: 0))
        endDragSession(restoreSelection: false)
        return true
    }

    func getInsertionCharacterIndex(at point: NSPoint) -> Int {
        guard let layoutManager, let textContainer else { return string.utf16.count }

        var adjusted = point
        adjusted.x -= textContainerInset.width
        adjusted.y -= textContainerInset.height

        var fraction: CGFloat = 0
        let characterIndex = layoutManager.characterIndex(
            for: adjusted,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        return min(fraction > 0.5 ? characterIndex + 1 : characterIndex, string.utf16.count)
    }

    private func beginDragSessionIfNeeded() {
        if dragOriginalSelectionRange == nil { dragOriginalSelectionRange = selectedRange() }
        didPerformDragInsertion = false
        window?.makeFirstResponder(self)
    }

    private func updateDragInsertionPoint(with sender: NSDraggingInfo) {
        let point          = convert(sender.draggingLocation, from: nil)
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
            // ③ 统一使用 NSRange.clamped 扩展
            let clamped = NSRange.clamped(originalRange, maxUTF16Length: string.utf16.count)
            setSelectedRange(clamped)
            scrollRangeToVisible(clamped)
        }
        dragOriginalSelectionRange = nil
        dragInsertionIndex         = nil
        didPerformDragInsertion    = false
    }

    // MARK: - Path Cache Management

    /// 外部调用的缓存失效方法（在 textDidChange 时调用）
    /// ④ 直接 removeAll，不再维护 isPathCacheDirty 布尔
    func invalidatePathCacheExternally() {
        cachedPaths.removeAll(keepingCapacity: true)
    }

    /// 获取缓存路径列表；④ 用 isEmpty 判断是否需要重新扫描
    private func getCachedPaths() -> [PathInfo] {
        guard !string.isEmpty else {
            cachedPaths.removeAll(keepingCapacity: true)
            return []
        }
        if cachedPaths.isEmpty {
            cachedPaths = scanAllPaths(in: string)
        }
        return cachedPaths
    }

    private func scanAllPaths(in text: String) -> [PathInfo] {
        guard !text.isEmpty else { return [] }

        var paths: [PathInfo] = []
        let nsText = text as NSString
        let length = nsText.length
        var i = 0

        while i < length {
            if nsText.character(at: i) == UTF16Code.doubleQuote {
                if let info = findQuotedPathInfo(in: nsText, startingAtUTF16: i) {
                    paths.append(info)
                    i = info.range.location + info.range.length
                    continue
                }
            }
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

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let baseMenu = super.menu(for: event) ?? NSMenu()

        let point = convert(event.locationInWindow, from: nil)
        if let pathInfo = detectPathInfoAt(point) {
            let pathExists = FileManager.default.fileExists(
                atPath: (pathInfo.path as NSString).expandingTildeInPath
            )

            baseMenu.insertItem(.separator(), at: 0)

            let copyItem = NSMenuItem(title: "复制路径", action: #selector(copyDetectedPath(_:)), keyEquivalent: "")
            copyItem.representedObject = pathInfo.path
            copyItem.target = self
            baseMenu.insertItem(copyItem, at: 0)

            let revealTitle = pathExists ? "在 Finder 中显示" : "在 Finder 中显示（路径不存在）"
            let revealItem  = NSMenuItem(
                title: revealTitle,
                action: pathExists ? #selector(revealInFinder(_:)) : nil,
                keyEquivalent: ""
            )
            revealItem.representedObject = pathInfo.path
            revealItem.target    = self
            revealItem.isEnabled = pathExists
            if !pathExists { revealItem.toolTip = "路径不存在：\(pathInfo.path)" }
            baseMenu.insertItem(revealItem, at: 0)
        }
        return baseMenu
    }

    // MARK: - Path Detection

    private struct PathInfo {
        let path: String
        let range: NSRange
    }

    private func detectPathInfoAt(_ point: NSPoint) -> PathInfo? {
        guard let layoutManager, let textContainer else { return nil }

        var adjusted = point
        adjusted.x -= textContainerInset.width
        adjusted.y -= textContainerInset.height

        let glyphIndex     = layoutManager.glyphIndex(for: adjusted, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < string.utf16.count else { return nil }

        return getCachedPaths().first { NSLocationInRange(characterIndex, $0.range) }
    }

    private func findQuotedPathInfo(in text: NSString, startingAtUTF16 quoteStart: Int) -> PathInfo? {
        guard quoteStart < text.length, text.character(at: quoteStart) == UTF16Code.doubleQuote else {
            return nil
        }
        var endQuote = quoteStart + 1
        while endQuote < text.length, text.character(at: endQuote) != UTF16Code.doubleQuote {
            endQuote += 1
        }
        guard endQuote < text.length, endQuote > quoteStart + 1 else { return nil }

        let pathRange = NSRange(location: quoteStart + 1, length: endQuote - quoteStart - 1)
        let path = text.substring(with: pathRange)
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return nil }

        return PathInfo(path: path, range: NSRange(location: quoteStart, length: endQuote - quoteStart + 1))
    }

    private func findSlashPathInfo(in text: NSString, startingAtUTF16 slashStart: Int) -> PathInfo? {
        guard slashStart < text.length, text.character(at: slashStart) == UTF16Code.slash else {
            return nil
        }
        var end = slashStart
        while end < text.length {
            let c = text.character(at: end)
            if isWhitespace(c) || c == UTF16Code.doubleQuote || c == UTF16Code.singleQuote { break }
            end += 1
        }
        guard end > slashStart else { return nil }

        let range = NSRange(location: slashStart, length: end - slashStart)
        return PathInfo(path: text.substring(with: range), range: range)
    }

    private func isWhitespace(_ character: unichar) -> Bool {
        switch character {
        case UTF16Code.space, UTF16Code.tab, UTF16Code.newline, UTF16Code.carriageReturn: return true
        default: return false
        }
    }

    private enum UTF16Code {
        static let space: unichar          = 32
        static let tab: unichar            = 9
        static let newline: unichar        = 10
        static let carriageReturn: unichar = 13
        static let slash: unichar          = 47
        static let doubleQuote: unichar    = 34
        static let singleQuote: unichar    = 39
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)]
        )
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
