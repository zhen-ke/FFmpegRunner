//
//  SettingsView.swift
//  FFmpegRunner
//

import AppKit
import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @EnvironmentObject private var executionViewModel: ExecutionViewModel
    @ObservedObject private var ffmpegService = FFmpegService.shared

    @AppStorage("enableVerboseLogging")         private var enableVerboseLogging = false
    @AppStorage("coalesceProgressLogs")         private var coalesceProgressLogs = true
    @AppStorage("progressCoalesceIntervalMs")   private var progressCoalesceIntervalMs = 200
    @AppStorage("maxLogEntries")                private var maxLogEntries = 1000
    @AppStorage("confirmBeforeRun")             private var confirmBeforeRun = false
    @AppStorage("notifyOnComplete")             private var notifyOnComplete = true
    @AppStorage("confirmOverwrite")             private var confirmOverwrite = true
    @AppStorage("executionTimeoutEnabled")      private var executionTimeoutEnabled = false
    @AppStorage("executionTimeoutSeconds")      private var executionTimeoutSeconds = 1800
    @AppStorage("showCommandPreviewBeforeRun")  private var showCommandPreviewBeforeRun = true
    @AppStorage("ffprobePath")                  private var ffprobePath = ""
    @AppStorage("sidebarWidth")                 private var sidebarWidth = 250.0
    @AppStorage("lastTemplateId")               private var lastTemplateId = ""
    @AppStorage("lastInputDirectory")           private var lastInputDirectory = ""
    @AppStorage("lastOutputDirectory")          private var lastOutputDirectory = ""
    @AppStorage("hasAcknowledgedSafetyWarning") private var hasAcknowledgedSafetyWarning = false
    @AppStorage("autoSaveLog")                  private var autoSaveLog = true
    @AppStorage("maxSavedLogs")                 private var maxSavedLogs = 50

    @State private var isCustomPathValid      = false
    @State private var showClearLogsConfirm   = false
    @State private var isFFprobePathValid     = true
    @State private var systemFFmpegPath: String?
    @State private var isSystemAvailable      = false

    // MARK: Bindings

    private var sourceBinding: Binding<FFmpegSource> {
        Binding(get: { ffmpegService.ffmpegSource },
                set: { ffmpegService.ffmpegSource = $0 })
    }
    private var customPathBinding: Binding<String> {
        Binding(get: { ffmpegService.customFFmpegPath },
                set: { ffmpegService.customFFmpegPath = $0 })
    }
    private var autoScrollBinding: Binding<Bool> {
        Binding(get: { executionViewModel.autoScroll },
                set: { executionViewModel.autoScroll = $0 })
    }

    // MARK: Body

    var body: some View {
        TabView {
            toolchainTab
                .tabItem { Label("工具链", systemImage: "cpu") }
                .tag(0)
            behaviorTab
                .tabItem { Label("行为", systemImage: "slider.horizontal.3") }
                .tag(1)
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(2)
        }
        .frame(width: 560, height: 660)
        .task { await refreshDiagnostics() }
        .onChange(of: ffmpegService.ffmpegSource) { newValue in
            if newValue == .system { Task { await refreshSystemPath() } }
        }
        .onChange(of: ffmpegService.customFFmpegPath) { checkCustomPath($0) }
        .onChange(of: ffprobePath) { newValue in
            checkFFprobePath(newValue)
            ffmpegService.setFFprobePathOverride(newValue)
        }
        .onChange(of: executionTimeoutEnabled) { enabled in
            if enabled && executionTimeoutSeconds < 10 { executionTimeoutSeconds = 300 }
        }
    }

    // MARK: - Toolchain Tab

    private var toolchainTab: some View {
        Form {
            Section("FFmpeg") {
                LabeledContent("来源") {
                    Picker("", selection: sourceBinding) {
                        ForEach(FFmpegSource.allCases, id: \.self) { src in
                            Text(src.displayName).tag(src)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }

                LabeledContent("状态") {
                    ffmpegStatusContent
                }

                if ffmpegService.ffmpegSource == .custom {
                    customPathField(
                        label: "FFmpeg 路径",
                        text: customPathBinding,
                        isValid: isCustomPathValid,
                        placeholder: "选择可执行文件",
                        emptyHint: "选择一个可执行的 ffmpeg 文件",
                        validHint: "路径有效",
                        invalidHint: "文件不存在或没有执行权限"
                    ) { await pickCustomFFmpegPath() }
                }
            }

            Section("当前解析路径") {
                resolvedPathRow(label: "FFmpeg",
                                value: ffmpegService.ffmpegPath,
                                isValid: ffmpegService.isFFmpegAvailable())
                resolvedPathRow(label: "FFprobe",
                                value: ffmpegService.ffprobePath,
                                isValid: ffmpegService.isExecutableAvailable(for: .ffprobe),
                                emptyFallback: "未解析到可用的 ffprobe")
            }

            Section("FFprobe 覆写") {
                customPathField(
                    label: "自定义路径",
                    text: $ffprobePath,
                    isValid: isFFprobePathValid,
                    placeholder: "留空时自动推断",
                    emptyHint: "留空时优先同级目录，再回退系统路径",
                    validHint: "覆写路径有效",
                    invalidHint: "路径无效，将继续回退自动推断",
                    showsClearButton: true
                ) { await pickFFprobePath() } onClear: { ffprobePath = "" }
            }

            if let version = executionViewModel.ffmpegVersion, !version.isEmpty {
                Section("版本") {
                    Text(version)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Behavior Tab

    private var behaviorTab: some View {
        Form {
            Section("执行保护") {
                Toggle("执行前确认", isOn: $confirmBeforeRun)
                Toggle("显示完整命令预览", isOn: $showCommandPreviewBeforeRun)
                    .disabled(!confirmBeforeRun)
                Toggle("覆盖文件前确认", isOn: $confirmOverwrite)
            }

            Section("通知与超时") {
                Toggle("完成后发送通知", isOn: $notifyOnComplete)
                Toggle("启用全局超时", isOn: $executionTimeoutEnabled)

                LabeledContent("最长执行时间") {
                    HStack(spacing: 8) {
                        Text(formattedTimeout(executionTimeoutSeconds))
                            .foregroundStyle(executionTimeoutEnabled ? .primary : .secondary)
                            .monospacedDigit()
                        Stepper("",
                                value: $executionTimeoutSeconds,
                                in: 10...86_400,
                                step: stepSize(for: executionTimeoutSeconds))
                            .labelsHidden()
                            .disabled(!executionTimeoutEnabled)
                    }
                }
                .foregroundStyle(executionTimeoutEnabled ? .primary : .secondary)
            }

            Section("日志显示") {
                Toggle("自动滚动", isOn: autoScrollBinding)
                Toggle("详细日志", isOn: $enableVerboseLogging)
                Toggle("合并进度日志", isOn: $coalesceProgressLogs)

                LabeledContent("合并间隔") {
                    HStack(spacing: 8) {
                        Text("\(progressCoalesceIntervalMs) ms")
                            .foregroundStyle(coalesceProgressLogs ? .primary : .secondary)
                            .monospacedDigit()
                        Stepper("", value: $progressCoalesceIntervalMs, in: 50...1000, step: 50)
                            .labelsHidden()
                            .disabled(!coalesceProgressLogs)
                    }
                }
                .foregroundStyle(coalesceProgressLogs ? .primary : .secondary)

                LabeledContent("最大日志条目") {
                    HStack(spacing: 8) {
                        Text("\(maxLogEntries)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("", value: $maxLogEntries, in: 100...10000, step: 100)
                            .labelsHidden()
                    }
                }
            }

            Section("日志保存") {
                Toggle("自动保存执行日志", isOn: $autoSaveLog)

                LabeledContent("最大保存数量") {
                    HStack(spacing: 8) {
                        Text("\(maxSavedLogs) 份")
                            .foregroundStyle(autoSaveLog ? .primary : .secondary)
                            .monospacedDigit()
                        Stepper("", value: $maxSavedLogs, in: 10...500, step: 10)
                            .labelsHidden()
                            .disabled(!autoSaveLog)
                    }
                }
                .foregroundStyle(autoSaveLog ? .primary : .secondary)

                LabeledContent("日志目录") {
                    Button("在 Finder 中显示") { openLogDirectory() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("工作区") {
                LabeledContent("侧边栏宽度") {
                    HStack(spacing: 10) {
                        Slider(value: $sidebarWidth, in: 220...360, step: 10)
                            .frame(width: 180)
                        Text("\(Int(sidebarWidth)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }

            Section("最近使用") {
                LabeledContent("上次模板") {
                    Text(lastTemplateId.isEmpty ? "未记录" : lastTemplateId)
                        .foregroundStyle(lastTemplateId.isEmpty ? .secondary : .primary)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                LabeledContent("最近输入目录") {
                    Text(displayPath(lastInputDirectory))
                        .foregroundStyle(lastInputDirectory.isEmpty ? .secondary : .primary)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                LabeledContent("最近输出目录") {
                    Text(displayPath(lastOutputDirectory))
                        .foregroundStyle(lastOutputDirectory.isEmpty ? .secondary : .primary)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                LabeledContent("清除记录") {
                    HStack(spacing: 8) {
                        Button("清除模板") { lastTemplateId = "" }
                            .disabled(lastTemplateId.isEmpty)
                        Button("清除目录") {
                            lastInputDirectory = ""
                            lastOutputDirectory = ""
                        }
                        .disabled(lastInputDirectory.isEmpty && lastOutputDirectory.isEmpty)
                    }
                }
            }

            Section("首次提醒") {
                LabeledContent("安全提醒") {
                    HStack(spacing: 10) {
                        Label(
                            hasAcknowledgedSafetyWarning ? "已确认" : "待显示",
                            systemImage: hasAcknowledgedSafetyWarning
                                ? "checkmark.circle.fill" : "clock.fill"
                        )
                        .foregroundStyle(hasAcknowledgedSafetyWarning ? .green : .orange)
                        .font(.callout)
                        Button("重新显示") { UserSettings.shared.resetSafetyAcknowledgement() }
                    }
                }
            }

            Section("危险操作") {
                LabeledContent("已保存日志") {
                    Button("清空所有日志", role: .destructive) { showClearLogsConfirm = true }
                        .confirmationDialog("确定要删除所有已保存的日志文件吗？",
                                            isPresented: $showClearLogsConfirm,
                                            titleVisibility: .visible) {
                            Button("删除所有日志", role: .destructive) { deleteAllSavedLogs() }
                            Button("取消", role: .cancel) {}
                        }
                }
                LabeledContent("偏好设置") {
                    Button("重置所有设置", role: .destructive) {
                        Task { await resetAllSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Reusable Content Builders

    @ViewBuilder
    private var ffmpegStatusContent: some View {
        let info = ffmpegStatusInfo
        HStack(spacing: 6) {
            Image(systemName: info.icon)
                .foregroundStyle(info.tint)
                .imageScale(.small)
            Text(info.message)
                .foregroundStyle(.secondary)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if ffmpegService.ffmpegSource == .system {
                Button(isSystemAvailable ? "重新解析" : "重试") {
                    Task { await refreshSystemPath() }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            if ffmpegService.ffmpegSource == .bundled, !ffmpegService.isBundledFFmpegAvailable {
                Button("查看帮助") { showBundledFFmpegHelp() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: ffmpegService.ffmpegSource)
    }

    @ViewBuilder
    private func resolvedPathRow(
        label: String,
        value: String,
        isValid: Bool,
        emptyFallback: String = "—"
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text(value.isEmpty ? emptyFallback : value)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isValid ? .green : .red)
                    .imageScale(.small)
            }
        }
    }

    @ViewBuilder
    private func customPathField(
        label: String,
        text: Binding<String>,
        isValid: Bool,
        placeholder: String,
        emptyHint: String,
        validHint: String,
        invalidHint: String,
        showsClearButton: Bool = false,
        browseAction: @escaping @MainActor () async -> Void,
        onClear: (() -> Void)? = nil
    ) -> some View {
        let trimmed   = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint      = trimmed.isEmpty ? emptyHint : (isValid ? validHint : invalidHint)
        let hintColor: Color = trimmed.isEmpty ? .secondary : (isValid ? .green : .red)

        // Full-width VStack: LabeledContent clips its control region,
        // leaving TextField too narrow to show placeholder without wrapping.
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                Button("浏览…") { Task { await browseAction() } }
                if showsClearButton {
                    Button("清空") { onClear?() }
                        .disabled(trimmed.isEmpty)
                }
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(hintColor)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private var ffmpegStatusInfo: (icon: String, tint: Color, message: String) {
        switch ffmpegService.ffmpegSource {
        case .bundled:
            return ffmpegService.isBundledFFmpegAvailable
                ? ("checkmark.circle.fill", .green,
                   ffmpegService.bundledFFmpegPath ?? "内置路径")
                : ("exclamationmark.triangle.fill", .orange,
                   "未找到内置 FFmpeg，请将二进制放入 Resources")
        case .system:
            return isSystemAvailable
                ? ("checkmark.circle.fill", .green,
                   systemFFmpegPath ?? ffmpegService.cachedSystemPath ?? "系统路径")
                : ("exclamationmark.triangle.fill", .orange,
                   "未找到系统 FFmpeg — brew install ffmpeg")
        case .custom:
            return isCustomPathValid
                ? ("checkmark.circle.fill", .green, "自定义来源")
                : ("questionmark.circle.fill", .secondary, "自定义来源")
        }
    }

    private func displayPath(_ path: String) -> String {
        let t = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "未记录" : t
    }

    private func checkCustomPath(_ path: String) {
        let t = path.trimmingCharacters(in: .whitespacesAndNewlines)
        isCustomPathValid = !t.isEmpty && FileManager.default.isExecutableFile(atPath: t)
    }

    private func checkFFprobePath(_ path: String) {
        let t = path.trimmingCharacters(in: .whitespacesAndNewlines)
        isFFprobePathValid = t.isEmpty || FileManager.default.isExecutableFile(atPath: t)
    }

    @MainActor
    private func pickCustomFFmpegPath() async {
        guard let url = await FilePicker.selectFile(
            initialDirectory: dirURL(from: ffmpegService.customFFmpegPath),
            prompt: "选择 FFmpeg 可执行文件") else { return }
        ffmpegService.customFFmpegPath = url.path
    }

    @MainActor
    private func pickFFprobePath() async {
        guard let url = await FilePicker.selectFile(
            initialDirectory: dirURL(from: ffprobePath),
            prompt: "选择 FFprobe 可执行文件") else { return }
        ffprobePath = url.path
    }

    private func refreshDiagnostics() async {
        checkCustomPath(ffmpegService.customFFmpegPath)
        checkFFprobePath(ffprobePath)
        ffmpegService.setFFprobePathOverride(ffprobePath)
        await refreshSystemPath()
    }

    private func refreshSystemPath() async {
        let path = await ffmpegService.findSystemFFmpeg()
        systemFFmpegPath = path
        isSystemAvailable = path != nil
    }

    private func resetAllSettings() async {
        UserSettings.shared.resetAll()
        executionViewModel.autoScroll = UserSettings.shared.autoScrollLog
        let discovered = await ffmpegService.findSystemFFmpeg()
        let preferred: FFmpegSource = ffmpegService.isBundledFFmpegAvailable
            ? .bundled : (discovered != nil ? .system : .bundled)
        ffmpegService.setSource(preferred)
        ffmpegService.setFFprobePathOverride(UserSettings.shared.ffprobePath)
        systemFFmpegPath = discovered
        isSystemAvailable = discovered != nil
        checkCustomPath(ffmpegService.customFFmpegPath)
        checkFFprobePath(ffprobePath)
    }

    private func dirURL(from path: String) -> URL? {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            .deletingLastPathComponent()
    }

    private func openLogDirectory() {
        let url = LogPersistenceService.shared.logDirectoryURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func deleteAllSavedLogs() {
        Task {
            do {
                try await LogPersistenceService.shared.deleteAllLogs()
            } catch {
                let alert = NSAlert()
                alert.messageText = "清空日志失败"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好的")
                alert.runModal()
            }
        }
    }

    private func showBundledFFmpegHelp() {
        let alert = NSAlert()
        alert.messageText = "如何添加内置 FFmpeg"
        alert.informativeText = """
        1. 下载 FFmpeg 静态构建：https://evermeet.cx/ffmpeg/
        2. 解压得到 ffmpeg 二进制文件
        3. 在 Xcode 中右键 Resources → Add Files to…
           勾选 Copy items if needed，Target 选 FFmpegRunner
        4. 重新构建应用
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    private func formattedTimeout(_ s: Int) -> String {
        let t = max(s, 1)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        if h > 0 { return sec == 0 ? "\(h) 小时 \(m) 分钟" : "\(h) 小时 \(m) 分钟 \(sec) 秒" }
        if m > 0 { return sec == 0 ? "\(m) 分钟" : "\(m) 分钟 \(sec) 秒" }
        return "\(sec) 秒"
    }

    private func stepSize(for v: Int) -> Int { v < 300 ? 10 : 60 }
}

// MARK: - Preview

private struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(ExecutionViewModel())
    }
}
