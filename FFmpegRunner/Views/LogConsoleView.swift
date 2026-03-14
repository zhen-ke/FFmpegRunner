//
//  LogConsoleView.swift
//  FFmpegRunner
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 语义颜色

extension Color {
    enum Console {
        static let errorBackground = Color.red.opacity(0.08)
        static let activeHighlight = Color.accentColor.opacity(0.05)
        static let stderrText      = Color(NSColor.systemOrange).opacity(0.9)
    }
}

// MARK: - 文件名格式化

private let filenameFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd_HHmmss"
    return f
}()

// MARK: - onChange 兼容封装（macOS 13 / 14+）

struct OnChangeCompat<V: Equatable>: ViewModifier {
    let value: V
    let action: (V) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            content.onChange(of: value) { newValue in action(newValue) }
        }
    }
}

extension View {
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        modifier(OnChangeCompat(value: value, action: action))
    }
}

// MARK: - contextMenu 复用

private struct LogEntryContextMenu: ViewModifier {
    let message: String
    func body(content: Content) -> some View {
        content.contextMenu {
            Button("复制日志") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            }
        }
    }
}

private extension View {
    func logContextMenu(message: String) -> some View {
        modifier(LogEntryContextMenu(message: message))
    }
}

// MARK: - LogConsoleView

struct LogConsoleView: View {

    @EnvironmentObject var viewModel: ExecutionViewModel
    @AppStorage("autoScrollLog") private var preferredAutoScroll = true

    @State private var autoScroll = true
    @State private var showExportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            ConsoleHeaderView(
                autoScroll: $autoScroll,
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
                autoScroll: $autoScroll,
                isRunning: viewModel.state.isRunning
            )

            ConsoleStatusBar(
                logCount: viewModel.visibleLogs.count,
                lastResult: viewModel.lastResult,
                ffmpegVersion: viewModel.ffmpegVersionShort,
                state: viewModel.state
            )
        }
        .onAppear {
            autoScroll = preferredAutoScroll
        }
        // 单向同步：只在 autoScroll 变化时持久化，不反向同步，避免循环触发
        .onChangeCompat(of: autoScroll) { newValue in
            preferredAutoScroll = newValue
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

                // 日志过滤器
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

                // 搜索按钮
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSearch.toggle()
                        if showSearch { isSearchFocused = true }
                        else          { searchText = "" }
                    }
                } label: {
                    Image(systemName: showSearch || !searchText.isEmpty
                          ? "magnifyingglass.circle.fill"
                          : "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .help("搜索日志")
                .keyboardShortcut("f", modifiers: .command)

                // 自动滚动开关
                Toggle(isOn: $autoScroll) {
                    Image(systemName: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .help("自动滚动到底部")

                // 导出
                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .help("导出日志")

                // 清空
                Button { showClearConfirm = true } label: {
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

            // 搜索栏（可展开/收起）
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

    // 只比较真正需要触发滚动的字段，移除 lastMessage 字符串比较
    private struct ScrollTrigger: Equatable {
        let count: Int
        let lastId: UUID?
        let isRunning: Bool
    }

    private let bottomAnchorID = "log-bottom-anchor"
    private let scrollThrottleInterval: Double = 0.05

    // 用计数器代替布尔标志，正确处理并发滚动请求
    @State private var programmaticScrollCount = 0
    @State private var scrollTask: Task<Void, Never>?

    private var scrollTrigger: ScrollTrigger {
        ScrollTrigger(
            count: logs.count,
            lastId: logs.last?.id,
            isRunning: isRunning
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            logListContent
                .background(Color(NSColor.textBackgroundColor))
                .onAppear {
                    requestScrollToBottom(proxy: proxy)
                }
                .onChangeCompat(of: scrollTrigger) { _ in
                    requestScrollToBottom(proxy: proxy)
                }
        }
        .onDisappear {
            scrollTask?.cancel()
            scrollTask = nil
        }
    }

    private var logListContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(logs.dropLast(1), id: \.id) { entry in
                    EquatableView(content:
                        LogEntryRow(entry: entry, isLatest: false, isRunning: isRunning)
                    )
                    .id(entry.id)
                    .logContextMenu(message: entry.message)
                }

                if let last = logs.last {
                    EquatableView(content:
                        LogEntryRow(entry: last, isLatest: true, isRunning: isRunning)
                    )
                    .id(last.id)
                    .logContextMenu(message: last.message)
                }

                // 底部锚点：利用 LazyVStack 生命周期检测用户是否在底部
                Color.clear
                    .frame(height: 1)
                    .id(bottomAnchorID)
                    .onAppear {
                        // 滚回底部 → 若是用户手动操作，则恢复自动滚动
                        if programmaticScrollCount == 0 && !autoScroll {
                            autoScroll = true
                        }
                    }
                    .onDisappear {
                        // 离开底部 → 若是用户手动操作，则暂停自动滚动
                        if programmaticScrollCount == 0 && autoScroll {
                            autoScroll = false
                        }
                    }
            }
            .padding(8)
        }
        // simultaneousGesture 不拦截 ScrollView 自身手势，只监听向上拖动
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    // 向上拖动（负 translation）= 用户想看历史日志，暂停自动滚动
                    if value.translation.height < -10 && autoScroll {
                        autoScroll = false
                    }
                }
        )
    }

    private func requestScrollToBottom(proxy: ScrollViewProxy) {
        guard autoScroll else { return }

        scrollTask?.cancel()

        scrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(scrollThrottleInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }

            programmaticScrollCount += 1

            // 修复 LazyVStack 懒加载导致的滚动失败：
            // 第一步：不带动画先滚到最后一条日志 id，强制 LazyVStack 渲染底部区域
            // 第二步：再滚到锚点，确保锚点已存在于视图树中
            if let lastId = logs.last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
            withAnimation(.easeOut(duration: 0.1)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }

            // 等待动画完成后减计数，期间屏蔽 onDisappear 误判
            try? await Task.sleep(nanoseconds: 150_000_000)
            programmaticScrollCount = max(0, programmaticScrollCount - 1)
        }
    }
}

// MARK: - LogEntryRow

struct LogEntryRow: View, Equatable {
    let entry: LogEntry
    let isLatest: Bool
    let isRunning: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry.id  == rhs.entry.id  &&
        lhs.isLatest  == rhs.isLatest  &&
        lhs.isRunning == rhs.isRunning
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // 左侧级别色条
            Rectangle()
                .fill(levelColor)
                .frame(width: 3)
                .cornerRadius(1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.formattedTimestamp)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))

                    Text(entry.level.displayName)
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(entry.level == .error ? .semibold : .regular)
                        .foregroundColor(levelColor)
                        .frame(width: 36, alignment: .leading)
                }

                highlightedMessage
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(entry.level == .error ? .semibold : .regular)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, entry.level == .error ? 4 : 1)
        .padding(.trailing, 4)
        .background(backgroundColor)
    }

    @ViewBuilder
    private var highlightedMessage: some View {
        if entry.containsErrorKeyword && entry.level != .error {
            Text(entry.message).foregroundColor(.orange)
        } else {
            Text(entry.message).foregroundColor(messageColor)
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .info:    return .blue.opacity(0.7)
        case .warning: return .orange
        case .error:   return .red
        case .debug:   return .secondary.opacity(0.5)
        }
    }

    private var messageColor: Color {
        if entry.level == .error { return .red }
        if entry.isStderr        { return Color.Console.stderrText }
        switch entry.level {
        case .debug: return .secondary
        default:     return .primary
        }
    }

    private var backgroundColor: Color {
        if entry.level == .error || entry.containsErrorKeyword {
            return Color.Console.errorBackground
        }
        if isLatest && isRunning {
            return Color.Console.activeHighlight
        }
        return .clear
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
            vm.appendLog(LogEntry(timestamp: Date(), level: .info,    message: "开始执行命令..."))
            vm.appendLog(LogEntry(timestamp: Date(), level: .debug,   message: "frame=  100 fps=30 size=1024kB time=00:00:03.33"))
            vm.appendLog(LogEntry(timestamp: Date(), level: .debug,   message: "frame=  150 fps=30 size=1536kB time=00:00:05.00"))
            vm.appendLog(LogEntry(timestamp: Date(), level: .info,    message: "正在处理视频流..."))
            vm.appendLog(LogEntry(timestamp: Date(), level: .warning, message: "deprecated option used"))
            vm.appendLog(LogEntry(timestamp: Date(), level: .debug,   message: "frame=  200 fps=29 size=2048kB time=00:00:06.67"))
            vm.appendLog(LogEntry(timestamp: Date(), level: .error,   message: "Error opening file: Permission denied"))
            vm.appendLog(LogEntry(timestamp: Date(), level: .info,    message: "尝试使用备用路径..."))
            return vm
        }())
        .frame(width: 700, height: 350)
}
