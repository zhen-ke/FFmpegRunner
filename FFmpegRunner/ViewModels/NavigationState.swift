//
//  NavigationState.swift
//  FFmpegRunner
//
//  统一管理侧边栏可见性，避免直接调用 AppKit toggleSidebar
//

import SwiftUI

@MainActor
final class NavigationState: ObservableObject {

    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    private var lastVisibleState: NavigationSplitViewVisibility = .all

    var isSidebarVisible: Bool {
        columnVisibility != .detailOnly
    }

    func toggleSidebar() {
        switch columnVisibility {
        case .detailOnly:
            columnVisibility = lastVisibleState
        case .all, .automatic, .doubleColumn:
            lastVisibleState = columnVisibility
            columnVisibility = .detailOnly
        default:
            columnVisibility = .all
        }
    }
}
