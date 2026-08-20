# ScriptWidget 🎨

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/ScriptWidget?style=flat-square&color=4ECDC4)](https://github.com/everettjf/ScriptWidget/stargazers)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Release Readiness](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml/badge.svg)](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml)

**Создавайте нативные виджеты для iPhone, iPad и Mac с помощью JavaScript, JSX и ИИ**

[English](README.md) | [简体中文](README_CN.md) | [Español](README_ES.md) | [日本語](README_JA.md) | [한국어](README_KO.md) | [Français](README_FR.md) | [Deutsch](README_DE.md) | [Português](README_PT_BR.md) | [Русский](README_RU.md) | [العربية](README_AR.md)

</div>

![Галерея шаблонов ScriptWidget](Resource/WidgetDemoScreenshots/_contact-sheet-1.jpg)

ScriptWidget — это открытая платформа для создания виджетов под лицензией MIT. Swift изучать не нужно: редактируйте `main.jsx` в ScriptWidget Studio на Mac, iPhone или iPad, а среда выполнения преобразует декларативный JSX в нативный интерфейс SwiftUI/WidgetKit.

## Почему ScriptWidget

- Один скрипт работает в iOS, iPadOS и macOS, а макеты адаптируются через `$getenv("widget-size")`.
- Поддерживает интерактивные виджеты, App Intents, Live Activities, Dynamic Island и Control Widgets.
- Studio для Mac включает CodeMirror, автодополнение, диагностику, консоль и предпросмотр в разных размерах.
- Модели, совместимые с OpenAI, позволяют создавать, запускать, диагностировать и улучшать виджеты; API-ключи хранятся в Keychain.
- Widget & Skills Gallery проверяет индекс, размеры, пути и SHA-256 перед установкой.
- Включает шаблоны, версионируемый Runtime API, Package 2.0 и Skills 1.0 с автотестами.

## Начало за пять минут

```bash
git clone https://github.com/everettjf/ScriptWidget.git
cd ScriptWidget
open macOS/ScriptWidgetMac.xcodeproj
# Или: open iOS/ScriptWidget.xcodeproj
```

В Xcode выберите схему `ScriptWidgetMac` или `ScriptWidget`, настройте контейнер `iCloud.ScriptWidget` и App Group `group.everettjf.scriptwidget`, затем запустите проект. Также доступен [пятиминутный урок](docs/five-minute-tutorial.md).

```jsx
$render(
  <vstack frame="max" background="#0f172a">
    <text font="title3" color="#f8fafc">Hello, ScriptWidget!</text>
  </vstack>
);
```

## Документация

- [Центр документации](docs/README.md)
- [Создание первого виджета](docs/getting-started.md)
- [ScriptWidget Studio](docs/studio.md)
- [Runtime API](docs/runtime-api.md)
- [Генерация с помощью ИИ](docs/ai-generate.md)
- [Widget & Skills Gallery](docs/gallery.md)
- [Package 2.0](docs/package-format.md), [Skills 1.0](docs/skills.md) и [план развития](ROADMAP.md)

## Участие и лицензия

Мы рады вкладам сообщества. Ознакомьтесь с [руководством](CONTRIBUTING.md), [моделью управления](GOVERNANCE.md) и [кодексом поведения](CODE_OF_CONDUCT.md). О проблемах безопасности сообщайте конфиденциально согласно [политике безопасности](SECURITY.md).

Исходный код этого репозитория опубликован под [лицензией MIT](LICENSE). Название ScriptWidget, логотипы, снимки экрана и маркетинговые материалы App Store не подпадают под лицензию MIT; права на них принадлежат соответствующим правообладателям.
