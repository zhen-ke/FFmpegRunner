//
//  FilePicker.swift
//  FFmpegRunner
//
//  文件选择器工具
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - FilePicker

struct FilePicker {

    // MARK: Public API

    @MainActor
    static func selectFile(
        types: [String]? = nil,
        initialDirectory: URL? = nil,
        prompt: String? = nil
    ) async -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        configure(panel, types: types, initialDirectory: initialDirectory, prompt: prompt)
        return await panel.beginAsync() == .OK ? panel.url : nil
    }

    @MainActor
    static func selectFiles(
        types: [String]? = nil,
        initialDirectory: URL? = nil,
        prompt: String? = nil
    ) async -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        configure(panel, types: types, initialDirectory: initialDirectory, prompt: prompt)
        return await panel.beginAsync() == .OK ? panel.urls : []
    }

    @MainActor
    static func selectDirectory(
        initialDirectory: URL? = nil,
        prompt: String? = "选择目录"
    ) async -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        configure(panel, initialDirectory: initialDirectory, prompt: prompt)
        return await panel.beginAsync() == .OK ? panel.url : nil
    }

    @MainActor
    static func saveFile(
        defaultName: String = "",
        types: [String]? = nil,
        initialDirectory: URL? = nil,
        prompt: String? = nil
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        configure(panel, types: types, initialDirectory: initialDirectory, prompt: prompt)
        return await panel.beginAsync() == .OK ? panel.url : nil
    }

    // MARK: Private

    private static func configure(
        _ panel: NSSavePanel,
        types: [String]? = nil,
        initialDirectory: URL? = nil,
        prompt: String? = nil
    ) {
        panel.allowedContentTypes = utTypes(from: types)
        panel.directoryURL = initialDirectory?.standardizedFileURL
        panel.prompt = prompt
        panel.canCreateDirectories = !(panel is NSOpenPanel)
    }

    private static func utTypes(from extensions: [String]?) -> [UTType] {
        guard let extensions, !extensions.isEmpty else { return [] }
        return extensions.compactMap { UTType(filenameExtension: $0) }
    }
}

// MARK: - NSSavePanel async extension

private extension NSSavePanel {
    func beginAsync() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            begin { continuation.resume(returning: $0) }
        }
    }
}

// MARK: - FilePickerModifier

struct FilePickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let types: [String]?
    let onSelect: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { newValue in   // 兼容 macOS 13
                guard newValue else { return }
                Task { @MainActor in
                    defer { isPresented = false }
                    if let url = await FilePicker.selectFile(types: types) {
                        onSelect(url)
                    }
                }
            }
    }
}

extension View {
    func filePicker(
        isPresented: Binding<Bool>,
        types: [String]? = nil,
        onSelect: @escaping (URL) -> Void
    ) -> some View {
        modifier(FilePickerModifier(isPresented: isPresented, types: types, onSelect: onSelect))
    }
}
