//
//  DragDropHandler.swift
//  FFmpegRunner
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - DragDropHandler

struct DragDropHandler {

    /// 从单个 provider 提取文件 URL
    /// 使用 AsyncThrowingStream 降级策略：先尝试 fileURL，失败则降级到 loadObject
    static func extractFileURL(from provider: NSItemProvider) async -> URL? {
        // 优先尝试 fileURL 类型（更精确）
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadFileURL(from: provider) {
                return url
            }
        }
        // 降级：直接加载 URL 对象
        return await loadURLObject(from: provider)
    }

    /// 并发提取多个文件 URL，保持原始顺序
    static func extractFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    let url = await extractFileURL(from: provider)
                    return (index, url)
                }
            }

            // 收集并按原始顺序排列
            var results = [(Int, URL)]()
            results.reserveCapacity(providers.count)

            for await (index, url) in group {
                if let url {
                    results.append((index, url))
                }
            }

            return results
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    /// 检查文件扩展名是否在允许列表中（nil 表示接受所有类型）
    static func matchesFileTypes(_ url: URL, types: [String]?) -> Bool {
        guard let types, !types.isEmpty else { return true }
        return types.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Private Helpers

private extension DragDropHandler {

    static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                continuation.resume(returning: url)
            }
        }
    }

    static func loadURLObject(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: URL.self) { object, _ in
                continuation.resume(returning: object)
            }
        }
    }
}

// MARK: - FileDropModifier

struct FileDropModifier: ViewModifier {
    let types: [String]?
    let isTargeted: Binding<Bool>?
    let onDrop: (URL) -> Void

    @State private var localTargeted = false

    func body(content: Content) -> some View {
        let targeted = isTargeted ?? $localTargeted

        content.onDrop(of: [.fileURL], isTargeted: targeted) { providers in
            Task {
                guard let url = await DragDropHandler.extractFileURL(from: providers.first ?? NSItemProvider()),
                      DragDropHandler.matchesFileTypes(url, types: types)
                else { return }

                await MainActor.run { onDrop(url) }
            }
            return true
        }
    }
}

// MARK: - View Extension

extension View {
    func onFileDrop(
        types: [String]? = nil,
        isTargeted: Binding<Bool>? = nil,
        action: @escaping (URL) -> Void
    ) -> some View {
        modifier(FileDropModifier(types: types, isTargeted: isTargeted, onDrop: action))
    }
}

// MARK: - DropZoneView

struct DropZoneView<Content: View>: View {
    let types: [String]?
    let onDrop: (URL) -> Void
    @ViewBuilder let content: () -> Content

    @State private var isTargeted = false

    var body: some View {
        content()
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isTargeted ? Color.accentColor : .clear,
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
            }
            .background(isTargeted ? Color.accentColor.opacity(0.1) : .clear)
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
            .onFileDrop(types: types, isTargeted: $isTargeted, action: onDrop)
    }
}
