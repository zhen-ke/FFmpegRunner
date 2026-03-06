//
//  MainSplitView.swift
//  FFmpegRunner
//
//  主分栏视图
//

import SwiftUI

/// 主分栏视图
struct MainSplitView: View {

    // MARK: - Environment

    @EnvironmentObject var listViewModel: TemplateListViewModel
    @EnvironmentObject var navigationState: NavigationState

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $navigationState.columnVisibility) {
            // 左侧：模板列表
            TemplateListView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } detail: {
            // 右侧：详情视图
            if listViewModel.selectedTemplate != nil {
                DetailContentView()
            } else {
                EmptyStateView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .animation(nil, value: navigationState.columnVisibility)
        .task {
            await listViewModel.loadTemplates()
        }
    }
}

// MARK: - 详情内容视图

struct DetailContentView: View {

    @EnvironmentObject var listViewModel: TemplateListViewModel
    @EnvironmentObject var detailViewModel: TemplateDetailViewModel
    @EnvironmentObject var executionViewModel: ExecutionViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 模板信息头部
            TemplateHeaderView()

            Divider()

            // 主内容区域
            HSplitView {
                // 左侧：参数表单
                VStack(spacing: 0) {
                    Text("参数设置")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))

                    Divider()

                    ScrollView {
                        ParameterFormView()
                            .padding()
                    }
                }
                .frame(minWidth: 300)

                // 右侧：命令预览和日志
                VStack(spacing: 0) {
                    // 命令预览
                    CommandPreviewView()
                        .padding([.horizontal, .top], 12)
                        .padding(.bottom, 4)
                        .frame(minHeight: 140, maxHeight: 220)

                    Divider()

                    // 日志控制台
                    LogConsoleView()
                }
                .frame(minWidth: 400)
            }
        }
        .onAppear {
            // DetailContentView 仅在 selectedTemplate != nil 时创建，
            // 需要把当前选择同步到详情模型。
            detailViewModel.selectTemplate(listViewModel.selectedTemplate)
        }
        .onChange(of: listViewModel.selectedTemplate) { newTemplate in
            detailViewModel.selectTemplate(newTemplate)
            // 切换模板或历史记录时，重置控制台
            executionViewModel.clearLogs()
            executionViewModel.reset()
        }
    }
}

// MARK: - Preview

#Preview {
    MainSplitView()
        .environmentObject(TemplateListViewModel())
        .environmentObject(TemplateDetailViewModel())
        .environmentObject(CommandPreviewViewModel())
        .environmentObject(ExecutionViewModel())
        .environmentObject(TemplateHeaderViewModel())
        .environmentObject(NavigationState())
        .frame(width: 1200, height: 800)
}
