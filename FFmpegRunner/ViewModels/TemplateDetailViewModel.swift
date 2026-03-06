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

    static let empty = TemplateDetailState(template: nil, values: [], templateBinding: nil)

    var validationErrors: [String: String] {
        Dictionary(
            uniqueKeysWithValues: values.compactMap { value in
                guard let message = value.errorMessage else { return nil }
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

    // MARK: - Private Properties

    private var cache = TemplateDetailCache()
    private let outputPathEngine = OutputPathAutoFillEngine()

    // MARK: - Initialization

    init(template: Template? = nil) {
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
        state = buildState(template: template, values: initialValues)
    }

    /// 更新参数值
    func updateValue(key: String, value: String) {
        guard let template = state.template,
              let index = cache.index(for: key),
              index < state.values.count else { return }

        var nextValues = state.values
        if nextValues[index].rawValue == value { return }

        nextValues[index].rawValue = value

        outputPathEngine.trackManualOutputEditIfNeeded(
            changedKey: key,
            newValue: value,
            cache: cache
        )

        let autoUpdatedKeys = outputPathEngine.applyAutoFillIfNeeded(
            changedKey: key,
            values: &nextValues,
            cache: cache
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
        let binding = TemplateBinding.bind(template: template, values: values)
        let validatedValues = binding.bindings.map(\.value)
        return TemplateDetailState(
            template: template,
            values: validatedValues,
            templateBinding: binding
        )
    }

    func clearState() {
        state = .empty
        cache = TemplateDetailCache()
        outputPathEngine.reset()
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
}

// MARK: - Detail Cache

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
           configuredParameter.type == .file,
           !isOutputParameter(configuredParameter) {
            return configuredSourceKey
        }

        let fileInputKeys = template.parameters
            .filter { $0.type == .file && !isOutputParameter($0) }
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

        let path = Self.normalizedPath(values[sourceIndex].rawValue)
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
        let sourceExtension = sourceURL.pathExtension.lowercased()
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
}
