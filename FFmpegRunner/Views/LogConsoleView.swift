//
//  LogConsoleView.swift
//  FFmpegRunner
//
//  日志控制台视图
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 语义颜色定义

extension Color {
    enum Console {
        /// 错误行背景
        static let errorBackground = Color.red.opacity(0.08)
        /// 当前活动行高亮
        static let activeHighlight = Color.accentColor.opacity(0.05)
        /// stderr 文本颜色
        static let stderrText = Color(NSColor.systemOrange).opacity(0.9)
    }
}

// MARK: - 文件名格式化

private let filenameFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    return formatter
}()

struct LogConsoleView: View {

    // MARK: - Environment

    @EnvironmentObject var viewModel: ExecutionViewModel
    @AppStorage("autoScrollLog") private var preferredAutoScroll = true

    // MARK: - State

    @State private var autoScroll = true
    @State private var showExportSheet = false
    @State private var showClearConfirm = false


    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            ConsoleHeaderView(
                autoScroll: $autoScroll,
                logFilter: $viewModel.logFilter,
                onClear: viewModel.clearLogs,
                onExport: { showExportSheet = true },
                state: viewModel.state,
                isFFmpegAvailable: viewModel.isFFmpegAvailable
            )

            Divider()

            // 日志内容
            LogContentView(
                logs: viewModel.visibleLogs,
                autoScroll: autoScroll,
                isRunning: viewModel.state.isRunning
            )

            // 状态栏

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
        .onChange(of: preferredAutoScroll) { newValue in
            if autoScroll != newValue {
                autoScroll = newValue
            }
        }
        .onChange(of: autoScroll) { newValue in
            if preferredAutoScroll != newValue {
                preferredAutoScroll = newValue
            }
        }
        .fileExporter(
            isPresented: $showExportSheet,
            document: LogDocument(content: viewModel.exportLogs()),
            contentType: .plainText,
            defaultFilename: "ffmpeg_log_\(filenameFormatter.string(from: Date())).txt"
        ) { result in
            // 处理导出结果
        }
    }
}

// MARK: - 控制台头部

struct ConsoleHeaderView: View {
    @Binding var autoScroll: Bool
    @Binding var logFilter: LogFilter
    let onClear: () -> Void
    let onExport: () -> Void
    let state: ExecutionState
    let isFFmpegAvailable: Bool

    @State private var showClearConfirm = false

    var body: some View {
        HStack {
            Text("控制台")
                .font(.headline)

            // 执行状态
            ExecutionStatusBadge(state: state)

            Spacer()

            // FFmpeg 状态
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
                Image(systemName: logFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("日志过滤: \(logFilter.rawValue)")

            // 自动滚动开关
            Toggle(isOn: $autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("自动滚动到底部")

            // 导出按钮
            Button(action: onExport) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .help("导出日志")

            // 清空按钮
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
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - 执行状态标签

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

// MARK: - 日志内容视图

struct LogContentView: View {
    let logs: [LogEntry]
    let autoScroll: Bool
    let isRunning: Bool

    private struct ScrollTrigger: Equatable {
        let count: Int
        let lastId: UUID?
        let lastMessage: String
        let lastTimestamp: Date?
        let isRunning: Bool
    }

    private let bottomAnchorID = "log-bottom-anchor"

    /// 滚动节流：使用 Task + cancel 模式
    /// - 天然节流：新请求自动取消旧任务
    /// - 不会排队：始终只有一个 pending task
    /// - View 重建安全：Task 引用比布尔锁更可靠
    @State private var scrollTask: Task<Void, Never>?

    /// 滚动节流间隔（秒）
    private let scrollThrottleInterval: Double = 0.05 // 50ms，约 20 fps

    private var scrollTrigger: ScrollTrigger {
        ScrollTrigger(
            count: logs.count,
            lastId: logs.last?.id,
            lastMessage: logs.last?.message ?? "",
            lastTimestamp: logs.last?.timestamp,
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
                // 监听最后一条可见日志的内容和执行状态变化。
                // 进度日志会原地替换并复用同一个 id，仅监听 id 会漏掉这类更新。
                .onChange(of: scrollTrigger) { _ in
                    requestScrollToBottom(proxy: proxy)
                }
        }
        .onDisappear {
            // 修复 Task 泄漏：View 销毁时取消滚动任务
            scrollTask?.cancel()
            scrollTask = nil
        }
    }

    /// 日志列表内容（提取以简化 body 类型推断）
    /// - 优化：拆分最后一行单独渲染，避免每行都计算 isLatest
    private var logListContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // 非最后一行：isLatest 固定为 false
                ForEach(logs.dropLast(1), id: \.id) { entry in
                    EquatableView(content:
                        LogEntryRow(entry: entry, isLatest: false, isRunning: isRunning)
                    )
                    .id(entry.id)
                }
                // 最后一行：isLatest 为 true
                if let last = logs.last {
                    EquatableView(content:
                        LogEntryRow(entry: last, isLatest: true, isRunning: isRunning)
                    )
                    .id(last.id)
                }

                Color.clear
                    .frame(height: 1)
                    .id(bottomAnchorID)
            }
            .padding(8)
        }
    }

    /// 节流滚动请求
    /// - 使用 Task + cancel 确保同一时间只有一个滚动任务
    /// - 新请求自动取消旧任务，天然防抖
    /// - 始终滚动到固定底部锚点，避免最后一行原地更新时漏滚动
    private func requestScrollToBottom(proxy: ScrollViewProxy) {
        guard autoScroll else { return }

        // 取消旧的滚动任务（如果存在）
        scrollTask?.cancel()

        scrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(scrollThrottleInterval * 1_000_000_000))

            // 检查是否被取消
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: 0.1)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }
}

// MARK: - 日志条目行

struct LogEntryRow: View, Equatable {
    let entry: LogEntry
    let isLatest: Bool
    let isRunning: Bool

    // MARK: - Equatable

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry.id == rhs.entry.id
            && lhs.isLatest == rhs.isLatest
            && lhs.isRunning == rhs.isRunning
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // 左侧级别色条 - 快速视觉锚点
            Rectangle()
                .fill(levelColor)
                .frame(width: 3)
                .cornerRadius(1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // 时间戳 - 弱化显示，存在但不抢戏
                    Text(entry.formattedTimestamp)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))

                    // 级别标签
                    Text(entry.level.displayName)
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(entry.level == .error ? .semibold : .regular)
                        .foregroundColor(levelColor)
                        .frame(width: 36, alignment: .leading)
                }

                // 消息（带错误关键字高亮）
                highlightedMessage
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(entry.level == .error ? .semibold : .regular)
                    .textSelection(.enabled)
            }
        }
        // Error 行获得更多垂直空间，提升扫描效率
        .padding(.vertical, entry.level == .error ? 4 : 1)
        .padding(.trailing, 4)
        .background(backgroundColor)
    }

    /// 高亮显示的消息
    @ViewBuilder
    private var highlightedMessage: some View {
        if entry.containsErrorKeyword && entry.level != .error {
            // 含有错误关键词但级别不是 error 时，高亮显示
            Text(entry.message)
                .foregroundColor(.orange)
        } else {
            Text(entry.message)
                .foregroundColor(messageColor)
        }
    }

    /// 级别标签颜色 - 用于左侧色条和级别文字
    private var levelColor: Color {
        switch entry.level {
        case .info: return .blue.opacity(0.7)
        case .warning: return .orange
        case .error: return .red
        case .debug: return .secondary.opacity(0.5)
        }
    }

    /// 消息颜色（区分 stderr）
    private var messageColor: Color {
        if entry.level == .error {
            return .red
        }
        if entry.isStderr {
            return Color.Console.stderrText
        }
        switch entry.level {
        case .debug: return .secondary
        default: return .primary
        }
    }

    /// 背景颜色
    private var backgroundColor: Color {
        // 错误行高亮
        if entry.level == .error || entry.containsErrorKeyword {
            return Color.Console.errorBackground
        }
        // 运行中最新行的"呼吸感"
        if isLatest && isRunning {
            return Color.Console.activeHighlight
        }
        return .clear
    }
}

// MARK: - 状态栏

struct ConsoleStatusBar: View {
    let logCount: Int
    let lastResult: ExecutionResult?
    let ffmpegVersion: String?
    let state: ExecutionState

    var body: some View {
        HStack(spacing: 12) {
            // 执行状态 - 最高优先级
            statusIndicator

            Divider()
                .frame(height: 12)

            // 日志数量
            Text("\(logCount) 条日志")
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()

            // 最后执行结果
            if let result = lastResult {
                Text("耗时: \(result.formattedDuration)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // FFmpeg 版本
            if let version = ffmpegVersion {
                Divider()
                    .frame(height: 12)
                Text(version)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// 状态指示器
    @ViewBuilder
    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.displayColor)
                .frame(width: 6, height: 6)
            Text(state.displayText)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(state.displayColor)
        }
    }
}

// MARK: - 日志文档（用于导出）

struct LogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            content = String(data: data, encoding: .utf8) ?? ""
        } else {
            content = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = content.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
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
