# ScriptWidget 🎨

<div align="center" dir="rtl">

[![GitHub Stars](https://img.shields.io/github/stars/everettjf/ScriptWidget?style=flat-square&color=4ECDC4)](https://github.com/everettjf/ScriptWidget/stargazers)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Release Readiness](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml/badge.svg)](https://github.com/everettjf/ScriptWidget/actions/workflows/release-readiness.yml)

**أنشئ أدوات مصغّرة أصلية لـ iPhone وiPad وMac باستخدام JavaScript وJSX والذكاء الاصطناعي**

[English](README.md) | [简体中文](README_CN.md) | [Español](README_ES.md) | [日本語](README_JA.md) | [한국어](README_KO.md) | [Français](README_FR.md) | [Deutsch](README_DE.md) | [Português](README_PT_BR.md) | [Русский](README_RU.md) | [العربية](README_AR.md)

</div>

![معرض قوالب ScriptWidget](Resource/WidgetDemoScreenshots/_contact-sheet-1.jpg)

<div dir="rtl">

ScriptWidget منصة مفتوحة المصدر بترخيص MIT لإنشاء الأدوات المصغّرة. لا تحتاج إلى تعلم Swift؛ حرّر `main.jsx` في ScriptWidget Studio على Mac أو iPhone أو iPad، وستحوّل بيئة التشغيل JSX التصريحي إلى واجهات SwiftUI وWidgetKit أصلية.

## لماذا ScriptWidget؟

- يعمل السكربت نفسه على iOS وiPadOS وmacOS، مع تخطيطات متكيفة عبر `$getenv("widget-size")`.
- يدعم الأدوات التفاعلية، وApp Intents، وLive Activities، وDynamic Island، وControl Widgets.
- يتضمن Studio لـ Mac محرر CodeMirror، والإكمال التلقائي، والتشخيص، ووحدة التحكم، ومعاينات بأحجام متعددة.
- يمكنك إنشاء الأدوات وتشغيلها وتشخيصها وتحسينها بنماذج متوافقة مع OpenAI؛ وتُحفظ مفاتيح API في Keychain.
- يتحقق Widget & Skills Gallery من الفهارس والأحجام والمسارات وSHA-256 قبل التثبيت.
- يتضمن قوالب، وRuntime API بإصدارات، وPackage 2.0، وSkills 1.0 مع اختبارات آلية.

## ابدأ خلال خمس دقائق

</div>

```bash
git clone https://github.com/everettjf/ScriptWidget.git
cd ScriptWidget
open macOS/ScriptWidgetMac.xcodeproj
# أو: open iOS/ScriptWidget.xcodeproj
```

<div dir="rtl">

في Xcode، اختر مخطط `ScriptWidgetMac` أو `ScriptWidget`، وهيئ حاوية `iCloud.ScriptWidget` وApp Group بالمعرّف `group.everettjf.scriptwidget`، ثم شغّل المشروع. يمكنك أيضًا اتباع [الدليل ذي الدقائق الخمس](docs/five-minute-tutorial.md).

</div>

```jsx
$render(
  <vstack frame="max" background="#0f172a">
    <text font="title3" color="#f8fafc">Hello, ScriptWidget!</text>
  </vstack>
);
```

<div dir="rtl">

## الوثائق

- [مركز الوثائق](docs/README.md)
- [أنشئ أول أداة مصغّرة](docs/getting-started.md)
- [ScriptWidget Studio](docs/studio.md)
- [Runtime API](docs/runtime-api.md)
- [الإنشاء بالذكاء الاصطناعي](docs/ai-generate.md)
- [Widget & Skills Gallery](docs/gallery.md)
- [Package 2.0](docs/package-format.md)، و[Skills 1.0](docs/skills.md)، و[خارطة الطريق](ROADMAP.md)

## المساهمة والترخيص

نرحب بالمساهمات. راجع [دليل المساهمة](CONTRIBUTING.md)، و[الحوكمة](GOVERNANCE.md)، و[قواعد السلوك](CODE_OF_CONDUCT.md). أبلغ عن المشكلات الأمنية بشكل خاص وفق [سياسة الأمان](SECURITY.md).

يُنشر الكود المصدري في هذا المستودع بموجب [ترخيص MIT](LICENSE). لا يشمل ترخيص MIT اسم ScriptWidget أو الشعارات أو لقطات الشاشة أو مواد App Store الترويجية؛ وتعود حقوقها إلى أصحاب الحقوق المعنيين.

</div>
