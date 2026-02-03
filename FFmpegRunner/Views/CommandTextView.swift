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

// MARK: - Throttler (通用节流器)

/// 通用节流器，用于限制高频事件的执行频率
final class Throttler {
    private var workItem: DispatchWorkItem?
    private let queue: DispatchQueue
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.05, queue: DispatchQueue = .main) {
        self.interval = interval
        self.queue = queue
    }

    /// 节流执行闘包，在 interval 时间内只执行最后一次调用
    func throttle(_ block: @escaping () -> Void) {
        workItem?.cancel()
        workItem = DispatchWorkItem(block: block)
        queue.asyncAfter(deadline: .now() + interval, execute: workItem!)
    }

    /// 取消待执行的任务
    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

// MARK: - String Extension (智能空格处理)

extension String {
    /// 智能包裹路径并添加必要空格
    /// - Parameters:
    ///   - range: 插入位置的范围
    ///   - text: 原始文本
    /// - Returns: 带有适当前后空格的字符串
    func withSmartSpacing(at range: NSRange, in text: String) -> String {
        var result = self
        let chars = Array(text)

        // 检查前一个字符，需要添加前导空格
        if range.location > 0 {
            let prevIndex = range.location - 1
            if prevIndex < chars.count && !chars[prevIndex].isWhitespace {
                result = " " + result
            }
        }

        // 检查后一个字符，需要添加后缀空格
        let nextIndex = range.location + range.length
        if nextIndex < chars.count && !chars[nextIndex].isWhitespace {
            result = result + " "
        }

        return result
    }
}

// MARK: - CommandTextView

/// 专业级命令输入视图（支持拖拽插入路径）
struct CommandTextView: View {
    @Binding var text: String
    var placeholder: String?

    /// 用于 closure-based 路径插入的引用
    @State private var insertPathHandler: ((String) -> Void)?

    /// 是否悬停或聚焦（显示工具入口）
    @State private var isHovering = false
    @State private var isFocused = false

    /// 是否应该高亮工具入口（-i 后缀检测）
    @State private var shouldHighlightMenu = false

    /// 光标选区（用于更精准的 -i 提示）
    @State private var selectionRange: NSRange = NSRange(location: 0, length: 0)

    /// 路径校验提示
    @State private var validationIssues: [CommandPathIssue] = []
    @State private var validationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                // 主文本输入区域
                ZStack(alignment: .topLeading) {
                    CommandTextViewRepresentable(
                        text: $text,
                        insertPathHandler: $insertPathHandler,
                        isFocused: $isFocused,
                        selectionRange: $selectionRange,
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
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }

            if !validationIssues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(validationIssues) { issue in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                            Text(issue.message)
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .onAppear {
            updateMenuHint(for: text, selection: selectionRange)
            scheduleValidation(for: text)
        }
        .onChange(of: text) { newValue in
            updateMenuHint(for: newValue, selection: selectionRange)
            scheduleValidation(for: newValue)
        }
        .onChange(of: selectionRange) { newRange in
            updateMenuHint(for: text, selection: newRange)
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
        let escapedPath = "\"\(path)\""
        // 使用 closure 直接插入（而非 Notification）
        insertPathHandler?(escapedPath)
    }

    /// 检测是否在 -i 后（高亮按钮）
    private func updateMenuHint(for text: String, selection: NSRange) {
        guard selection.location != NSNotFound else {
            shouldHighlightMenu = false
            return
        }
        let caretIndex = min(selection.location, text.count)
        let prefix = text.prefix(caretIndex)
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsWithInputFlag = trimmed.hasSuffix("-i")

        withAnimation(.easeInOut(duration: 0.2)) {
            shouldHighlightMenu = endsWithInputFlag
        }
    }

    // MARK: - Path Validation

    private func scheduleValidation(for text: String) {
        validationTask?.cancel()
        validationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            validationIssues = collectValidationIssues(from: text)
        }
    }

    private func collectValidationIssues(from text: String) -> [CommandPathIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let args = CommandRenderer.splitCommand(trimmed)
        guard !args.isEmpty else { return [] }

        var issues: [CommandPathIssue] = []
        let fm = FileManager.default

        // 1) 校验 -i 输入文件是否存在（仅检查绝对路径或 ~）
        for index in 0..<args.count {
            guard args[index] == "-i", index + 1 < args.count else { continue }
            let candidate = args[index + 1]
            guard shouldValidatePath(candidate) else { continue }

            let expanded = (candidate as NSString).expandingTildeInPath
            if !fm.fileExists(atPath: expanded) {
                issues.append(CommandPathIssue(message: "输入文件不存在：\(candidate)"))
            }
        }

        // 2) 输出格式与扩展名不一致（轻量提示）
        if let output = findOutputPath(in: args),
           let format = findLastFormat(in: args),
           let ext = output.pathExtensionLowercased,
           !ext.isEmpty,
           format != ext {
            issues.append(CommandPathIssue(message: "输出格式 (-f \(format)) 与扩展名 (.\(ext)) 可能不一致"))
        }

        // 限制提示数量，避免干扰
        if issues.count > 3 {
            return Array(issues.prefix(3))
        }

        return issues
    }

    private func shouldValidatePath(_ value: String) -> Bool {
        if value.hasPrefix("-") { return false }
        if value == "-" { return false }
        if value.contains("://") { return false }
        if value.hasPrefix("pipe:") || value.hasPrefix("concat:") { return false }
        return value.hasPrefix("/") || value.hasPrefix("~")
    }

    private func findOutputPath(in args: [String]) -> String? {
        var output: String?
        for arg in args {
            if arg.hasPrefix("-") { continue }
            if arg.contains(":") && !arg.contains("/") { continue }
            output = arg
        }
        return output
    }

    private func findLastFormat(in args: [String]) -> String? {
        var format: String?
        for index in 0..<args.count {
            guard args[index] == "-f", index + 1 < args.count else { continue }
            format = args[index + 1].lowercased()
        }
        return format
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

// MARK: - Command Path Issue

private struct CommandPathIssue: Identifiable {
    let id = UUID()
    let message: String
}

private extension String {
    var pathExtensionLowercased: String? {
        let ext = (self as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}

// MARK: - NSViewRepresentable

struct CommandTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var insertPathHandler: ((String) -> Void)?
    @Binding var isFocused: Bool
    @Binding var selectionRange: NSRange
    var onInsertFile: (() -> Void)?
    var onInsertDirectory: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = CommandNSTextView()
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
        textView.onInsertFile = onInsertFile
        textView.onInsertDirectory = onInsertDirectory

        scrollView.documentView = textView

        // 设置 closure-based 插入处理器
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            self.insertPathHandler = { [weak coordinator] path in
                coordinator?.insertAtCursor(path)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // 仅在内容不同时更新，避免光标跳动
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            // 尝试恢复光标位置
            if selectedRange.location <= text.count {
                textView.setSelectedRange(selectedRange)
            }
        }
        if let commandTextView = textView as? CommandNSTextView {
            commandTextView.onInsertFile = onInsertFile
            commandTextView.onInsertDirectory = onInsertDirectory
        }
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
            guard let textView = notification.object as? NSTextView else { return }
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
            guard let textView = textView else { return }

            let range = textView.selectedRange()
            let textWithSpacing = path.withSmartSpacing(at: range, in: textView.string)

            textView.insertText(textWithSpacing, replacementRange: range)
            parent.text = textView.string
        }
    }
}

// MARK: - Custom NSTextView with Drag Support

final class CommandNSTextView: NSTextView {

    var onInsertFile: (() -> Void)?
    var onInsertDirectory: (() -> Void)?

    /// 当前 hover 的路径范围（用于高亮）
    private var hoveredPathRange: NSRange?

    /// hover 高亮的背景颜色
    private let pathHighlightColor = NSColor.controlAccentColor.withAlphaComponent(0.1)

    /// mouseMoved 节流器，避免高频路径检测（50ms 间隔）
    private lazy var mouseMoveThrottler = Throttler(interval: 0.05)

    /// 路径检测缓存（文本变化时失效）
    private var cachedPaths: [PathInfo] = []
    private var cachedText: String = ""

    /// 拖拽时的插入位置指示器
    private var dragCaretView: NSView?

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // 移除旧的 tracking area
        for area in trackingAreas {
            removeTrackingArea(area)
        }

        // 添加新的 tracking area
        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect]
        let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)

        // 使用节流器限制高频路径检测
        mouseMoveThrottler.throttle { [weak self] in
            self?.handleMouseMoveThrottled(with: event)
        }
    }

    /// 节流后的鼠标移动处理
    private func handleMouseMoveThrottled(with event: NSEvent) {
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

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.iBeam.set()

        if hoveredPathRange != nil {
            hoveredPathRange = nil
            setNeedsDisplay(bounds)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 绘制路径高亮背景
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
    }

    // MARK: - Keyboard Shortcuts

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased(),
           key == "i" {
            if flags.contains(.shift) {
                onInsertDirectory?()
            } else {
                onInsertFile?()
            }
            return
        }

        super.keyDown(with: event)
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        showDragCaret(at: point)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDragCaret()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideDragCaret()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDragCaret()

        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return super.performDragOperation(sender)
        }

        // 使用当前选区位置（如果有选中文本则替换，否则在光标位置插入）
        let range = selectedRange()

        // 支持多文件拖拽：构建带引号的路径列表（用 -i 连接）
        let escapedPaths: String
        if urls.count == 1 {
            escapedPaths = "\"\(urls[0].path)\""
        } else {
            // 多文件：每个路径前加 -i 前缀
            escapedPaths = urls.map { "-i \"\($0.path)\"" }.joined(separator: " ")
        }

        let textWithSpacing = escapedPaths.withSmartSpacing(at: range, in: string)

        // 在选区位置插入（替换选中内容）
        insertText(textWithSpacing, replacementRange: range)

        return true
    }

    // MARK: - Drag Caret (拖拽插入指示器)

    /// 显示拖拽插入位置指示线
    private func showDragCaret(at point: NSPoint) {
        let insertionIndex = getInsertionCharacterIndex(at: point)

        guard let layoutManager = layoutManager,
              textContainer != nil else { return }

        // 计算插入位置的矩形
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: insertionIndex)
        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: max(0, glyphIndex), effectiveRange: nil)
        lineRect.origin.x += textContainerInset.width
        lineRect.origin.y += textContainerInset.height

        // 获取精确的 X 坐标
        let location = layoutManager.location(forGlyphAt: max(0, glyphIndex))
        let caretX = lineRect.origin.x + location.x

        // 创建或更新指示线
        if dragCaretView == nil {
            let caret = NSView()
            caret.wantsLayer = true
            caret.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            addSubview(caret)
            dragCaretView = caret
        }

        dragCaretView?.frame = NSRect(
            x: caretX - 1,
            y: lineRect.origin.y,
            width: 2,
            height: lineRect.height
        )
        dragCaretView?.isHidden = false
    }

    /// 隐藏拖拽插入指示线
    private func hideDragCaret() {
        dragCaretView?.isHidden = true
    }

    /// 获取插入位置的字符索引
    func getInsertionCharacterIndex(at point: NSPoint) -> Int {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return string.count
        }

        // 调整坐标以考虑文本容器的边距
        var adjustedPoint = point
        adjustedPoint.x -= textContainerInset.width
        adjustedPoint.y -= textContainerInset.height

        let glyphIndex = layoutManager.glyphIndex(for: adjustedPoint, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        return min(characterIndex, string.count)
    }

    // MARK: - Path Cache Management

    /// 使路径缓存失效（文本变化时调用）
    private func invalidatePathCache() {
        if cachedText != string {
            cachedPaths = []
            cachedText = string
        }
    }

    /// 获取缓存的路径列表，如果缓存失效则重新扫描
    private func getCachedPaths() -> [PathInfo] {
        invalidatePathCache()

        if cachedPaths.isEmpty && !string.isEmpty {
            cachedPaths = scanAllPaths(in: string)
        }

        return cachedPaths
    }

    /// 扫描文本中的所有路径
    private func scanAllPaths(in text: String) -> [PathInfo] {
        var paths: [PathInfo] = []
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            // 检查引号包裹的路径
            if chars[i] == "\"" {
                if let info = findQuotedPathInfo(in: text, around: i + 1) {
                    paths.append(info)
                    i = info.range.location + info.range.length
                    continue
                }
            }

            // 检查 / 开头的路径
            if chars[i] == "/" && (i == 0 || chars[i - 1].isWhitespace) {
                if let info = findSlashPathInfo(in: text, around: i) {
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

        guard characterIndex < string.count else { return nil }

        // 使用缓存的路径列表进行 O(n) 查找（n = 路径数量，通常很小）
        let paths = getCachedPaths()
        return paths.first { NSLocationInRange(characterIndex, $0.range) }
    }

    /// 查找引号包裹的路径 "..."
    private func findQuotedPathInfo(in text: String, around index: Int) -> PathInfo? {
        let chars = Array(text)
        guard index < chars.count else { return nil }

        // 向前查找引号
        var startQuote = -1
        for i in stride(from: index, through: 0, by: -1) {
            if chars[i] == "\"" {
                startQuote = i
                break
            }
        }

        guard startQuote >= 0 else { return nil }

        // 向后查找引号
        var endQuote = -1
        for i in (startQuote + 1)..<chars.count {
            if chars[i] == "\"" {
                endQuote = i
                break
            }
        }

        guard endQuote > startQuote + 1 else { return nil }
        guard index >= startQuote && index <= endQuote else { return nil }

        let pathStart = text.index(text.startIndex, offsetBy: startQuote + 1)
        let pathEnd = text.index(text.startIndex, offsetBy: endQuote)
        let path = String(text[pathStart..<pathEnd])

        // 验证是否像路径
        if path.hasPrefix("/") || path.hasPrefix("~") {
            let range = NSRange(location: startQuote, length: endQuote - startQuote + 1)
            return PathInfo(path: path, range: range)
        }

        return nil
    }

    /// 查找以 / 开头的路径
    private func findSlashPathInfo(in text: String, around index: Int) -> PathInfo? {
        let chars = Array(text)
        guard index < chars.count else { return nil }

        // 向前查找路径起始
        var start = index
        for i in stride(from: index, through: 0, by: -1) {
            let c = chars[i]
            if c.isWhitespace || c == "\"" || c == "'" {
                start = i + 1
                break
            }
            if i == 0 {
                start = 0
            }
        }

        // 确保以 / 开头
        guard start < chars.count, chars[start] == "/" else { return nil }

        // 向后查找路径结束
        var end = index
        for i in index..<chars.count {
            let c = chars[i]
            if c.isWhitespace || c == "\"" || c == "'" {
                end = i
                break
            }
            if i == chars.count - 1 {
                end = chars.count
            }
        }

        guard end > start else { return nil }

        let pathStart = text.index(text.startIndex, offsetBy: start)
        let pathEnd = text.index(text.startIndex, offsetBy: end)
        let path = String(text[pathStart..<pathEnd])
        let range = NSRange(location: start, length: end - start)

        return PathInfo(path: path, range: range)
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
