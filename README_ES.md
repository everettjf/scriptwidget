# ScriptWidget 🎨

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/ScriptWidget?style=flat-square&color=4ECDC4)](https://github.com/everettjf/ScriptWidget/stargazers)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Release Readiness](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml/badge.svg)](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml)

**Crea widgets nativos para iPhone, iPad y Mac con JavaScript, JSX e IA**

[English](README.md) | [简体中文](README_CN.md) | [Español](README_ES.md) | [日本語](README_JA.md) | [한국어](README_KO.md) | [Français](README_FR.md) | [Deutsch](README_DE.md) | [Português](README_PT_BR.md) | [Русский](README_RU.md) | [العربية](README_AR.md)

</div>

![Galería de plantillas de ScriptWidget](Resource/WidgetDemoScreenshots/_contact-sheet-1.jpg)

ScriptWidget es una plataforma de código abierto con licencia MIT para crear widgets. No necesitas aprender Swift: edita `main.jsx` en ScriptWidget Studio para Mac, iPhone o iPad y el entorno de ejecución convertirá el JSX declarativo en interfaces nativas de SwiftUI y WidgetKit.

## Por qué elegir ScriptWidget

- Un mismo script funciona en iOS, iPadOS y macOS, con diseños adaptables mediante `$getenv("widget-size")`.
- Admite widgets interactivos, App Intents, Live Activities, Dynamic Island y Control Widgets.
- Studio para Mac incluye CodeMirror, autocompletado, diagnósticos, consola y vistas previas en varios tamaños.
- Puede generar, ejecutar, diagnosticar y mejorar widgets con modelos compatibles con OpenAI; las claves API se guardan en Keychain.
- La galería de widgets y skills verifica índices, tamaños, rutas y SHA-256 antes de instalar.
- Incluye plantillas, una Runtime API versionada, Package 2.0 y Skills 1.0 con pruebas automatizadas.

## Inicio en cinco minutos

```bash
git clone https://github.com/everettjf/ScriptWidget.git
cd ScriptWidget
open macOS/ScriptWidgetMac.xcodeproj
# O bien: open iOS/ScriptWidget.xcodeproj
```

En Xcode, selecciona el esquema `ScriptWidgetMac` o `ScriptWidget`, configura el contenedor `iCloud.ScriptWidget` y el App Group `group.everettjf.scriptwidget`, y ejecuta el proyecto. También puedes seguir el [tutorial de cinco minutos](docs/five-minute-tutorial.md).

```jsx
$render(
  <vstack frame="max" background="#0f172a">
    <text font="title3" color="#f8fafc">Hello, ScriptWidget!</text>
  </vstack>
);
```

## Documentación

- [Centro de documentación](docs/README.md)
- [Crea tu primer widget](docs/getting-started.md)
- [ScriptWidget Studio](docs/studio.md)
- [Runtime API](docs/runtime-api.md)
- [Generación con IA](docs/ai-generate.md)
- [Galería de widgets y skills](docs/gallery.md)
- [Package 2.0](docs/package-format.md), [Skills 1.0](docs/skills.md) y [hoja de ruta](ROADMAP.md)

## Contribuir y licencia

Las contribuciones son bienvenidas. Consulta la [guía de contribución](CONTRIBUTING.md), el [modelo de gobernanza](GOVERNANCE.md) y el [código de conducta](CODE_OF_CONDUCT.md). Informa de problemas de seguridad de forma privada siguiendo la [política de seguridad](SECURITY.md).

El código fuente de este repositorio se publica bajo la [licencia MIT](LICENSE). El nombre ScriptWidget, sus logotipos, capturas de pantalla y materiales promocionales de App Store no están cubiertos por la licencia MIT; sus derechos pertenecen a sus respectivos titulares.
