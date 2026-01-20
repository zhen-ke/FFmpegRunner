//
//  DragDropHandler.swift
//  FFmpegRunner
//
//  拖放处理工具
//

import SwiftUI
import UniformTypeIdentifiers

/// 拖放处理器
struct DragDropHandler {

    /// 从拖放项中提取文件 URL
    @MainActor
    static func extractFileURL(from providers: [NSItemProvider]) async -> URL? {
        guard let provider = providers.first else { return nil }

        // 在主线程上同步获取 provider 信息
        let typeIdentifier = UTType.fileURL.identifier

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                DispatchQueue.main.async {
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                    } else if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    /// 从拖放项中提取多个文件 URL
    @MainActor
    static func extractFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []

        for provider in providers {
            if let url = await extractFileURL(from: [provider]) {
                urls.append(url)
            }
        }

        return urls
    }

    /// 检查文件类型是否匹配
    static func matchesFileTypes(_ url: URL, types: [String]?) -> Bool {
        guard let types = types, !types.isEmpty else { return true }
        return types.contains(url.pathExtension.lowercased())
    }
}

// MARK: - 拖放视图修饰符

struct FileDropModifier: ViewModifier {
    let types: [String]?
    let isTargeted: Binding<Bool>?
    let onDrop: (URL) -> Void

    @State private var localTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: isTargeted ?? $localTargeted) { providers in
                Task {
                    if let url = await DragDropHandler.extractFileURL(from: providers) {
                        if DragDropHandler.matchesFileTypes(url, types: types) {
                            await MainActor.run {
                                onDrop(url)
                            }
                        }
                    }
                }
                return true
            }
    }
}

extension View {
    /// 添加文件拖放支持
    func onFileDrop(
        types: [String]? = nil,
        isTargeted: Binding<Bool>? = nil,
        action: @escaping (URL) -> Void
    ) -> some View {
        modifier(FileDropModifier(
            types: types,
            isTargeted: isTargeted,
            onDrop: action
        ))
    }
}

// MARK: - 拖放区域视图

struct DropZoneView<Content: View>: View {
    let types: [String]?
    let onDrop: (URL) -> Void
    @ViewBuilder let content: () -> Content

    @State private var isTargeted = false

    var body: some View {
        content()
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isTargeted ? Color.accentColor : Color.clear,
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
            )
            .background(
                isTargeted ? Color.accentColor.opacity(0.1) : Color.clear
            )
            .onFileDrop(types: types, isTargeted: $isTargeted, action: onDrop)
    }
}
