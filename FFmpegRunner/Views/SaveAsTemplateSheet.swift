//
//  SaveAsTemplateSheet.swift
//  FFmpegRunner
//
//  保存为模板弹窗
//

import SwiftUI

/// 保存为模板弹窗
struct SaveAsTemplateSheet: View {
    let command: String
    @ObservedObject var headerViewModel: TemplateHeaderViewModel
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("保存为模板")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("模板名称")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField("例如：视频压缩 H265", text: $headerViewModel.templateName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("分类（可选）")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField("例如：视频处理", text: $headerViewModel.templateCategory)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("命令预览")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(4)
            }

            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("保存") {
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(headerViewModel.templateName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
