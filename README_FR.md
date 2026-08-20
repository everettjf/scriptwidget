# ScriptWidget 🎨

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/ScriptWidget?style=flat-square&color=4ECDC4)](https://github.com/everettjf/ScriptWidget/stargazers)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Release Readiness](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml/badge.svg)](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml)

**Créez des widgets natifs pour iPhone, iPad et Mac avec JavaScript, JSX et l’IA**

[English](README.md) | [简体中文](README_CN.md) | [Español](README_ES.md) | [日本語](README_JA.md) | [한국어](README_KO.md) | [Français](README_FR.md) | [Deutsch](README_DE.md) | [Português](README_PT_BR.md) | [Русский](README_RU.md) | [العربية](README_AR.md)

</div>

![Galerie de modèles ScriptWidget](Resource/WidgetDemoScreenshots/_contact-sheet-1.jpg)

ScriptWidget est une plateforme open source sous licence MIT pour créer des widgets. Nul besoin d’apprendre Swift : modifiez `main.jsx` dans ScriptWidget Studio sur Mac, iPhone ou iPad, et le moteur transforme le JSX déclaratif en interfaces SwiftUI et WidgetKit natives.

## Pourquoi choisir ScriptWidget

- Un même script fonctionne sur iOS, iPadOS et macOS, avec des mises en page adaptées via `$getenv("widget-size")`.
- Prend en charge les widgets interactifs, App Intents, Live Activities, Dynamic Island et Control Widgets.
- Studio pour Mac intègre CodeMirror, la complétion, les diagnostics, une console et des aperçus multitailles.
- Génère, exécute, diagnostique et améliore les widgets avec des modèles compatibles OpenAI ; les clés API restent dans le trousseau.
- La galerie de widgets et de skills vérifie index, tailles, chemins et SHA-256 avant installation.
- Fournit des modèles, une Runtime API versionnée, Package 2.0 et Skills 1.0 avec des tests automatisés.

## Démarrer en cinq minutes

```bash
git clone https://github.com/everettjf/ScriptWidget.git
cd ScriptWidget
open macOS/ScriptWidgetMac.xcodeproj
# Ou : open iOS/ScriptWidget.xcodeproj
```

Dans Xcode, choisissez le schéma `ScriptWidgetMac` ou `ScriptWidget`, configurez le conteneur `iCloud.ScriptWidget` et l’App Group `group.everettjf.scriptwidget`, puis lancez le projet. Vous pouvez aussi suivre le [tutoriel de cinq minutes](docs/five-minute-tutorial.md).

```jsx
$render(
  <vstack frame="max" background="#0f172a">
    <text font="title3" color="#f8fafc">Hello, ScriptWidget!</text>
  </vstack>
);
```

## Documentation

- [Portail de documentation](docs/README.md)
- [Créer votre premier widget](docs/getting-started.md)
- [ScriptWidget Studio](docs/studio.md)
- [Runtime API](docs/runtime-api.md)
- [Génération par IA](docs/ai-generate.md)
- [Galerie de widgets et de skills](docs/gallery.md)
- [Package 2.0](docs/package-format.md), [Skills 1.0](docs/skills.md) et [feuille de route](ROADMAP.md)

## Contribution et licence

Les contributions sont les bienvenues. Consultez le [guide de contribution](CONTRIBUTING.md), la [gouvernance](GOVERNANCE.md) et le [code de conduite](CODE_OF_CONDUCT.md). Signalez les problèmes de sécurité en privé selon la [politique de sécurité](SECURITY.md).

Le code source de ce dépôt est publié sous [licence MIT](LICENSE). Le nom ScriptWidget, les logos, les captures d’écran et les supports promotionnels de l’App Store ne sont pas couverts par la licence MIT ; leurs droits appartiennent à leurs titulaires respectifs.
