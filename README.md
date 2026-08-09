# ScriptWidget 🎨

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/ScriptWidget?style=flat-square&color=4ECDC4)](https://github.com/everettjf/ScriptWidget/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/everettjf/ScriptWidget?style=flat-square)](https://github.com/everettjf/ScriptWidget/network)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20macOS-lightgrey?style=flat-square&logo=apple)](https://developer.apple.com)
[![Version](https://img.shields.io/badge/Version-3.0-blue?style=flat-square)](https://github.com/everettjf/ScriptWidget/releases)
[![Release Readiness](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml/badge.svg)](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml)

**Create native widgets for iPhone, iPad, and Mac using JavaScript, JSX, and AI**

[English](README.md) | [中文](README_CN.md)

</div>

> ✨ *Build iPhone, iPad, and Mac widgets in ScriptWidget Studio—without writing Swift.*

---

## 🎯 What is ScriptWidget?

ScriptWidget is a powerful widget development platform that lets you create native iOS and macOS widgets using **JavaScript** and **JSX-like syntax**. No Swift required!

Think of it as "React Native for Widgets" - but simpler and more flexible.

![ScriptWidget template gallery](Resource/WidgetDemoScreenshots/_contact-sheet-1.jpg)

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🖥️ **Cross-Platform** | One codebase for iOS and macOS widgets |
| 🎨 **JSX Support** | Declarative UI with JavaScript XML syntax |
| ⚡ **Native Performance** | Compiled to native Swift/SwiftUI |
| 🔧 **Rich APIs** | Access device sensors, data sources, and more |
| 📱 **Interactive Widgets** | Tap, swipe, and interact with widgets |
| 🎨 **Custom Styling** | Full control over appearance |
| 📦 **Template Gallery** | Pre-built templates to get started |
| 🌐 **Community Gallery** | Verified, one-click Widget and AI Skill installs |
| 🧰 **ScriptWidget Studio** | Build on Mac with CodeMirror, diagnostics, console, and multi-size preview |
| ✨ **AI Generation** | Generate, run, diagnose, and refine widgets with an OpenAI-compatible model |

---

## 🚀 Quick Start

### 1. Download

```bash
# Clone the repository
git clone https://github.com/everettjf/ScriptWidget.git
cd ScriptWidget
```

### 2. Open in Xcode

```bash
# iOS app + widget + share extension
open iOS/ScriptWidget.xcodeproj

# macOS app + widget
open macOS/ScriptWidgetMac.xcodeproj
```

### 3. Run & Explore

1. Select a scheme (`ScriptWidget` / `ScriptWidgetWidget` for iOS, `ScriptWidgetMac` for macOS)
2. Enable the `iCloud.ScriptWidget` container and `group.everettjf.scriptwidget` app group so script storage works
3. Press `Cmd + R` to build and run
4. Browse the bundled example scripts under `Shared/ScriptWidgetRuntime/Resource/Script.bundle/` (`api/`, `component/`, `template/`)

---

## 📁 Project Structure

```
ScriptWidget/
├── Shared/
│   └── ScriptWidgetRuntime/   # Core runtime: JavaScriptCore host, JSX→SwiftUI
│       ├── Common/            # Script storage & package management
│       ├── Gallery/           # Verified GitHub catalog, cache & installer
│       ├── Widget/Runtime/    # JS engine setup, Babel transform, execution
│       ├── Widget/API/        # JS APIs ($device, $file, $storage, ...)
│       ├── Widget/Component/  # Element → SwiftUI view mapping
│       └── Resource/          # Babel bundle + bundled example scripts
├── iOS/
│   ├── ScriptWidget/          # iOS app (editor, settings)
│   ├── ScriptWidgetWidget/    # Widget, Live Activity, Control Widget
│   └── ScriptWidgetShare/     # Share extension
├── macOS/
│   ├── ScriptWidgetMac/       # macOS app
│   └── ScriptWidgetMacWidget/ # macOS widget
├── Editor/editorfe/           # React + CodeMirror editor frontend
├── Gallery/                   # Curated Widget & Skills Gallery index
├── Resource/                  # Marketing assets, screenshots
└── README.md
```

---

## 💻 Example Widgets

A script's entry point is the `$render(...)` call, which takes a JSX tree built from
runtime tags (`vstack`, `hstack`, `zstack`, `text`, `image`, `gauge`, `chart`, ...).

### Hello World

```jsx
$render(
  <vstack frame="max">
    <text font="title">Hello, ScriptWidget! 👋</text>
  </vstack>
);
```

### Fetch remote data

```jsx
const result = await fetch("https://jsonplaceholder.typicode.com/todos/1");
const model = JSON.parse(result);

$render(
  <vstack>
    <text font="title">{model.title}</text>
  </vstack>
);
```

### Persist values with `$storage`

```jsx
$storage.setString("greeting", "Hello ScriptWidget");
const greeting = $storage.getString("greeting");

$render(
  <vstack frame="max" background="#0f172a">
    <text font="caption" color="#94a3b8">Storage</text>
    <text font="title3" color="#e2e8f0">{greeting}</text>
  </vstack>
);
```

---

## 🛠️ Development

### Prerequisites

- **Xcode** 27+
- **macOS** 26+
- **iOS** 16+ (for iOS widgets)

### Build from Source

```bash
# Clone and setup
git clone https://github.com/everettjf/ScriptWidget.git
cd ScriptWidget

# Open in Xcode (pick the platform you want)
open iOS/ScriptWidget.xcodeproj      # iOS
open macOS/ScriptWidgetMac.xcodeproj # macOS

# Build and run (Cmd + R)
```

The editor frontend (React + CodeMirror) lives in `Editor/editorfe`:

```bash
cd Editor/editorfe
npm install
npm start   # dev server at http://localhost:3000
npm run build
```

### Create Your Own Widget

1. Open **ScriptWidget Studio** on Mac (or ScriptWidget on iPhone/iPad) and create a script from a template, AI prompt, or blank project
2. Write your widget in `main.jsx` and call `$render(...)` with a JSX tree
3. Use the live preview to iterate, then add the widget from the Home Screen

Each script is a package stored under `Scripts/<PackageName>/` (synced via iCloud /
the app group), with `main.jsx` as the entry point and an optional `image/` folder.

---

## 📚 Documentation

Start with the **[documentation hub](docs/README.md)** or build **[your first widget](docs/getting-started.md)** in ScriptWidget Studio.

### Core Concepts

- **Entry point** - call `$render(<tree/>)` to draw the widget
- **Components** - `vstack`, `hstack`, `zstack`, `text`, `image`, `gauge`, `chart`, shapes, ...
- **Styling** - element attributes such as `font`, `color`, `background`, `frame`, `padding`
- **Widget sizes** - read `$getenv("widget-size")` (small / medium / large / accessory…)
- **Interactions** - buttons and links via App Intents

### APIs

| API | Description |
|-----|-------------|
| `fetch()` | HTTP requests (`fetch`/`$fetch`) |
| `$storage` | Persisted key/value store (string & JSON) |
| `$file` | Read/write files in the script package |
| `$device` | Device info (model, battery, screen, dark mode, …) |
| `$location` | Location & geocoding |
| `$health` | HealthKit data (steps, heart rate, …) |
| `$system` | System info (timezone, app version, …) |
| `$import` | Import another file from the package |
| `console` | Logging (`console.log` / `console.error`) |

---

## 🎨 Gallery

<div align="center">

![Widget Gallery](Resource/WidgetDemoScreenshots/_contact-sheet-2.jpg)

*Sample widgets created with ScriptWidget*

</div>

---

## 📱 Platforms

| Platform | Support | Notes |
|----------|---------|-------|
| **iOS** | ✅ Full | iOS 16+ (iPhone, iPad) |
| **macOS** | ✅ Full | macOS 26+ (Mac) |
| **watchOS** | — | Not in the current roadmap |
| **visionOS** | — | Not in the current roadmap |

---

## 🤝 Contributing

Contributions are welcome! Please read our [Contributing Guide](CONTRIBUTING.md) for details.

### Ways to Contribute

- 🐛 Report bugs
- 💡 Suggest features
- 🔧 Submit pull requests
- 📝 Write documentation
- 🎨 Share your widgets
- 🧠 Share focused AI Skills

See the [public roadmap](ROADMAP.md), [governance model](GOVERNANCE.md), and [Gallery submission guide](docs/gallery.md). Every pull request runs the same release-readiness checks used locally.

---

## 📜 License

ScriptWidget is released under the [MIT License](LICENSE).

---

## 🙏 Acknowledgements

Built with:
- [JavaScriptCore](https://developer.apple.com/documentation/javascriptcore) - Apple's JavaScript engine
- [SwiftUI](https://developer.apple.com/xcode/swiftui/) - Modern UI framework
- [Xcode Gen](https://github.com/yonaskolb/XcodeGen) - Project generation

Inspired by:
- [React](https://reactjs.org/) - Component-based UI
- [React Native](https://reactnative.dev/) - Mobile development
- [WidgetKit](https://developer.apple.com/documentation/widgetkit) - Apple's widget framework

---

## 📈 Star History

<div align="center">

[![Star History Chart](https://api.star-history.com/svg?repos=everettjf/ScriptWidget&type=Date&theme=dark)](https://star-history.com/#everettjf/ScriptWidget&Date)

</div>

---

## 📞 Support

<div align="center">

[![GitHub Issues](https://img.shields.io/badge/Issues-Bug_Reports-FF6B6B?style=for-the-badge&logo=github)](https://github.com/everettjf/ScriptWidget/issues)
[![GitHub Discussions](https://img.shields.io/badge/Discussions-Q&A-4ECDC4?style=for-the-badge&logo=github)](https://github.com/everettjf/ScriptWidget/discussions)
[![Discord](https://img.shields.io/badge/Discord-Join_Chat-7289DA?style=for-the-badge&logo=discord)](https://discord.gg/scriptwidget)

**有问题？去 [Issues](https://github.com/everettjf/ScriptWidget/issues) 提问！**

</div>

---

<div align="center">

**Made with ❤️ by [Everett](https://github.com/everettjf)**

**Project Link:** [https://github.com/everettjf/ScriptWidget](https://github.com/everettjf/ScriptWidget)

</div>
