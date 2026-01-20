# FFmpegRunner

一个基于 Swift + SwiftUI 开发的模板驱动型 FFmpeg GUI 应用程序。旨在通过声明式 JSON 模板，将复杂的 FFmpeg 命令行操作转化为直观的图形界面。

## ✨ 核心特性

- 🎯 **模板驱动** - 通过 JSON 配置文件定义命令逻辑，无需编写代码即可扩展功能。
- 🎨 **动态渲染 UI** - 根据模板定义的参数（文件、开关、滑块、下拉框）自动生成交互表单。
- ⚡ **参数即时预览** - 编辑参数时实时生成并显示最终的 FFmpeg 命令。
- 🛡️ **参数校验系统** - 内置对输入参数的合法性校验，降低执行错误率。
- 📝 **流式日志输出** - 实时捕捉并美化显示 FFmpeg 的标准输出与错误信息。
- 📦 **零依赖分发** - 支持内置静态 FFmpeg 二进制文件，确保在未安装 FFmpeg 的环境下也能正常运行。

## 🏗️ 系统架构

本项目采用 **MVVM + Application Layer** 架构，确保业务逻辑与界面显示深度解耦。

### 核心设计理念：Arguments-First
为了避免 Shell 转义导致的潜在错误，应用内部采用“参数优先”的渲染路径：
1. **Model**: 参数值（`TemplateValue`）被解析为内部状态。
2. **Application**: `CommandPlanner` 将内部状态转换为语义化的 `ExecutionPlan`。
3. **Service**: `CommandRenderer` 生成原始参数数组（`[String]`），直接传递给 `Process` 执行，彻底告别不稳定的字符串拼接。

### 项目结构

```
FFmpegRunner/
├── App/                    # 应用入口与全局环境配置
├── Application/            # 应用层：业务流程整合（ExecutionController, CommandPlanner）
├── Models/                 # 领域模型：模板定义、执行计划、绑定关系
├── Services/               # 服务层：FFmpeg 执行、路径解析、命令渲染、日志处理
├── ViewModels/             # 界面模型：状态维护与 UI 逻辑响应
├── Views/                  # 视图层：SwiftUI 界面组件
├── Resources/              # 资源文件：内置命令模板、FFmpeg 二进制（可选）
└── Utilities/              # 工具类：文件选择、性能优化工具
```

## 🧪 质量保障 (Testing)

项目包含完整的测试套件，确保核心逻辑的稳定性：

- **单元测试**: 覆盖 `CommandRenderer`（转义与分割逻辑）及 `CommandValidator`。
- **验证机制**: 支持对“渲染结果”与“预期 CLI 输出”进行等效性验证。

运行测试：在 Xcode 中通过 `⌘U` 运行 `FFmpegRunnerTests`。

## 🚀 快速开始

### 系统要求
- macOS 13.0 (Ventura) +
- Xcode 15.0 +

### 配置 FFmpeg
应用支持三种 FFmpeg 优先级来源：
1. **内置**: 将 `ffmpeg` 放入项目的 `Resources` 目录并勾选 Target Membership。
2. **系统**: 通过 `brew install ffmpeg` 安装。
3. **自定义**: 在应用设置中手动指定路径。

### 开发运行
1. 克隆仓库。
2. 双击 `FFmpegRunner.xcodeproj`。
3. 选择 "My Mac" 并按 `⌘R` 运行。

## 🛠️ 扩展与自定义

只需在 `Resources/Templates/` 下添加新的 JSON 文件即可添加新功能。

**示例模板结构：**
```json
{
  "id": "video_convert",
  "name": "格式转换",
  "commandTemplate": "ffmpeg -i {{input}} {{output}}",
  "parameters": [
    {
      "key": "input",
      "label": "选择视屏",
      "type": "file",
      "isRequired": true
    }
  ]
}
```

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。
