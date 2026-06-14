//
//  FileListOrdering.swift
//  FFmpegRunner
//
//  多文件参数的顺序规则
//

import Foundation

enum FileListOrdering {
    static func naturalAscending(_ urls: [URL]) -> [URL] {
        urls.sorted { lhs, rhs in
            let nameComparison = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    static func appendingUniqueNaturalAscending(existing: [URL], incoming: [URL]) -> [URL] {
        var result = existing
        var existingPaths = Set(existing.map(\.path))

        for url in incoming where existingPaths.insert(url.path).inserted {
            result.append(url)
        }

        return naturalAscending(result)
    }
}
