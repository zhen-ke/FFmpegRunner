# FFmpegRunner

一个基于 Swift + SwiftUI 开发的 macOS 原生 FFmpeg GUI。它用 JSON 模板描述参数和界面，把常见的 FFmpeg 工作流变成可视化表单，同时保留“自定义命令”模式，兼顾日常使用和高级场景。

## 界面预览

| 自定义命令 | 主工作区 |
| :---: | :---: |
| ![Main UI](https://cdn.statically.io/gh/zhen-ke/img@main/202603/IMG_2026-04-01-19-22-30-1.webp) | ![Settings UI](https://cdn.statically.io/gh/zhen-ke/img@main/202603/IMG_2026-04-01-19-22-07-1.webp) |

## 核心功能

- 模板驱动：用 JSON 定义命令模板、参数类型、默认值和条件显示规则，不需要写 Swift 代码就能扩展常用流程。
- 原生动态表单：根据模板自动生成文件选择、文本输入、数字输入、布尔开关、下拉选择等控件。
- 即时命令预览：修改任意参数后，命令预览会立即更新，方便确认最终会执行什么。
- 安全执行：底层使用参数数组直接调用 `Process`，避免传统字符串拼接带来的注入和转义问题。
- 自定义命令模式：可以直接输入完整的 `ffmpeg` 或 `ffprobe` 命令，适合临时任务和高级调试。
- 最近使用恢复：可从最近使用列表快速回填参数，也可以把最近一次成功执行保存成模板。
- 模板管理：支持导入、导出、复制、重命名、删除用户模板。
- 顺序队列：可将多个任务加入队列，按顺序逐个执行，并支持中途停止。
- 日志与历史：支持实时日志、自动保存执行日志、查看历史日志文件。
- 执行保护：支持首次执行提醒、输出覆盖确认、超时保护和完成通知。

## FFmpeg 来源

FFmpegRunner 支持三种可执行文件来源：

1. 内置二进制：把 `ffmpeg` / `ffprobe` 放进应用资源中，适合开箱即用分发。
2. 系统环境：自动探测系统中的 FFmpeg，例如通过 Homebrew 安装的版本。
3. 自定义路径：在设置页手动指定任意 `ffmpeg` / `ffprobe` 可执行文件。

## 项目结构

```text
FFmpegRunner/
├── App/                    # 应用入口与全局环境
├── Application/            # 执行编排与命令规划
├── Models/                 # 模板、执行计划、进度等核心模型
├── Services/               # 模板仓库、FFmpeg 服务、历史与日志
├── ViewModels/             # 界面状态与交互逻辑
├── Views/                  # SwiftUI 视图
├── Resources/              # 内置模板与可选二进制资源
└── Utilities/              # 设置、日志、文件工具等
```

## 模板系统

### 内置模板和用户模板

- 内置模板位于 `FFmpegRunner/Resources/Templates/`，适合开发时随项目一起维护。
- 用户模板默认保存在 `~/Library/Application Support/FFmpegRunner/Templates/`。
- 在应用内可以直接导入、导出、复制、重命名和删除用户模板，不一定需要手动改文件。

### 最小可用模板示例

下面是一份和当前项目格式一致的模板示例：

```json
{
  "id": "compress_video",
  "name": "视频压缩 (H.264)",
  "description": "使用 H.264 编码压缩视频",
  "category": "视频处理",
  "icon": "video.fill",
  "commandTemplate": "ffmpeg -i {{input}} -c:v libx264 -crf {{crf}} -preset {{preset}} -y {{output}}",
  "parameters": [
    {
      "key": "input",
      "label": "输入文件",
      "type": "file",
      "defaultValue": "",
      "placeholder": "选择视频文件",
      "isRequired": true
    },
    {
      "key": "crf",
      "label": "质量 (CRF)",
      "type": "number",
      "defaultValue": "23",
      "isRequired": true,
      "constraints": {
        "min": 0,
        "max": 51
      }
    },
    {
      "key": "preset",
      "label": "编码速度",
      "type": "select",
      "defaultValue": "medium",
      "isRequired": true,
      "constraints": {
        "options": ["ultrafast", "veryfast", "medium", "slow", "veryslow"]
      }
    },
    {
      "key": "output",
      "label": "输出文件",
      "type": "file",
      "defaultValue": "",
      "placeholder": "选择保存位置",
      "isRequired": true,
      "constraints": {
        "fileTypes": ["mp4"],
        "isOutputFile": true
      }
    }
  ]
}
```

### 当前支持的参数类型

- `string`
- `number`
- `boolean`
- `file`
- `select`

### 模板能力补充

- 支持 `defaultValue`、`placeholder`、`isRequired`
- 支持 `constraints`，例如 `min`、`max`、`fileTypes`、`options`
- 支持 `optionLabels` 自定义下拉显示文案
- 支持 `uiHint.visibleWhen` 做条件显示
- 支持 `role: "raw"` 和 `escapeStrategy: "raw"` 处理原始参数片段

## 构建与运行

### 系统要求

- macOS 13.0 及以上
- Xcode 15.0 及以上

### 本地运行

1. 克隆仓库

```bash
git clone <repository-url>
cd FFmpegRunner
```

2. 可选：准备内置 `ffmpeg` / `ffprobe`

如果你希望应用在没有系统 FFmpeg 的机器上也能直接运行，可以下载静态编译版本，并把 `ffmpeg` / `ffprobe` 放入 Xcode 工程的 `Resources/` 中。

3. 打开工程

```bash
open FFmpegRunner.xcodeproj
```

4. 在 Xcode 中选择 `My Mac`

5. 按 `⌘R` 运行

## 常用使用方式

### 使用内置模板

1. 选择左侧模板
2. 填写输入文件、输出文件和参数
3. 查看命令预览
4. 点击执行，或先加入队列再统一执行

### 使用自定义命令

1. 选择“自定义命令”
2. 直接输入完整 `ffmpeg` / `ffprobe` 命令
3. 执行后，如需复用，可保存为模板

### 管理模板

- 导入外部 JSON 模板
- 导出当前模板
- 复制模板后再修改
- 重命名用户模板
- 删除用户模板

## 测试

项目当前包含命令解析、模板加载、模板管理、最近使用恢复、执行控制、队列等关键路径测试。

在 Xcode 中可使用 `⌘U` 运行测试，也可以在命令行运行：

```bash
xcodebuild test \
  -project FFmpegRunner.xcodeproj \
  -scheme FFmpegRunner \
  -destination 'platform=macOS'
```

## 许可证

本项目基于 [MIT License](LICENSE) 开源。欢迎提交 Issue、PR 或 Fork 继续扩展。
