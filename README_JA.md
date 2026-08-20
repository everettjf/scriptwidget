# ScriptWidget 🎨

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/ScriptWidget?style=flat-square&color=4ECDC4)](https://github.com/everettjf/ScriptWidget/stargazers)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Release Readiness](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml/badge.svg)](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml)

**JavaScript、JSX、AI で iPhone、iPad、Mac 向けのネイティブウィジェットを作成**

[English](README.md) | [简体中文](README_CN.md) | [Español](README_ES.md) | [日本語](README_JA.md) | [한국어](README_KO.md) | [Français](README_FR.md) | [Deutsch](README_DE.md) | [Português](README_PT_BR.md) | [Русский](README_RU.md) | [العربية](README_AR.md)

</div>

![ScriptWidget テンプレートギャラリー](Resource/WidgetDemoScreenshots/_contact-sheet-1.jpg)

ScriptWidget は、MIT ライセンスのオープンソース・ウィジェット作成プラットフォームです。Swift を学ぶ必要はありません。Mac、iPhone、iPad の ScriptWidget Studio で `main.jsx` を編集すると、ランタイムが宣言的 JSX をネイティブな SwiftUI/WidgetKit UI に変換します。

## ScriptWidget の特長

- 1 つのスクリプトが iOS、iPadOS、macOS で動作し、`$getenv("widget-size")` でサイズ別に調整できます。
- インタラクティブウィジェット、App Intents、Live Activities、Dynamic Island、Control Widgets に対応します。
- Mac 版 Studio には CodeMirror、補完、診断、コンソール、複数サイズのプレビューがあります。
- OpenAI 互換モデルで生成・実行・診断・改善でき、API キーは Keychain に保存されます。
- Widget & Skills Gallery は、インデックス、サイズ、パス、SHA-256 を検証してからインストールします。
- テンプレート、バージョン管理された Runtime API、Package 2.0、Skills 1.0 を含みます。

## 5 分で始める

```bash
git clone https://github.com/everettjf/ScriptWidget.git
cd ScriptWidget
open macOS/ScriptWidgetMac.xcodeproj
# または: open iOS/ScriptWidget.xcodeproj
```

Xcode で `ScriptWidgetMac` または `ScriptWidget` スキームを選択し、`iCloud.ScriptWidget` コンテナと `group.everettjf.scriptwidget` App Group を設定して実行します。[5 分間チュートリアル](docs/five-minute-tutorial.md)も利用できます。

```jsx
$render(
  <vstack frame="max" background="#0f172a">
    <text font="title3" color="#f8fafc">Hello, ScriptWidget!</text>
  </vstack>
);
```

## ドキュメント

- [ドキュメントハブ](docs/README.md)
- [最初のウィジェットを作成](docs/getting-started.md)
- [ScriptWidget Studio](docs/studio.md)
- [Runtime API](docs/runtime-api.md)
- [AI 生成](docs/ai-generate.md)
- [Widget & Skills Gallery](docs/gallery.md)
- [Package 2.0](docs/package-format.md)、[Skills 1.0](docs/skills.md)、[ロードマップ](ROADMAP.md)

## 貢献とライセンス

貢献を歓迎します。[コントリビューションガイド](CONTRIBUTING.md)、[ガバナンス](GOVERNANCE.md)、[行動規範](CODE_OF_CONDUCT.md)をご覧ください。セキュリティ問題は[セキュリティポリシー](SECURITY.md)に従い、非公開で報告してください。

このリポジトリのソースコードは [MIT License](LICENSE) で公開されています。ScriptWidget の名称、ロゴ、スクリーンショット、App Store 用宣伝素材は MIT ライセンスの対象外であり、それらの権利は各権利者に帰属します。
