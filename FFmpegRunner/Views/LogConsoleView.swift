//
//  LogConsoleView.swift
//  FFmpegRunner
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 语义颜色

extension Color {
    enum Console {
        static let errorBackground = Color.red.opacity(0.08)
        static let activeHighlight = Color.accentColor.opacity(0.05)
        static let stderrText = Color(NSColor.systemOrange).opacity(0.9)
    }
}

// MARK: - 文件名格式化

private let filenameFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd_HHmmss"
    return f
}()

// MARK: - 控制台主题

private enum ConsoleTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let emphasisFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let timestampFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let metadataFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static let background = NSColor.textBackgroundColor
    static let chromeBackground = NSColor.controlBackgroundColor
    static let border = NSColor.separatorColor.withAlphaComponent(0.22)
    static let divider = NSColor.separatorColor.withAlphaComponent(0.18)

    static let text = NSColor.textColor
    static let timestamp = NSColor.secondaryLabelColor.withAlphaComponent(0.6)
    static let debug = NSColor.secondaryLabelColor
    static let warning = NSColor.systemOrange.withAlphaComponent(0.92)
    static let error = NSColor.systemRed.withAlphaComponent(0.95)
    static let stderr = NSColor.systemOrange.withAlphaComponent(0.88)
    static let errorBackground = NSColor.systemRed.withAlphaComponent(0.08)
    static let activeHighlight = NSColor.controlAccentColor.withAlphaComponent(0.05)
}

private final class ConsoleLogTextView: NSTextView {
    var onUserScrollEvent: (() -> Void)?
    var lineMenuProvider: ((NSPoint) -> NSMenu?)?

    override func scrollWheel(with event: NSEvent) {
        onUserScrollEvent?()
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return lineMenuProvider?(point) ?? super.menu(for: event)
    }
}

// MARK: - LogConsoleView

struct LogConsoleView: View {
    @EnvironmentObject var viewModel: ExecutionViewModel

    @State private var showExportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            ConsoleHeaderView(
                autoScroll: $viewModel.autoScroll,
                logFilter: $viewModel.logFilter,
                searchText: $viewModel.searchText,
                onClear: viewModel.clearLogs,
                onExport: { showExportSheet = true },
                state: viewModel.state,
                isFFmpegAvailable: viewModel.isFFmpegAvailable,
                matchCount: viewModel.searchText.isEmpty ? nil : viewModel.visibleLogs.count
            )

            Divider()

            LogContentView(
                logs: viewModel.visibleLogs,
                autoScroll: $viewModel.autoScroll,
                isRunning: viewModel.state.isRunning
            )

            ConsoleStatusBar(
                logCount: viewModel.visibleLogs.count,
                lastResult: viewModel.lastResult,
                ffmpegVersion: viewModel.ffmpegVersionShort,
                state: viewModel.state
            )
        }
        .fileExporter(
            isPresented: $showExportSheet,
            document: LogDocument(content: viewModel.exportLogs()),
            contentType: .plainText,
            defaultFilename: "ffmpeg_log_\(filenameFormatter.string(from: Date())).txt"
        ) { _ in }
    }
}

// MARK: - ConsoleHeaderView

struct ConsoleHeaderView: View {
    @Binding var autoScroll: Bool
    @Binding var logFilter: LogFilter
    @Binding var searchText: String
    let onClear: () -> Void
    let onExport: () -> Void
    let state: ExecutionState
    let isFFmpegAvailable: Bool
    let matchCount: Int?

    @State private var showClearConfirm = false
    @State private var showSearch = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("控制台")
                    .font(.headline)

                ExecutionStatusBadge(state: state)

                Spacer()

                if !isFFmpegAvailable {
                    Label("FFmpeg 未找到", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Menu {
                    ForEach(LogFilter.allCases, id: \.self) { filter in
                        Button {
                            logFilter = filter
                        } label: {
                            HStack {
                                Text(filter.rawValue)
                                if logFilter == filter {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: logFilter == .all
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .help("日志过滤: \(logFilter.rawValue)")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSearch.toggle()
                        if showSearch {
                            isSearchFocused = true
                        } else {
                            searchText = ""
                        }
                    }
                } label: {
                    Image(systemName: showSearch || !searchText.isEmpty
                          ? "magnifyingglass.circle.fill"
                          : "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .help("搜索日志")
                .keyboardShortcut("f", modifiers: .command)

                Toggle(isOn: $autoScroll) {
                    Image(systemName: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .help("自动滚动到底部")

                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .help("导出日志")

                Button {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("清空日志")
                .confirmationDialog(
                    "确定要清空所有日志吗？",
                    isPresented: $showClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("清空", role: .destructive, action: onClear)
                    Button("取消", role: .cancel) {}
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if showSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.caption)

                    TextField("搜索日志...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .monospaced))
                        .focused($isSearchFocused)
                        .onExitCommand {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSearch = false
                                searchText = ""
                            }
                        }

                    if let count = matchCount {
                        Text("\(count) 条匹配")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - ExecutionStatusBadge

struct ExecutionStatusBadge: View {
    let state: ExecutionState

    var body: some View {
        HStack(spacing: 4) {
            if state.isRunning {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else {
                Circle()
                    .fill(state.displayColor)
                    .frame(width: 8, height: 8)
            }
            Text(state.displayText).font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(state.displayColor.opacity(0.1))
        .cornerRadius(4)
    }
}

// MARK: - LogContentView

struct LogContentView: View {
    let logs: [LogEntry]
    @Binding var autoScroll: Bool
    let isRunning: Bool

    var body: some View {
        ZStack {
            Color(ConsoleTheme.background)

            InteractiveLogConsoleView(
                logs: logs,
                isRunning: isRunning,
                followEnabled: $autoScroll
            )

            if logs.isEmpty {
                ConsoleEmptyState(isRunning: isRunning)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(ConsoleTheme.divider))
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(ConsoleTheme.border))
                .frame(height: 1)
        }
    }
}

private struct ConsoleEmptyState: View {
    let isRunning: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isRunning ? "ellipsis.message" : "terminal")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)

            Text(isRunning ? "等待输出..." : "控制台已就绪")
                .font(.subheadline.weight(.medium))

            Text(
                isRunning
                ? "新的 FFmpeg 输出会持续追加到这里。"
                : "运行命令后，这里会显示可选择、可搜索、可暂停跟随的日志。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: 320)
    }
}

// MARK: - InteractiveLogConsoleView

private struct InteractiveLogConsoleView: NSViewRepresentable {
    let logs: [LogEntry]
    let isRunning: Bool
    @Binding var followEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = ConsoleLogTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = ConsoleTheme.background
        textView.textColor = .textColor
        textView.font = ConsoleTheme.font
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true

        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        context.coordinator.attach(scrollView: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(logs: logs, isRunning: isRunning)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var parent: InteractiveLogConsoleView

        private weak var scrollView: NSScrollView?
        private weak var textView: ConsoleLogTextView?
        private var boundsObserver: NSObjectProtocol?
        private var liveScrollStartObserver: NSObjectProtocol?
        private var liveScrollEndObserver: NSObjectProtocol?

        private var suppressViewportSync = false
        private var lastRenderFingerprint: Int?
        private var lastFollowEnabled: Bool
        private let bottomThreshold: CGFloat = 12
        private let userScrollGraceInterval: TimeInterval = 0.35
        private var lastUserScrollTimestamp: TimeInterval = 0
        private var isLiveScrolling = false
        private var renderedLines: [ConsoleRenderedLine] = []
        private var contextMenuMessage: String?
        private var contextMenuFullLog: String?

        init(_ parent: InteractiveLogConsoleView) {
            self.parent = parent
            self.lastFollowEnabled = parent.followEnabled
            super.init()
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let liveScrollStartObserver {
                NotificationCenter.default.removeObserver(liveScrollStartObserver)
            }
            if let liveScrollEndObserver {
                NotificationCenter.default.removeObserver(liveScrollEndObserver)
            }
        }

        func attach(scrollView: NSScrollView, textView: ConsoleLogTextView) {
            self.scrollView = scrollView
            self.textView = textView

            textView.onUserScrollEvent = { [weak self] in
                self?.markUserScroll()
            }
            textView.lineMenuProvider = { [weak self] point in
                self?.makeLineMenu(at: point)
            }

            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.syncViewportState(allowFollowStateChange: self?.isLikelyUserScroll ?? false)
            }

            liveScrollStartObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.markUserScroll()
                self?.isLiveScrolling = true
            }

            liveScrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.markUserScroll()
                self?.isLiveScrolling = false
                self?.syncViewportState(allowFollowStateChange: true)
            }
        }

        func update(logs: [LogEntry], isRunning: Bool) {
            guard let scrollView, let textView else { return }

            let currentFollowEnabled = parent.followEnabled
            let followWasResumed = currentFollowEnabled && !lastFollowEnabled
            let renderFingerprint = ConsoleTextRenderer.fingerprint(for: logs, isRunning: isRunning)
            let contentChanged = renderFingerprint != lastRenderFingerprint

            if contentChanged {
                let selectedRange = textView.selectedRange()
                let visibleOrigin = scrollView.contentView.bounds.origin

                suppressViewportSync = true
                syncTextStorage(logs: logs, isRunning: isRunning)
                textView.setSelectedRange(.clamped(selectedRange, maxUTF16Length: textView.string.utf16.count))

                if currentFollowEnabled {
                    scrollToBottom()
                } else {
                    restoreVisibleOrigin(visibleOrigin)
                }

                scheduleViewportSync()
            } else if currentFollowEnabled && followWasResumed {
                suppressViewportSync = true
                scrollToBottom()
                scheduleViewportSync()
            }

            lastRenderFingerprint = renderFingerprint
            lastFollowEnabled = currentFollowEnabled
        }

        private func syncTextStorage(logs: [LogEntry], isRunning: Bool) {
            guard let textView, let textStorage = textView.textStorage else { return }

            let update = ConsoleTextRenderer.makeUpdate(
                logs: logs,
                previous: renderedLines,
                isRunning: isRunning
            )

            textStorage.beginEditing()
            defer { textStorage.endEditing() }

            switch update {
            case .rebuild(let render):
                textStorage.setAttributedString(render.text)
                renderedLines = render.lines

            case .incremental(let changes, let append):
                for change in changes {
                    applyReplacement(change, textStorage: textStorage)
                }

                if let append {
                    if textStorage.length > 0 && append.leadingNewline {
                        textStorage.append(NSAttributedString(string: "\n"))
                    }

                    let appendStart = textStorage.length
                    textStorage.append(append.text)

                    var location = appendStart
                    for (index, line) in append.lines.enumerated() {
                        if index > 0 {
                            location += 1
                        }
                        renderedLines.append(
                            ConsoleRenderedLine(
                                id: line.id,
                                fingerprint: line.fingerprint,
                                range: NSRange(location: location, length: line.text.length)
                            )
                        )
                        location += line.text.length
                    }
                }
            }
        }

        private func applyReplacement(
            _ change: ConsoleLineChange,
            textStorage: NSTextStorage
        ) {
            let currentRange = renderedLines[change.index].range
            textStorage.replaceCharacters(in: currentRange, with: change.text)

            let delta = change.text.length - currentRange.length
            renderedLines[change.index].fingerprint = change.fingerprint
            renderedLines[change.index].range.length = change.text.length

            guard delta != 0 else { return }
            for nextIndex in (change.index + 1)..<renderedLines.count {
                renderedLines[nextIndex].range.location += delta
            }
        }

        private func scheduleViewportSync() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.suppressViewportSync = false
                self.syncViewportState(allowFollowStateChange: false)
            }
        }

        private var isLikelyUserScroll: Bool {
            isLiveScrolling ||
            (ProcessInfo.processInfo.systemUptime - lastUserScrollTimestamp) <= userScrollGraceInterval
        }

        private func markUserScroll() {
            lastUserScrollTimestamp = ProcessInfo.processInfo.systemUptime
        }

        private func syncViewportState(allowFollowStateChange: Bool) {
            guard !suppressViewportSync, let scrollView else { return }

            if isScrolledToBottom(scrollView) {
                if allowFollowStateChange && !parent.followEnabled {
                    setFollowEnabled(true)
                }
            } else if allowFollowStateChange && parent.followEnabled {
                setFollowEnabled(false)
            }
        }

        private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let visibleMaxY = scrollView.contentView.bounds.maxY
            return documentHeight - visibleMaxY <= bottomThreshold
        }

        private func scrollToBottom() {
            guard let textView else { return }
            let endRange = NSRange(location: textView.string.utf16.count, length: 0)
            textView.scrollRangeToVisible(endRange)
        }

        private func restoreVisibleOrigin(_ origin: NSPoint) {
            guard let scrollView else { return }

            let visibleHeight = scrollView.contentView.bounds.height
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let maxY = max(0, documentHeight - visibleHeight)
            let clampedOrigin = NSPoint(x: 0, y: min(max(origin.y, 0), maxY))

            scrollView.contentView.scroll(to: clampedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func setFollowEnabled(_ value: Bool) {
            guard parent.followEnabled != value else { return }
            lastFollowEnabled = value
            DispatchQueue.main.async { [weak self] in
                self?.parent.followEnabled = value
            }
        }

        private func makeLineMenu(at point: NSPoint) -> NSMenu? {
            guard let lineEntry = lineEntry(at: point) else { return nil }

            contextMenuMessage = lineEntry.message
            contextMenuFullLog = fullLogString(for: lineEntry)

            let menu = NSMenu()
            let copyMessageItem = NSMenuItem(
                title: "复制正文",
                action: #selector(copyContextMenuMessage),
                keyEquivalent: ""
            )
            copyMessageItem.target = self
            menu.addItem(copyMessageItem)

            let copyFullLogItem = NSMenuItem(
                title: "复制完整日志",
                action: #selector(copyContextMenuFullLog),
                keyEquivalent: ""
            )
            copyFullLogItem.target = self
            menu.addItem(copyFullLogItem)
            return menu
        }

        private func lineEntry(at point: NSPoint) -> LogEntry? {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  !renderedLines.isEmpty
            else {
                return nil
            }

            let containerPoint = NSPoint(
                x: point.x - textView.textContainerOrigin.x,
                y: point.y - textView.textContainerOrigin.y
            )
            let hitRect = layoutManager.usedRect(for: textContainer).insetBy(dx: -6, dy: -2)
            guard hitRect.contains(containerPoint) else { return nil }

            let charIndex = layoutManager.characterIndex(
                for: containerPoint,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            guard let lineIndex = renderedLineIndex(forCharacterIndex: charIndex) else { return nil }
            guard parent.logs.indices.contains(lineIndex) else { return nil }

            textView.setSelectedRange(renderedLines[lineIndex].range)
            return parent.logs[lineIndex]
        }

        private func fullLogString(for entry: LogEntry) -> String {
            "[\(entry.formattedTimestamp)] [\(entry.level.displayName)] \(entry.message)"
        }

        private func renderedLineIndex(forCharacterIndex charIndex: Int) -> Int? {
            guard !renderedLines.isEmpty else { return nil }

            for (index, line) in renderedLines.enumerated() {
                let lower = line.range.location
                let upper = NSMaxRange(line.range)

                if lower...upper ~= charIndex {
                    return index
                }

                if index + 1 < renderedLines.count {
                    let nextLower = renderedLines[index + 1].range.location
                    if charIndex > upper && charIndex < nextLower {
                        return index
                    }
                }
            }

            if let lastIndex = renderedLines.indices.last,
               charIndex >= renderedLines[lastIndex].range.location {
                return lastIndex
            }

            return nil
        }

        @objc
        private func copyContextMenuMessage() {
            guard let contextMenuMessage else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(contextMenuMessage, forType: .string)
        }

        @objc
        private func copyContextMenuFullLog() {
            guard let contextMenuFullLog else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(contextMenuFullLog, forType: .string)
        }
    }
}

private struct ConsoleRenderableLine {
    let id: UUID
    let fingerprint: Int
    let text: NSAttributedString
}

private struct ConsoleRenderedLine {
    let id: UUID
    var fingerprint: Int
    var range: NSRange
}

private struct ConsoleRenderState {
    let text: NSAttributedString
    let lines: [ConsoleRenderedLine]
}

private struct ConsoleAppendBlock {
    let leadingNewline: Bool
    let text: NSAttributedString
    let lines: [ConsoleRenderableLine]
}

private struct ConsoleLineChange {
    let index: Int
    let fingerprint: Int
    let text: NSAttributedString
}

private enum ConsoleRenderUpdate {
    case rebuild(ConsoleRenderState)
    case incremental(changes: [ConsoleLineChange], append: ConsoleAppendBlock?)
}

// MARK: - ConsoleTextRenderer

private enum ConsoleTextRenderer {
    private static let timestampColumn: CGFloat = 64
    private static let levelColumn: CGFloat = 100
    private static let messageColumn: CGFloat = 108

    static func fingerprint(for logs: [LogEntry], isRunning: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(isRunning)
        hasher.combine(logs.count)

        for entry in logs {
            hasher.combine(entry.id)
            hasher.combine(entry.level.rawValue)
            hasher.combine(entry.message)
            hasher.combine(entry.isStderr)
            hasher.combine(entry.isProgress)
            hasher.combine(entry.containsErrorKeyword)
            hasher.combine(entry.formattedTimestamp)
        }

        return hasher.finalize()
    }

    static func makeUpdate(
        logs: [LogEntry],
        previous: [ConsoleRenderedLine],
        isRunning: Bool
    ) -> ConsoleRenderUpdate {
        let targetLines = logs.enumerated().map { index, entry in
            makeLine(
                for: entry,
                highlightLatest: index == logs.indices.last && isRunning
            )
        }

        let previousIDs = previous.map(\.id)
        let targetIDs = targetLines.map(\.id)

        if previous.isEmpty || targetLines.isEmpty || targetLines.count < previous.count {
            return .rebuild(buildRender(from: targetLines))
        }

        if previousIDs == targetIDs {
            let changes = targetLines.enumerated().compactMap { index, line -> ConsoleLineChange? in
                guard previous[index].fingerprint != line.fingerprint else { return nil }
                return ConsoleLineChange(index: index, fingerprint: line.fingerprint, text: line.text)
            }
            return .incremental(changes: changes, append: nil)
        }

        guard Array(targetIDs.prefix(previousIDs.count)) == previousIDs else {
            return .rebuild(buildRender(from: targetLines))
        }

        let prefixChanges = previous.indices.compactMap { index -> ConsoleLineChange? in
            guard previous[index].fingerprint != targetLines[index].fingerprint else { return nil }
            return ConsoleLineChange(
                index: index,
                fingerprint: targetLines[index].fingerprint,
                text: targetLines[index].text
            )
        }

        let appendedLines = Array(targetLines.dropFirst(previous.count))
        let appendBlock: ConsoleAppendBlock? = appendedLines.isEmpty
            ? nil
            : ConsoleAppendBlock(
                leadingNewline: !previous.isEmpty,
                text: joinedText(from: appendedLines),
                lines: appendedLines
            )

        return .incremental(changes: prefixChanges, append: appendBlock)
    }

    private static func buildRender(from lines: [ConsoleRenderableLine]) -> ConsoleRenderState {
        let text = NSMutableAttributedString()
        var rendered: [ConsoleRenderedLine] = []

        for index in lines.indices {
            if index > 0 {
                text.append(NSAttributedString(string: "\n"))
            }

            let start = text.length
            text.append(lines[index].text)
            rendered.append(
                ConsoleRenderedLine(
                    id: lines[index].id,
                    fingerprint: lines[index].fingerprint,
                    range: NSRange(location: start, length: lines[index].text.length)
                )
            )
        }

        return ConsoleRenderState(text: text, lines: rendered)
    }

    private static func joinedText(from lines: [ConsoleRenderableLine]) -> NSAttributedString {
        let text = NSMutableAttributedString()

        for index in lines.indices {
            if index > 0 {
                text.append(NSAttributedString(string: "\n"))
            }
            text.append(lines[index].text)
        }

        return text
    }

    private static func makeLine(
        for entry: LogEntry,
        highlightLatest: Bool
    ) -> ConsoleRenderableLine {
        ConsoleRenderableLine(
            id: entry.id,
            fingerprint: lineFingerprint(for: entry, highlightLatest: highlightLatest),
            text: line(for: entry, highlightLatest: highlightLatest)
        )
    }

    private static func lineFingerprint(for entry: LogEntry, highlightLatest: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(entry.id)
        hasher.combine(entry.message)
        hasher.combine(entry.level.rawValue)
        hasher.combine(entry.isStderr)
        hasher.combine(entry.isProgress)
        hasher.combine(entry.containsErrorKeyword)
        hasher.combine(entry.formattedTimestamp)
        hasher.combine(highlightLatest)
        return hasher.finalize()
    }

    private static func line(for entry: LogEntry, highlightLatest: Bool) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let paragraphStyle = paragraphStyle()
        let lineBackground = backgroundColor(for: entry, highlightLatest: highlightLatest)
        let level = shortLevelLabel(for: entry).padding(toLength: 5, withPad: " ", startingAt: 0)

        line.append(
            fragment(
                shortTimestamp(for: entry),
                color: ConsoleTheme.timestamp,
                background: lineBackground,
                font: ConsoleTheme.timestampFont,
                paragraphStyle: paragraphStyle
            )
        )
        line.append(fragment("\t", background: lineBackground, paragraphStyle: paragraphStyle))
        line.append(
            fragment(
                level,
                color: metadataColor(for: entry),
                background: lineBackground,
                font: ConsoleTheme.metadataFont,
                paragraphStyle: paragraphStyle
            )
        )
        line.append(fragment("\t", background: lineBackground, paragraphStyle: paragraphStyle))
        line.append(
            fragment(
                entry.message,
                color: messageColor(for: entry),
                background: lineBackground,
                font: entry.level == .error ? ConsoleTheme.emphasisFont : ConsoleTheme.font,
                paragraphStyle: paragraphStyle
            )
        )

        return line
    }

    private static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        style.paragraphSpacing = 0
        style.tabStops = [
            NSTextTab(textAlignment: .left, location: timestampColumn),
            NSTextTab(textAlignment: .left, location: levelColumn),
            NSTextTab(textAlignment: .left, location: messageColumn)
        ]
        style.defaultTabInterval = messageColumn
        style.headIndent = messageColumn
        return style
    }

    private static func fragment(
        _ string: String,
        color: NSColor? = nil,
        background: NSColor? = nil,
        font: NSFont = ConsoleTheme.font,
        paragraphStyle: NSParagraphStyle
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]

        if let color {
            attributes[.foregroundColor] = color
        }
        if let background {
            attributes[.backgroundColor] = background
        }

        return NSAttributedString(string: string, attributes: attributes)
    }

    private static func shortTimestamp(for entry: LogEntry) -> String {
        String(entry.formattedTimestamp.prefix(8))
    }

    private static func shortLevelLabel(for entry: LogEntry) -> String {
        switch entry.level {
        case .info:
            return "INFO"
        case .warning:
            return "WARN"
        case .error:
            return "ERR"
        case .debug:
            return "DBG"
        }
    }

    private static func metadataColor(for entry: LogEntry) -> NSColor {
        switch entry.level {
        case .info:
            return entry.isStderr ? ConsoleTheme.stderr : ConsoleTheme.timestamp
        case .warning:
            return ConsoleTheme.warning
        case .error:
            return ConsoleTheme.error
        case .debug:
            return ConsoleTheme.debug
        }
    }

    private static func messageColor(for entry: LogEntry) -> NSColor {
        if entry.level == .error {
            return ConsoleTheme.error
        }
        if entry.containsErrorKeyword {
            return ConsoleTheme.warning
        }

        switch entry.level {
        case .debug:
            return ConsoleTheme.debug
        case .warning:
            return ConsoleTheme.warning
        default:
            return ConsoleTheme.text
        }
    }

    private static func backgroundColor(for entry: LogEntry, highlightLatest: Bool) -> NSColor? {
        if entry.level == .error || entry.containsErrorKeyword {
            return ConsoleTheme.errorBackground
        }
        if highlightLatest {
            return ConsoleTheme.activeHighlight
        }
        return nil
    }
}

// MARK: - ConsoleStatusBar

struct ConsoleStatusBar: View {
    let logCount: Int
    let lastResult: ExecutionResult?
    let ffmpegVersion: String?
    let state: ExecutionState

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Circle()
                    .fill(state.displayColor)
                    .frame(width: 6, height: 6)
                Text(state.displayText)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(state.displayColor)
            }

            Divider().frame(height: 12)

            Text("\(logCount) 条日志")
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()

            if let result = lastResult {
                Text("耗时: \(result.formattedDuration)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let version = ffmpegVersion {
                Divider().frame(height: 12)
                Text(version)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - LogDocument（用于导出）

struct LogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var content: String

    init(content: String) { self.content = content }

    init(configuration: ReadConfiguration) throws {
        content = configuration.file.regularFileContents
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: content.data(using: .utf8) ?? Data())
    }
}

// MARK: - Preview

#Preview {
    LogConsoleView()
        .environmentObject({
            let vm = ExecutionViewModel()
            vm.appendLog(LogEntry(timestamp: Date(), level: .info, message: "开始执行命令..."))
            vm.appendLog(LogEntry(timestamp: Date(), level: .debug, message: "frame=  100 fps=30 size=1024kB time=00:00:03.33"))
            vm.appendLog(LogEntry(timestamp: Date(), level: .debug, message: "frame=  150 fps=30 size=1536kB time=00:00:05.00"))
            vm.appendLog(LogEntry(timestamp: Date(), level: .info, message: "正在处理视频流..."))
            vm.appendLog(LogEntry(timestamp: Date(), level: .warning, message: "deprecated option used"))
            vm.appendLog(LogEntry(timestamp: Date(), level: .debug, message: "frame=  200 fps=29 size=2048kB time=00:00:06.67"))
            vm.appendLog(LogEntry(timestamp: Date(), level: .error, message: "Error opening file: Permission denied"))
            vm.appendLog(LogEntry(timestamp: Date(), level: .info, message: "尝试使用备用路径..."))
            return vm
        }())
        .frame(width: 700, height: 350)
}
