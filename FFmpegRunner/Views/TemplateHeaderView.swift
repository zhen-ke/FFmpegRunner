//
//  TemplateHeaderView.swift
//  FFmpegRunner
//
//  模板头部视图 - 显示模板信息和操作按钮
//

import SwiftUI

/// 模板头部视图
struct TemplateHeaderView: View {

    @EnvironmentObject var detailViewModel: TemplateDetailViewModel
    @EnvironmentObject var previewViewModel: CommandPreviewViewModel
    @EnvironmentObject var executionViewModel: ExecutionViewModel
    @EnvironmentObject var listViewModel: TemplateListViewModel
    @EnvironmentObject var headerViewModel: TemplateHeaderViewModel

    var body: some View {
        HStack {
            // 模板信息
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let icon = detailViewModel.template?.icon {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(.accentColor)
                    }

                    Text(detailViewModel.template?.name ?? "")
                        .font(.title2)
                        .fontWeight(.semibold)
                }

                Text(detailViewModel.template?.description ?? "")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 操作按钮
            HStack(spacing: 12) {
                // 保存为模板按钮（仅在 RawCommand 模板且成功执行后显示）
                if canShowSaveAsTemplate {
                    Button(action: { headerViewModel.showSaveAsTemplateSheet = true }) {
                        Label("保存为模板", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }

                // 重置按钮
                Button(action: detailViewModel.resetToDefaults) {
                    Label("重置", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .disabled(executionViewModel.isRunning)

                // 执行/取消按钮
                if executionViewModel.isRunning {
                    Button(action: executionViewModel.cancel) {
                        Label("取消", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button(action: {
                        Task {
                            await headerViewModel.requestExecution(
                                binding: detailViewModel.templateBinding,
                                currentCommand: previewViewModel.currentCommand,
                                executionViewModel: executionViewModel
                            )
                        }
                    }) {
                        Label("执行", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!detailViewModel.canExecute || !previewViewModel.isComplete)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
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
        .alert("保存成功", isPresented: $headerViewModel.showSuccess) {
            Button("好的") {}
        } message: {
            Text(headerViewModel.successMessage)
        }
        .alert("保存失败", isPresented: $headerViewModel.showError) {
            Button("好的") {}
        } message: {
            Text(headerViewModel.errorMessage)
        }
    }

    /// 是否显示保存为模板按钮（纯 UI 逻辑，保留在 View 中）
    private var canShowSaveAsTemplate: Bool {
        guard let template = detailViewModel.template else { return false }
        let isRawCommand = template.id == Template.rawCommandId
        let hasSuccessfulResult = executionViewModel.lastResult?.isSuccess == true
        return isRawCommand && hasSuccessfulResult && !executionViewModel.isRunning
    }
}
