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
    @State private var showQueuePopover = false

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
                .disabled(executionViewModel.isRunning || executionViewModel.isQueueRunning)

                Button(action: {
                    Task {
                        await headerViewModel.requestEnqueue(
                            binding: detailViewModel.templateBinding,
                            currentCommand: previewViewModel.currentCommand,
                            executionViewModel: executionViewModel
                        )
                    }
                }) {
                    Label("加入队列", systemImage: "text.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(!detailViewModel.canExecute || !previewViewModel.isComplete)

                Button(action: { showQueuePopover.toggle() }) {
                    Label(queueButtonTitle, systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showQueuePopover, arrowEdge: .top) {
                    QueuePopoverView(executionViewModel: executionViewModel)
                }

                // 执行/取消按钮
                if executionViewModel.isRunning || executionViewModel.isQueueRunning {
                    Button(action: executionViewModel.cancel) {
                        Label(executionViewModel.isQueueRunning ? "停止队列" : "取消", systemImage: "stop.fill")
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
        .executionAlerts(
            headerViewModel: headerViewModel,
            executionViewModel: executionViewModel,
            previewViewModel: previewViewModel,
            listViewModel: listViewModel
        )

    }

    /// 是否显示保存为模板按钮（纯 UI 逻辑，保留在 View 中）
    private var canShowSaveAsTemplate: Bool {
        guard let template = detailViewModel.template else { return false }
        let isRawCommand = template.isBuiltInRawCommand
        let hasSuccessfulResult = executionViewModel.lastResult?.isSuccess == true
        let previewMatchesLastExecution = executionViewModel.matchesLastExecutedCommand(
            previewViewModel.renderedCommand
        )
        return isRawCommand &&
            hasSuccessfulResult &&
            previewMatchesLastExecution &&
            !executionViewModel.isRunning &&
            !executionViewModel.isQueueRunning
    }

    private var queueButtonTitle: String {
        if executionViewModel.isQueueRunning {
            return "队列 \(executionViewModel.completedQueueItemCount)/\(executionViewModel.completedQueueItemCount + executionViewModel.queueItems.count)"
        }

        if executionViewModel.queueItems.isEmpty {
            return "队列"
        }

        return "队列 \(executionViewModel.queueItems.count)"
    }
}

private struct QueuePopoverView: View {
    @ObservedObject var executionViewModel: ExecutionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("执行队列")
                        .font(.headline)

                    Text(queueDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if executionViewModel.hasQueuedItems {
                    Button("清空", role: .destructive) {
                        executionViewModel.clearQueue()
                    }
                    .disabled(executionViewModel.isQueueRunning && executionViewModel.queueItems.count <= 1)
                }
            }

            if executionViewModel.queueItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("还没有待执行任务。")
                        .font(.subheadline)
                    Text("先把不同模板或参数加入队列，再点“开始执行”。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 20)
            } else {
                List {
                    ForEach(executionViewModel.queueItems) { item in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(item.title)
                                        .font(.subheadline.weight(.semibold))

                                    if executionViewModel.activeQueueItemID == item.id {
                                        Text("执行中")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                                    }
                                }

                                Text(item.plan.displayCommand)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 8)

                            if executionViewModel.activeQueueItemID != item.id {
                                Button(role: .destructive) {
                                    executionViewModel.removeQueuedItem(id: item.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: 180, maxHeight: 260)
                .listStyle(.plain)
            }

            HStack {
                if executionViewModel.isQueueRunning {
                    Text("队列会按顺序逐个执行。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("开始后会按当前顺序依次执行。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("开始执行") {
                    executionViewModel.startQueue()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!executionViewModel.canStartQueue)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private var queueDescription: String {
        if executionViewModel.isQueueRunning {
            let total = executionViewModel.completedQueueItemCount + executionViewModel.queueItems.count
            return "已完成 \(executionViewModel.completedQueueItemCount) / \(max(total, 1))"
        }

        return "待执行 \(executionViewModel.queueItems.count) 项"
    }
}
