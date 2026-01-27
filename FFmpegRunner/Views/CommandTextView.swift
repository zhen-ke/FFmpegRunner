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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 主文本输入区域
            ZStack(alignment: .topLeading) {
                CommandTextViewRepresentable(
                    text: $text,
                    insertPathHandler: $insertPathHandler,
                    isFocused: $isFocused
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

            // 悬浮工具入口（仅在 hover / focus 时显示）
            if isHovering || isFocused {
                CommandInlineMenu(
                    isHighlighted: shouldHighlightMenu,
                    insertFile: { insertFile(isDirectory: false) },
                    insertDirectory: { insertFile(isDirectory: true) }
                )
                .frame(width: 28, height: 28)
                .contentShape(Circle())
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
        .onChange(of: text) { newValue in
            updateMenuHint(for: newValue)
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

    /// 检测是否在 -i 后（高亮菜单）
    private func updateMenuHint(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let endsWithInputFlag = trimmed.hasSuffix("-i") || text.hasSuffix("-i ")

        withAnimation(.easeInOut(duration: 0.2)) {
            shouldHighlightMenu = endsWithInputFlag
        }
    }
}

// MARK: - Inline Menu (悬浮工具入口)

private struct CommandInlineMenu: View {
    var isHighlighted: Bool = false
    let insertFile: () -> Void
    let insertDirectory: () -> Void

    @State private var isHovering = false

    var body: some View {
        Menu {
            Button(action: insertFile) {
                Label("插入文件…", systemImage: "doc")
            }
            Button(action: insertDirectory) {
                Label("插入目录…", systemImage: "folder")
            }
            Divider()
            Text("💡 可直接从 Finder 拖入文件")
                .font(.caption)
        } label: {
            Image(systemName: isHighlighted ? "plus.circle.fill" : "ellipsis.circle")
                .foregroundColor(isHighlighted ? .accentColor : .secondary)
                .font(.system(size: 14, weight: isHighlighted ? .medium : .regular))
                .padding(6)
                .background(
                    Circle()
                        .fill(backgroundColor)
                )
                .overlay(
                    Circle()
                        .stroke(isHighlighted ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                )
                .scaleEffect(isHovering ? 1.1 : 1.0)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .help(isHighlighted ? "检测到 -i，建议插入输入文件" : "插入文件或目录路径")
    }

    private var backgroundColor: Color {
        if isHighlighted {
            return Color.accentColor.opacity(0.1)
        }
        return isHovering ? Color.black.opacity(0.08) : Color.black.opacity(0.04)
    }
}

// MARK: - NSViewRepresentable

struct CommandTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var insertPathHandler: ((String) -> Void)?
    @Binding var isFocused: Bool

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

        /// 在光标位置插入文本（带智能空格）
        func insertAtCursor(_ path: String) {
            guard let textView = textView else { return }

            let range = textView.selectedRange()
            let textWithSpacing = addSmartSpacing(for: path, at: range, in: textView.string)

            textView.insertText(textWithSpacing, replacementRange: range)
            parent.text = textView.string
        }

        /// 智能添加空格
        private func addSmartSpacing(for path: String, at range: NSRange, in text: String) -> String {
            var result = path
            let chars = Array(text)

            // 检查前一个字符
            if range.location > 0 {
                let prevIndex = range.location - 1
                if prevIndex < chars.count && !chars[prevIndex].isWhitespace {
                    result = " " + result
                }
            }

            // 检查后一个字符
            let nextIndex = range.location + range.length
            if nextIndex < chars.count && !chars[nextIndex].isWhitespace {
                result = result + " "
            }

            return result
        }
    }
}

// MARK: - Custom NSTextView with Drag Support

final class CommandNSTextView: NSTextView {

    /// 当前 hover 的路径范围（用于高亮）
    private var hoveredPathRange: NSRange?

    /// hover 高亮的背景颜色
    private let pathHighlightColor = NSColor.controlAccentColor.withAlphaComponent(0.1)

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

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let url = urls.first else {
            return super.performDragOperation(sender)
        }

        // 获取拖拽位置对应的字符索引
        let point = convert(sender.draggingLocation, from: nil)
        let characterIndex = getInsertionCharacterIndex(at: point)

        // 构建带引号的路径（带智能空格）
        let escapedPath = "\"\(url.path)\""
        let range = NSRange(location: characterIndex, length: 0)
        let textWithSpacing = addSmartSpacing(for: escapedPath, at: range)

        // 在指定位置插入
        insertText(textWithSpacing, replacementRange: range)

        return true
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

    /// 智能添加空格
    private func addSmartSpacing(for path: String, at range: NSRange) -> String {
        var result = path
        let chars = Array(string)

        // 检查前一个字符
        if range.location > 0 {
            let prevIndex = range.location - 1
            if prevIndex < chars.count && !chars[prevIndex].isWhitespace {
                result = " " + result
            }
        }

        // 检查后一个字符
        let nextIndex = range.location + range.length
        if nextIndex < chars.count && !chars[nextIndex].isWhitespace {
            result = result + " "
        }

        return result
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

    /// 检测点击位置的路径（带范围信息）
    private func detectPathInfoAt(_ point: NSPoint) -> PathInfo? {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return nil
        }

        // 获取字符索引
        var adjustedPoint = point
        adjustedPoint.x -= textContainerInset.width
        adjustedPoint.y -= textContainerInset.height

        let glyphIndex = layoutManager.glyphIndex(for: adjustedPoint, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        // 在当前位置周围查找路径
        let text = string
        guard characterIndex < text.count else { return nil }

        // 查找引号包裹的路径
        if let info = findQuotedPathInfo(in: text, around: characterIndex) {
            return info
        }

        // 查找以 / 开头的路径
        if let info = findSlashPathInfo(in: text, around: characterIndex) {
            return info
        }

        return nil
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
