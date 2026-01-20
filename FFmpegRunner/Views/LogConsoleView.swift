//
//  LogConsoleView.swift
//  FFmpegRunner
//
//  日志控制台视图
//

import SwiftUI

/// 日志控制台视图
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
                onClear: viewModel.clearLogs,
                onExport: { showExportSheet = true },
                state: viewModel.state,
                isFFmpegAvailable: viewModel.isFFmpegAvailable
            )

            Divider()

            // 日志内容
            LogContentView(logs: viewModel.logs, autoScroll: autoScroll)

            // 状态栏
            ConsoleStatusBar(
                logCount: viewModel.logs.count,
                lastResult: viewModel.lastResult,
                ffmpegVersion: viewModel.ffmpegVersion
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(logs) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: logs.count) { _ in
                if autoScroll, let lastId = logs.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - 日志条目行

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 时间戳
            Text(entry.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

            // 级别标签
            Text(entry.level.displayName)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(entry.level == .error ? .bold : .regular)
                .foregroundColor(levelColor)
                .frame(width: 40)

            // 消息（带错误关键字高亮）
            highlightedMessage
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
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

    /// 级别标签颜色
    private var levelColor: Color {
        switch entry.level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .debug: return .secondary
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
        return levelColor
    }

    /// 背景颜色（错误行高亮）
    private var backgroundColor: Color {
        if entry.level == .error || entry.containsErrorKeyword {
            return Color.red.opacity(0.08)
        }
        return .clear
    }
}

// MARK: - 状态栏

struct ConsoleStatusBar: View {
    let logCount: Int
    let lastResult: ExecutionResult?
    let ffmpegVersion: String?

    var body: some View {
        HStack {
            // 日志数量
            Text("\(logCount) 条日志")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            // 最后执行结果
            if let result = lastResult {
                Text("耗时: \(result.formattedDuration)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // FFmpeg 版本
            if let version = ffmpegVersion {
                Text(extractVersionNumber(from: version))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// 从完整版本字符串中提取版本号
    private func extractVersionNumber(from fullVersion: String) -> String {
        // 尝试提取类似 "ffmpeg version 7.1" 中的 "7.1"
        if let range = fullVersion.range(of: #"version\s+(\d+\.\d+(?:\.\d+)?)"#, options: .regularExpression) {
            let versionPart = fullVersion[range]
            if let numberRange = versionPart.range(of: #"\d+\.\d+(?:\.\d+)?"#, options: .regularExpression) {
                return "v\(versionPart[numberRange])"
            }
        }
        // 如果无法提取，返回 "FFmpeg"
        return "FFmpeg"
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
            vm.appendLog(LogEntry(timestamp: Date(), level: .warning, message: "deprecated option used"))
            vm.appendLog(LogEntry(timestamp: Date(), level: .error, message: "Error opening file"))
            return vm
        }())
        .frame(width: 600, height: 300)
}
