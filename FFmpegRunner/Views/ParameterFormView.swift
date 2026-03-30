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
                    // 静态隐藏（compositeType 代理）
                    if parameter.uiHint?.hidden == true {
                        EmptyView()
                    }
                    // 条件隐藏（visibleWhen 规则不满足）
                    else if viewModel.isConditionallyHidden(parameter.key) {
                        EmptyView()
                    }
                    // 复合控件路由
                    else if parameter.uiHint?.compositeType == "gifFilter" {
                        GifFpsWidthField(
                            filterValue: viewModel.binding(for: parameter.key),
                            validationError: viewModel.validationErrors[parameter.key]
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if parameter.uiHint?.compositeType == "timeRange" {
                        let groupKey = parameter.uiHint?.compositeGroup ?? "duration"
                        FastCutTimeRangeField(
                            startTime: viewModel.binding(for: parameter.key),
                            duration: viewModel.binding(for: groupKey),
                            startValidationError: viewModel.validationErrors[parameter.key]
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    // 普通参数
                    else {
                        ParameterFieldView(
                            parameter: parameter,
                            value: viewModel.binding(for: parameter.key),
                            error: viewModel.validationErrors[parameter.key]
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            } else {
                Text("请选择一个模板")
                    .foregroundColor(.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.conditionallyHiddenKeys)
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
                options: parameter.constraints?.options ?? [],
                optionLabels: parameter.constraints?.optionLabels
            )
        }
    }
}

// MARK: - Fast Cut Time Range Field

struct FastCutTimeRangeField: View {
    @Binding var startTime: String
    @Binding var duration: String
    let startValidationError: String?

    @State private var startText: String = ""
    @State private var endText: String = ""
    @State private var localError: String?
    @State private var lastSyncedStartTime: String = ""
    @State private var lastSyncedDuration: String = ""

    private var helperText: String {
        if let startSeconds = FastCutTimecodeSupport.parseUserTimecode(startTime),
           let durationSeconds = Double(duration),
           durationSeconds > 0 {
            let endSeconds = startSeconds + durationSeconds
            let secondsText = FastCutTimecodeSupport.formatDurationSeconds(durationSeconds)
            let durationClock = FastCutTimecodeSupport.formatTimecode(endSeconds - startSeconds)
            return "自动换算时长：\(secondsText) 秒（\(durationClock)），结束点：\(FastCutTimecodeSupport.formatTimecode(endSeconds))"
        }

        return "支持秒数、HH:MM:SS，以及 01.30 这类分.秒速记；结束时间会自动换算为命令里的 -t。"
    }

    private var visibleError: String? {
        localError ?? startValidationError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                timeInput(
                    title: "开始时间",
                    text: $startText,
                    prompt: "例如 00:00:00 / 90 / 01.30"
                )

                timeInput(
                    title: "结束时间",
                    text: $endText,
                    prompt: "例如 00:01:00 / 150 / 02.30"
                )
            }

            if let error = visibleError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            } else {
                Text(helperText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            syncFromBindingsIfNeeded()
        }
        .onChange(of: startTime) { _ in
            syncFromBindingsIfNeeded()
        }
        .onChange(of: duration) { _ in
            syncFromBindingsIfNeeded()
        }
    }

    @ViewBuilder
    private func timeInput(title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.headline)

                Text("*")
                    .foregroundColor(.red)
            }

            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onChange(of: text.wrappedValue) { _ in
                    updateDerivedDuration()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func syncFromBindingsIfNeeded() {
        guard startTime != lastSyncedStartTime || duration != lastSyncedDuration else { return }

        lastSyncedStartTime = startTime
        lastSyncedDuration = duration

        if startText != startTime {
            startText = startTime
        }

        if let endTime = FastCutTimecodeSupport.derivedEndTime(
            normalizedStartTime: startTime,
            durationText: duration
        ) {
            if endText != endTime {
                endText = endTime
            }
        } else if duration.isEmpty, !endText.isEmpty {
            endText = ""
        }

        localError = nil
    }

    private func updateDerivedDuration() {
        switch FastCutTimecodeSupport.resolveRange(startInput: startText, endInput: endText) {
        case .success(let resolved):
            localError = nil
            applyBindings(
                startTime: resolved.normalizedStartTime,
                duration: resolved.durationText
            )

        case .failure(let error):
            localError = error.errorDescription

            let normalizedStart: String
            if let startSeconds = FastCutTimecodeSupport.parseUserTimecode(startText) {
                normalizedStart = FastCutTimecodeSupport.formatTimecode(startSeconds)
            } else {
                normalizedStart = ""
            }

            applyBindings(startTime: normalizedStart, duration: "")
        }
    }

    private func applyBindings(startTime: String, duration: String) {
        lastSyncedStartTime = startTime
        lastSyncedDuration = duration

        if self.startTime != startTime {
            self.startTime = startTime
        }

        if self.duration != duration {
            self.duration = duration
        }
    }
}

// MARK: - Fast Cut Timecode Support

enum FastCutTimecodeSupport {
    struct ResolvedRange: Equatable {
        let normalizedStartTime: String
        let normalizedEndTime: String
        let durationText: String
    }

    enum RangeError: LocalizedError, Equatable {
        case missingStart
        case invalidStart
        case missingEnd
        case invalidEnd
        case endBeforeStart

        var errorDescription: String? {
            switch self {
            case .missingStart:
                return "请输入开始时间"
            case .invalidStart:
                return "开始时间格式无效"
            case .missingEnd:
                return "请输入结束时间"
            case .invalidEnd:
                return "结束时间格式无效"
            case .endBeforeStart:
                return "结束时间必须晚于开始时间"
            }
        }
    }

    static func resolveRange(startInput: String, endInput: String) -> Result<ResolvedRange, RangeError> {
        let trimmedStart = startInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStart.isEmpty else {
            return .failure(.missingStart)
        }

        guard let startSeconds = parseUserTimecode(trimmedStart) else {
            return .failure(.invalidStart)
        }

        let trimmedEnd = endInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEnd.isEmpty else {
            return .failure(.missingEnd)
        }

        guard let endSeconds = parseUserTimecode(trimmedEnd) else {
            return .failure(.invalidEnd)
        }

        guard endSeconds > startSeconds else {
            return .failure(.endBeforeStart)
        }

        return .success(
            ResolvedRange(
                normalizedStartTime: formatTimecode(startSeconds),
                normalizedEndTime: formatTimecode(endSeconds),
                durationText: formatDurationSeconds(endSeconds - startSeconds)
            )
        )
    }

    static func derivedEndTime(normalizedStartTime: String, durationText: String) -> String? {
        guard let startSeconds = parseUserTimecode(normalizedStartTime),
              let durationSeconds = Double(durationText),
              durationSeconds > 0 else {
            return nil
        }

        return formatTimecode(startSeconds + durationSeconds)
    }

    static func parseUserTimecode(_ rawValue: String) -> TimeInterval? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let shortcutSeconds = parseMinuteSecondShortcut(trimmed) {
            return shortcutSeconds
        }

        if trimmed.contains(":") {
            return parseColonSeparatedTimecode(trimmed)
        }

        guard let seconds = Double(trimmed), seconds >= 0 else {
            return nil
        }

        return seconds
    }

    static func formatTimecode(_ seconds: TimeInterval) -> String {
        let clampedSeconds = max(0, seconds)
        let roundedMilliseconds = Int((clampedSeconds * 1000).rounded())
        let totalSeconds = roundedMilliseconds / 1000
        let milliseconds = roundedMilliseconds % 1000

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let wholeSeconds = totalSeconds % 60

        if milliseconds == 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, wholeSeconds)
        }

        return String(
            format: "%02d:%02d:%02d.%03d",
            hours,
            minutes,
            wholeSeconds,
            milliseconds
        )
    }

    static func formatDurationSeconds(_ seconds: TimeInterval) -> String {
        let roundedMilliseconds = (seconds * 1000).rounded() / 1000
        let integralPart = roundedMilliseconds.rounded(.towardZero)

        if abs(roundedMilliseconds - integralPart) < 0.0005 {
            return String(Int(integralPart))
        }

        var text = String(format: "%.3f", roundedMilliseconds)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }

    private static func parseMinuteSecondShortcut(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 2,
              parts[1].count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else {
            return nil
        }

        return (minutes * 60) + seconds
    }

    private static func parseColonSeparatedTimecode(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }

        if parts.count == 2 {
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]),
                  minutes >= 0,
                  seconds >= 0 else {
                return nil
            }
            return (minutes * 60) + seconds
        }

        guard let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]),
              hours >= 0,
              minutes >= 0,
              seconds >= 0 else {
            return nil
        }

        return (hours * 3600) + (minutes * 60) + seconds
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
        Task { @MainActor in
            let initialDirectory = resolvedInitialDirectoryURL()
            let selectedURL: URL?

            if isOutput {
                selectedURL = await FilePicker.saveFile(
                    defaultName: resolvedSuggestedFileName(),
                    types: fileTypes,
                    initialDirectory: initialDirectory,
                    prompt: "选择输出文件"
                )
            } else {
                selectedURL = await FilePicker.selectFile(
                    types: fileTypes,
                    initialDirectory: initialDirectory,
                    prompt: "选择文件"
                )
            }

            if let selectedURL {
                value = selectedURL.path
            }
        }
    }

    private func resolvedInitialDirectoryURL() -> URL? {
        let normalizedValue = (value as NSString)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedValue.isEmpty {
            return URL(fileURLWithPath: normalizedValue).deletingLastPathComponent()
        }

        let recentDirectory = isOutput
            ? UserSettings.shared.lastOutputDirectory
            : UserSettings.shared.lastInputDirectory
        let normalizedDirectory = (recentDirectory as NSString)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedDirectory.isEmpty else { return nil }
        return URL(fileURLWithPath: normalizedDirectory)
    }

    private func resolvedSuggestedFileName() -> String {
        let normalizedValue = (value as NSString)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else { return "" }
        return URL(fileURLWithPath: normalizedValue).lastPathComponent
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
    var optionLabels: [String]? = nil

    var body: some View {
        Picker("", selection: $value) {
            if !options.contains(value) {
                Text("请选择...").tag("")
            }
            ForEach(options, id: \.self) { option in
                Text(displayLabel(for: option)).tag(option)
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

    private func displayLabel(for option: String) -> String {
        guard let labels = optionLabels,
              labels.count == options.count,
              let index = options.firstIndex(of: option)
        else {
            return option
        }
        return labels[index]
    }
}

// MARK: - Import

import UniformTypeIdentifiers

// MARK: - Preview

private struct ParameterFormView_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        ScrollView {
            ParameterFormView()
                .environmentObject(TemplateDetailViewModel(template: .example))
                .padding()
        }
        .frame(width: 400, height: 600)
    }
}
