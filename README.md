# FFmpegRunner

一个基于 Swift + SwiftUI 开发的 macOS 原生模板驱动型 FFmpeg GUI 应用程序。通过声明式的 JSON 模板，将晦涩复杂的 FFmpeg 命令行参数转化为直观、现代的用户界面，让视频处理和自定义脚本转码变得前所未有的连贯与简单。

## 📸 界面预览

| 自定义命令 | 主工作区 |
| :---: | :---: |
| ![Main UI](https://cdn.statically.io/gh/zhen-ke/img@main/202603/IMG_2026-04-01-19-22-30-1.webp) | ![Settings UI](https://cdn.statically.io/gh/zhen-ke/img@main/202603/IMG_2026-04-01-19-22-07-1.webp) |

## ✨ 核心特性

- 🎯 **模板驱动 (Template-Driven)**
  通过修改 JSON 配置文件即可定义命令逻辑与交互界面，真正意义上的零代码扩展能力。灵活支持复杂的参数联动、动态显隐和特定参数默认值配置。

- 🎨 **原生动态 UI (SwiftUI)**
  充分利用 SwiftUI 深度构建。无需手动编写视图，系统可根据模板内的控件类型（输入输出目录、文件选择器、布尔拨动开关、数字步进器、选择列表等）动态映射、自适应渲染出符合 macOS HIG 规范的原生交互表单。

- 🛡️ **安全至上的执行架构 (Arguments-First)**
  重构了传统的 shell 命令运行方式，摒弃高风险的字符串拼接手段。底层采取“参数数组” (`[String]`) 直接对接 `Process`，彻底杜绝命令注入漏洞以及由空格、特殊转义字符引发的执行崩溃。

- 👀 **即时参数与命令预览**
  拥有超强反馈：调节任何一个参数改变，下方的“命令预览区”都会即时变动，以开发者所见即所得的形式呈现最终交至核心 `ffmpeg` 程序的真实调用链路。

- 📊 **智能日志与进阶调优**
  - **进度节流 (Coalescing Progress Layer)**：智能合并高频流式的 FFmpeg 帧步输出，保护 UI 线程免受性能损耗乃至卡顿，兼顾极客信息流与丝滑体验。
  - **持久化记录 (Log Persistence)**：可开启历史回放视角，自执行任务自动分片并转存历史执行日志，助力开发复盘。

- ⚙️ **无缝工具链集成 (Smart Toolchain)**
  支持热切换的 3 层优先级 FFmpeg 二进制路径解析策略：
  1. 📦 **内置优先**：支持打包静态库至 `Resources` 达成“开箱即用”极客级免环境分发（免配置）。
  2. 🌐 **系统环境探测**：自动嗅探系统中通过 Homebrew (`brew install ffmpeg`) 安装的路径。
  3. 🛠️ **自选外挂 (Custom Injection)**：满足最严苛的场景验证要求，可随意在设置面板挂载任意位置的单一 `ffmpeg`/`ffprobe` 可执行文件。

- 🔒 **全天候任务沙盒与保护**
  - 触发执行前支持安全二次确认弹窗、覆写警告保护。
  - **防死锁/僵尸任务防线**：引入全局执行超时防护 (`Timeout Prevention Engine`)。
  - 原生系统级集成通知：在后台挂机转码完成后，下发轻量级 macOS 发送横幅提醒。

---

## 🏗️ 系统架构解析

项目严格采用 **MVVM** 设计模式并隔离 **Application Service (服务层)**，从文件 I/O 到数据结构再到视觉状态进行三段式剥离。

```text
FFmpegRunner/
├── App/                    # WindowGroup 及全局 Application Delegate 挂载
├── Application/            # 核心控制中枢 (CommandPlanner, ExecutionController)
├── Models/                 # 核心数据流模版 (Template, ExecutionPlan, FFmpegProgress)
├── Services/               # 基础单例支撑系统 (工具链解析 FFmpegService, 日志系统)
├── ViewModels/             # 发布订阅中继、双向数据流转视图模型状态
├── Views/                  # 可复用的纯展示 SwiftUI 分支结构树
├── Resources/              # JSON 预设数据池以及可选的二进制核心环境区
└── Utilities/              # 功能性沙箱（Sandbox）及工具类扩展层
```

---

## 🛠️ 三分钟添加您的专属套件

本项目的高阶玩法即：您可以根据不同的生产任务流，随时捏合自己的执行参数集。只需在 `Resources/Templates/` 目录下添加或修改 JSON 数据模版。

### 📄 标准 JSON 示范结构：
```json
{
  "id": "video_watermark_compress",
  "name": "极速压缩预设",
  "commandTemplate": "ffmpeg -i {{input_file}} {{video_codec}} -crf 23 {{output_path}}",
  "parameters": [
    {
      "key": "input_file",
      "label": "源视步文件",
      "type": "file",
      "isRequired": true
    },
    {
      "key": "video_codec",
      "label": "选择视步编码方案",
      "type": "choice",
      "options": [
        { "label": "无损转录 (Copy)", "value": "-c:v copy" },
        { "label": "H.264 基准", "value": "-c:v libx264" },
        { "label": "高效 HEVC", "value": "-c:v libx265" }
      ],
      "defaultValue": "-c:v libx264"
    },
    {
      "key": "output_path",
      "label": "转储目标",
      "type": "output",
      "isRequired": true
    }
  ]
}
```

---

## 🚀 起跑线 (构建与部署)

### 系统支持底座
- **OS**: macOS 13.0 (Ventura) 及以上版本
- **IDE**: Xcode 15.0 及以上版本
- （纯正的 Swift 独立仓库，暂未搭载第三方重依赖架构，轻量敏捷）

### 手动引导运行指南
1. **拉取资产**：
   ```bash
   git clone <你的开源仓库地址或目录>
   cd FFmpegRunner
   ```
2. **构建本地全封闭核心支持（选做强推）**：
   欲获得完全与您的 macOS 系统解耦的环境执行，请至 [evermeet.cx](https://evermeet.cx/ffmpeg/) 等权威源下载静态编译版本，解压提取其内核 `ffmpeg`/`ffprobe`。将其文件向 Xcode 工程结构的 `Resources/` 目录中拖拽（勾选 “*Copy items if needed*” 和 target：*FFmpegRunner* 绑定）。
3. 主入口双击唤起 `FFmpegRunner.xcodeproj`。
4. 在 Xcode 的物理模拟靶向栏中选取 **"My Mac"**。
5. 按下光速启动组合键 `⌘ + R` 或按下 Run 三角箭标点燃主程序引擎。

---

## 🧪 质检保证 (Testing Suite)

我们不希望看到转义异常和组件链路的断裂，内建针对核心引擎的基础 Sandbox Unit Test：
1. `CommandRenderer` 转义逻辑的完备查杀。
2. Context 挂载预期性以及底层 `ExecutionPlan` 回填覆盖测试。

（利用 Xcode 唤起 `⌘ + U` 或开启专门的 Test Navigator 无感运行）

---

## 📄 开源许可证

本项目遵从 [MIT License](LICENSE) 允许在保留声明的情况下进行二次散播及私人定制。欢迎提交 Issues、Fork 和 PR 共建！
