//
//  EmptyStateView.swift
//  FFmpegRunner
//
//  空状态占位视图
//

import SwiftUI

/// 空状态视图（支持自定义图标、标题、副标题）
struct EmptyStateView: View {

    var icon: String = "film.stack"
    var title: String = "选择一个模板开始"
    var subtitle: String = "从左侧列表选择一个 FFmpeg 命令模板"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text(title)
                .font(.title2)
                .foregroundColor(.secondary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
