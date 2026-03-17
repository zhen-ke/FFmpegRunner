//
//  LogConsoleView.swift
//  FFmpegRunner
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - 文件名格式化

private let filenameFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    return formatter
}()

// MARK: - 控制台主题

private enum ConsoleTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    static let background = NSColor.textBackgroundColor
    static let timestamp = NSColor.secondaryLabelColor.withAlphaComponent(0.72)
    static let debug = NSColor.secondaryLabelColor
    static let info = NSColor.systemBlue.withAlphaComponent(0.9)
    static let warning = NSColor.systemOrange
    static let error = NSColor.systemRed
    static let stderr = NSColor.systemOrange.withAlphaComponent(0.92)
    static let activeBackground = NSColor.controlAccentColor.withAlphaComponent(0.08)
    static let errorBackground = NSColor.systemRed.withAlphaComponent(0.08)
}

// MARK: - LogConsoleView

struct LogConsoleView: View {
    @EnvironmentObject var viewModel: ExecutionViewModel

    @State private var showExportSheet = false
    @State private var isAtBottom = true
    @State private var unreadCount = 0
    @State private var jumpToLatestToken = 0

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
                followEnabled: $viewModel.autoScroll,
                isRunning: viewModel.state.isRunning,
                isAtBottom: $isAtBottom,
                unreadCount: $unreadCount,
                jumpToLatestToken: jumpToLatestToken
            )

            if unreadCount > 0 && !viewModel.autoScroll {
                NewOutputBanner(unreadCount: unreadCount) {
                    viewModel.autoScroll = true
                    jumpToLatestToken += 1
                }
            }

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

// MARK: - NewOutputBanner

struct NewOutputBanner: View {
    let unreadCount: Int
    let onJumpToLatest: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line")
                .foregroundStyle(Color.accentColor)
                .font(.caption)

            Text("新日志 \(unreadCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("跳到最新", action: onJumpToLatest)
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08))
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
                        .foregroundStyle(.orange)
                }

                Picker("过滤", selection: $logFilter) {
                    ForEach(LogFilter.allCases, id: \.self) { filter in
                        Text(filter.shortLabel).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .help("日志过滤")

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
                    Image(systemName: autoScroll ? "arrow.down.to.line" : "pause.circle")
                        .foregroundStyle(autoScroll ? Color.primary : Color.orange)
                }
                .toggleStyle(.button)
                .help(autoScroll ? "自动滚动中（点击暂停）" : "已暂停（点击恢复）")
                .tint(autoScroll ? .accentColor : .orange)

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
                        .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                    }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
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

            Text(state.displayText)
                .font(.caption)
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
    @Binding var followEnabled: Bool
    let isRunning: Bool
    @Binding var isAtBottom: Bool
    @Binding var unreadCount: Int
    let jumpToLatestToken: Int

    var body: some View {
        InteractiveLogConsoleView(
            logs: logs,
            isRunning: isRunning,
            followEnabled: $followEnabled,
            isAtBottom: $isAtBottom,
            unreadCount: $unreadCount,
            jumpToLatestToken: jumpToLatestToken
        )
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - InteractiveLogConsoleView

private struct InteractiveLogConsoleView: NSViewRepresentable {
    let logs: [LogEntry]
    let isRunning: Bool
    @Binding var followEnabled: Bool
    @Binding var isAtBottom: Bool
    @Binding var unreadCount: Int
    let jumpToLatestToken: Int

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

        let textView = NSTextView()
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
        private weak var textView: NSTextView?
        private var boundsObserver: NSObjectProtocol?

        private var suppressViewportSync = false
        private var lastRenderFingerprint: Int?
        private var lastJumpToLatestToken: Int
        private var lastFollowEnabled: Bool
        private var previousLogIDs: [UUID] = []
        private var unreadCountSnapshot: Int
        private var isAtBottomSnapshot: Bool
        private let bottomThreshold: CGFloat = 12

        init(_ parent: InteractiveLogConsoleView) {
            self.parent = parent
            self.lastJumpToLatestToken = parent.jumpToLatestToken
            self.lastFollowEnabled = parent.followEnabled
            self.unreadCountSnapshot = parent.unreadCount
            self.isAtBottomSnapshot = parent.isAtBottom
            super.init()
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func attach(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView

            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.syncViewportState(userInitiated: true)
            }
        }

        func update(logs: [LogEntry], isRunning: Bool) {
            guard let scrollView, let textView else { return }

            let currentFollowEnabled = parent.followEnabled
            let followWasResumed = currentFollowEnabled && !lastFollowEnabled
            let jumpRequested = parent.jumpToLatestToken != lastJumpToLatestToken
            let currentLogIDs = logs.map(\.id)
            let appendedCount = appendedEntryCount(from: previousLogIDs, to: currentLogIDs)
            let renderFingerprint = ConsoleTextRenderer.fingerprint(for: logs, isRunning: isRunning)
            let contentChanged = renderFingerprint != lastRenderFingerprint
            let isInitialRender = lastRenderFingerprint == nil

            if contentChanged {
                let selectedRange = textView.selectedRange()
                let visibleOrigin = scrollView.contentView.bounds.origin

                suppressViewportSync = true
                textView.textStorage?.setAttributedString(
                    ConsoleTextRenderer.attributedString(for: logs, isRunning: isRunning)
                )
                textView.setSelectedRange(.clamped(selectedRange, maxUTF16Length: textView.string.utf16.count))

                if currentFollowEnabled {
                    scrollToBottom()
                } else {
                    restoreVisibleOrigin(visibleOrigin)
                }

                scheduleViewportSync()
            } else if currentFollowEnabled && (followWasResumed || jumpRequested) {
                suppressViewportSync = true
                scrollToBottom()
                scheduleViewportSync()
            }

            if logs.isEmpty {
                setUnreadCount(0)
                setIsAtBottom(true)
            } else if currentFollowEnabled {
                setUnreadCount(0)
            } else if !isInitialRender, let appendedCount, appendedCount > 0 {
                setUnreadCount(unreadCountSnapshot + appendedCount)
            } else if !isInitialRender, contentChanged, appendedCount == nil {
                setUnreadCount(0)
            }

            previousLogIDs = currentLogIDs
            lastRenderFingerprint = renderFingerprint
            lastJumpToLatestToken = parent.jumpToLatestToken
            lastFollowEnabled = currentFollowEnabled
        }

        private func scheduleViewportSync() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.suppressViewportSync = false
                self.syncViewportState(userInitiated: false)
            }
        }

        private func syncViewportState(userInitiated: Bool) {
            guard !suppressViewportSync, let scrollView else { return }

            let atBottom = isScrolledToBottom(scrollView)
            setIsAtBottom(atBottom)

            if atBottom {
                setUnreadCount(0)
                if userInitiated && !parent.followEnabled {
                    setFollowEnabled(true)
                }
            } else if userInitiated && parent.followEnabled {
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
            setUnreadCount(0)
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

        private func appendedEntryCount(from oldIDs: [UUID], to newIDs: [UUID]) -> Int? {
            guard newIDs.count >= oldIDs.count else { return nil }
            guard Array(newIDs.prefix(oldIDs.count)) == oldIDs else { return nil }
            return newIDs.count - oldIDs.count
        }

        private func setFollowEnabled(_ value: Bool) {
            guard parent.followEnabled != value else { return }
            lastFollowEnabled = value
            DispatchQueue.main.async { [weak self] in
                self?.parent.followEnabled = value
            }
        }

        private func setIsAtBottom(_ value: Bool) {
            guard isAtBottomSnapshot != value else { return }
            isAtBottomSnapshot = value
            DispatchQueue.main.async { [weak self] in
                self?.parent.isAtBottom = value
            }
        }

        private func setUnreadCount(_ value: Int) {
            let sanitizedValue = max(0, value)
            guard unreadCountSnapshot != sanitizedValue else { return }
            unreadCountSnapshot = sanitizedValue
            DispatchQueue.main.async { [weak self] in
                self?.parent.unreadCount = sanitizedValue
            }
        }
    }
}

// MARK: - ConsoleTextRenderer

private enum ConsoleTextRenderer {
    static func fingerprint(for logs: [LogEntry], isRunning: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(isRunning)
        hasher.combine(logs.count)

        for entry in logs {
            hasher.combine(entry.id)
            hasher.combine(entry.level.rawValue)
            hasher.combine(entry.message)
            hasher.combine(entry.isStderr)
            hasher.combine(entry.containsErrorKeyword)
            hasher.combine(entry.formattedTimestamp)
        }

        return hasher.finalize()
    }

    static func attributedString(for logs: [LogEntry], isRunning: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for index in logs.indices {
            let entry = logs[index]
            let isLatest = index == logs.indices.last && isRunning
            result.append(line(for: entry, highlightLatest: isLatest))

            if index != logs.index(before: logs.endIndex) {
                result.append(NSAttributedString(string: "\n"))
            }
        }

        return result
    }

    private static func line(for entry: LogEntry, highlightLatest: Bool) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let levelLabel = entry.level.displayName.padding(toLength: 7, withPad: " ", startingAt: 0)
        let backgroundColor = backgroundColor(for: entry, highlightLatest: highlightLatest)

        line.append(fragment(entry.formattedTimestamp, color: ConsoleTheme.timestamp, background: backgroundColor))
        line.append(fragment(" ", color: nil, background: backgroundColor))
        line.append(
            fragment(
                levelLabel,
                color: levelColor(for: entry),
                background: backgroundColor,
                font: entry.level == .error ? ConsoleTheme.boldFont : ConsoleTheme.font
            )
        )
        line.append(fragment(" ", color: nil, background: backgroundColor))
        line.append(
            fragment(
                entry.message,
                color: messageColor(for: entry),
                background: backgroundColor,
                font: entry.level == .error ? ConsoleTheme.boldFont : ConsoleTheme.font
            )
        )

        return line
    }

    private static func fragment(
        _ string: String,
        color: NSColor?,
        background: NSColor?,
        font: NSFont = ConsoleTheme.font
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 1

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

    private static func levelColor(for entry: LogEntry) -> NSColor {
        switch entry.level {
        case .info:
            return ConsoleTheme.info
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
        if entry.isStderr {
            return ConsoleTheme.stderr
        }
        switch entry.level {
        case .debug:
            return ConsoleTheme.debug
        default:
            return NSColor.textColor
        }
    }

    private static func backgroundColor(for entry: LogEntry, highlightLatest: Bool) -> NSColor? {
        if entry.level == .error || entry.containsErrorKeyword {
            return ConsoleTheme.errorBackground
        }
        if highlightLatest {
            return ConsoleTheme.activeBackground
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
                    .foregroundStyle(state.displayColor)
            }

            Divider().frame(height: 12)

            Text("\(logCount) 条日志")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            if let result = lastResult {
                Text("耗时: \(result.formattedDuration)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let ffmpegVersion {
                Divider().frame(height: 12)

                Text(ffmpegVersion)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - LogDocument

struct LogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var content: String

    init(content: String) {
        self.content = content
    }

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
            let viewModel = ExecutionViewModel()
            viewModel.appendLog(LogEntry(timestamp: Date(), level: .info, message: "开始执行命令..."))
            viewModel.appendLog(LogEntry(timestamp: Date(), level: .debug, message: "frame=  100 fps=30 size=1024kB time=00:00:03.33"))
            viewModel.appendLog(LogEntry(timestamp: Date(), level: .debug, message: "frame=  150 fps=30 size=1536kB time=00:00:05.00"))
            viewModel.appendLog(LogEntry(timestamp: Date(), level: .info, message: "正在处理视频流..."))
            viewModel.appendLog(LogEntry(timestamp: Date(), level: .warning, message: "deprecated option used"))
            viewModel.appendLog(LogEntry(timestamp: Date(), level: .debug, message: "frame=  200 fps=29 size=2048kB time=00:00:06.67"))
            viewModel.appendLog(LogEntry(timestamp: Date(), level: .error, message: "Error opening file: Permission denied"))
            viewModel.appendLog(LogEntry(timestamp: Date(), level: .error, message: "Conversion failed: invalid codec"))
            viewModel.appendLog(LogEntry(timestamp: Date(), level: .info, message: "尝试使用备用路径..."))
            return viewModel
        }())
        .frame(width: 700, height: 400)
}
