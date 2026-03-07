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
