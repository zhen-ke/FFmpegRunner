//
//  ExecutionAlerts.swift
//  FFmpegRunner
//
//  执行相关弹窗 ViewModifier - 集中管理所有执行流程弹窗
//

import SwiftUI

/// 执行相关弹窗 Modifier
/// 将 TemplateHeaderView 中的 5 个弹窗声明集中管理
struct ExecutionAlertsModifier: ViewModifier {

    @ObservedObject var headerViewModel: TemplateHeaderViewModel
    @ObservedObject var executionViewModel: ExecutionViewModel
    @ObservedObject var previewViewModel: CommandPreviewViewModel
    @ObservedObject var listViewModel: TemplateListViewModel

    func body(content: Content) -> some View {
        content
            // 保存为模板 Sheet
            .sheet(isPresented: $headerViewModel.showSaveAsTemplateSheet) {
                SaveAsTemplateSheet(
                    command: previewViewModel.renderedCommand,
                    headerViewModel: headerViewModel,
                    onSave: {
                        Task {
                            await headerViewModel.saveAsTemplate(
                                command: previewViewModel.renderedCommand,
                                listViewModel: listViewModel,
                                executionViewModel: executionViewModel
                            )
                        }
                    }
                )
            }
            .sheet(isPresented: $headerViewModel.showRunPreviewSheet) {
                ExecutionReviewSheet(
                    title: headerViewModel.runPreviewTitle,
                    executableName: headerViewModel.runPreviewExecutable,
                    command: headerViewModel.runPreviewCommand,
                    outputPath: headerViewModel.runPreviewOutputPath,
                    onCancel: headerViewModel.cancelPendingExecution,
                    onContinue: {
                        Task {
                            await headerViewModel.confirmPendingExecution(
                                executionViewModel: executionViewModel
                            )
                        }
                    }
                )
            }
            .alert("首次执行提醒", isPresented: $headerViewModel.showSafetyWarning) {
                Button("继续") {
                    Task {
                        await headerViewModel.acknowledgeSafetyWarning(
                            executionViewModel: executionViewModel
                        )
                    }
                }
                Button("取消", role: .cancel) {
                    headerViewModel.cancelPendingExecution()
                }
            } message: {
                Text(
                    """
                    应用会直接调用本机 FFmpeg/FFprobe 二进制，并按照当前参数写入输出路径。

                    首次执行前请确认输入来源、输出位置与覆盖行为，尤其在“自定义命令”模式下。
                    """
                )
            }
            // 执行前确认对话框
            .confirmationDialog(
                headerViewModel.runConfirmationTitle,
                isPresented: $headerViewModel.showRunConfirmation,
                titleVisibility: .visible
            ) {
                Button("执行") {
                    Task {
                        await headerViewModel.confirmPendingExecution(
                            executionViewModel: executionViewModel
                        )
                    }
                }
                Button("取消", role: .cancel) {
                    headerViewModel.cancelPendingExecution()
                }
            } message: {
                Text(headerViewModel.runConfirmationMessage)
            }
            // 文件覆盖确认
            .alert("文件已存在", isPresented: $headerViewModel.showOverwriteConfirm) {
                Button("取消", role: .cancel) {
                    headerViewModel.cancelPendingExecution()
                }
                Button("覆盖", role: .destructive) {
                    Task {
                        await headerViewModel.confirmPendingOverwrite(
                            executionViewModel: executionViewModel
                        )
                    }
                }
            } message: {
                Text("输出文件「\(headerViewModel.existingOutputFile)」已存在，是否覆盖？")
            }
            // 保存成功提示
            .alert("保存成功", isPresented: $headerViewModel.showSuccess) {
                Button("好的") {}
            } message: {
                Text(headerViewModel.successMessage)
            }
            // 保存失败提示
            .alert("保存失败", isPresented: $headerViewModel.showError) {
                Button("好的") {}
            } message: {
                Text(headerViewModel.errorMessage)
            }
    }
}

extension View {
    /// 添加执行相关弹窗
    func executionAlerts(
        headerViewModel: TemplateHeaderViewModel,
        executionViewModel: ExecutionViewModel,
        previewViewModel: CommandPreviewViewModel,
        listViewModel: TemplateListViewModel
    ) -> some View {
        modifier(ExecutionAlertsModifier(
            headerViewModel: headerViewModel,
            executionViewModel: executionViewModel,
            previewViewModel: previewViewModel,
            listViewModel: listViewModel
        ))
    }
}

private struct ExecutionReviewSheet: View {
    let title: String
    let executableName: String
    let command: String
    let outputPath: String?
    let onCancel: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.09, green: 0.37, blue: 0.45),
                                        Color(red: 0.15, green: 0.53, blue: 0.63)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 52, height: 52)

                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.title3.weight(.semibold))

                        Text("执行前预览当前命令、输出路径与可执行文件来源。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Label(executableName.uppercased(), systemImage: "terminal")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                    }
                }

                if let outputPath, !outputPath.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("输出路径")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(outputPath)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(NSColor.textBackgroundColor))
                            )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("完整命令")
                    .font(.headline)

                ScrollView {
                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(minHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            HStack {
                Text("命令会按当前预览原样执行。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("继续执行", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 640, idealWidth: 700, maxWidth: 760, minHeight: 500, idealHeight: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
