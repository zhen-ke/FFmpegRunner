//
//  UserSettings.swift
//  FFmpegRunner
//
//  用户设置
//

import SwiftUI
import UserNotifications
import AppKit

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
    @AppStorage("ffprobePath") var ffprobePath: String = ""

    // MARK: - UI 设置

    /// 自动滚动日志
    @AppStorage("autoScrollLog") var autoScrollLog: Bool = true

    /// 最大日志条目数
    @AppStorage("maxLogEntries") var maxLogEntries: Int = 1000

    /// 详细日志输出（开发排查用）
    @AppStorage("enableVerboseLogging") var enableVerboseLogging: Bool = false

    /// 合并进度日志，减少滚动压力
    @AppStorage("coalesceProgressLogs") var coalesceProgressLogs: Bool = true

    /// 进度日志合并间隔（毫秒）
    @AppStorage("progressCoalesceIntervalMs") var progressCoalesceIntervalMs: Int = 200

    /// 侧边栏宽度
    @AppStorage("sidebarWidth") var sidebarWidth: Double = 250

    // MARK: - 执行设置

    /// 执行前确认
    @AppStorage("confirmBeforeRun") var confirmBeforeRun: Bool = false

    /// 执行完成后通知
    @AppStorage("notifyOnComplete") var notifyOnComplete: Bool = true

    /// 覆盖输出文件前确认
    @AppStorage("confirmOverwrite") var confirmOverwrite: Bool = true

    /// 是否启用全局执行超时
    @AppStorage("executionTimeoutEnabled") var executionTimeoutEnabled: Bool = false

    /// 全局执行超时时间（秒）
    @AppStorage("executionTimeoutSeconds") var executionTimeoutSeconds: Int = 1800

    // MARK: - 最近使用

    /// 最近使用的模板 ID
    @AppStorage("lastTemplateId") var lastTemplateId: String = ""

    /// 最近使用的输入目录
    @AppStorage("lastInputDirectory") var lastInputDirectory: String = ""

    /// 最近使用的输出目录
    @AppStorage("lastOutputDirectory") var lastOutputDirectory: String = ""

    // MARK: - 日志持久化设置

    /// 自动保存执行日志
    @AppStorage("autoSaveLog") var autoSaveLog: Bool = true

    /// 最大保存日志文件数
    @AppStorage("maxSavedLogs") var maxSavedLogs: Int = 50

    // MARK: - 安全沙箱设置

    /// 是否已确认首次运行安全警告
    @AppStorage("hasAcknowledgedSafetyWarning") var hasAcknowledgedSafetyWarning: Bool = false

    /// 是否在执行前显示命令预览
    @AppStorage("showCommandPreviewBeforeRun") var showCommandPreviewBeforeRun: Bool = true

    // MARK: - Private

    private init() {}

    /// 当前生效的全局执行超时时间；未启用时返回 nil
    var maximumExecutionTime: TimeInterval? {
        guard executionTimeoutEnabled else { return nil }
        return TimeInterval(max(executionTimeoutSeconds, 1))
    }

    // MARK: - Methods

    /// 重置所有设置
    func resetAll() {
        ffmpegSourceRaw = FFmpegSource.bundled.rawValue
        customFFmpegPath = ""
        ffprobePath = ""
        autoScrollLog = true
        maxLogEntries = 1000
        enableVerboseLogging = false
        coalesceProgressLogs = true
        progressCoalesceIntervalMs = 200
        sidebarWidth = 250
        confirmBeforeRun = false
        notifyOnComplete = true
        confirmOverwrite = true
        executionTimeoutEnabled = false
        executionTimeoutSeconds = 1800
        lastTemplateId = ""
        lastInputDirectory = ""
        lastOutputDirectory = ""
        autoSaveLog = true
        maxSavedLogs = 50
        hasAcknowledgedSafetyWarning = false
        showCommandPreviewBeforeRun = true
    }

    /// 清除最近使用记录
    func clearRecentSelections() {
        lastTemplateId = ""
        lastInputDirectory = ""
        lastOutputDirectory = ""
    }

    /// 重置首次运行提醒状态
    func resetSafetyAcknowledgement() {
        hasAcknowledgedSafetyWarning = false
    }
}

// MARK: - Notification Service

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private let categoryId = "ffmpegrunner.execution"
    private let actionOpenOutput = "open_output_directory"

    private override init() {
        super.init()
    }

    func configure() {
        center.delegate = self

        let openAction = UNNotificationAction(
            identifier: actionOpenOutput,
            title: "打开输出目录",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([category])
    }

    func sendExecutionNotification(
        success: Bool,
        message: String,
        outputDirectory: String?
    ) async {
        guard UserSettings.shared.notifyOnComplete else { return }
        let granted = await requestAuthorizationIfNeeded()
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = success ? "FFmpeg 执行成功" : "FFmpeg 执行失败"
        content.body = message
        content.sound = .default

        if success, let outputDirectory = outputDirectory {
            content.categoryIdentifier = categoryId
            content.userInfo["outputDirectory"] = outputDirectory
            content.userInfo["shouldOpenOutput"] = true
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try? await center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 前台运行时也展示横幅+声音，避免只进入通知中心列表
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let shouldOpen = (userInfo["shouldOpenOutput"] as? Bool) == true

        if shouldOpen,
           let outputDirectory = userInfo["outputDirectory"] as? String {
            openOutputDirectory(outputDirectory)
        }

        completionHandler()
    }

    // MARK: - Authorization

    private func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied, .ephemeral:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Helpers

    private func openOutputDirectory(_ outputDirectory: String) {
        let expanded = (outputDirectory as NSString).expandingTildeInPath
        let directoryURL = URL(fileURLWithPath: expanded)
        NSWorkspace.shared.open(directoryURL)
    }
}
