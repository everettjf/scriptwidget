# Official Microsoft widget platform on Windows 11 (state of November 2026)

Research date: 2026-11-16. Source labels used below: **[MS]** = read on an official Microsoft page (learn.microsoft.com, support.microsoft.com, blogs.windows.com); **[2nd]** = secondary press or community reporting; **[2nd, search snippet]** = only seen as a search-result summary, page not opened. Most Microsoft Learn widget pages carry `ms.date` 2026-10-23 or 2026-10-27, so they reflect the current documentation.

## 1. Which official widget surfaces exist, on which versions and regions, and what changed in 2025-2026

### Takeaway
There are three official surfaces: the Widgets Board (flyout opened from the taskbar Widgets button, Win+W or a left-edge swipe), lock screen widgets, and the taskbar button itself (weather/alerts/badge, not a third-party surface). There is no official surface that places widgets on the desktop. In 2026 Microsoft did not deprecate widgets; it made them "quiet by default" and rebuilt parts of the board, while HTML ("web") widgets and third-party feeds remain EEA-only.

### Cited Findings
- [MS, ms.date 2026-10-27] The Widgets Board is "a flyout plane that overlays the Windows desktop when the user clicks Widgets icon on the taskbar, uses the Windows+W shortcut, or swipes from the left edge of the screen"; widgets are displayed in a grid. The docs define a "Widgets host" as "an application that displays and manages Windows widgets. The Widgets Board built into Windows 11 is a widget host." — [Windows Widgets overview](https://learn.microsoft.com/en-us/windows/apps/design/widgets/)
- [MS] Support page lists the surfaces as lock screen, taskbar and Widgets board; lock screen widgets are configured in Settings > Personalization > Lock screen; "Currently, only widgets that support a small size can be added to the lock screen." Windows 10 only has the fixed "Weather and more" lock-screen app. — [Customize the Lock Screen in Windows](https://support.microsoft.com/en-US/Windows/Experience/Personalization/customize-the-lock-screen-in-windows)
- [MS, 2025-11-04] Canary build 27982: "Multiple dashboards in Widgets give you more space for your favorite widgets"; new left navigation bar to switch between dashboards and the Discover feed; updated lock screen widgets replacing "Weather and more" with add/remove/rearrange. No mention of desktop placement, EEA or developers. — [Announcing Build 27982 (Canary)](http://blogs.windows.com/windows-insider/2025/11/04/announcing-windows-11-insider-preview-build-27982-canary-channel/)
- [MS, 2026-06-12] Beta build 26220.8680 (25H2-based) release notes, Widgets section: "making the experience quiet by default": Open on hover disabled by default; taskbar badging off by default; board opens to widgets (not the feed) on first launch; "Weather as the only default widget on the lockscreen"; daily cap on taskbar alerts; alerts limited until the user engages; badge uses the accent color; per-dashboard badges in the navigation bar; full-screen Widgets settings; lower memory footprint and limited pre-launch on low-memory devices. — [Build 26220.8680 release notes](https://learn.microsoft.com/en-us/windows-insider/release-notes/beta/preview-build-26220-8680)
- [MS, 2026-07-31] Windows quality update post: in May 2026 Microsoft "previewed updates to the widgets and feed experience" (more control, quieter by default); "More control over widgets and feed experiences" is one of the March 2026 commitments; Widgets is named as a surface WinUI 3 has been extended into; broader rollout "beginning this fall". No specific future widget features are named. — [Windows quality: an update on the commitment we made in March](https://blogs.windows.com/windows-insider/2026/07/31/windows-quality-an-update-on-the-commitment-we-made-in-march/)
- [MS] The March 20, 2026 commitment post exists and lists widgets/feed control (seen via search summary and the July follow-up, not opened directly). — [Our commitment to Windows quality](https://blogs.windows.com/windows-insider/2026/03/20/our-commitment-to-windows-quality/)
- [2nd, 2026-09-17] Windows Latest: lock screen change (Weather only by default; widgets can be turned off entirely) began for new users in July 2026, appeared in an August 27 preview changelog, shipped in the September 8, 2026 Patch Tuesday update, with a release-note entry on September 14. MSN feed/ads in Widgets were turned off by default in May 2026. Third-party lock screen widgets (e.g. Spotify) have been possible since February 2025; a Countdown widget without a small size could not be added. — [Windows Latest, 2026-09-17](https://www.windowslatest.com/2026/09/17/microsoft-turned-windows-11s-lock-screen-into-msn-hell-now-its-undoing-most-of-it/)
- [2nd, 2025-02-05] Windows Latest: customizable lock screen widgets arrived in Beta build 22635.4870 (announced 2025-02-03), initially for Insiders in the EEA, "will later expand"; built-in choices Weather, Watchlist, Sports, Traffic; "Find more widgets" links to the Store; a group policy "Disable Widgets On Lock Screen" was added. — [Windows Latest hands-on](https://www.windowslatest.com/2025/02/05/hands-on-windows-11s-new-lock-screen-widget-customization-with-3rd-party-apps)
- [2nd, community site, no primary citation] The quiet-by-default changes reportedly reached Windows 11 24H2 and 25H2 through optional update KB5095093 in June 2026; the news feed (Discover) has been optional since the 2024-2025 rebuild; Dev Home (source of CPU/GPU widgets) was retired in May 2025. — [xakpc.dev](https://xakpc.dev/windows-widgets/what-are-windows-widgets/)
- [2nd, search snippet] Windows Central's "K2" tracker lists the widgets commitment as delivered. — [Windows Central tracker](https://www.windowscentral.com/microsoft/windows-11/windows-k2-status-tracker-windows-11-commitments)
- [2nd, search snippet] Insider build 23521 (2023) added a "Pin" button that keeps the whole board open while switching apps; that is a pinned panel, not desktop widgets. — [Pureinfotech](https://pureinfotech.com/enable-new-widgets-pin-windows-11/)

### Inferences
- The 2025-2026 direction is consolidation and noise reduction (separate "my widgets" from the MSN feed, fewer alerts, less memory), not expansion of what a widget can render. Nothing found points to deprecation of the third-party provider model: the developer docs were all revised in late October 2026 and a new analytics interface targets build 26900 (see section 2).
- "Build 26900" in the developer docs implies a Windows build line newer than 25H2's 262xx; which marketing release that is was not confirmed.

### Gaps
- No Build 2025 or Build 2026 session specifically about widgets was found; the July 2026 post mentions Build 2026 only as an event. Whether anything widget-related was announced there is unconfirmed.
- Exact GA build/KB for the dashboards/navigation-bar redesign outside Insider channels was not confirmed on a Microsoft page (KB5095093 comes from a community site only).
- No official statement about the next Windows version's widget plans ("Windows 12" or otherwise) was found.
- Regional availability of lock screen widgets today: the Microsoft support page states no regional restriction; the EEA-first rollout is from February 2025 press. Worldwide availability is implied by the 2026 release notes but not stated explicitly.

## 2. How a third-party app provides widgets (provider types and requirements)

### Takeaway
Two routes exist: a packaged Win32 app implementing `IWidgetProvider` as an out-of-process COM server registered in the MSIX manifest, or a PWA declaring `widgets` in its web app manifest and handling events in its service worker. Package identity is mandatory; nothing newer has replaced these.

### Cited Findings
- [MS, ms.date 2026-10-23] "Currently you can implement a widget provider using a packaged Win32 desktop app or a Progressive Web App (PWA)." — [Widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-providers)
- [MS] Capability/version table: lifecycle + Adaptive Card updates (`IWidgetProvider`, `WidgetManager`) from Windows App SDK 1.2; user customization (`IWidgetProvider2`, `IsCustomizable`) from 1.4; web content, resource requests and messaging (`IWidgetResourceProvider`, `IWidgetProviderMessage`, `WidgetManager.SendMessageToContent`) from 1.6.3; `IsPlaceholderContent` from 1.6.6; `IWidgetProviderAnalytics` callbacks supported by the Widgets Board "starting with Windows 11 build 26900". — [Widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-providers)
- [MS] "For Win32 apps, only packaged apps are currently supported and widget providers specify their registration information in the app package manifest file." Registration is a `uap3:AppExtension` with `Name="com.microsoft.windows.widgets"`; activation is `CreateInstance ClassId=<CLSID>` (COM, recommended) or `ActivateApplication` (command line with base64url JSON). — [Widget provider package manifest XML format](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-provider-manifest)
- [MS] The C# walkthrough (ms.date 2026-10-23) uses Microsoft.WindowsAppSDK 2.5.1 ("not the minimum version"), an MSIX packaging project (target 1809 or later), a `com:Extension Category="windows.comServer"` with `com:ExeServer`/`com:Class Id`, and an `IClassFactory` implementation; prerequisite is "A Windows 11 device with the Widgets Board available". — [Implement a widget provider in a C# Windows App](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/implement-widget-provider-cs)
- [MS] `IWidgetProvider` must be "implemented as an Out-of-process COM Server. The lifetime of a widget provider is independent of its widgets' lifetimes; a widget provider can be activated and released by the widget manager at any time. Multiple providers for the same provider app will be run in a shared process." API monikers run from windows-app-sdk-1.2 to 2.0. Methods: Activate, CreateWidget, Deactivate, DeleteWidget, OnActionInvoked, OnWidgetContextChanged. — [IWidgetProvider](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.widgets.providers.iwidgetprovider)
- [MS, ms.date 2023-08-10, page touched 2026-09-02] PWA widgets: defined in the manifest `widgets` array (`name`, `description`, `tag`, `ms_ac_template`, `data`, `screenshots`, `icons`, `auth`, `update`, `multiple`); service worker gets `widgetinstall`, `widgetuninstall`, `widgetresume`, `widgetclick` and updates via `self.widgets.updateByTag/updateByInstanceId`; can ship to the Microsoft Store through PWABuilder with no C++/C# code; local testing needs WinAppSDK 1.2 and Developer Mode. — [Build PWA-driven widgets](https://learn.microsoft.com/en-us/microsoft-edge/progressive-web-apps/how-to/widgets)

### Inferences
- An Electron/Tauri/other non-MSIX desktop app cannot register widgets unless it is shipped as (or alongside) an MSIX package with a COM server; "packaging with external location" (sparse package) was not checked for widget support.
- The PWA route is documented but its page has not been substantively revised since 2023, suggesting low investment there.

### Gaps
- Whether sparse/"external location" packages can host the widget app extension was not verified.
- Whether a Store listing is required (vs. sideloaded MSIX) for widgets to appear for normal users was not verified on an official page; the PWA page only describes Developer Mode for local testing.

## 3. Rendering model: Adaptive Cards, images, custom drawing, web widgets

### Takeaway
Outside the EEA a widget is still an Adaptive Card JSON template plus JSON data, rendered by the host with its own controls and Segoe UI; there is no custom drawing, custom font, free transform or animation API. Arbitrary visuals are only reachable via Image/backgroundImage elements. HTML "web widgets" exist (Windows App SDK 1.6.3+) but are documented as available only to users in the EEA.

### Cited Findings
- [MS, ms.date 2026-10-23] "You can provide an Adaptive Card template and data, or use a web widget to display HTML from a URL. Web widgets still use an Adaptive Card JSON payload to specify the content URL." — [Widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-providers)
- [MS, ms.date 2026-10-27] Current template examples declare Adaptive Cards `"version": "1.6"`; the C# walkthrough samples use `"version": "1.5"`. — [Create a widget template](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widgets-create-a-template); [C# walkthrough](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/implement-widget-provider-cs)
- [MS] "The Designer uses its own renderer and host options. Don't assume that features it offers are supported by the Widgets Board." — [Create a widget template](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widgets-create-a-template)
- [MS] Host properties available to templates: `$host.widgetSize` (small/medium/large), `hostTheme` (light/dark), `isSettingsPayload`, `isHeaderSupported`, `isHeader`, `isWebSupported`, `isUserContextAuthenticated`. — [Create a widget template](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widgets-create-a-template)
- [MS] Images in official samples are HTTPS URLs: card-level `backgroundImage` and `Image` elements pointing at raw.githubusercontent.com. — [C# walkthrough](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/implement-widget-provider-cs)
- [MS] "The widget background supports customization with either a solid light/dark background, gradient tint, or image background." Typography guidance is "Use Segoe UI and the type ramp" (Caption 12/16 epx up to Title 28/36 epx, mapped to Adaptive Cards sizes/weights); "the target host controls their rendered appearance". — [Widget design fundamentals](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-design-fundamentals)
- [MS] Where header customization is supported, the provider can override header text/icon or set `header` to `null` so content extends into the 48px header region (that region is not clickable). — [Widget states and built-in UI](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-states-and-ui)
- [MS, ms.date 2026-10-23] Web widgets: payload `metadata.webUrl` points to HTML; an Adaptive Card `body` should be supplied as fallback; a manifest `WebRequestFilter` (must match the `webUrl` origin) lets the provider intercept resource requests in `IWidgetResourceProvider.OnResourceRequested` and answer from local data (e.g. `ms-appx:///Assets/image.png`); two-way string messaging via `window.chrome.webview.postMessage` and `WidgetManager.SendMessageToContent`. "This feature is available only to users in the European Economic Area (EEA)." — [Web widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/web-widget-providers)
- [MS] Design constraints such as no scrolling/second-level pages "are design constraints for a glanceable experience, not a statement that HTML web content can't implement scrolling or navigation." — [Widget interaction design](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-interaction-design)
- [MS] Third-party feeds ("feed providers") are a separate preview feature: a web component rendered in an iframe on the board, shown as a pivot; "available only to users in the European Economic Area (EEA)". ms.date 2026-06-24. — [Dashboards and feed providers](https://learn.microsoft.com/en-us/windows/apps/develop/feeds/feed-providers)
- [MS, 2023 page] PWA page still says "The Windows 11 Widgets Board requires widgets to be built by using Adaptive Card templates instead of HTML and JavaScript". — [Build PWA-driven widgets](https://learn.microsoft.com/en-us/microsoft-edge/progressive-web-apps/how-to/widgets)
- [MS staff on GitHub, 2023-01] Asked whether two images can be layered (z-index), the maintainer pointed to Container, where images stack vertically; overlap was not confirmed. — [WindowsAppSDK discussion #3300](https://github.com/microsoft/WindowsAppSDK/discussions/3300)
- [2nd, community workshop, search snippet] Templates embedding `"url": "data:image/svg+xml;base64,${ImageData}"` are used in a community widget workshop, i.e. data: URIs reportedly work for Image elements. — [tutorialr/windows-widget-workshop](https://github.com/tutorialr/windows-widget-workshop)
- [2nd, 2025] Web-content widgets shipped to Windows via build 26100.3613 (KB5053656, Release Preview, March 2025), per Windows Report. — [Windows Report](https://windowsreport.com/with-kb5053656-microsoft-enhances-windows-11-to-allow-devs-to-build-their-own-widgets/)

### Inferences
- For a tree with gradients, rotation, shadows and custom fonts, the only worldwide-compatible approach is the same as the Android one: rasterize the tree to a bitmap and show it as a full-bleed `Image`/`backgroundImage` in an Adaptive Card, with a small number of Adaptive Card actions (e.g. `selectAction` on images/containers laid out in columns) standing in for click regions. Arbitrary pixel-accurate click regions are not expressible in Adaptive Cards.
- In the EEA only, a web widget could render the tree as HTML/canvas directly and have the provider serve local resources through `OnResourceRequested`; the Adaptive Card fallback body is still needed for hosts where `isWebSupported` is false.
- Animation would only be possible through an animated image format (the manifest example lists an `icon.gif`, hinting GIF is accepted at least for icons) or web widgets; not confirmed for card images.

### Gaps
- No Microsoft page read states which Adaptive Cards elements/actions the Widgets Board supports or rejects, the maximum template/data payload size, image byte or pixel limits, allowed image formats, or whether `data:` URIs / local file URIs are officially supported. Data-URI support rests on a community sample only.
- Whether the board caches or re-fetches HTTPS images on each update was not found.
- Web widget host requirements beyond "EEA" (minimum build, WebView2 specifics, CSP, size, lock screen behavior) are not listed on the page.

## 4. Sizes, widgets per app, configuration UI, interaction, update limits, provider lifetime

### Takeaway
Three sizes (small/medium/large) with a fixed 300px width; only the medium height (304px) is stated officially. An app can declare multiple definitions, each allowing multiple instances; customization is an Adaptive Card settings payload; interaction is `Action.Execute` (round-trip to the provider) and `Action.OpenUrl`. No numeric update-rate, payload or memory limits are published; the provider is activated and released at the host's discretion.

### Cited Findings
- [MS] Sizes are "small", "medium", "large", declared per definition as `Capability/Size`; "If no capabilities are declared, one capability specifying a 'large' size is added by default." — [Manifest format](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-provider-manifest)
- [MS, ms.date 2026-10-23] Picker screenshot "should display the medium size version of your widget" and "should be 300 pixels wide and 304 pixels tall", with transparent rounded corners. — [Integrate with the widget picker](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-picker-integration)
- [MS] Layout: 16px margin, 48px attribution/header area, 4px gutters, multiples of 4px. — [Widget design fundamentals](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-design-fundamentals)
- [MS] Recommended maximum touchpoints: small 1, medium 3, large 4. One primary page; no pivots between unrelated experiences, second-level pages, or scrolling to reach primary content; host-rendered pagination dots/arrows, hyperlinks and dropdowns are shown as supported patterns. — [Widget interaction design](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-interaction-design)
- [MS] "Small and medium sizes provide better discoverability as they get surfaced more often within the dynamic feed." — [Widget design fundamentals](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-design-fundamentals)
- [MS] "Your app can support multiple individual widgets." `Definitions` is "the container element for one or more widget registrations"; `AllowMultiple` defaults to true (multiple pinned instances of one definition, each with its own `WidgetContext.Id`). No maximum count is stated. — [Overview](https://learn.microsoft.com/en-us/windows/apps/design/widgets/); [Manifest format](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-provider-manifest)
- [MS] Customization: `IsCustomizable="true"` (Windows App SDK 1.4+) shows "Customize widget" in the ellipsis menu; the provider answers via `IWidgetProvider2.OnCustomizationRequested` or by branching on `$host.isSettingsPayload`; the settings UI is itself an Adaptive Card JSON template. Context menu also offers size choice and unpin. — [Widget states and built-in UI](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-states-and-ui); [Create a widget template](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widgets-create-a-template)
- [MS] `Action.Execute` (with a `verb`) is forwarded to the provider's `OnActionInvoked`; `Action.OpenUrl` navigates without calling the provider. "When `$host.isUserContextAuthenticated` is false ... only Action.OpenUrl is supported." — [Create a widget template](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widgets-create-a-template)
- [MS] Updates are pushed with `WidgetManager.UpdateWidget(WidgetUpdateRequestOptions)` carrying Template, Data and a `CustomState` string that the host stores and returns via `GetWidgetInfos()`; `WidgetManager` "can only perform operations on existing widgets". — [WidgetManager](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.widgets.providers.widgetmanager); [C# walkthrough](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/implement-widget-provider-cs)
- [MS] `Activate` means "the widget host is currently interested in receiving updated content" (e.g. the user is viewing the host); `Deactivate` means it no longer requests updates; "the time window between Activate and Deactivate may be small, so it's recommended that you try to make your widget update code path as quick as possible." `OnWidgetContextChanged` "is only called when the user changes the size of a pinned widget" in the current release. — [C# walkthrough](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/implement-widget-provider-cs)
- [MS] "The host can activate and release a provider while widgets remain pinned. In a production provider, manage the COM server's lifetime independently, restore saved widget state on startup". — [C# walkthrough](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/implement-widget-provider-cs)
- [MS] Error state: if the board cannot retrieve layout/data it shows a system error with reload; with cached content the header shows time since last refresh (minutes, or rounded hours). — [Widget states and built-in UI](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-states-and-ui)
- [MS] `IsPlaceholderContent=true`: "The host may prioritize widgets with customized content over widgets with placeholder content." — [Widget states and built-in UI](https://learn.microsoft.com/en-us/windows/apps/design/widgets/widgets-states-and-ui)
- [MS, 2023 page] PWA `update` field is "the frequency, in seconds, at which the widget will be updated", but "the widget is not updated automatically"; the service worker must do it, e.g. via Periodic Background Sync; `widgetresume` fires after the host "suspended the rendering of widgets to preserve resources". — [Build PWA-driven widgets](https://learn.microsoft.com/en-us/microsoft-edge/progressive-web-apps/how-to/widgets)
- [MS staff on GitHub, 2023-01] A timer in the provider process calling UpdateWidget with fresh data works for periodic (15-30 minute) updates. — [WindowsAppSDK discussion #3300](https://github.com/microsoft/WindowsAppSDK/discussions/3300)
- [2nd, community tutorial, search snippet] A small-widget background is authored at 300x200 px (3:2) in a community tutorial; unofficial. — [xakpc/Widgets.Playground tutorial](https://github.com/xakpc/Widgets.Playground/blob/master/tutorial/windows-widget/steps/03-adaptive-card-template.md)

### Inferences
- Text input is available in principle through Adaptive Cards Input.* elements submitted with Action.Execute (the customization UI relies on this), but the widget docs read here only show buttons; treat in-widget text input as plausible, not confirmed.
- Because a widget instance receives a `CustomState` string and its own instance ID, one definition with `AllowMultiple=true` plus the customization card can map each pinned instance to a different user script (a "pick your script" settings payload). This is the practical substitute for per-script definitions.
- A provider that wants timed refreshes must keep its own process (or a companion background process) alive; the host does not schedule updates for it, and content pushed while the board is closed is simply stored until shown.

### Gaps
- Official pixel heights for small and large were not found on any current Microsoft page (only medium = 300x304 from the picker screenshot spec). Commonly quoted figures elsewhere were not verified and are deliberately not reproduced.
- No published numbers for: update throttling, maximum template/data/CustomState size, provider memory or CPU limits, callback time limits, or how long the provider stays alive after Deactivate.
- Whether Action.Execute works on the lock screen was not confirmed (the support page says selecting a widget leads to sign-in and the provider's landing page).

## 5. Pinning and dynamic definitions

### Takeaway
Nothing in the documented API lets an app pin a widget or create a widget definition at runtime. Definitions are static entries in the package manifest (or PWA manifest); the user adds widgets from the board's picker (or the lock screen settings page).

### Cited Findings
- [MS] `WidgetManager` exposes only DeleteWidget, GetDefault, GetWidgetIds, GetWidgetInfo, GetWidgetInfos, SendMessageToContent, UpdateWidget; remark: "This class can only perform operations on existing widgets." There is no create/pin/request-pin method. — [WidgetManager](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.widgets.providers.widgetmanager)
- [MS] `CreateWidget` is a notification from the host "when the user has pinned one of your app's widgets in the widget host". — [C# walkthrough](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/implement-widget-provider-cs)
- [MS] Each `Definition` has an `Id` that "must be unique among the definitions in the app manifest", with required DisplayName, Description, Icon and Screenshot package-relative paths. — [Manifest format](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-provider-manifest)
- [MS] "The package manifest schema does not enforce the structure of the uap3:Properties element other than requiring well-formed XML." — [Manifest format](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-provider-manifest)
- [MS] PWA: "When a PWA is installed, the widgets that the app defines in its manifest are added to the widgets dashboard but not installed yet. A widget is only installed when the user chooses to add the widget from the dashboard." — [Build PWA-driven widgets](https://learn.microsoft.com/en-us/microsoft-edge/progressive-web-apps/how-to/widgets)

### Inferences
- A scripting app must ship a fixed set of generic definitions (for example one "Script widget" definition per size mix, `AllowMultiple=true`, `IsCustomizable=true`) and bind each pinned instance to a script through the customization card and `CustomState`. Per-script names, icons and picker screenshots are not possible because those come from static package assets.

### Gaps
- No Microsoft statement was found that explicitly says "programmatic pinning is not supported"; the conclusion is from the absence of any such API in the reference and docs. No deep link or URI scheme for opening the picker on a specific widget was found.
- A targeted search of microsoft/WindowsAppSDK issues for pin/dynamic-definition requests returned nothing usable.

## 6. Third-party widgets on the lock screen

### Takeaway
Yes: third-party widgets can be added to the lock screen by the user, with the only documented rule being that the widget must support the small size. There is no separate lock screen developer API or manifest flag in the docs read.

### Cited Findings
- [MS] "Currently, only widgets that support a small size can be added to the lock screen." Customization is available only if the provider supports it; selecting a widget on the lock screen leads to sign-in and then the provider's landing page; the Widgets toggle hides them all. — [Customize the Lock Screen in Windows](https://support.microsoft.com/en-US/Windows/Experience/Personalization/customize-the-lock-screen-in-windows)
- [MS, 2026-06-12] Weather becomes the only default lock screen widget. — [Build 26220.8680 release notes](https://learn.microsoft.com/en-us/windows-insider/release-notes/beta/preview-build-26220-8680)
- [MS] `$host.isUserContextAuthenticated`: "When this value is false, the only action that is supported is Action.OpenUrl." — [Create a widget template](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widgets-create-a-template)
- [2nd, 2025-02-05] A Store Spotify widget was placed on the lock screen in testing; widgets without a small size show an error when added; the article describes lock screen widgets as interactive (timers, playback). — [Windows Latest hands-on](https://www.windowslatest.com/2025/02/05/hands-on-windows-11s-new-lock-screen-widget-customization-with-3rd-party-apps)
- [2nd, 2026-09-17] A third-party Countdown widget lacking a small size could not be added. — [Windows Latest](https://www.windowslatest.com/2026/09/17/microsoft-turned-windows-11s-lock-screen-into-msn-hell-now-its-undoing-most-of-it/)

### Inferences
- `isUserContextAuthenticated=false` is very likely the lock screen state, meaning Action.Execute buttons do not work there and only OpenUrl-style navigation (after sign-in) is available. The docs do not name the lock screen explicitly, and this conflicts with the 2025 press description of interactive lock screen widgets, so it needs a device test.
- A scripting app's widgets would qualify for the lock screen simply by declaring the small size.

### Gaps
- Maximum number of lock screen widgets, their rendered pixel size, refresh behavior while locked, and whether web widgets render there were not found.

## 7. Usage, sentiment, and Microsoft's investment

### Takeaway
No usage figures for the Widgets Board were found from Microsoft or from press. Sentiment in the Windows press is that widgets were noisy and MSN-driven with a thin third-party catalog; Microsoft's 2026 response was to quiet and slim the experience rather than drop it, and it keeps the developer docs current.

### Cited Findings
- [MS, 2026-06-12] Microsoft's own framing: "We're working to make Widgets feel less distracting and overwhelming"; for "a user who barely engages with Widgets" the experience is quieted automatically; memory footprint reduced. — [Build 26220.8680 release notes](https://learn.microsoft.com/en-us/windows-insider/release-notes/beta/preview-build-26220-8680)
- [MS, 2026-07-31] Widgets/feed control is part of the 2026 Windows quality commitments; Widgets is being moved onto WinUI 3. — [Windows quality update](https://blogs.windows.com/windows-insider/2026/07/31/windows-quality-an-update-on-the-commitment-we-made-in-march/)
- [MS] Developer docs for widgets were revised 2026-10-23/27 and a new `IWidgetProviderAnalytics` interface targets build 26900. — [Widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-providers)
- [2nd, 2026-09-17] Windows Latest characterizes the earlier lock screen as overrun by MSN content, calls the widget catalog thin, and reports no usage data. — [Windows Latest](https://www.windowslatest.com/2026/09/17/microsoft-turned-windows-11s-lock-screen-into-msn-hell-now-its-undoing-most-of-it/)
- [2nd, community site] Claims a native (non-WebView2) Widgets board uses about a third of the memory, without a measurement; notes Dev Home's retirement removed the built-in CPU/GPU widgets. — [xakpc.dev](https://xakpc.dev/windows-widgets/what-are-windows-widgets/)
- [2nd, search snippet] A reviewer argued that developers do not value making widgets for Windows 11. — [TWiT](https://twit.tv/posts/tech/windows-11-widgets-update-how-new-experience-makes-your-desktop-less-annoying)

### Inferences
- Microsoft acknowledging users who "barely engage" and capping alerts suggests modest engagement, but that is a reading of tone, not data.
- The platform looks maintained but not expanding for developers outside the EEA: the worldwide rendering contract is unchanged since 2022-2023 (Adaptive Cards), and the richer options (HTML widgets, feeds) remain regulatory, EEA-only features.

### Gaps
- No daily/monthly active usage numbers, no count of Store apps shipping widgets, and no Microsoft roadmap statement about third-party widgets were found.

## 8. Signs of official desktop widgets

### Takeaway
No evidence was found of Microsoft shipping or testing widgets that sit on the desktop in any Windows 11 Insider build through November 2026. The closest things are the 2023 "pin the board open" experiment and the 2025-2026 multi-dashboard board.

### Cited Findings
- [MS, 2025-11-04] Build 27982 introduces multiple dashboards and a navigation bar inside the Widgets Board; no desktop placement is described. — [Announcing Build 27982](http://blogs.windows.com/windows-insider/2025/11/04/announcing-windows-11-insider-preview-build-27982-canary-channel/)
- [MS, 2026-06-12] The 2026 Widgets changes are about defaults, badges, settings and memory; no desktop surface. — [Build 26220.8680 release notes](https://learn.microsoft.com/en-us/windows-insider/release-notes/beta/preview-build-26220-8680)
- [MS] The docs define the Widgets Board as the built-in widget host and speak of "other hosts" only generically ("Other hosts must also support the interface"). — [Widget providers](https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-providers)
- [2nd, search snippet] Build 23521 (2023) "Pin" button keeps the board open while switching apps. — [Pureinfotech](https://pureinfotech.com/enable-new-widgets-pin-windows-11/)
- [2nd, search snippet] Pureinfotech's summary of build 27982 was phrased by the search tool as a dashboard "in the Desktop"; Microsoft's own post does not say that, so this is treated as a wording artifact. — [Pureinfotech build 27982](https://pureinfotech.com/build-27982-windows-11/)

### Inferences
- Desktop-placed widgets on Windows remain the territory of third-party hosts; an app wanting true desktop widgets must draw its own windows rather than use the official platform.

### Gaps
- Absence of evidence only: searches were limited, and hidden/experimental features in Experimental-channel builds (e.g. 26300.x) were not exhaustively checked. No "Windows 12" widget information was found.
