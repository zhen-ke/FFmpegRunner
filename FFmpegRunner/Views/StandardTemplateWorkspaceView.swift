//
//  StandardTemplateWorkspaceView.swift
//  FFmpegRunner
//
//  常规模板工作区
//

import SwiftUI

struct StandardTemplateWorkspaceView: View {
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Text("参数设置")
                    .font(.title3)
                    .fontWeight(.semibold)
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

            VStack(spacing: 0) {
                CommandPreviewView()
                    .frame(minHeight: 140, maxHeight: 220)

                Divider()

                LogConsoleView()
            }
            .frame(minWidth: 400)
        }
    }
}

private struct StandardTemplateWorkspaceView_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        StandardTemplateWorkspaceView()
            .environmentObject(TemplateDetailViewModel())
            .environmentObject(CommandPreviewViewModel())
            .environmentObject(ExecutionViewModel())
            .frame(width: 1000, height: 700)
    }
}
