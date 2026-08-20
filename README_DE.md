# ScriptWidget 🎨

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/ScriptWidget?style=flat-square&color=4ECDC4)](https://github.com/everettjf/ScriptWidget/stargazers)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Release Readiness](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml/badge.svg)](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml)

**Erstelle native Widgets für iPhone, iPad und Mac mit JavaScript, JSX und KI**

[English](README.md) | [简体中文](README_CN.md) | [Español](README_ES.md) | [日本語](README_JA.md) | [한국어](README_KO.md) | [Français](README_FR.md) | [Deutsch](README_DE.md) | [Português](README_PT_BR.md) | [Русский](README_RU.md) | [العربية](README_AR.md)

</div>

![ScriptWidget-Vorlagengalerie](Resource/WidgetDemoScreenshots/_contact-sheet-1.jpg)

ScriptWidget ist eine Open-Source-Plattform unter der MIT-Lizenz zum Erstellen von Widgets. Du musst kein Swift lernen: Bearbeite `main.jsx` in ScriptWidget Studio auf Mac, iPhone oder iPad, und die Laufzeit bildet deklaratives JSX auf native SwiftUI- und WidgetKit-Oberflächen ab.

## Warum ScriptWidget?

- Ein Skript läuft auf iOS, iPadOS und macOS; Layouts lassen sich mit `$getenv("widget-size")` anpassen.
- Unterstützt interaktive Widgets, App Intents, Live Activities, Dynamic Island und Control Widgets.
- Studio für Mac bietet CodeMirror, Autovervollständigung, Diagnosen, Konsole und Vorschauen in mehreren Größen.
- Widgets lassen sich mit OpenAI-kompatiblen Modellen erzeugen, ausführen, diagnostizieren und verbessern; API-Schlüssel bleiben im Schlüsselbund.
- Die Widget & Skills Gallery prüft Index, Größe, Pfade und SHA-256 vor der Installation.
- Enthält Vorlagen, eine versionierte Runtime API, Package 2.0 und Skills 1.0 mit automatisierten Tests.

## In fünf Minuten starten

```bash
git clone https://github.com/everettjf/ScriptWidget.git
cd ScriptWidget
open macOS/ScriptWidgetMac.xcodeproj
# Oder: open iOS/ScriptWidget.xcodeproj
```

Wähle in Xcode das Schema `ScriptWidgetMac` oder `ScriptWidget`, konfiguriere den Container `iCloud.ScriptWidget` und die App Group `group.everettjf.scriptwidget`, und starte das Projekt. Alternativ hilft das [Fünf-Minuten-Tutorial](docs/five-minute-tutorial.md).

```jsx
$render(
  <vstack frame="max" background="#0f172a">
    <text font="title3" color="#f8fafc">Hello, ScriptWidget!</text>
  </vstack>
);
```

## Dokumentation

- [Dokumentationsübersicht](docs/README.md)
- [Das erste Widget erstellen](docs/getting-started.md)
- [ScriptWidget Studio](docs/studio.md)
- [Runtime API](docs/runtime-api.md)
- [KI-Generierung](docs/ai-generate.md)
- [Widget & Skills Gallery](docs/gallery.md)
- [Package 2.0](docs/package-format.md), [Skills 1.0](docs/skills.md) und [Roadmap](ROADMAP.md)

## Mitwirken und Lizenz

Beiträge sind willkommen. Lies den [Leitfaden für Beiträge](CONTRIBUTING.md), die [Governance](GOVERNANCE.md) und den [Verhaltenskodex](CODE_OF_CONDUCT.md). Melde Sicherheitsprobleme gemäß der [Sicherheitsrichtlinie](SECURITY.md) vertraulich.

Der Quellcode dieses Repositorys wird unter der [MIT-Lizenz](LICENSE) veröffentlicht. Der Name ScriptWidget, Logos, Screenshots und Werbematerialien für den App Store sind nicht von der MIT-Lizenz erfasst; die Rechte daran verbleiben bei den jeweiligen Rechteinhabern.
