//
//  TemplateDetailViewModel.swift
//  FFmpegRunner
//
//  模板详情 ViewModel
//

import Foundation
import Combine

/// 模板详情 ViewModel
@MainActor
class TemplateDetailViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 当前模板
    @Published var template: Template? {
        didSet {
            if let template = template {
                initializeValues(for: template)
            }
        }
    }

    /// 参数值列表
    @Published var values: [TemplateValue] = []

    /// 验证状态
    @Published private(set) var validationErrors: [String: String] = [:]

    // MARK: - Computed Properties

    /// 参数值字典
    var valuesDictionary: TemplateValueDict {
        values.asDictionary
    }

    /// 是否所有参数都有效
    var isValid: Bool {
        validationErrors.isEmpty && values.allValid
    }

    /// 是否可以执行
    var canExecute: Bool {
        isValid && template != nil
    }

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(template: Template? = nil) {
        self.template = template
        if let template = template {
            initializeValues(for: template)
        }
    }

    // MARK: - Public Methods

    /// 初始化参数值
    func initializeValues(for template: Template) {
        values = TemplateValue.from(template: template)
        validationErrors = [:]
        validateAll()
    }

    /// 更新参数值
    func updateValue(key: String, value: String) {
        guard let index = values.firstIndex(where: { $0.key == key }) else { return }

        values[index].rawValue = value
        validate(key: key)
    }

    /// 获取参数值
    func getValue(for key: String) -> String {
        values.first { $0.key == key }?.rawValue ?? ""
    }

    /// 获取参数定义
    func getParameter(for key: String) -> TemplateParameter? {
        template?.parameters.first { $0.key == key }
    }

    /// 验证单个参数
    func validate(key: String) {
        guard let parameter = getParameter(for: key),
              let index = values.firstIndex(where: { $0.key == key }) else { return }

        let result = parameter.validate(values[index].rawValue)
        values[index].validationResult = result

        if let error = result.errorMessage {
            validationErrors[key] = error
        } else {
            validationErrors.removeValue(forKey: key)
        }
    }

    /// 验证所有参数
    func validateAll() {
        guard let template = template else { return }

        validationErrors = [:]

        for (index, parameter) in template.parameters.enumerated() {
            guard index < values.count else { continue }

            let result = parameter.validate(values[index].rawValue)
            values[index].validationResult = result

            if let error = result.errorMessage {
                validationErrors[parameter.key] = error
            }
        }
    }

    /// 重置为默认值
    func resetToDefaults() {
        guard let template = template else { return }
        initializeValues(for: template)
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

import SwiftUI

extension TemplateDetailViewModel {
    /// 创建带验证的 Binding
    func validatedBinding(for key: String) -> Binding<String> {
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
