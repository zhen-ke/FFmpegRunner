//
//  CommandPreviewView.swift
//  FFmpegRunner
//
//  命令预览视图 - 专业化版本
//

import SwiftUI

/// 命令预览视图
struct CommandPreviewView: View {

    // MARK: - Environment

    @EnvironmentObject var viewModel: CommandPreviewViewModel

    // MARK: - State

    @State private var showCopied = false

    // MARK: - Configuration

    // 终端风格配色
    private let terminalBackground = Color(red: 40/255, green: 44/255, blue: 52/255) // One Dark 背景色
    private let terminalBorder = Color(white: 0.2)
    private let headerBackground = Color(NSColor.controlBackgroundColor)

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                // 标题
                Text("命令预览")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .tracking(1)

                // 字符数 Badge
                CharacterCountBadge(count: viewModel.commandLength)

                Spacer()

                // Status Indicator
                StatusBadge(isComplete: viewModel.isComplete)

                // Display Mode Button (AUTO/WRAP/SINGLE)
                DisplayModeButton(mode: viewModel.displayMode) {
                    viewModel.toggleDisplayMode()
                }

                // Copy Button
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

            // Code Area
            ScrollView(viewModel.shouldWrap ? .vertical : [.horizontal, .vertical]) {
                Text(viewModel.highlightedCommand())
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(terminalBackground)

            // Footer (Warnings)
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
    }

    // MARK: - Actions

    private func copyCommand() {
        viewModel.copyToClipboard()
        withAnimation {
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

/// 字符数显示 Badge
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
                .foregroundColor(isLong ? .orange : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(isLong ? Color.orange.opacity(0.1) : Color(NSColor.controlColor).opacity(0.3))
                )
        }
    }
}

struct StatusBadge: View {
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isComplete ? Color.green : Color.orange)
                .frame(width: 6, height: 6)

            Text(isComplete ? "就绪" : "未完成")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isComplete ? .green : .orange)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(isComplete ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        )
        .overlay(
            Capsule()
                .strokeBorder(isComplete ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), lineWidth: 1)
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

struct CopyButton: View {
    let isCopied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
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
                .fill(Color(NSColor.controlColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
}

struct MissingParametersView: View {
    let placeholders: [String]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.system(size: 12))

            Text("缺少参数：\(placeholders.joined(separator: "、"))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.yellow)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.1))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.yellow.opacity(0.2)),
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
