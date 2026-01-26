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
