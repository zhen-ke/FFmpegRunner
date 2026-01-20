//
//  UserSettings.swift
//  FFmpegRunner
//
//  用户设置
//

import SwiftUI

/// 用户设置
class UserSettings: ObservableObject {

    // MARK: - Singleton

    static let shared = UserSettings()

    // MARK: - FFmpeg 设置

    /// FFmpeg 来源类型
    @AppStorage("ffmpegSource") var ffmpegSourceRaw: String = FFmpegSource.bundled.rawValue

    /// FFmpeg 来源
    var ffmpegSource: FFmpegSource {
        get { FFmpegSource(rawValue: ffmpegSourceRaw) ?? .bundled }
        set { ffmpegSourceRaw = newValue.rawValue }
    }

    /// 自定义 FFmpeg 路径
    @AppStorage("customFFmpegPath") var customFFmpegPath: String = ""

    /// FFprobe 可执行文件路径
    @AppStorage("ffprobePath") var ffprobePath: String = "/opt/homebrew/bin/ffprobe"

    // MARK: - UI 设置

    /// 自动滚动日志
    @AppStorage("autoScrollLog") var autoScrollLog: Bool = true

    /// 最大日志条目数
    @AppStorage("maxLogEntries") var maxLogEntries: Int = 1000

    /// 侧边栏宽度
    @AppStorage("sidebarWidth") var sidebarWidth: Double = 250

    // MARK: - 执行设置

    /// 执行前确认
    @AppStorage("confirmBeforeRun") var confirmBeforeRun: Bool = false

    /// 执行完成后通知
    @AppStorage("notifyOnComplete") var notifyOnComplete: Bool = true

    /// 覆盖输出文件前确认
    @AppStorage("confirmOverwrite") var confirmOverwrite: Bool = true

    // MARK: - 最近使用

    /// 最近使用的模板 ID
    @AppStorage("lastTemplateId") var lastTemplateId: String = ""

    /// 最近使用的输入目录
    @AppStorage("lastInputDirectory") var lastInputDirectory: String = ""

    /// 最近使用的输出目录
    @AppStorage("lastOutputDirectory") var lastOutputDirectory: String = ""

    // MARK: - 安全沙箱设置

    /// 是否已确认首次运行安全警告
    @AppStorage("hasAcknowledgedSafetyWarning") var hasAcknowledgedSafetyWarning: Bool = false

    /// 是否在执行前显示命令预览
    @AppStorage("showCommandPreviewBeforeRun") var showCommandPreviewBeforeRun: Bool = true

    // MARK: - Private

    private init() {}

    // MARK: - Methods

    /// 重置所有设置
    func resetAll() {
        ffmpegSourceRaw = FFmpegSource.bundled.rawValue
        customFFmpegPath = ""
        ffprobePath = "/opt/homebrew/bin/ffprobe"
        autoScrollLog = true
        maxLogEntries = 1000
        sidebarWidth = 250
        confirmBeforeRun = false
        notifyOnComplete = true
        confirmOverwrite = true
        lastTemplateId = ""
        lastInputDirectory = ""
        lastOutputDirectory = ""
        hasAcknowledgedSafetyWarning = false
        showCommandPreviewBeforeRun = true
    }
}

// MARK: - 设置视图

struct SettingsView: View {
    @ObservedObject var settings = UserSettings.shared
    @EnvironmentObject var executionViewModel: ExecutionViewModel

    // 直接访问 FFmpegService.shared
    private var ffmpegService: FFmpegService { FFmpegService.shared }

    var body: some View {
        Form {
            // FFmpeg 设置
            Section("FFmpeg 来源") {
                // 来源选择器
                Picker("FFmpeg 来源", selection: Binding(
                    get: { ffmpegService.ffmpegSource },
                    set: { newSource in
                        ffmpegService.ffmpegSource = newSource
                        settings.ffmpegSource = newSource
                    }
                )) {
                    ForEach(FFmpegSource.allCases, id: \.self) { source in
                        HStack {
                            Text(source.displayName)
                            if source == .bundled && !ffmpegService.isBundledFFmpegAvailable {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                        .tag(source)
                    }
                }
                .pickerStyle(.segmented)

                // 内置二进制状态
                if ffmpegService.ffmpegSource == .bundled {
                    if ffmpegService.isBundledFFmpegAvailable {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("内置 FFmpeg 可用")
                            Spacer()
                            Text(ffmpegService.bundledFFmpegPath ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("未找到内置 FFmpeg")
                            }

                            Text("请将 ffmpeg 二进制文件放入 App Bundle 的 Resources 目录")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Button("如何添加内置 FFmpeg") {
                                showBundledFFmpegHelp()
                            }
                            .buttonStyle(.link)
                        }
                    }
                }

                // 系统安装状态
                if ffmpegService.ffmpegSource == .system {
                    if ffmpegService.isSystemFFmpegAvailable {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("系统 FFmpeg 可用")
                            Spacer()
                            Text(ffmpegService.findSystemFFmpeg() ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("未找到系统 FFmpeg")
                            }

                            Text("请通过 Homebrew 安装: brew install ffmpeg")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // 自定义路径
                if ffmpegService.ffmpegSource == .custom {
                    HStack {
                        TextField("自定义 FFmpeg 路径", text: Binding(
                            get: { ffmpegService.customFFmpegPath },
                            set: { newPath in
                                ffmpegService.customFFmpegPath = newPath
                                settings.customFFmpegPath = newPath
                            }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button("浏览...") {
                            FilePicker.selectFile(types: nil) { url in
                                if let url = url {
                                    ffmpegService.customFFmpegPath = url.path
                                    settings.customFFmpegPath = url.path
                                }
                            }
                        }
                    }

                    if !ffmpegService.customFFmpegPath.isEmpty {
                        if FileManager.default.isExecutableFile(atPath: ffmpegService.customFFmpegPath) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("自定义路径有效")
                            }
                        } else {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text("文件不存在或不可执行")
                            }
                        }
                    }
                }

                // 当前使用的路径
                Divider()

                HStack {
                    Text("当前路径:")
                        .foregroundColor(.secondary)
                    Text(ffmpegService.ffmpegPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(ffmpegService.isFFmpegAvailable() ? .primary : .red)
                        .lineLimit(1)
                }

                // 版本信息
                if executionViewModel.isFFmpegAvailable {
                    if let version = executionViewModel.ffmpegVersion {
                        Text(version)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // UI 设置
            Section("界面") {
                Toggle("自动滚动日志", isOn: $settings.autoScrollLog)

                Stepper("最大日志条目: \(settings.maxLogEntries)", value: $settings.maxLogEntries, in: 100...10000, step: 100)
            }

            // 执行设置
            Section("执行") {
                Toggle("执行前确认", isOn: $settings.confirmBeforeRun)
                Toggle("完成后发送通知", isOn: $settings.notifyOnComplete)
                Toggle("覆盖文件前确认", isOn: $settings.confirmOverwrite)
            }

            // 重置
            Section {
                Button("重置所有设置", role: .destructive) {
                    settings.resetAll()
                    ffmpegService.setSource(.bundled)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 550, height: 550)
        .onAppear {
            // 同步设置到服务
            ffmpegService.customFFmpegPath = settings.customFFmpegPath
            ffmpegService.ffmpegSource = settings.ffmpegSource
        }
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

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(ExecutionViewModel())
}
