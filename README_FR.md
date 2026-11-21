# ScriptWidget 🎨

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/ScriptWidget?style=flat-square&color=4ECDC4)](https://github.com/everettjf/ScriptWidget/stargazers)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square)](LICENSE)
[![Release Readiness](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml/badge.svg)](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml)

**Créez des widgets pour iPhone, iPad, Mac, Android, Windows et Linux avec JavaScript, JSX et l’IA**

[English](README.md) | [简体中文](README_CN.md) | [Español](README_ES.md) | [日本語](README_JA.md) | [한국어](README_KO.md) | [Français](README_FR.md) | [Deutsch](README_DE.md) | [Português](README_PT_BR.md) | [Русский](README_RU.md) | [العربية](README_AR.md)

</div>

![Galerie de modèles ScriptWidget](Resource/WidgetDemoScreenshots/_contact-sheet-1.jpg)

ScriptWidget est une plateforme open source sous licence Apache 2.0 pour créer des widgets. Nul besoin d’apprendre Swift : modifiez `main.jsx` dans ScriptWidget Studio sur Mac, iPhone ou iPad, et le moteur transforme le JSX déclaratif en interfaces SwiftUI et WidgetKit natives.

L’application Android (Android 13 ou ultérieur) est disponible en [APK sur GitHub Releases](https://github.com/everettjf/scriptwidget/releases?q=%22ScriptWidget+for+Android%22&expanded=true). Sur Google Play, elle est en test fermé : pour participer, rejoignez le [groupe Atomsprout Testers](https://groups.google.com/g/atomsprout). Voir [ScriptWidget pour Android](docs/android/README.md).

Les versions Windows et Linux sont des préversions : [Windows](https://apps.microsoft.com/detail/9MVR97B9C938) nécessite Windows 11 (21H2, build 22000) ou ultérieur, voir [ScriptWidget pour Windows](docs/windows/README.md) ; la version Linux fonctionne pour l’instant sous [Omarchy](https://omarchy.org) 4.5, les archives se trouvent dans les [GitHub Releases](https://github.com/everettjf/scriptwidget/releases), voir [ScriptWidget pour Linux](docs/linux/README.md). Les deux exécutent les mêmes paquets de widgets, mais n’ont pas les API de données de l’appareil comme la santé, le calendrier, la localisation et la musique.

### Captures d’écran de chaque plateforme

Ce sont toutes de vraies captures d’écran. Windows et Linux sont des préversions.

| iPhone | iPad | Mac |
| --- | --- | --- |
| ![Galerie de modèles sur iPhone](docs/images/platforms/iphone-templates.webp) | ![Éditeur sur iPad](docs/images/platforms/ipad-editor.webp) | ![ScriptWidget Studio sur Mac](docs/images/platforms/mac-studio.webp) |

| Android | Windows | Linux (Omarchy) |
| --- | --- | --- |
| ![Widgets sur l’écran d’accueil d’Android](docs/images/platforms/android-widgets.webp) | ![Widgets sur le bureau de Windows](docs/images/platforms/windows-desktop.webp) | ![Widgets sur le bureau d’Omarchy](docs/images/platforms/linux-desktop.webp) |
| ![Éditeur sur Android](docs/images/platforms/android-editor.webp) | ![Éditeur sur Windows](docs/images/platforms/windows-editor.webp) | ![Éditeur sur Linux](docs/images/platforms/linux-editor.webp) |

| Web Studio |
| --- |
| ![Web Studio dans le navigateur](docs/images/platforms/web-studio.webp) |

## Pourquoi choisir ScriptWidget

- Un même paquet fonctionne sur iPhone, iPad, Mac et Android, et en préversion sur Windows 11 et Linux (Omarchy), avec des mises en page adaptées via `$getenv("widget-size")`.
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

Pour Android, compilez plutôt avec Gradle (JDK 17 ou version ultérieure et le SDK Android ; l’application nécessite Android 13 ou version ultérieure) :

```bash
cd Android && ./gradlew :app:assembleDebug
```

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

Le code source de ce dépôt est publié sous [licence Apache 2.0](LICENSE). Le nom ScriptWidget, les logos, les captures d’écran et les supports promotionnels de l’App Store ne sont pas couverts par la licence Apache 2.0 ; leurs droits appartiennent à leurs titulaires respectifs.

[Discord](https://discord.gg/eGzEaP6TzR)
