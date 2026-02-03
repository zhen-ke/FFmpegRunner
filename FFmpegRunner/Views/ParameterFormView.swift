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
                    if template.id == "video_to_gif", parameter.key == "filter" {
                        GifFpsWidthField(
                            filterValue: viewModel.binding(for: parameter.key),
                            validationError: viewModel.validationErrors[parameter.key]
                        )
                    } else {
                        ParameterFieldView(
                            parameter: parameter,
                            value: viewModel.binding(for: parameter.key),
                            error: viewModel.validationErrors[parameter.key]
                        )
                    }
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
            if let placeholder = parameter.effectivePlaceholder, error == nil {
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

// MARK: - GIF FPS + Width Field

struct GifFpsWidthField: View {
    @Binding var filterValue: String
    let validationError: String?

    @State private var widthText: String = ""
    @State private var fpsText: String = ""
    @State private var parseError: String?
    @State private var lastFilterValue: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 宽度
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("宽度 (像素)")
                        .font(.headline)
                    Text("*")
                        .foregroundColor(.red)
                }

                TextField("例如 320, 480, 640", text: $widthText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(maxWidth: 220, alignment: .leading)
                    .onChange(of: widthText) { _ in
                        updateFilterFromInputs()
                    }
            }

            // 帧率
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("帧率 (FPS)")
                        .font(.headline)
                    Text("*")
                        .foregroundColor(.red)
                }

                TextField("建议 10-24", text: $fpsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(maxWidth: 220, alignment: .leading)
                    .onChange(of: fpsText) { _ in
                        updateFilterFromInputs()
                    }
            }

            if let error = parseError ?? validationError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            } else {
                Text("将自动生成 GIF 的滤镜链（palettegen/paletteuse）")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            syncFromFilterIfNeeded(filterValue)
        }
        .onChange(of: filterValue) { newValue in
            syncFromFilterIfNeeded(newValue)
        }
    }

    private func syncFromFilterIfNeeded(_ value: String) {
        guard value != lastFilterValue else { return }
        lastFilterValue = value

        if let parsed = parseFilterValue(value) {
            if widthText != parsed.width {
                widthText = parsed.width
            }
            if fpsText != parsed.fps {
                fpsText = parsed.fps
            }
        } else if widthText.isEmpty && fpsText.isEmpty {
            widthText = "480"
            fpsText = "15"
            updateFilterFromInputs()
        }
    }

    private func updateFilter(_ value: String) {
        if filterValue != value {
            filterValue = value
            lastFilterValue = value
        }
    }

    private func updateFilterFromInputs() {
        let width = widthText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fps = fpsText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !width.isEmpty && !fps.isEmpty else {
            parseError = "请输入宽度和帧率"
            updateFilter("")
            return
        }

        guard (Double(width) ?? 0) > 0, (Double(fps) ?? 0) > 0 else {
            parseError = "宽度和帧率必须为数字"
            updateFilter("")
            return
        }

        parseError = nil
        updateFilter(buildFilter(fps: fps, width: width))
    }

    private func parseFilterValue(_ value: String) -> (fps: String, width: String)? {
        guard !value.isEmpty else { return nil }
        let fpsPattern = #"fps=([0-9]+(?:\.[0-9]+)?)"#
        let widthPattern = #"scale=([0-9]+)"#

        guard let fpsRegex = try? NSRegularExpression(pattern: fpsPattern),
              let widthRegex = try? NSRegularExpression(pattern: widthPattern) else {
            return nil
        }

        let range = NSRange(value.startIndex..., in: value)
        guard let fpsMatch = fpsRegex.firstMatch(in: value, range: range),
              let widthMatch = widthRegex.firstMatch(in: value, range: range),
              let fpsRange = Range(fpsMatch.range(at: 1), in: value),
              let widthRange = Range(widthMatch.range(at: 1), in: value) else {
            return nil
        }

        return (String(value[fpsRange]), String(value[widthRange]))
    }

    private func buildFilter(fps: String, width: String) -> String {
        "fps=\(fps),scale=\(width):-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
    }
}

// MARK: - 字符串字段

struct StringField: View {
    @Binding var value: String
    let placeholder: String?
    var isMultiline: Bool = false
    var isMonospace: Bool = false

    // MARK: - 防抖状态
    @State private var localText: String = ""
    @State private var debounceTask: Task<Void, Never>?

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
                // 单行输入（带防抖）
                TextField(placeholder ?? "", text: $localText)
                    .textFieldStyle(.roundedBorder)
                    .font(isMonospace ? .body.monospaced() : .body)
                    .onAppear {
                        localText = value
                    }
                    .onChange(of: localText) { newValue in
                        debounceTask?.cancel()
                        debounceTask = Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            value = newValue
                        }
                    }
                    .onChange(of: value) { newValue in
                        // 外部值变化时同步本地状态
                        if localText != newValue {
                            localText = newValue
                        }
                    }
            }
        }
    }
}

// MARK: - 数字字段

struct NumberField: View {
    @Binding var value: String
    let min: Double?
    let max: Double?

    // MARK: - 本地状态缓存
    @State private var localText: String = ""
    @State private var sliderValue: Double = 0
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        HStack {
            TextField("", text: $localText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .onAppear {
                    localText = value
                    sliderValue = Double(value) ?? min ?? 0
                }
                .onChange(of: localText) { newValue in
                    // 更新滑块值（如果是有效数字）
                    if let num = Double(newValue) {
                        sliderValue = num
                    }
                    // 防抖同步到绑定
                    debounceTask?.cancel()
                    debounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        value = newValue
                    }
                }
                .onChange(of: value) { newValue in
                    // 外部值变化时同步本地状态
                    if localText != newValue {
                        localText = newValue
                        sliderValue = Double(newValue) ?? min ?? 0
                    }
                }

            if let min = min, let max = max {
                Slider(value: $sliderValue, in: min...max, step: 1)
                    .onChange(of: sliderValue) { newValue in
                        let intValue = String(Int(newValue))
                        localText = intValue
                        value = intValue
                    }

                Text("\(Int(sliderValue))")
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
