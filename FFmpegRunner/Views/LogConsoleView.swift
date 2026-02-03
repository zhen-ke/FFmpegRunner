//
//  LogConsoleView.swift
//  FFmpegRunner
//
//  日志控制台视图
//

import SwiftUI

/// 日志过滤级别
enum LogFilter: String, CaseIterable {
    case all = "全部"
    case important = "仅错误/警告"
    case noDebug = "隐藏 Debug"
}

struct LogConsoleView: View {

    // MARK: - Environment

    @EnvironmentObject var viewModel: ExecutionViewModel

    // MARK: - State

    @State private var autoScroll = true
    @State private var showExportSheet = false


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
        .fileExporter(
            isPresented: $showExportSheet,
            document: LogDocument(content: viewModel.exportLogs()),
            contentType: .plainText,
            defaultFilename: "ffmpeg_log_\(Date().formatted(.iso8601)).txt"
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
            Button(action: onClear) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .help("清空日志")
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
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            Text(statusText)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.1))
        .cornerRadius(4)
    }

    private var statusText: String {
        switch state {
        case .idle: return "就绪"
        case .preparing: return "准备中"
        case .running: return "执行中"
        case .cancelling: return "取消中"
        case .completed(let result): return result.isSuccess ? "完成" : "失败"
        case .cancelled: return "已取消"
        case .error: return "错误"
        }
    }

    private var statusColor: Color {
        switch state {
        case .idle: return .secondary
        case .preparing: return .blue
        case .running: return .blue
        case .cancelling: return .orange
        case .completed(let result): return result.isSuccess ? .green : .red
        case .cancelled: return .orange
        case .error: return .red
        }
    }
}

// MARK: - 日志内容视图

struct LogContentView: View {
    let logs: [LogEntry]
    let autoScroll: Bool
    let isRunning: Bool

    /// 滚动节流：防止高频日志输出时触发过多滚动动画
    @State private var pendingScrollId: UUID?
    @State private var scrollThrottleTask: Task<Void, Never>?

    /// 滚动节流间隔（毫秒）
    private let scrollThrottleInterval: UInt64 = 150 // ~6-7 fps，足够流畅

    var body: some View {
        ScrollViewReader { proxy in
            logListContent
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: logs.count) { _ in
                    handleScrollThrottle(proxy: proxy)
                }
        }
    }

    /// 日志列表内容（提取以简化 body 类型推断）
    private var logListContent: some View {
        let lastLogId = logs.last?.id
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(logs) { entry in
                    LogEntryRow(
                        entry: entry,
                        isLatest: entry.id == lastLogId,
                        isRunning: isRunning
                    )
                    .id(entry.id)
                }
            }
            .padding(8)
        }
    }

    /// 节流滚动处理
    private func handleScrollThrottle(proxy: ScrollViewProxy) {
        guard autoScroll, let lastId = logs.last?.id else { return }

        // 记录待滚动的 ID
        pendingScrollId = lastId

        // 如果已有节流任务在运行，则跳过（会使用最新的 pendingScrollId）
        guard scrollThrottleTask == nil else { return }

        // 创建节流任务
        scrollThrottleTask = Task { @MainActor in
            // 等待一小段时间，让多个日志合并为一次滚动
            try? await Task.sleep(nanoseconds: scrollThrottleInterval * 1_000_000)

            // 执行滚动到最新 ID
            if let targetId = pendingScrollId {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(targetId, anchor: .bottom)
                }
            }

            // 清理状态
            pendingScrollId = nil
            scrollThrottleTask = nil
        }
    }
}

// MARK: - 日志条目行

struct LogEntryRow: View {
    let entry: LogEntry
    let isLatest: Bool
    let isRunning: Bool

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
            return Color(NSColor.systemOrange).opacity(0.9)
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
            return Color.red.opacity(0.08)
        }
        // 运行中最新行的"呼吸感"
        if isLatest && isRunning {
            return Color.accentColor.opacity(0.05)
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
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(statusColor)
        }
    }

    private var statusText: String {
        switch state {
        case .idle: return "就绪"
        case .preparing: return "准备中"
        case .running: return "执行中"
        case .cancelling: return "取消中"
        case .completed(let result): return result.isSuccess ? "完成" : "失败"
        case .cancelled: return "已取消"
        case .error: return "错误"
        }
    }

    private var statusColor: Color {
        switch state {
        case .idle: return .secondary
        case .preparing, .running: return .blue
        case .cancelling, .cancelled: return .orange
        case .completed(let result): return result.isSuccess ? .green : .red
        case .error: return .red
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

import UniformTypeIdentifiers

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
