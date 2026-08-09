# ScriptWidget 🎨

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/ScriptWidget?style=flat-square&color=4ECDC4)](https://github.com/everettjf/ScriptWidget/stargazers)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Release Readiness](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml/badge.svg)](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml)

**使用 JavaScript、JSX 和 AI，为 iPhone、iPad 与 Mac 创建原生 Widget**

[English](README.md) | [中文](README_CN.md)

</div>

![ScriptWidget 模板画廊](Resource/WidgetDemoScreenshots/_contact-sheet-1.jpg)

ScriptWidget 是一个 MIT 开源的 Widget 创作平台。你不需要学习 Swift：在 Mac Studio、iPhone 或 iPad 上编辑 `main.jsx`，运行时会把声明式 JSX 映射为原生 SwiftUI/WidgetKit 界面。

## 为什么选择 ScriptWidget

- 一份脚本适配 iOS、iPadOS 与 macOS，多尺寸布局可通过 `$getenv("widget-size")` 调整。
- 支持交互式 Widget、App Intents、Live Activity、灵动岛与 Control Widget。
- Mac Studio 内置 CodeMirror 编辑器、补全、诊断、Console 和多尺寸预览。
- 可用 OpenAI 兼容模型生成、运行、诊断并迭代 Widget；API Key 保存在 Keychain。
- Widget & Skills Gallery 支持经过索引、大小、路径与 SHA-256 验证的一键安装和离线缓存。
- 70 个内置模板、版本化 Runtime API、Package 2.0 与 Skills 1.0 均有自动测试和发布门禁。

## 五分钟开始

```bash
git clone https://github.com/everettjf/ScriptWidget.git
cd ScriptWidget
open macOS/ScriptWidgetMac.xcodeproj
# 或：open iOS/ScriptWidget.xcodeproj
```

在 Xcode 中选择 `ScriptWidgetMac` 或 `ScriptWidget` scheme，配置 `iCloud.ScriptWidget` container 与 `group.everettjf.scriptwidget` App Group，然后运行。也可以直接按照[五分钟教程](docs/five-minute-tutorial.md)创建第一个 Widget。

最小脚本：

```jsx
$render(
  <vstack frame="max" background="#0f172a">
    <text font="title3" color="#f8fafc">Hello, ScriptWidget!</text>
  </vstack>
);
```

## 文档

- [文档中心](docs/README.md)
- [从零创建第一个 Widget](docs/getting-started.md)
- [ScriptWidget Studio](docs/studio.md)
- [Runtime API](docs/runtime-api.md)
- [AI 生成](docs/ai-generate.md)
- [Widget & Skills Gallery](docs/gallery.md)
- [Package 2.0](docs/package-format.md) 与 [Skills 1.0](docs/skills.md)
- [公开路线图](ROADMAP.md)

## 参与贡献

欢迎提交 Runtime、Mac/iOS 体验、模板、Gallery Widget、AI Skill、测试与文档。请先阅读[贡献指南](CONTRIBUTING.md)、[治理规则](GOVERNANCE.md)和[行为准则](CODE_OF_CONDUCT.md)，并在提交前运行：

```bash
./Scripts/release-readiness.sh
```

安全问题请按照[安全政策](SECURITY.md)私下报告，不要在公开 Issue 中披露利用细节或个人数据。

ScriptWidget 使用 [MIT License](LICENSE) 发布。
