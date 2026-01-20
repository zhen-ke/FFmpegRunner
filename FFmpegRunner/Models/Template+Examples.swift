//
//  Template+Examples.swift
//  FFmpegRunner
//
//  模板示例 - 用于预览和测试
//

import Foundation

// MARK: - 示例模板

extension Template {
    /// 用于预览和测试的示例模板
    static let example = Template(
        id: "compress_video",
        name: "视频压缩",
        description: "使用 H.264 编码压缩视频文件，可调节质量和速度",
        commandTemplate: "ffmpeg -i {{input}} -c:v libx264 -crf {{crf}} -preset {{preset}} -c:a aac -b:a {{audioBitrate}} {{output}}",
        parameters: [
            TemplateParameter(
                key: "input",
                label: "输入文件",
                type: .file,
                defaultValue: "",
                placeholder: "选择视频文件",
                isRequired: true,
                constraints: TemplateParameter.Constraints(
                    fileTypes: ["mp4", "mov", "avi", "mkv"]
                ),
                role: .positional
            ),
            TemplateParameter(
                key: "crf",
                label: "质量 (CRF)",
                type: .number,
                defaultValue: "23",
                placeholder: "0-51, 越小质量越高",
                isRequired: true,
                constraints: TemplateParameter.Constraints(min: 0, max: 51),
                role: .flagValue
            ),
            TemplateParameter(
                key: "preset",
                label: "编码速度",
                type: .select,
                defaultValue: "medium",
                placeholder: nil,
                isRequired: true,
                constraints: TemplateParameter.Constraints(
                    options: ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"]
                ),
                role: .flagValue
            ),
            TemplateParameter(
                key: "audioBitrate",
                label: "音频码率",
                type: .string,
                defaultValue: "128k",
                placeholder: "例如: 128k, 192k, 256k",
                isRequired: true,
                constraints: nil,
                role: .flagValue
            ),
            TemplateParameter(
                key: "output",
                label: "输出文件",
                type: .file,
                defaultValue: "",
                placeholder: "选择保存位置",
                isRequired: true,
                constraints: TemplateParameter.Constraints(
                    fileTypes: ["mp4"],
                    isOutputFile: true
                ),
                role: .positional
            )
        ],
        category: "视频处理",
        icon: "video.fill"
    )
}
