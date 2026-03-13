//
//  RawCommandWorkspaceView.swift
//  FFmpegRunner
//
//  自定义命令工作区
//

import SwiftUI

struct RawCommandWorkspaceView: View {
    @EnvironmentObject private var detailViewModel: TemplateDetailViewModel

    private var commandParameter: TemplateParameter? {
        detailViewModel.template?.parameters.first(where: { $0.key == Template.rawCommandParameterKey })
    }

    private var commandText: Binding<String> {
        detailViewModel.binding(for: Template.rawCommandParameterKey)
    }

    private var validationError: String? {
        detailViewModel.validationErrors[Template.rawCommandParameterKey]
    }

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("命令编辑器")
                            .font(.headline)

                        Spacer()

                        if !commandText.wrappedValue.isEmpty {
                            Text("\(commandText.wrappedValue.count) 字符")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("直接编辑完整 FFmpeg 命令，日志保留在下方控制台。输入参数时可用 Tab 补全常见选项。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                CommandTextView(
                    text: commandText,
                    placeholder: commandParameter?.effectivePlaceholder ?? "输入完整 FFmpeg 命令"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .frame(minHeight: 220)

            LogConsoleView()
                .frame(minHeight: 240)
        }
    }
}

#Preview {
    RawCommandWorkspaceView()
        .environmentObject(TemplateDetailViewModel(template: Template.makeRawCommandTemplate(
            name: "自定义命令",
            description: "直接输入并执行完整 FFmpeg 命令",
            defaultCommand: "ffmpeg -i input.mp4 -c:v libx264 output.mp4",
            placeholder: "在此输入完整命令...",
            category: "高级",
            icon: "terminal.fill"
        )))
        .environmentObject(ExecutionViewModel())
        .frame(width: 1000, height: 700)
}
