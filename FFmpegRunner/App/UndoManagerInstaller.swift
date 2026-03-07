//
//  UndoManagerInstaller.swift
//  FFmpegRunner
//
//  将自定义 UndoManager 安装到 NSWindow，使 ⌘Z / ⇧⌘Z 生效
//

import SwiftUI
import AppKit

/// 将自定义 UndoManager 安装到宿主 NSWindow
///
/// SwiftUI 的 `\.undoManager` 是只读的，无法通过 `.environment()` 注入。
/// 此 NSViewRepresentable 通过访问 NSWindow 来安装自定义 UndoManager。
struct UndoManagerInstaller: NSViewRepresentable {
    let undoManager: UndoManager

    func makeNSView(context: Context) -> NSView {
        let view = UndoManagerInstallerView(undoManager: undoManager)
        view.frame = .zero
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 内部 NSView，通过覆盖 undoManager 属性，将自定义 UndoManager 注入到响应链中
private final class UndoManagerInstallerView: NSView {
    private let customUndoManager: UndoManager

    init(undoManager: UndoManager) {
        self.customUndoManager = undoManager
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var undoManager: UndoManager? {
        customUndoManager
    }
}
