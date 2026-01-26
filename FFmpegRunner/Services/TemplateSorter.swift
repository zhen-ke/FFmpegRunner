//
//  TemplateSorter.swift
//  FFmpegRunner
//
//  纯函数排序器，职责分离
//

import Foundation

/// 模板排序器
enum TemplateSorter {

    /// 对模板进行标准排序
    /// - RawCommand 始终在第一位
    /// - 按分类排序
    /// - 同分类按名称排序
    ///
    /// - Parameter templates: 模板集合
    /// - Returns: 排序后的模板数组
    static func sort<C: Collection>(_ templates: C) -> [Template] where C.Element == Template {
        Array(templates).sorted { t1, t2 in
            // RawCommand 始终在第一位
            if t1.id == Template.rawCommandId { return true }
            if t2.id == Template.rawCommandId { return false }

            // 按分类排序
            let cat1 = t1.category ?? "其他"
            let cat2 = t2.category ?? "其他"
            if cat1 != cat2 { return cat1 < cat2 }

            // 同分类按名称排序
            return t1.name < t2.name
        }
    }

    /// 按分类分组
    /// - Parameter templates: 模板数组
    /// - Returns: 分类 -> 模板数组的字典
    static func groupByCategory(_ templates: [Template]) -> [String: [Template]] {
        Dictionary(grouping: templates) { $0.category ?? "其他" }
    }
}
