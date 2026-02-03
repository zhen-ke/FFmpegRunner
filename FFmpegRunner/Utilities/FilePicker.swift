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

// MARK: - Command Path Detector

enum CommandPathDetector {

    /// 从参数数组中检测输出文件路径
    static func detectOutputPath(from arguments: [String]) -> String? {
        let validArgs = arguments.filter { !$0.isEmpty }
        guard !validArgs.isEmpty else { return nil }

        // 获取最后一个非选项参数作为输出路径
        guard let lastArg = validArgs.last, !lastArg.hasPrefix("-") else { return nil }

        // 跳过特殊输出（如 pipe:, null 等）
        if lastArg.contains(":") && !lastArg.contains("/") {
            return nil
        }

        return lastArg
    }

    /// 从参数数组中检测输出目录（仅绝对路径或 ~）
    static func detectOutputDirectory(from arguments: [String]) -> URL? {
        guard let outputPath = detectOutputPath(from: arguments) else { return nil }
        guard outputPath.hasPrefix("/") || outputPath.hasPrefix("~") else { return nil }

        let expanded = (outputPath as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expanded)
        return fileURL.deletingLastPathComponent()
    }

    /// 从参数数组中检测输出文件名（仅用于显示）
    static func detectOutputFileName(from arguments: [String]) -> String? {
        guard let outputPath = detectOutputPath(from: arguments) else { return nil }
        let expanded = (outputPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).lastPathComponent
    }
}
