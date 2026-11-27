# ScriptWidget 🎨

<div align="center">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/scriptwidget?style=flat-square&color=4ECDC4)](https://github.com/everettjf/scriptwidget/stargazers)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square)](LICENSE)
[![Release Readiness](https://github.com/everettjf/scriptwidget/actions/workflows/release-readiness.yml/badge.svg)](https://github.com/everettjf/scriptwidget/actions/workflows/release-readiness.yml)

**Создавайте виджеты для iPhone, iPad, Mac, Android, Windows и Linux с помощью JavaScript, JSX и ИИ**

[English](README.md) | [简体中文](README_CN.md) | [Español](README_ES.md) | [日本語](README_JA.md) | [한국어](README_KO.md) | [Français](README_FR.md) | [Deutsch](README_DE.md) | [Português](README_PT_BR.md) | [Русский](README_RU.md) | [العربية](README_AR.md)

</div>

![Галерея шаблонов ScriptWidget](Resource/WidgetDemoScreenshots/_contact-sheet-1.jpg)

ScriptWidget — это открытая платформа для создания виджетов под лицензией Apache 2.0. Swift изучать не нужно: редактируйте `main.jsx` в ScriptWidget Studio на Mac, iPhone или iPad, а среда выполнения преобразует декларативный JSX в нативный интерфейс SwiftUI/WidgetKit.

Приложение для Android (Android 13 и новее) доступно как [APK в GitHub Releases](https://github.com/everettjf/scriptwidget/releases?q=%22ScriptWidget+for+Android%22&expanded=true). В Google Play идёт закрытое тестирование: чтобы участвовать, вступите в [группу Atomsprout Testers](https://groups.google.com/g/atomsprout). См. [ScriptWidget для Android](docs/android/README.md).

Версии для Windows и Linux — предварительные: [Windows](https://apps.microsoft.com/detail/9MVR97B9C938) требует Windows 11 (21H2, сборка 22000) или новее, см. [ScriptWidget для Windows](docs/windows/README.md); версия для Linux пока работает в [Omarchy](https://omarchy.org) 4.5, архивы лежат в [GitHub Releases](https://github.com/everettjf/scriptwidget/releases?q=%22ScriptWidget+for+Linux%22&expanded=true), см. [ScriptWidget для Linux](docs/linux/README.md). Обе запускают те же пакеты виджетов, но в них нет API данных устройства: здоровья, календаря, геопозиции, музыки и других.

### Снимки экрана на каждой платформе

Все снимки настоящие. Версии для Windows и Linux — предварительные.

| iPhone | iPad | Mac |
| --- | --- | --- |
| ![Галерея шаблонов на iPhone](docs/images/platforms/iphone-templates.webp) | ![Редактор на iPad](docs/images/platforms/ipad-editor.webp) | ![ScriptWidget Studio на Mac](docs/images/platforms/mac-studio.webp) |

| Android | Windows | Linux (Omarchy) |
| --- | --- | --- |
| ![Виджеты на главном экране Android](docs/images/platforms/android-widgets.webp) | ![Виджеты на рабочем столе Windows](docs/images/platforms/windows-desktop.webp) | ![Виджеты на рабочем столе Omarchy](docs/images/platforms/linux-desktop.webp) |
| ![Редактор в Android](docs/images/platforms/android-editor.webp) | ![Редактор в Windows](docs/images/platforms/windows-editor.webp) | ![Редактор в Linux](docs/images/platforms/linux-editor.webp) |

| Web Studio |
| --- |
| ![Web Studio в браузере](docs/images/platforms/web-studio.webp) |

## Почему ScriptWidget

- Один пакет работает на iPhone, iPad, Mac и Android, а также в предварительной версии в Windows 11 и Linux (Omarchy); макеты адаптируются через `$getenv("widget-size")`.
- Поддерживает интерактивные виджеты, App Intents, Live Activities, Dynamic Island и Control Widgets.
- Studio для Mac включает CodeMirror, автодополнение, диагностику, консоль и предпросмотр в разных размерах.
- Модели, совместимые с OpenAI, позволяют создавать, запускать, диагностировать и улучшать виджеты; API-ключи хранятся в Keychain.
- Widget & Skills Gallery проверяет индекс, размеры, пути и SHA-256 перед установкой.
- Включает шаблоны, версионируемый Runtime API, Package 2.0 и Skills 1.0 с автотестами.

## Начало за пять минут

```bash
git clone https://github.com/everettjf/scriptwidget.git
cd ScriptWidget
open macOS/ScriptWidgetMac.xcodeproj
# Или: open iOS/ScriptWidget.xcodeproj
```

В Xcode выберите схему `ScriptWidgetMac` или `ScriptWidget`, настройте контейнер `iCloud.ScriptWidget` и App Group `group.everettjf.scriptwidget`, затем запустите проект. Также доступен [пятиминутный урок](docs/five-minute-tutorial.md).

Для Android используйте сборку через Gradle (нужны JDK 17 или новее и Android SDK; приложению требуется Android 13 или новее):

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

Исходный код этого репозитория опубликован под [лицензией Apache 2.0](LICENSE). Название ScriptWidget, логотипы, снимки экрана и маркетинговые материалы App Store не подпадают под лицензию Apache 2.0; права на них принадлежат соответствующим правообладателям.

[Discord](https://discord.gg/eGzEaP6TzR)
