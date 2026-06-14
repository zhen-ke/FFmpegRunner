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
    static let progressFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let timestampFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let metadataFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static let background = NSColor.textBackgroundColor
    static let chromeBackground = NSColor.controlBackgroundColor
    static let border = NSColor.separatorColor.withAlphaComponent(0.22)
    static let divider = NSColor.separatorColor.withAlphaComponent(0.18)

    static let text = NSColor.textColor
    static let timestamp = NSColor.secondaryLabelColor
    static let debug = NSColor.secondaryLabelColor
    static let warning = NSColor.systemOrange.withAlphaComponent(0.92)
    static let error = NSColor.systemRed.withAlphaComponent(0.95)
    static let stderr = NSColor.systemOrange.withAlphaComponent(0.88)
    static let errorBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.systemRed.withAlphaComponent(0.16)
            : NSColor.systemRed.withAlphaComponent(0.08)
    }
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

enum ConsoleFollowPolicy {
    enum UserScrollState {
        case idle
        case recentManualScroll
        case manualResume
    }

    static func shouldFollowDuringContentUpdate(
        requestedFollow: Bool,
        viewportIsAtBottom: Bool,
        userScrollState: UserScrollState
    ) -> Bool {
        guard requestedFollow else { return false }

        switch userScrollState {
        case .manualResume:
            return true
        case .recentManualScroll:
            return viewportIsAtBottom
        case .idle:
            return true
        }
    }
}

enum ConsoleLogMessageFormatter {
    private static let progressFields = ["frame", "fps", "size", "time", "speed"]

    static func displayMessage(for entry: LogEntry) -> String {
        guard entry.isProgress else { return entry.message }

        let fields = progressFields.compactMap { key -> String? in
            guard let value = fieldValue(for: key, in: entry.message) else { return nil }
            return "\(key) \(value)"
        }

        return fields.isEmpty ? entry.message : fields.joined(separator: "   ")
    }

    private static func fieldValue(for key: String, in message: String) -> String? {
        let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: key))=\s*([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              let valueRange = Range(match.range(at: 1), in: message)
        else {
            return nil
        }

        return String(message[valueRange])
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
                isRegexSearchEnabled: $viewModel.isRegexSearchEnabled,
                onClear: viewModel.clearLogs,
                onExport: { showExportSheet = true },
                state: viewModel.state,
                isFFmpegAvailable: viewModel.isFFmpegAvailable,
                matchCount: viewModel.searchText.isEmpty || viewModel.regexSearchError != nil
                    ? nil
                    : viewModel.visibleLogs.count,
                regexSearchError: viewModel.regexSearchError
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
                state: viewModel.state,
                progress: viewModel.progress
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
    @Binding var isRegexSearchEnabled: Bool
    let onClear: () -> Void
    let onExport: () -> Void
    let state: ExecutionState
    let isFFmpegAvailable: Bool
    let matchCount: Int?
    let regexSearchError: String?

    @State private var showClearConfirm = false
    @State private var showSearch = false
    @State private var showLogHistory = false
    @State private var focusSearchField = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("控制台")
                    .font(.headline)

                ExecutionStatusBadge(state: state)

                Spacer()

                if !isFFmpegAvailable {
                    Label("FFmpeg 未找到", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Picker("过滤", selection: $logFilter) {
                    ForEach(LogFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 144)
                .help("过滤日志")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSearch.toggle()
                        if showSearch {
                            focusSearchField = true
                        } else {
                            searchText = ""
                            focusSearchField = false
                        }
                    }
                } label: {
                    Image(systemName: showSearch || !searchText.isEmpty
                          ? "magnifyingglass.circle.fill"
                          : "magnifyingglass")
                }
                .consoleToolbarButtonStyle()
                .help("搜索日志")
                .keyboardShortcut("f", modifiers: .command)

                Button {
                    autoScroll.toggle()
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .consoleToolbarButtonStyle(isSelected: autoScroll)
                .help("自动滚动到底部")

                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up")
                }
                .consoleToolbarButtonStyle()
                .help("导出日志")

                Button {
                    showLogHistory.toggle()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .consoleToolbarButtonStyle()
                .help("历史日志")
                .popover(isPresented: $showLogHistory, arrowEdge: .bottom) {
                    LogHistoryPopover()
                }

                Button {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .consoleToolbarButtonStyle()
                .help("清空日志")
                // Note: SwiftUI automatically places Cancel on left and Clear on right on macOS
                .confirmationDialog(
                    "清空所有日志",
                    isPresented: $showClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("清空", role: .destructive, action: onClear)
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("此操作无法撤销。")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if showSearch {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        NativeSearchField(
                            text: $searchText,
                            placeholder: isRegexSearchEnabled ? "输入正则表达式..." : "搜索日志...",
                            shouldFocus: $focusSearchField
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSearch = false
                                searchText = ""
                            }
                        }
                        .frame(height: 22)

                        Toggle(isOn: $isRegexSearchEnabled) {
                            Text(".*")
                                .font(.system(.caption, design: .monospaced))
                        }
                        .toggleStyle(.button)
                        .help("切换为正则搜索")

                        if let count = matchCount {
                            Text("\(count) 条匹配")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let regexSearchError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                            Text(regexSearchError)
                                .font(.caption2)
                        }
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

private extension View {
    func consoleToolbarButtonStyle(isSelected: Bool = false) -> some View {
        self
            .font(.system(size: 15, weight: .medium))
            .frame(width: 30, height: 30)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                Image(systemName: "circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(state.displayColor)
                    .font(.system(size: 8))
            }
            Text(state.displayText).font(.caption)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(state.displayColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
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
                : "运行后日志将在此显示"
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
            var effectiveFollowEnabled = currentFollowEnabled
            let followWasResumed = currentFollowEnabled && !lastFollowEnabled
            let renderFingerprint = ConsoleTextRenderer.fingerprint(for: logs, isRunning: isRunning)
            let contentChanged = renderFingerprint != lastRenderFingerprint
            let shouldFollowContent = ConsoleFollowPolicy.shouldFollowDuringContentUpdate(
                requestedFollow: currentFollowEnabled,
                viewportIsAtBottom: isScrolledToBottom(scrollView),
                userScrollState: followWasResumed ? .manualResume : currentUserScrollState
            )

            if contentChanged {
                let selectedRange = textView.selectedRange()
                let visibleOrigin = scrollView.contentView.bounds.origin

                suppressViewportSync = true
                syncTextStorage(logs: logs, isRunning: isRunning)
                textView.setSelectedRange(.clamped(selectedRange, maxUTF16Length: textView.string.utf16.count))

                if shouldFollowContent {
                    scrollToBottom()
                } else {
                    restoreVisibleOrigin(visibleOrigin)
                    if currentFollowEnabled {
                        setFollowEnabled(false)
                        effectiveFollowEnabled = false
                    }
                }

                scheduleViewportSync()
            } else if currentFollowEnabled && followWasResumed {
                suppressViewportSync = true
                scrollToBottom()
                scheduleViewportSync()
            }

            lastRenderFingerprint = renderFingerprint
            lastFollowEnabled = effectiveFollowEnabled
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

        private var currentUserScrollState: ConsoleFollowPolicy.UserScrollState {
            isLikelyUserScroll ? .recentManualScroll : .idle
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
            guard let scrollView else { return }

            let visibleHeight = scrollView.contentView.bounds.height
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let targetOrigin = NSPoint(x: 0, y: max(0, documentHeight - visibleHeight))

            scrollView.contentView.scroll(to: targetOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
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
        let paragraphStyle = paragraphStyle(isProgress: entry.isProgress)
        let lineBackground = backgroundColor(for: entry, highlightLatest: highlightLatest)
        let level = shortLevelLabel(for: entry).padding(toLength: 5, withPad: " ", startingAt: 0)
        let message = ConsoleLogMessageFormatter.displayMessage(for: entry)

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
                message,
                color: messageColor(for: entry),
                background: lineBackground,
                font: messageFont(for: entry),
                paragraphStyle: paragraphStyle
            )
        )

        return line
    }

    private static func paragraphStyle(isProgress: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = isProgress ? 1 : 2
        style.paragraphSpacing = 0
        style.tabStops = [
            NSTextTab(textAlignment: .left, location: timestampColumn),
            NSTextTab(textAlignment: .left, location: levelColumn),
            NSTextTab(textAlignment: .left, location: messageColumn)
        ]
        style.defaultTabInterval = messageColumn
        style.headIndent = 0
        return style
    }

    private static func messageFont(for entry: LogEntry) -> NSFont {
        if entry.level == .error {
            return ConsoleTheme.emphasisFont
        }
        if entry.isProgress {
            return ConsoleTheme.progressFont
        }
        return ConsoleTheme.font
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
        entry.formattedTimestamp
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
            return ConsoleTheme.timestamp
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
    var progress: FFmpegProgress? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 顶部分隔线 - 与上方的日志内容清晰分隔
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(height: 1)

            // 进度条（仅执行中且有进度数据时显示）
            if state.isRunning, let progress {
                TranscodeProgressBar(progress: progress)
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                // 进度条与状态栏之间的分隔线
                Rectangle()
                    .fill(Color(NSColor.separatorColor).opacity(0.6))
                    .frame(height: 1)
            }

            // 状态栏
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(state.displayColor)
                        .font(.system(size: 6))
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

                if let result = lastResult, !state.isRunning {
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
            .padding(.vertical, 6)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .animation(.easeInOut(duration: 0.25), value: progress != nil)
    }
}

// MARK: - TranscodeProgressBar

/// HIG-compliant 转码进度条
///
/// 设计原则（遵循 macOS Human Interface Guidelines）：
/// - 已知总时长时使用确定性进度条（determinate），显示百分比
/// - 未知总时长时使用不确定进度条（indeterminate），仅显示已处理信息
/// - 进度条高度使用系统标准尺寸（.regular controlSize）
/// - 信息文本使用 .secondary 颜色，不喧宾夺主
/// - 进度条颜色使用 .accentColor，与系统设置一致
struct TranscodeProgressBar: View {
    let progress: FFmpegProgress

    var body: some View {
        VStack(spacing: 4) {
            // 进度条
            if let fraction = progress.fractionCompleted {
                // 确定性进度条
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                // 不确定进度条（无总时长）
                ProgressView()
                    .progressViewStyle(.linear)
            }

            // 进度信息
            HStack(spacing: 0) {
                // 左侧：核心进度信息
                progressSummary
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                // 右侧：技术细节
                technicalDetails
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: - 左侧摘要

    @ViewBuilder
    private var progressSummary: some View {
        HStack(spacing: 8) {
            // 百分比（如果可用）
            if let fraction = progress.fractionCompleted {
                Text("\(Int(fraction * 100))%")
                    .fontWeight(.medium)
                    .monospacedDigit()
            }

            // 时间进度
            if let totalFormatted = progress.formattedTotalDuration {
                Text("\(progress.formattedTime) / \(totalFormatted)")
                    .monospacedDigit()
            } else {
                Text(progress.formattedTime)
                    .monospacedDigit()
            }

            // ETA
            if let eta = progress.formattedETA {
                Text("剩余 \(eta)")
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 右侧技术细节

    @ViewBuilder
    private var technicalDetails: some View {
        HStack(spacing: 8) {
            if progress.fps > 0 {
                Text("\(Int(progress.fps)) fps")
                    .monospacedDigit()
            }

            if let speed = progress.formattedSpeed {
                Text(speed)
                    .monospacedDigit()
            }

            if progress.sizeBytes > 0 {
                Text(progress.formattedSize)
                    .monospacedDigit()
            }
        }
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

// MARK: - LogHistoryPopover

struct LogHistoryPopover: View {
    @State private var savedLogs: [SavedLogInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Label("历史日志", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Button {
                    Task {
                        await loadSavedLogs()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("刷新列表")

                Button {
                    let url = LogPersistenceService.shared.logDirectoryURL
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("在 Finder 中打开日志目录")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            // 内容
            if isLoading {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("加载中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if savedLogs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无已保存的日志")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("执行命令后会自动保存日志")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(savedLogs) { logInfo in
                            LogHistoryRow(info: logInfo) {
                                await delete(logInfo)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 360, height: 400)
        .task {
            await loadSavedLogs()
        }
    }

    @MainActor
    private func loadSavedLogs() async {
        isLoading = true
        errorMessage = nil
        do {
            savedLogs = try await LogPersistenceService.shared.listSavedLogs()
        } catch {
            errorMessage = "加载失败: \(error.localizedDescription)"
        }
        isLoading = false
    }

    @MainActor
    private func delete(_ logInfo: SavedLogInfo) async {
        do {
            try await LogPersistenceService.shared.deleteLog(at: logInfo.id)
            savedLogs.removeAll { $0.id == logInfo.id }
        } catch {
            errorMessage = "删除失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - LogHistoryRow

private struct LogHistoryRow: View {
    let info: SavedLogInfo
    let onDelete: @Sendable () async -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static let byteCountFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.templateName ?? "自由命令")
                    .font(.system(.body, design: .default))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: info.date))
                    Text(Self.byteCountFormatter.string(fromByteCount: info.fileSize))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([info.id])
            } label: {
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("在 Finder 中显示")
            .accessibilityLabel("在 Finder 中显示")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([info.id])
            }
            Button("用默认编辑器打开") {
                NSWorkspace.shared.open(info.id)
            }
            Divider()
            Button("删除", role: .destructive) {
                Task {
                    await onDelete()
                }
            }
        }
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

// MARK: - NativeSearchField

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var shouldFocus: Bool
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = placeholder
        searchField.delegate = context.coordinator
        searchField.bezelStyle = .roundedBezel
        searchField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if shouldFocus {
            if nsView.window?.firstResponder !== nsView {
                nsView.window?.makeFirstResponder(nsView)
            }
            DispatchQueue.main.async {
                self.shouldFocus = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField

        init(_ parent: NativeSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
