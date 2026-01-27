//
//  ParameterFormView.swift
//  FFmpegRunner
//
//  参数表单视图 - 动态生成控件
//

import SwiftUI

/// 参数表单视图
struct ParameterFormView: View {

    // MARK: - Environment

    @EnvironmentObject var viewModel: TemplateDetailViewModel

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let template = viewModel.template {
                ForEach(template.parameters) { parameter in
                    ParameterFieldView(
                        parameter: parameter,
                        value: viewModel.binding(for: parameter.key),
                        error: viewModel.validationErrors[parameter.key]
                    )
                }
            } else {
                Text("请选择一个模板")
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 参数字段视图

struct ParameterFieldView: View {
    let parameter: TemplateParameter
    @Binding var value: String
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标签
            HStack {
                Text(parameter.label)
                    .font(.headline)

                if parameter.isRequired {
                    Text("*")
                        .foregroundColor(.red)
                }
            }

            // 输入控件
            inputField

            // 占位符/帮助文本
            if let placeholder = parameter.placeholder, error == nil {
                Text(placeholder)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 错误信息
            if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - 输入控件

    @ViewBuilder
    private var inputField: some View {
        switch parameter.type {
        case .string:
            StringField(
                value: $value,
                placeholder: parameter.effectivePlaceholder,
                isMultiline: parameter.effectiveMultiline,
                isMonospace: parameter.effectiveMonospace
            )

        case .number:
            NumberField(
                value: $value,
                min: parameter.constraints?.min,
                max: parameter.constraints?.max
            )

        case .boolean:
            BooleanField(value: $value)

        case .file:
            FileField(
                value: $value,
                fileTypes: parameter.constraints?.fileTypes,
                isOutput: parameter.constraints?.isOutputFile ?? false
            )

        case .select:
            SelectField(
                value: $value,
                options: parameter.constraints?.options ?? []
            )
        }
    }
}

// MARK: - 字符串字段

struct StringField: View {
    @Binding var value: String
    let placeholder: String?
    var isMultiline: Bool = false
    var isMonospace: Bool = false

    var body: some View {
        Group {
            if isMultiline {
                if isMonospace {
                    // 命令输入（支持拖拽插入路径）
                    CommandTextView(text: $value, placeholder: placeholder)
                        .frame(minHeight: 120)
                } else {
                    // 普通多行输入
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $value)
                            .font(.body)
                            .frame(minHeight: 120)
                            .padding(4)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )

                        // 简易 Placeholder 实现
                        if value.isEmpty, let placeholder = placeholder {
                            Text(placeholder)
                                .foregroundColor(.secondary.opacity(0.5))
                                .padding(.top, 8)
                                .padding(.leading, 8)
                                .allowsHitTesting(false)
                        }
                    }
                }
            } else {
                // 单行输入
                TextField(placeholder ?? "", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(isMonospace ? .body.monospaced() : .body)
            }
        }
    }
}

// MARK: - 数字字段

struct NumberField: View {
    @Binding var value: String
    let min: Double?
    let max: Double?

    var body: some View {
        HStack {
            TextField("", text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)

            if let min = min, let max = max {
                Slider(
                    value: Binding(
                        get: { Double(value) ?? min },
                        set: { value = String(Int($0)) }
                    ),
                    in: min...max,
                    step: 1
                )

                Text("\(Int(Double(value) ?? min))")
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

// MARK: - 布尔字段

struct BooleanField: View {
    @Binding var value: String

    var isOn: Binding<Bool> {
        Binding(
            get: { value.lowercased() == "true" || value == "1" },
            set: { value = $0 ? "true" : "false" }
        )
    }

    var body: some View {
        Toggle("启用", isOn: isOn)
            .toggleStyle(.switch)
    }
}

// MARK: - 文件字段

struct FileField: View {
    @Binding var value: String
    let fileTypes: [String]?
    let isOutput: Bool

    @State private var isDragging = false

    var body: some View {
        HStack {
            TextField(isOutput ? "输出路径" : "文件路径", text: $value)
                .textFieldStyle(.roundedBorder)

            Button(action: selectFile) {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDragging ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers)
        }
    }

    private func selectFile() {
        let panel = isOutput ? NSSavePanel() : NSOpenPanel()

        if let openPanel = panel as? NSOpenPanel {
            openPanel.allowsMultipleSelection = false
            openPanel.canChooseDirectories = false
            openPanel.canChooseFiles = true
        }

        if let fileTypes = fileTypes, !fileTypes.isEmpty {
            panel.allowedContentTypes = fileTypes.compactMap { ext in
                UTType(filenameExtension: ext)
            }
        }

        panel.begin { response in
            if response == .OK, let url = panel.url {
                value = url.path
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                DispatchQueue.main.async {
                    value = url.path
                }
            }
        }

        return true
    }
}

// MARK: - 选择字段

struct SelectField: View {
    @Binding var value: String
    let options: [String]

    var body: some View {
        Picker("", selection: $value) {
            if !options.contains(value) {
                Text("请选择...").tag("")
            }
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 200)
        .onAppear {
            // 如果当前值无效，设置为第一个选项
            if !value.isEmpty && !options.contains(value) && !options.isEmpty {
                value = options[0]
            }
        }
    }
}

// MARK: - Import

import UniformTypeIdentifiers

// MARK: - Preview

#Preview {
    ScrollView {
        ParameterFormView()
            .environmentObject(TemplateDetailViewModel(template: .example))
            .padding()
    }
    .frame(width: 400, height: 600)
}
