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
    @AppStorage("sidebarWidth") private var sidebarWidth = 250.0

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $navigationState.columnVisibility) {
            // 左侧：模板列表
            TemplateListView()
                .navigationSplitViewColumnWidth(
                    min: 220,
                    ideal: CGFloat(sidebarWidth),
                    max: 420
                )
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
    @EnvironmentObject var headerViewModel: TemplateHeaderViewModel

    var body: some View {
        VStack(spacing: 0) {
            TemplateHeaderView()
            Divider()
            if detailViewModel.template?.isRawCommandTemplate == true {
                RawCommandWorkspaceView()
            } else {
                StandardTemplateWorkspaceView()
            }
        }
        .onAppear {
            detailViewModel.selectTemplate(listViewModel.selectedTemplate)
        }
        .onChange(of: listViewModel.selectedTemplate) { newTemplate in
            headerViewModel.cancelPendingExecution()
            detailViewModel.selectTemplate(newTemplate)
            executionViewModel.clearLogs()
            executionViewModel.reset()
        }
    }
}

// MARK: - Preview

private struct MainSplitView_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        MainSplitView()
            .environmentObject(TemplateListViewModel())
            .environmentObject(TemplateDetailViewModel())
            .environmentObject(CommandPreviewViewModel())
            .environmentObject(ExecutionViewModel())
            .environmentObject(TemplateHeaderViewModel())
            .environmentObject(NavigationState())
            .frame(width: 1200, height: 800)
    }
}
