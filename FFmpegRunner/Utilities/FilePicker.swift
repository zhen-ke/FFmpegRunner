//
//  FilePicker.swift
//  FFmpegRunner
//
//  文件选择器工具
//

import SwiftUI
import UniformTypeIdentifiers

/// 文件选择器包装
struct FilePicker {

    /// 选择文件
    static func selectFile(
        types: [String]? = nil,
        completion: @escaping (URL?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if let types = types, !types.isEmpty {
            panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        }

        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    /// 选择多个文件
    static func selectFiles(
        types: [String]? = nil,
        completion: @escaping ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if let types = types, !types.isEmpty {
            panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        }

        panel.begin { response in
            completion(response == .OK ? panel.urls : [])
        }
    }

    /// 选择目录
    static func selectDirectory(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    /// 保存文件
    static func saveFile(
        defaultName: String = "",
        types: [String]? = nil,
        completion: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName

        if let types = types, !types.isEmpty {
            panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        }

        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}

// MARK: - SwiftUI 修饰符

struct FilePickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let types: [String]?
    let onSelect: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { newValue in
                if newValue {
                    FilePicker.selectFile(types: types) { url in
                        isPresented = false
                        if let url = url {
                            onSelect(url)
                        }
                    }
                }
            }
    }
}

extension View {
    /// 添加文件选择器
    func filePicker(
        isPresented: Binding<Bool>,
        types: [String]? = nil,
        onSelect: @escaping (URL) -> Void
    ) -> some View {
        modifier(FilePickerModifier(
            isPresented: isPresented,
            types: types,
            onSelect: onSelect
        ))
    }
}
