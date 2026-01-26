//
//  CommandPreviewView.swift
//  FFmpegRunner
//
//  命令预览视图 - 专业化版本 v2
//  优化：Header 精简、命令呼吸感、渐变遮罩、状态语义化、复制波纹
//

import SwiftUI

/// 命令预览视图
struct CommandPreviewView: View {

    // MARK: - Environment

    @EnvironmentObject var viewModel: CommandPreviewViewModel

    // MARK: - State

    @State private var showCopied = false
    @State private var isHovering = false

    // MARK: - Configuration

    // 终端风格配色
    private let terminalBackground = Color(red: 40/255, green: 44/255, blue: 52/255) // One Dark 背景色
    private let terminalBorder = Color(white: 0.2)
    private let headerBackground = Color(NSColor.controlBackgroundColor)

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header - 优化1：左轻右重
            headerView

            // Code Area - 带浮层状态和渐变遮罩
            codeAreaView

            // Footer (Warnings) - 优化4：语义降级
            if !viewModel.missingPlaceholders.isEmpty {
                MissingParametersView(placeholders: viewModel.missingPlaceholders)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(terminalBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - Header View (优化1：左轻右重)

    private var headerView: some View {
        HStack(spacing: 10) {
            // 左侧：仅标题（轻量）
            Text("命令预览")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            // 右侧：操作按钮
            DisplayModeButton(mode: viewModel.displayMode) {
                viewModel.toggleDisplayMode()
            }

            CopyButton(isCopied: showCopied) {
                copyCommand()
            }
            .disabled(viewModel.renderedCommand.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(headerBackground)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(NSColor.separatorColor)),
            alignment: .bottom
        )
    }

    // MARK: - Code Area View (优化2+3：呼吸感 + 渐变遮罩)

    private var codeAreaView: some View {
        ZStack {
            // 主内容
            ScrollView(viewModel.shouldWrap ? .vertical : [.horizontal, .vertical]) {
                Text(viewModel.highlightedCommand())
                    // 优化2：呼吸感
                    .lineSpacing(3)
                    .tracking(0.2)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(terminalBackground)

            // 优化3：长命令渐变遮罩（非换行模式时显示）
            if !viewModel.shouldWrap {
                HStack {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, terminalBackground],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 24)
                }
                .allowsHitTesting(false)
            }

            // 优化1：状态浮层（右上角）
            VStack(alignment: .trailing, spacing: 6) {
                StatusBadge(isComplete: viewModel.isComplete)
                CharacterCountBadge(count: viewModel.commandLength)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Actions

    private func copyCommand() {
        viewModel.copyToClipboard()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            showCopied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCopied = false
            }
        }
    }
}

// MARK: - Helper Views

/// 字符数显示 Badge（优化后：更轻量的浮层样式）
struct CharacterCountBadge: View {
    let count: Int

    /// 超过此阈值显示警告色
    private let warningThreshold = 80

    private var isLong: Bool {
        count > warningThreshold
    }

    var body: some View {
        if count > 0 {
            Text("\(count) 字符")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(isLong ? .orange : Color.white.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.4))
                )
        }
    }
}

/// 状态 Badge（优化后：浮层样式，更语义化）
struct StatusBadge: View {
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isComplete ? Color.green : Color.orange)
                .frame(width: 6, height: 6)

            Text(isComplete ? "就绪" : "待填写")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isComplete ? .green : .orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.5))
        )
        .overlay(
            Capsule()
                .strokeBorder(isComplete ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

/// 显示模式切换按钮 (AUTO/WRAP/SINGLE)
struct DisplayModeButton: View {
    let mode: DisplayMode
    let action: () -> Void

    private var isActive: Bool {
        mode != .auto
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: mode.icon)
                    .font(.system(size: 11))
                Text(mode.label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(modeColor)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(modeBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(modeBorderColor, lineWidth: 1)
        )
        .help(modeTooltip)
    }

    private var modeColor: Color {
        switch mode {
        case .auto: return .secondary
        case .wrap: return .accentColor
        case .single: return .accentColor
        }
    }

    private var modeBackgroundColor: Color {
        switch mode {
        case .auto: return Color(NSColor.controlColor).opacity(0.5)
        case .wrap: return Color.accentColor.opacity(0.1)
        case .single: return Color.accentColor.opacity(0.1)
        }
    }

    private var modeBorderColor: Color {
        switch mode {
        case .auto: return Color(NSColor.separatorColor)
        case .wrap: return Color.accentColor.opacity(0.5)
        case .single: return Color.accentColor.opacity(0.5)
        }
    }

    private var modeTooltip: String {
        switch mode {
        case .auto: return "自动：根据命令长度智能换行"
        case .wrap: return "换行：强制多行显示"
        case .single: return "单行：强制单行显示"
        }
    }
}

// 保留旧的 FormatButton 以兼容（如果其他地方使用）
struct FormatButton: View {
    @Binding var isMultiline: Bool

    var body: some View {
        Button(action: {
            withAnimation {
                isMultiline.toggle()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: isMultiline ? "arrow.right.to.line" : "text.alignleft")
                    .font(.system(size: 11))
                Text(isMultiline ? "单行" : "换行")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isMultiline ? .accentColor : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isMultiline ? Color.accentColor.opacity(0.1) : Color(NSColor.controlColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isMultiline ? Color.accentColor.opacity(0.5) : Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
}

/// 复制按钮（优化5：支持 symbolEffect 波纹反馈）
struct CopyButton: View {
    let isCopied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                // 优化5：macOS 14+ 弹跳效果
                if #available(macOS 14.0, *) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .symbolEffect(.bounce, value: isCopied)
                } else {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                Text(isCopied ? "已复制" : "复制")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isCopied ? .green : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isCopied ? Color.green.opacity(0.1) : Color(NSColor.controlColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isCopied ? Color.green.opacity(0.5) : Color(NSColor.separatorColor), lineWidth: 1)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isCopied)
    }
}

/// 缺失参数提示（优化4：语义降级为"提示"而非"警告"）
struct MissingParametersView: View {
    let placeholders: [String]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 12))

            Text("仍需填写：\(placeholders.joined(separator: "、"))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.orange)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.orange.opacity(0.15)),
            alignment: .top
        )
    }
}

// MARK: - Preview

#Preview {
    CommandPreviewView()
        .environmentObject({
            let vm = CommandPreviewViewModel()
            vm.update(
                template: .example,
                values: TemplateValue.from(template: .example)
            )
            return vm
        }())
        .frame(width: 600, height: 200)
}
