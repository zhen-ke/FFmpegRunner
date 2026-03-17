//
//  SettingsView.swift
//  FFmpegRunner
//
//  设置视图
//

import AppKit
import SwiftUI

private enum SettingsLayout {
    static let contentWidth: CGFloat = 860
    static let sectionSpacing: CGFloat = 26
    static let rowSpacing: CGFloat = 16
    static let insetSpacing: CGFloat = 12
}

struct SettingsView: View {
    @EnvironmentObject private var executionViewModel: ExecutionViewModel

    @ObservedObject private var ffmpegService = FFmpegService.shared

    @AppStorage("enableVerboseLogging") private var enableVerboseLogging = false
    @AppStorage("coalesceProgressLogs") private var coalesceProgressLogs = true
    @AppStorage("progressCoalesceIntervalMs") private var progressCoalesceIntervalMs = 200
    @AppStorage("maxLogEntries") private var maxLogEntries = 1000
    @AppStorage("confirmBeforeRun") private var confirmBeforeRun = false
    @AppStorage("notifyOnComplete") private var notifyOnComplete = true
    @AppStorage("confirmOverwrite") private var confirmOverwrite = true
    @AppStorage("showCommandPreviewBeforeRun") private var showCommandPreviewBeforeRun = true
    @AppStorage("ffprobePath") private var ffprobePath = ""
    @AppStorage("sidebarWidth") private var sidebarWidth = 250.0
    @AppStorage("lastTemplateId") private var lastTemplateId = ""
    @AppStorage("lastInputDirectory") private var lastInputDirectory = ""
    @AppStorage("lastOutputDirectory") private var lastOutputDirectory = ""
    @AppStorage("hasAcknowledgedSafetyWarning") private var hasAcknowledgedSafetyWarning = false

    @State private var isCustomPathValid = false
    @State private var isFFprobePathValid = true
    @State private var systemFFmpegPath: String?
    @State private var isSystemAvailable = false

    private var ffmpegSourceBinding: Binding<FFmpegSource> {
        Binding(
            get: { ffmpegService.ffmpegSource },
            set: { ffmpegService.ffmpegSource = $0 }
        )
    }

    private var customFFmpegPathBinding: Binding<String> {
        Binding(
            get: { ffmpegService.customFFmpegPath },
            set: { ffmpegService.customFFmpegPath = $0 }
        )
    }

    private var autoScrollBinding: Binding<Bool> {
        Binding(
            get: { executionViewModel.autoScroll },
            set: { executionViewModel.autoScroll = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                toolsSection
                executionSection
                loggingSection
                workspaceSection
                recentSection
                maintenanceSection
            }
            .frame(maxWidth: SettingsLayout.contentWidth, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(minWidth: 760, idealWidth: 900, maxWidth: 1020, minHeight: 680, idealHeight: 800, maxHeight: 980)
        .task {
            await refreshDiagnostics()
        }
        .onChange(of: ffmpegService.ffmpegSource) { newValue in
            if newValue == .system {
                Task { await refreshSystemPath() }
            }
        }
        .onChange(of: ffmpegService.customFFmpegPath) { newValue in
            checkCustomPath(newValue)
        }
        .onChange(of: ffprobePath) { newValue in
            checkFFprobePath(newValue)
            ffmpegService.setFFprobePathOverride(newValue)
        }
    }

    private var toolsSection: some View {
        SettingsSection(
            title: "FFmpeg 与 FFprobe",
            description: "管理可执行文件来源、覆写路径和当前解析状态。"
        ) {
            VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                SettingsBlock {
                    VStack(alignment: .leading, spacing: SettingsLayout.insetSpacing) {
                        Text("FFmpeg 来源")
                            .font(.subheadline)
                            .bold()

                        Picker("FFmpeg 来源", selection: ffmpegSourceBinding) {
                            ForEach(FFmpegSource.allCases, id: \.self) { source in
                                Text(source.displayName).tag(source)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }

                SettingsBlock {
                    sourceStatusRow
                }

                if ffmpegService.ffmpegSource == .custom {
                    SettingsBlock {
                        pathEditor(
                            title: "自定义 FFmpeg 路径",
                            text: customFFmpegPathBinding,
                            placeholder: "选择可执行文件",
                            isValid: isCustomPathValid,
                            emptyMessage: "选择一个可执行的 ffmpeg 文件。",
                            validMessage: "路径有效，运行时将直接使用这个二进制。",
                            invalidMessage: "文件不存在或没有执行权限。"
                        ) {
                            await pickCustomFFmpegPath()
                        }
                    }
                }

                SettingsBlock {
                    statusPathBlock(
                        title: "当前 FFmpeg 路径",
                        value: ffmpegService.ffmpegPath,
                        isValid: ffmpegService.isFFmpegAvailable()
                    )
                }

                SettingsBlock {
                    statusPathBlock(
                        title: "当前 FFprobe 路径",
                        value: ffmpegService.ffprobePath,
                        isValid: ffmpegService.isExecutableAvailable(for: .ffprobe),
                        emptyFallback: "当前未解析出可用的 ffprobe。"
                    )
                }

                SettingsBlock {
                    pathEditor(
                        title: "FFprobe 覆写路径",
                        text: $ffprobePath,
                        placeholder: "留空时自动推断",
                        isValid: isFFprobePathValid,
                        emptyMessage: "留空时会优先尝试同级目录，再回退到常见系统路径。",
                        validMessage: "覆写路径有效，ffprobe 任务会优先使用它。",
                        invalidMessage: "覆写路径无效，运行时会继续回退自动推断。",
                        showsClearButton: true
                    ) {
                        await pickFFprobePath()
                    } onClear: {
                        ffprobePath = ""
                    }
                }

                if let version = executionViewModel.ffmpegVersion, !version.isEmpty {
                    SettingsBlock {
                        VStack(alignment: .leading, spacing: SettingsLayout.insetSpacing) {
                            Text("版本信息")
                                .font(.subheadline)
                                .bold()

                            Text(version)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color(NSColor.textBackgroundColor))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5)
                                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                        )
                                )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sourceStatusRow: some View {
        switch ffmpegService.ffmpegSource {
        case .bundled:
            if ffmpegService.isBundledFFmpegAvailable {
                SettingsInlineNotice(
                    title: "内置 FFmpeg 可用",
                    message: ffmpegService.bundledFFmpegPath ?? "内置路径未知",
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                )
            } else {
                SettingsInlineNotice(
                    title: "未找到内置 FFmpeg",
                    message: "将 ffmpeg 二进制放入 App Bundle 的 Resources 后即可随应用分发。",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    actionTitle: "如何添加内置 FFmpeg",
                    action: showBundledFFmpegHelp
                )
            }
        case .system:
            if isSystemAvailable {
                SettingsInlineNotice(
                    title: "系统 FFmpeg 可用",
                    message: systemFFmpegPath ?? ffmpegService.cachedSystemPath ?? "检测到系统路径",
                    systemImage: "checkmark.circle.fill",
                    tint: .green,
                    actionTitle: "刷新系统路径"
                ) {
                    Task { await refreshSystemPath() }
                }
            } else {
                SettingsInlineNotice(
                    title: "未找到系统 FFmpeg",
                    message: "可以通过 Homebrew 安装：brew install ffmpeg",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    actionTitle: "刷新系统路径"
                ) {
                    Task { await refreshSystemPath() }
                }
            }
        case .custom:
            SettingsInlineNotice(
                title: "自定义来源",
                message: "适合测试 nightly build、静态分发版本或隔离环境。",
                systemImage: "folder.fill.badge.gearshape",
                tint: .blue
            )
        }
    }

    private var executionSection: some View {
        SettingsSection(
            title: "执行与安全",
            description: "控制运行前确认、命令预览、覆盖保护和完成通知。"
        ) {
            SettingsBlock {
                SettingsToggleRow(
                    title: "执行前确认",
                    subtitle: "在真正启动进程前停下来检查本次任务。",
                    isOn: $confirmBeforeRun
                )
            }

            SettingsBlock {
                SettingsToggleRow(
                    title: "显示完整命令预览",
                    subtitle: "确认执行时展示完整命令和输出路径，而不是简短提示。",
                    isOn: $showCommandPreviewBeforeRun,
                    isDisabled: !confirmBeforeRun
                )
            }

            SettingsBlock {
                SettingsToggleRow(
                    title: "覆盖文件前确认",
                    subtitle: "当输出文件已存在时，再做一次防误操作确认。",
                    isOn: $confirmOverwrite
                )
            }

            SettingsBlock {
                SettingsToggleRow(
                    title: "完成后发送通知",
                    subtitle: "长任务完成或失败时发送系统通知，可直接打开输出目录。",
                    isOn: $notifyOnComplete
                )
            }

            SettingsBlock {
                LabeledContent("首次安全提醒") {
                    HStack(spacing: 10) {
                        SettingsStatusTag(
                            title: hasAcknowledgedSafetyWarning ? "已确认" : "待显示",
                            tint: hasAcknowledgedSafetyWarning ? .green : .orange
                        )

                        Button("重新显示") {
                            UserSettings.shared.resetSafetyAcknowledgement()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var loggingSection: some View {
        SettingsSection(
            title: "日志与调试",
            description: "平衡滚动跟随、日志密度和排查信息量。"
        ) {
            SettingsBlock {
                SettingsToggleRow(
                    title: "自动滚动日志",
                    subtitle: "控制台跟随最新输出，关闭后可停留在历史位置。",
                    isOn: autoScrollBinding
                )
            }

            SettingsBlock {
                SettingsToggleRow(
                    title: "详细日志输出",
                    subtitle: "向系统日志写入更详细的调试信息，适合开发排查。",
                    isOn: $enableVerboseLogging
                )
            }

            SettingsBlock {
                SettingsToggleRow(
                    title: "合并进度日志",
                    subtitle: "把高频进度刷新合并成更稳定的单行输出。",
                    isOn: $coalesceProgressLogs
                )
            }

            SettingsBlock {
                SettingsStepperRow(
                    title: "最大日志条目",
                    subtitle: "超过上限后优先移除不重要日志，保持界面轻量。",
                    value: "\(maxLogEntries)"
                ) {
                    Stepper("", value: $maxLogEntries, in: 100...10000, step: 100)
                        .labelsHidden()
                }
            }

            SettingsBlock {
                SettingsStepperRow(
                    title: "进度合并间隔",
                    subtitle: "间隔越大，滚动压力越小；间隔越小，进度变化越实时。",
                    value: "\(progressCoalesceIntervalMs) ms",
                    isDisabled: !coalesceProgressLogs
                ) {
                    Stepper("", value: $progressCoalesceIntervalMs, in: 50...1000, step: 50)
                        .labelsHidden()
                }
            }
        }
    }

    private var workspaceSection: some View {
        SettingsSection(
            title: "工作区",
            description: "调整主界面布局密度，让模板列表宽度更贴合使用习惯。"
        ) {
            SettingsBlock {
                VStack(alignment: .leading, spacing: SettingsLayout.insetSpacing) {
                    HStack {
                        Text("侧边栏宽度")
                            .font(.subheadline)
                            .bold()

                        Spacer()

                        Text("\(Int(sidebarWidth)) pt")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $sidebarWidth, in: 220...360, step: 10)

                    Text("数值会立即作用于左侧模板栏，适合按模板名称长度微调。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var recentSection: some View {
        SettingsSection(
            title: "最近使用",
            description: "管理模板记忆与文件选择器回到的目录。"
        ) {
            SettingsBlock {
                SettingsInfoRow(title: "上次模板", value: lastTemplateId.isEmpty ? "未记录" : lastTemplateId)
            }

            SettingsBlock {
                SettingsInfoRow(title: "最近输入目录", value: displayPath(lastInputDirectory))
            }

            SettingsBlock {
                SettingsInfoRow(title: "最近输出目录", value: displayPath(lastOutputDirectory))
            }

            SettingsBlock {
                HStack {
                    Button("清除模板记忆") {
                        lastTemplateId = ""
                    }
                    .disabled(lastTemplateId.isEmpty)

                    Button("清除最近目录") {
                        lastInputDirectory = ""
                        lastOutputDirectory = ""
                    }
                    .disabled(lastInputDirectory.isEmpty && lastOutputDirectory.isEmpty)

                    Spacer()
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var maintenanceSection: some View {
        SettingsSection(
            title: "维护",
            description: "恢复默认偏好，并重新检测当前机器上的可用来源。"
        ) {
            SettingsBlock {
                Text("重置后会清空最近记录、首次提醒状态和运行偏好，同时保留\"当前机器可用来源优先级\"的自动判断。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()

                    Button("重置所有设置", role: .destructive) {
                        Task { await resetAllSettings() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func pathEditor(
        title: String,
        text: Binding<String>,
        placeholder: String,
        isValid: Bool,
        emptyMessage: String,
        validMessage: String,
        invalidMessage: String,
        showsClearButton: Bool = false,
        browseAction: @escaping @MainActor () async -> Void,
        onClear: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayout.insetSpacing) {
            Text(title)
                .font(.subheadline)
                .bold()

            HStack(spacing: 8) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)

                Button("浏览") {
                    Task { await browseAction() }
                }
                .buttonStyle(.bordered)

                if showsClearButton {
                    Button("清空") {
                        onClear?()
                    }
                    .buttonStyle(.borderless)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Text(pathStatusMessage(
                for: text.wrappedValue,
                isValid: isValid,
                emptyMessage: emptyMessage,
                validMessage: validMessage,
                invalidMessage: invalidMessage
            ))
            .font(.callout)
            .foregroundStyle(pathStatusColor(for: text.wrappedValue, isValid: isValid))
        }
    }

    private func statusPathBlock(
        title: String,
        value: String,
        isValid: Bool,
        emptyFallback: String = "当前没有可用路径。"
    ) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayout.insetSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline)
                    .bold()

                Spacer()

                SettingsStatusTag(
                    title: isValid ? "可用" : "未就绪",
                    tint: isValid ? .green : .orange
                )
            }

            Text(value.isEmpty ? emptyFallback : value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(NSColor.textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                )
        }
    }

    private func pathStatusMessage(
        for value: String,
        isValid: Bool,
        emptyMessage: String,
        validMessage: String,
        invalidMessage: String
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return emptyMessage }
        return isValid ? validMessage : invalidMessage
    }

    private func pathStatusColor(for value: String, isValid: Bool) -> Color {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .secondary
        }
        return isValid ? .green : .orange
    }

    private func displayPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未记录" : trimmed
    }

    private func checkCustomPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        isCustomPathValid = !trimmed.isEmpty && FileManager.default.isExecutableFile(atPath: trimmed)
    }

    private func checkFFprobePath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        isFFprobePathValid = trimmed.isEmpty || FileManager.default.isExecutableFile(atPath: trimmed)
    }

    @MainActor
    private func pickCustomFFmpegPath() async {
        let selectedURL = await FilePicker.selectFile(
            initialDirectory: customPathDirectoryURL,
            prompt: "选择 FFmpeg 可执行文件"
        )
        guard let selectedURL else { return }
        ffmpegService.customFFmpegPath = selectedURL.path
    }

    @MainActor
    private func pickFFprobePath() async {
        let selectedURL = await FilePicker.selectFile(
            initialDirectory: ffprobePathDirectoryURL,
            prompt: "选择 FFprobe 可执行文件"
        )
        guard let selectedURL else { return }
        ffprobePath = selectedURL.path
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

        let discoveredSystemPath = await ffmpegService.findSystemFFmpeg()
        let preferredSource: FFmpegSource = ffmpegService.isBundledFFmpegAvailable
            ? .bundled
            : (discoveredSystemPath != nil ? .system : .bundled)

        ffmpegService.setSource(preferredSource)
        ffmpegService.setFFprobePathOverride(UserSettings.shared.ffprobePath)

        systemFFmpegPath = discoveredSystemPath
        isSystemAvailable = discoveredSystemPath != nil

        checkCustomPath(ffmpegService.customFFmpegPath)
        checkFFprobePath(ffprobePath)
    }

    private var customPathDirectoryURL: URL? {
        directoryURL(from: ffmpegService.customFFmpegPath)
    }

    private var ffprobePathDirectoryURL: URL? {
        directoryURL(from: ffprobePath)
    }

    private func directoryURL(from path: String) -> URL? {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return nil }

        let expandedPath = (normalizedPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath).deletingLastPathComponent()
    }

    private func showBundledFFmpegHelp() {
        let alert = NSAlert()
        alert.messageText = "如何添加内置 FFmpeg"
        alert.informativeText = """
        1. 下载 FFmpeg 静态构建版本:
           https://evermeet.cx/ffmpeg/

        2. 解压得到 ffmpeg 二进制文件

        3. 在 Xcode 中:
           - 右键点击项目中的 Resources 文件夹
           - 选择 "Add Files to..."
           - 添加 ffmpeg 文件
           - 确保 "Copy items if needed" 已勾选
           - Target Membership 勾选 FFmpegRunner

        4. 重新构建应用
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}

// MARK: - SettingsSection

private struct SettingsSection<Content: View>: View {
    let title: String
    let description: String
    let content: Content

    init(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                // description 移入 content 区域顶部，label 只保留 title
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)

                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text(title)
                .font(.headline)
        }
    }
}

// MARK: - SettingsBlock

private struct SettingsBlock<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

// MARK: - SettingsToggleRow

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var isDisabled = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .bold()

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Toggle 右对齐，符合 macOS HIG 惯例
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .disabled(isDisabled)
        }
        .opacity(isDisabled ? 0.6 : 1)
    }
}

// MARK: - SettingsStepperRow

private struct SettingsStepperRow<Control: View>: View {
    let title: String
    let subtitle: String
    let value: String
    var isDisabled = false
    let control: Control

    init(
        title: String,
        subtitle: String,
        value: String,
        isDisabled: Bool = false,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.isDisabled = isDisabled
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .bold()

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            control
                .disabled(isDisabled)
        }
        .opacity(isDisabled ? 0.6 : 1)
    }
}

// MARK: - SettingsInlineNotice

private struct SettingsInlineNotice: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .bold()

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.07))
        )
    }
}

// MARK: - SettingsStatusTag

private struct SettingsStatusTag: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(tint.opacity(0.14))
            )
            .foregroundStyle(tint)
    }
}

// MARK: - SettingsInfoRow

private struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .bold()

            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(value == "未记录" ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(NSColor.textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                )
        }
    }
}

// MARK: - Preview

private struct SettingsView_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        SettingsView()
            .environmentObject(ExecutionViewModel())
    }
}
