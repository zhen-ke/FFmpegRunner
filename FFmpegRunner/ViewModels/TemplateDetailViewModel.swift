//
//  TemplateDetailViewModel.swift
//  FFmpegRunner
//
//  模板详情 ViewModel
//

import Foundation
import SwiftUI

struct TemplateDetailState {
    let template: Template?
    let values: [TemplateValue]
    let templateBinding: TemplateBinding?

    /// 被条件规则隐藏的参数 key 集合
    let conditionallyHiddenKeys: Set<String>

    static let empty = TemplateDetailState(
        template: nil, values: [], templateBinding: nil, conditionallyHiddenKeys: []
    )

    var validationErrors: [String: String] {
        Dictionary(
            uniqueKeysWithValues: values.compactMap { value in
                // 被条件隐藏的参数不显示验证错误
                guard !conditionallyHiddenKeys.contains(value.key),
                      let message = value.errorMessage else { return nil }
                return (value.key, message)
            }
        )
    }

    var isValid: Bool {
        templateBinding?.isValid ?? false
    }

    var canExecute: Bool {
        template != nil && isValid
    }

    /// 判断参数是否因条件规则被隐藏
    func isConditionallyHidden(_ key: String) -> Bool {
        conditionallyHiddenKeys.contains(key)
    }
}

/// 模板详情 ViewModel
@MainActor
final class TemplateDetailViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 当前详情页状态
    @Published private(set) var state: TemplateDetailState = .empty

    // MARK: - Computed Properties

    /// 当前模板
    var template: Template? {
        state.template
    }

    /// 参数值列表
    var values: [TemplateValue] {
        state.values
    }

    /// 当前模板绑定快照
    var templateBinding: TemplateBinding? {
        state.templateBinding
    }

    /// 验证状态
    var validationErrors: [String: String] {
        state.validationErrors
    }

    /// 参数值字典
    var valuesDictionary: TemplateValueDict {
        values.asDictionary
    }

    /// 是否所有参数都有效
    var isValid: Bool {
        state.isValid
    }

    /// 是否可以执行
    var canExecute: Bool {
        state.canExecute
    }

    /// 被条件规则隐藏的参数 key 集合
    var conditionallyHiddenKeys: Set<String> {
        state.conditionallyHiddenKeys
    }

    /// 判断参数是否因条件规则被隐藏
    func isConditionallyHidden(_ key: String) -> Bool {
        state.isConditionallyHidden(key)
    }

    // MARK: - Private Properties

    private var cache = TemplateDetailCache()
    private let outputPathEngine = OutputPathAutoFillEngine()
    private let mediaDurationResolver: MediaDurationResolving
    private let mediaDurationAutoFillEngine = MediaDurationAutoFillEngine()
    private var mediaDurationAutoFillTask: Task<Void, Never>?

    /// macOS 系统 Undo 管理器，支持 ⌘Z / ⇧⌘Z
    let undoManager = UndoManager()

    // MARK: - Initialization

    init(
        template: Template? = nil,
        mediaDurationResolver: @escaping @Sendable MediaDurationResolving = MediaDurationResolver.resolveDuration(for:)
    ) {
        self.mediaDurationResolver = mediaDurationResolver
        selectTemplate(template)
    }

    // MARK: - Public Methods

    /// 选择模板并初始化详情状态
    func selectTemplate(_ template: Template?) {
        guard let template else {
            clearState()
            return
        }

        let initialValues = TemplateValue.from(template: template)
        cache.rebuild(template: template, values: initialValues)
        outputPathEngine.reset()
        mediaDurationAutoFillEngine.reset()
        mediaDurationAutoFillTask?.cancel()
        mediaDurationAutoFillTask = nil
        undoManager.removeAllActions()
        state = buildState(template: template, values: initialValues)
    }

    /// 更新参数值
    func updateValue(key: String, value: String) {
        guard let template = state.template,
              let index = cache.index(for: key),
              index < state.values.count else { return }

        var nextValues = state.values
        let oldValue = nextValues[index].rawValue
        if oldValue == value { return }

        // 注册 Undo
        undoManager.registerUndo(withTarget: self) { vm in
            vm.updateValue(key: key, value: oldValue)
        }
        undoManager.setActionName("修改 \(cache.parameter(for: key)?.label ?? key)")

        nextValues[index].rawValue = value

        outputPathEngine.trackManualOutputEditIfNeeded(
            changedKey: key,
            newValue: value,
            cache: cache
        )
        mediaDurationAutoFillEngine.trackManualTimeRangeEditIfNeeded(
            changedKey: key,
            newValue: value,
            cache: cache
        )

        let autoUpdatedKeys = outputPathEngine.applyAutoFillIfNeeded(
            changedKey: key,
            values: &nextValues,
            cache: cache
        )
        scheduleMediaDurationAutoFillIfNeeded(
            changedKey: key,
            values: nextValues,
            template: template
        )

        state = buildState(template: template, values: nextValues)
        persistRecentDirectoryIfNeeded(for: key, values: nextValues)
        for autoUpdatedKey in autoUpdatedKeys {
            persistRecentDirectoryIfNeeded(for: autoUpdatedKey, values: nextValues)
        }
    }

    /// 获取参数值
    func getValue(for key: String) -> String {
        guard let index = cache.index(for: key), index < state.values.count else { return "" }
        return state.values[index].rawValue
    }

    /// 获取参数定义
    func getParameter(for key: String) -> TemplateParameter? {
        cache.parameter(for: key)
    }

    /// 重置为默认值
    func resetToDefaults() {
        undoManager.removeAllActions()
        selectTemplate(state.template)
    }

    /// 使用快照恢复当前模板值
    func applySnapshot(_ rawValuesByKey: [String: String]) {
        guard let template = state.template else { return }
        restore(template: template, rawValuesByKey: rawValuesByKey)
    }

    /// 使用指定模板和快照恢复详情状态
    func restore(template: Template, rawValuesByKey: [String: String]) {
        let restoredValues = template.parameters.map { parameter in
            TemplateValue(
                key: parameter.key,
                rawValue: rawValuesByKey[parameter.key] ?? parameter.defaultValue
            )
        }

        cache.rebuild(template: template, values: restoredValues)
        outputPathEngine.reset()
        mediaDurationAutoFillEngine.reset()
        mediaDurationAutoFillTask?.cancel()
        mediaDurationAutoFillTask = nil
        state = buildState(template: template, values: restoredValues)

        for parameter in template.parameters where parameter.type == .file {
            persistRecentDirectoryIfNeeded(for: parameter.key, values: state.values)
        }
    }

    /// 获取绑定
    func binding(for key: String) -> Binding<String> {
        Binding(
            get: { [weak self] in
                self?.getValue(for: key) ?? ""
            },
            set: { [weak self] newValue in
                self?.updateValue(key: key, value: newValue)
            }
        )
    }
}

// MARK: - Binding Support

extension TemplateDetailViewModel {
    /// 创建带验证的 Binding
    func validatedBinding(for key: String) -> Binding<String> {
        binding(for: key)
    }
}

// MARK: - Private Helpers

private extension TemplateDetailViewModel {
    func buildState(template: Template, values: [TemplateValue]) -> TemplateDetailState {
        // 1. 计算条件可见性
        let hiddenKeys = Self.computeConditionallyHiddenKeys(
            parameters: template.parameters,
            values: values
        )

        // 2. 绑定并验证（隐藏参数跳过验证，命令渲染时由 CommandRenderer 处理）
        let binding = TemplateBinding.bind(
            template: template,
            values: values,
            conditionallyHiddenKeys: hiddenKeys
        )
        let validatedValues = binding.bindings.map(\.value)

        return TemplateDetailState(
            template: template,
            values: validatedValues,
            templateBinding: binding,
            conditionallyHiddenKeys: hiddenKeys
        )
    }

    /// 根据当前参数值计算哪些参数被条件规则隐藏
    /// - 安全处理：引用不存在的 key 时视为条件不满足（隐藏）
    static func computeConditionallyHiddenKeys(
        parameters: [TemplateParameter],
        values: [TemplateValue]
    ) -> Set<String> {
        let valueByKey = Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.rawValue) })
        var hiddenKeys = Set<String>()

        for parameter in parameters {
            guard let condition = parameter.uiHint?.visibleWhen else { continue }

            // 获取被观察参数的当前值
            guard let observedValue = valueByKey[condition.key] else {
                // 引用的 key 不存在 → 条件无法满足 → 隐藏
                hiddenKeys.insert(parameter.key)
                continue
            }

            if !condition.evaluate(currentValue: observedValue) {
                hiddenKeys.insert(parameter.key)
            }
        }

        return hiddenKeys
    }

    func clearState() {
        state = .empty
        cache = TemplateDetailCache()
        outputPathEngine.reset()
        mediaDurationAutoFillEngine.reset()
        mediaDurationAutoFillTask?.cancel()
        mediaDurationAutoFillTask = nil
    }

    func persistRecentDirectoryIfNeeded(for key: String, values: [TemplateValue]) {
        guard let parameter = cache.parameter(for: key),
              parameter.type == .file,
              let index = cache.index(for: key),
              index < values.count else {
            return
        }

        let normalizedPath = (values[index].rawValue as NSString)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return }

        let directoryPath = URL(fileURLWithPath: normalizedPath)
            .deletingLastPathComponent()
            .path
        guard !directoryPath.isEmpty else { return }

        if parameter.constraints?.isOutputFile == true {
            UserSettings.shared.lastOutputDirectory = directoryPath
        } else {
            UserSettings.shared.lastInputDirectory = directoryPath
        }
    }

    func scheduleMediaDurationAutoFillIfNeeded(
        changedKey: String,
        values: [TemplateValue],
        template: Template
    ) {
        guard let request = cache.mediaDurationRequest(forChangedKey: changedKey, values: values) else {
            return
        }

        mediaDurationAutoFillTask?.cancel()
        let templateID = template.id
        mediaDurationAutoFillTask = Task.detached(priority: .utility) { [weak self, mediaDurationResolver, request, templateID] in
            let duration = await mediaDurationResolver(request.sourceURL)
            guard !Task.isCancelled, let duration, duration > 0 else { return }

            await MainActor.run {
                self?.applyMediaDurationAutoFill(
                    duration: duration,
                    request: request,
                    expectedTemplateID: templateID
                )
            }
        }
    }

    func applyMediaDurationAutoFill(
        duration: TimeInterval,
        request: MediaDurationAutoFillRequest,
        expectedTemplateID: String
    ) {
        guard let template = state.template,
              template.id == expectedTemplateID,
              getValue(for: request.sourceKey) == request.sourceURL.path else {
            return
        }

        var nextValues = state.values
        let updatedKeys = mediaDurationAutoFillEngine.applyAutoFillIfNeeded(
            duration: duration,
            request: request,
            values: &nextValues,
            cache: cache
        )

        guard !updatedKeys.isEmpty else { return }
        state = buildState(template: template, values: nextValues)
    }
}

// MARK: - Detail Cache

private struct MediaDurationAutoFillRequest: Equatable, Sendable {
    let sourceKey: String
    let sourceURL: URL
    let startKey: String
    let durationKey: String
}

/// 参数索引和输出依赖缓存，负责把模板定义转换成可快速查询的结构。
private struct TemplateDetailCache {
    private static let preferredSourceKeys = ["input", "video", "source", "src", "inputFile", "videoInput"]

    private(set) var valueIndexByKey: [String: Int] = [:]
    private(set) var parameterByKey: [String: TemplateParameter] = [:]
    private(set) var outputParameters: [TemplateParameter] = []
    private(set) var sourceKeyByOutputKey: [String: String] = [:]
    private(set) var outputRegenerationDependencies: [String: Set<String>] = [:]

    var hasParameters: Bool {
        !parameterByKey.isEmpty
    }

    mutating func rebuild(template: Template, values: [TemplateValue]) {
        valueIndexByKey = Self.buildValueIndex(values)
        parameterByKey = Self.buildParameterIndex(template.parameters)
        outputParameters = template.parameters.filter { isOutputParameter($0) }
        sourceKeyByOutputKey = [:]
        outputRegenerationDependencies = [:]

        for outputParameter in outputParameters {
            guard let sourceKey = sourceKey(for: outputParameter, template: template) else { continue }
            sourceKeyByOutputKey[outputParameter.key] = sourceKey
            outputRegenerationDependencies[sourceKey, default: []].insert(outputParameter.key)

            if let extensionSourceKey = outputParameter.constraints?.outputExtensionFromKey,
               !extensionSourceKey.isEmpty {
                outputRegenerationDependencies[extensionSourceKey, default: []].insert(outputParameter.key)
            }
        }
    }

    func index(for key: String) -> Int? {
        valueIndexByKey[key]
    }

    func parameter(for key: String) -> TemplateParameter? {
        parameterByKey[key]
    }

    func isOutputKey(_ key: String) -> Bool {
        guard let parameter = parameterByKey[key] else { return false }
        return isOutputParameter(parameter)
    }

    func isTimeRangeDurationKey(_ key: String) -> Bool {
        parameterByKey.values.contains { parameter in
            parameter.uiHint?.compositeType == "timeRange" &&
            parameter.uiHint?.compositeGroup == key
        }
    }

    func mediaDurationRequest(forChangedKey key: String, values: [TemplateValue]) -> MediaDurationAutoFillRequest? {
        guard let sourceParameter = parameterByKey[key],
              sourceParameter.type == .file,
              !isOutputParameter(sourceParameter),
              let sourceIndex = index(for: key),
              sourceIndex < values.count else {
            return nil
        }

        let sourcePath = values[sourceIndex].rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourcePath.isEmpty,
              FileManager.default.fileExists(atPath: sourcePath) else {
            return nil
        }

        guard let timeRangeParameter = parameterByKey.values.first(where: { $0.uiHint?.compositeType == "timeRange" }),
              let durationKey = timeRangeParameter.uiHint?.compositeGroup,
              index(for: durationKey) != nil else {
            return nil
        }

        return MediaDurationAutoFillRequest(
            sourceKey: key,
            sourceURL: URL(fileURLWithPath: sourcePath),
            startKey: timeRangeParameter.key,
            durationKey: durationKey
        )
    }

    private static func buildValueIndex(_ values: [TemplateValue]) -> [String: Int] {
        var index: [String: Int] = [:]
        for (offset, value) in values.enumerated() where index[value.key] == nil {
            index[value.key] = offset
        }
        return index
    }

    private static func buildParameterIndex(_ parameters: [TemplateParameter]) -> [String: TemplateParameter] {
        var index: [String: TemplateParameter] = [:]
        for parameter in parameters where index[parameter.key] == nil {
            index[parameter.key] = parameter
        }
        return index
    }

    private func sourceKey(for outputParameter: TemplateParameter, template: Template) -> String? {
        if let configuredSourceKey = outputParameter.constraints?.outputSourceKey,
           !configuredSourceKey.isEmpty,
           let configuredParameter = parameterByKey[configuredSourceKey],
           Self.isSourceParameter(configuredParameter),
           !isOutputParameter(configuredParameter) {
            return configuredSourceKey
        }

        let fileInputKeys = template.parameters
            .filter { Self.isSourceParameter($0) && !isOutputParameter($0) }
            .map(\.key)

        guard !fileInputKeys.isEmpty else { return nil }

        for candidate in relatedSourceCandidates(forOutputKey: outputParameter.key) where fileInputKeys.contains(candidate) {
            return candidate
        }

        for key in Self.preferredSourceKeys where fileInputKeys.contains(key) {
            return key
        }

        return fileInputKeys[0]
    }

    private func relatedSourceCandidates(forOutputKey outputKey: String) -> [String] {
        let lowercased = outputKey.lowercased()
        var candidates: [String] = []

        if lowercased.contains("output") {
            candidates.append((outputKey as NSString).replacingOccurrences(of: "output", with: "input"))
            candidates.append((outputKey as NSString).replacingOccurrences(of: "output", with: "source"))
        }
        if lowercased.contains("audio") {
            candidates.append("audio")
            candidates.append("inputAudio")
        }
        if lowercased.contains("video") {
            candidates.append("video")
            candidates.append("inputVideo")
        }

        candidates.append("input")
        candidates.append("video")
        return candidates.filter { !$0.isEmpty }
    }

    private func isOutputParameter(_ parameter: TemplateParameter) -> Bool {
        parameter.type == .file &&
        (parameter.constraints?.isOutputFile == true || parameter.key == "output")
    }

    private static func isSourceParameter(_ parameter: TemplateParameter) -> Bool {
        parameter.type == .file || parameter.type == .files
    }
}

// MARK: - Media Duration Auto-Fill Engine

/// 剪切模板的片尾自动填充规则，只覆盖空值或上次自动生成的值。
private final class MediaDurationAutoFillEngine {
    private var autoGeneratedDurations: [String: String] = [:]
    private var manuallyEditedDurationKeys: Set<String> = []

    func reset() {
        autoGeneratedDurations.removeAll()
        manuallyEditedDurationKeys.removeAll()
    }

    func trackManualTimeRangeEditIfNeeded(
        changedKey: String,
        newValue: String,
        cache: TemplateDetailCache
    ) {
        guard cache.isTimeRangeDurationKey(changedKey) else {
            return
        }

        if autoGeneratedDurations[changedKey] == newValue {
            return
        }

        autoGeneratedDurations.removeValue(forKey: changedKey)
        manuallyEditedDurationKeys.insert(changedKey)
    }

    func applyAutoFillIfNeeded(
        duration: TimeInterval,
        request: MediaDurationAutoFillRequest,
        values: inout [TemplateValue],
        cache: TemplateDetailCache
    ) -> [String] {
        guard let startIndex = cache.index(for: request.startKey),
              startIndex < values.count,
              let durationIndex = cache.index(for: request.durationKey),
              durationIndex < values.count else {
            return []
        }

        var updatedKeys: [String] = []

        let currentStart = values[startIndex].rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if currentStart.isEmpty {
            values[startIndex].rawValue = "00:00:00"
            updatedKeys.append(request.startKey)
        }

        let normalizedStart = values[startIndex].rawValue
        let startSeconds = FastCutTimecodeSupport.parseUserTimecode(normalizedStart) ?? 0
        let remainingDuration = max(duration - startSeconds, 0)
        guard remainingDuration > 0 else { return updatedKeys }

        let generatedDuration = FastCutTimecodeSupport.formatDurationSeconds(remainingDuration)
        let currentDuration = values[durationIndex].rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let durationDefaultValue = cache.parameter(for: request.durationKey)?.defaultValue
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shouldReplace = currentDuration.isEmpty ||
            currentDuration == autoGeneratedDurations[request.durationKey] ||
            (currentDuration == durationDefaultValue && !manuallyEditedDurationKeys.contains(request.durationKey))

        guard shouldReplace,
              values[durationIndex].rawValue != generatedDuration else {
            autoGeneratedDurations[request.durationKey] = generatedDuration
            return updatedKeys
        }

        values[durationIndex].rawValue = generatedDuration
        autoGeneratedDurations[request.durationKey] = generatedDuration
        updatedKeys.append(request.durationKey)

        return updatedKeys
    }
}

// MARK: - Output Auto-Fill Engine

/// 输出路径自动补全规则引擎，负责追踪自动生成值与覆盖策略。
private final class OutputPathAutoFillEngine {
    private static let outputTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter
    }()

    private var autoGeneratedOutputPaths: [String: String] = [:]

    func reset() {
        autoGeneratedOutputPaths.removeAll()
    }

    func trackManualOutputEditIfNeeded(
        changedKey: String,
        newValue: String,
        cache: TemplateDetailCache
    ) {
        guard cache.isOutputKey(changedKey) else { return }

        let normalized = Self.normalizedPath(newValue)
        if normalized.isEmpty {
            autoGeneratedOutputPaths.removeValue(forKey: changedKey)
            return
        }

        // 用户手动修改输出路径后，不再自动覆盖。
        if let autoGenerated = autoGeneratedOutputPaths[changedKey], normalized == autoGenerated {
            return
        }

        autoGeneratedOutputPaths.removeValue(forKey: changedKey)
    }

    func applyAutoFillIfNeeded(
        changedKey: String,
        values: inout [TemplateValue],
        cache: TemplateDetailCache
    ) -> [String] {
        guard let affectedOutputKeys = cache.outputRegenerationDependencies[changedKey],
              !affectedOutputKeys.isEmpty else { return [] }

        var autoUpdatedKeys: [String] = []

        for outputParameter in cache.outputParameters {
            guard affectedOutputKeys.contains(outputParameter.key) else { continue }
            guard changedKey != outputParameter.key else { continue }
            guard let outputIndex = cache.index(for: outputParameter.key), outputIndex < values.count else { continue }
            guard let sourcePath = sourceFilePath(for: outputParameter, values: values, cache: cache) else { continue }

            let currentOutput = Self.normalizedPath(values[outputIndex].rawValue)
            let shouldReplace = currentOutput.isEmpty || currentOutput == autoGeneratedOutputPaths[outputParameter.key]
            guard shouldReplace else { continue }

            let generatedOutput = buildOutputPath(
                fromSourcePath: sourcePath,
                outputParameter: outputParameter,
                values: values,
                cache: cache
            )

            guard values[outputIndex].rawValue != generatedOutput else { continue }
            values[outputIndex].rawValue = generatedOutput
            autoGeneratedOutputPaths[outputParameter.key] = generatedOutput
            autoUpdatedKeys.append(outputParameter.key)
        }

        return autoUpdatedKeys
    }

    private func sourceFilePath(
        for outputParameter: TemplateParameter,
        values: [TemplateValue],
        cache: TemplateDetailCache
    ) -> String? {
        guard let sourceKey = cache.sourceKeyByOutputKey[outputParameter.key],
              let sourceIndex = cache.index(for: sourceKey),
              sourceIndex < values.count else {
            return nil
        }

        let path = Self.firstExistingSourcePath(
            from: values[sourceIndex].rawValue,
            parameter: cache.parameter(for: sourceKey)
        )
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    private func buildOutputPath(
        fromSourcePath sourcePath: String,
        outputParameter: TemplateParameter,
        values: [TemplateValue],
        cache: TemplateDetailCache
    ) -> String {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let directoryURL = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let sourceExtension: String
        if let sourceKey = cache.sourceKeyByOutputKey[outputParameter.key],
           cache.parameter(for: sourceKey)?.type == .files {
            sourceExtension = ""
        } else {
            sourceExtension = sourceURL.pathExtension.lowercased()
        }
        let outputExtension = resolveOutputExtension(
            sourceExtension: sourceExtension,
            outputParameter: outputParameter,
            values: values,
            cache: cache
        )
        let timestamp = Self.outputTimestampFormatter.string(from: Date())

        let outputName: String
        if outputExtension.isEmpty {
            outputName = "\(baseName)_\(timestamp)"
        } else {
            outputName = "\(baseName)_\(timestamp).\(outputExtension)"
        }

        let rawPath = directoryURL.appendingPathComponent(outputName).path
        return makeUniquePathIfNeeded(rawPath, outputKey: outputParameter.key, values: values)
    }

    private func resolveOutputExtension(
        sourceExtension: String,
        outputParameter: TemplateParameter,
        values: [TemplateValue],
        cache: TemplateDetailCache
    ) -> String {
        let allowedExtensions = outputParameter.constraints?.fileTypes?.map { $0.lowercased() } ?? []

        if let derivedExtension = resolveDerivedOutputExtension(
            for: outputParameter,
            values: values,
            cache: cache
        ), allowedExtensions.isEmpty || allowedExtensions.contains(derivedExtension) {
            return derivedExtension
        }

        if !allowedExtensions.isEmpty {
            if !sourceExtension.isEmpty, allowedExtensions.contains(sourceExtension) {
                return sourceExtension
            }
            return allowedExtensions[0]
        }

        return sourceExtension
    }

    private func resolveDerivedOutputExtension(
        for outputParameter: TemplateParameter,
        values: [TemplateValue],
        cache: TemplateDetailCache
    ) -> String? {
        guard let sourceKey = outputParameter.constraints?.outputExtensionFromKey,
              !sourceKey.isEmpty,
              let rawMapping = outputParameter.constraints?.outputExtensionByValue,
              !rawMapping.isEmpty,
              let sourceIndex = cache.index(for: sourceKey),
              sourceIndex < values.count else {
            return nil
        }

        let mapping = Dictionary(uniqueKeysWithValues: rawMapping.map { ($0.key.lowercased(), $0.value.lowercased()) })
        let sourceValue = values[sourceIndex].rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !sourceValue.isEmpty else { return nil }
        return mapping[sourceValue]
    }

    private func makeUniquePathIfNeeded(
        _ path: String,
        outputKey: String,
        values: [TemplateValue]
    ) -> String {
        let reserved = Set(
            values
                .filter { $0.key != outputKey }
                .map { Self.normalizedPath($0.rawValue) }
                .filter { !$0.isEmpty }
        )

        let originalURL = URL(fileURLWithPath: path)
        let directoryURL = originalURL.deletingLastPathComponent()
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let fileExtension = originalURL.pathExtension

        var candidate = path
        var suffix = 1

        while FileManager.default.fileExists(atPath: candidate) || reserved.contains(candidate) {
            let numberedName: String
            if fileExtension.isEmpty {
                numberedName = "\(baseName)_\(suffix)"
            } else {
                numberedName = "\(baseName)_\(suffix).\(fileExtension)"
            }

            candidate = directoryURL.appendingPathComponent(numberedName).path
            suffix += 1
        }

        return candidate
    }

    private static func normalizedPath(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed as NSString).expandingTildeInPath
    }

    private static func firstExistingSourcePath(
        from rawValue: String,
        parameter: TemplateParameter?
    ) -> String {
        let rawPaths: [String]
        if parameter?.type == .files {
            rawPaths = rawValue.components(separatedBy: "\n")
        } else {
            rawPaths = [rawValue]
        }

        return rawPaths
            .map(normalizedPath)
            .first { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) } ?? ""
    }
}
