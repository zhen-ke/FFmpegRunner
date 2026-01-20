# FFmpegRunner 命令解析管道测试文档 (Level 1-3)

本文档定义了 FFmpegRunner 的工业级分层测试模型，用于确保命令解析管道（特别是 `CommandRenderer.splitCommand`）的稳定性与安全性。

## 一、 测试模型概述

测试分为三个层级，重点验证参数等价性与执行安全性。

| 层级 | 测试目标 | 核心关注点 |
| :--- | :--- | :--- |
| **Level 0** | FFmpeg 自身支持 | FFmpeg 功能验证（不在本项目测试范围） |
| **Level 1** | 参数管道等价性 | 确保分词后的 `[String]` 数组与原始 CLI 意图完全一致 |
| **Level 2** | 高风险 CLI 处理 | 验证 Pipe (IO)、特殊源 (lavfi/rtmp) 等复杂语法的透传 |
| **Level 3** | 无效命令安全拒绝 | 验证空输入、脚本注入尝试及非 ffmpeg 命令的拦截 |

---

## 二、 代表性测试用例

这些用例覆盖了 FFmpeg 使用中最容易出问题的边界情况。

### A. 基础 Sanity (100% 通过)
*   `ffmpeg -version`
*   `ffmpeg -hide_banner -loglevel error -i input.mp4 output.mp4`
    *   **验证点**：参数顺序、标准 IO 识别、Token 完整。

### B. 顺序敏感参数
*   `ffmpeg -ss 10 -i input.mp4 -t 5 out.mp4` (快速 Seek)
*   `ffmpeg -i input.mp4 -ss 10 -t 5 out.mp4` (精确 Seek)
    *   **验证点**：系统必须原样透传，严禁“智能调整”参数顺序，因为两者行为完全不同。

### C. 复杂 Filtergraph (硬仗)
*   `ffmpeg -i input.mp4 -vf "scale=1280:-2,drawtext=text='Hello World':x=10:y=10" -pix_fmt yuv420p out.mp4`
    *   **验证点**：引号、冒号、逗号、等号必须保持 intact（原封不动）。

### D. 多输入 / 多输出
*   `ffmpeg -i video.mp4 -i audio.wav -c:v copy -c:a aac out.mp4`
    *   **验证点**：多 `-i` 标志识别、Stream Mapping 隐式规则透传。

### E. Pipe / 特殊 IO
*   `ffmpeg -i pipe:0 -f mp4 pipe:1`
    *   **验证点**：在 GUI 中允许因环境限制失败，但绝不能卡死或无限等待（由 `-nostdin` 保证）。

---

## 三、 验证计划

### 1. 自动化测试 (CI/CD)
使用 `xcodebuild` 运行单元测试：
```bash
xcodebuild test \
  -project FFmpegRunner.xcodeproj \
  -scheme FFmpegRunner \
  -destination 'platform=macOS' \
  -only-testing:FFmpegRunnerTests
```

### 2. 手动验证
*   **Xcode 快捷键**：使用 `⌘+U` 运行所有测试。
*   **GUI 验证**：在 App 中粘贴复杂 Filter 命令，观察生成的预览 `Arguments` 数组是否匹配预期。

---

## 四、 架构一致性保障

FFmpegRunner 具备高兼容性的天然优势：
1.  **非 Shell 执行**：采用 `Process(arguments: [String])`，不依赖 bash/zsh 转义规则，不受 `shell quoting` 干扰。
2.  **Arguments-First**：渲染器优先生成参数数组用于执行，UI 渲染仅供展示。
3.  **Token 级验证**：`CommandValidator` 基于分词后的首个 Token 识别可执行文件，天然免疫分号、管道符等注入攻击。

## 五、 风险点监控

唯一的“兼容性黑洞”在于 `CommandRenderer.splitCommand(command)`。
*   **策略**：所有回归测试必须围绕 `splitCommand` -> `arguments` 的等价性进行。
*   **原则**：如果 `splitCommand` 无法 100% 确定意图，应优先报错而非错误猜测。
