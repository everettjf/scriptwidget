# Windows desktop-widget competitors and market (state of 16 November 2026)

Method notes for the report writer:
- "GitHub API, 2026-11-16" = read directly from `api.github.com` on that day (stars, licence, last push, release-asset download counts). Download totals cover only the latest 100 releases of each repository and count GitHub release assets only (not Store, winget mirrors or own-site downloads).
- "Store API, 2026-11-16" = read directly from the public `apps.microsoft.com` product endpoints, US market. Rating counts may be market-specific.
- "Steam API / SteamSpy, 2026-11-16" = read directly from `store.steampowered.com/api/appdetails` and `steamspy.com/api.php`. SteamSpy owner ranges are estimates.
- "search summary" = the figure came from a web-search result summary of the linked page; the page itself was not opened in full. Treat as secondary.

## 1. Which products matter today?

### Takeaway
The Windows widget space is crowded but split into three camps that barely overlap: (a) the legacy skin engine Rainmeter (INI/Lua, native plugins, no sandbox, by far the largest installed base), (b) closed, non-scriptable "ready-made widgets" Store apps (Widget Launcher, BeWidgets, Smart Widgets, and the fast-growing open-source DeskBox), and (c) web-tech shells for tinkerers (Seelen UI, Zebar, YASB) where a widget is an unrestricted or lightly restricted web page / Python config. None of them offers a per-widget permission model comparable to a declared-capability manifest, and none of the big ones lets a normal user write a small script and share it safely.

### Cited Findings

#### Comparison table (all figures 2026-11-16 unless dated otherwise)

| Product | What it is | Authoring | Sandbox / permissions | Licence / price | Channel | Audience indicators |
|---|---|---|---|---|---|---|
| Rainmeter | Desktop skin/meter engine, since 2001 | INI skins, Lua scripts, native C++/C# plugin DLLs, `.rmskin` packages | None. Skins can run commands; plugins are native DLLs | GPL-2.0, free | GitHub, rainmeter.net | 6,153 stars; 75.66M release-asset downloads over the latest 100 releases; 4.5.28 stable 2026-10-12, 5.0.0 pre-release 2026-11-15 |
| Seelen UI | Full desktop environment replacement (dock, toolbar, tiling WM, widgets, wallpapers) | Web tech in Tauri/WebView2; themes (CSS), widgets and plugins as "resources" | Not documented as a per-widget permission model (gap) | AGPL-3.0, free; optional "Seelen Sky" subscription | Microsoft Store (recommended), GitHub | 18,529 stars; 3.97M GitHub release downloads (latest 100 releases); Store 4.5 avg / 660 ratings (US) |
| Zebar (glzr-io) | Toolkit for taskbars, desktop widgets, popups | HTML/CSS/JS in native webviews; React buildless template; `zpack.json` pack manifest | Partial: release notes mention per-widget "permissions" for some window APIs; README documents no general permission model | GPL-3.0, free | GitHub, in-app marketplace | 3,126 stars; 90,875 downloads; v3.3.1 2026-03-16; Windows, macOS, Linux |
| GlazeWM | i3-style tiling WM (Windows, macOS since v3.10) that Zebar ships alongside | YAML config | n/a | GPL-3.0, free | GitHub | 13,003 stars; 395,032 downloads; v3.10.1 2026-03-21 |
| YASB (amnweb) | Status bar with widgets | YAML config + CSS styling; widgets are Python classes inside the app | None described | MIT, free | GitHub, winget | 5,804 stars; 517,606 downloads; v2.0.8 2026-11-07 |
| komorebi | Tiling WM commonly paired with YASB/Zebar | JSON config; own bar | n/a | Custom "Komorebi License 2.0.0" (not OSI) | GitHub | 15,383 stars |
| Lively Wallpaper | Animated/interactive wallpapers, including web pages | Video, HTML/JS web pages (with a `LivelyProperties.json` for settings), shaders | Web wallpapers run in an embedded browser; no declared-permission model found (gap) | GPL-3.0, free (Store listing shows in-app purchases) | Microsoft Store, GitHub | 20,125 stars; 22.38M GitHub downloads; Store 4.6 avg / 19,230 ratings (US); last GitHub release v2.2.1.0 2025-09-18 |
| Wallpaper Engine | Paid live-wallpaper engine with Steam Workshop; supports web (HTML/JS) wallpapers and has a free Android companion app | Scene editor, video, web (HTML/JS), application wallpapers | Not established in this research (gap) | Proprietary, US$4.99 | Steam | SteamSpy: 20M-50M owners (estimate), 932,961 positive / 23,477 negative reviews, 108,471 concurrent at query time |
| Widget Launcher | Ready-made widgets pinned to desktop (clock, weather, RSS, CPU, notes...) | Not user-scriptable; "extensions"/skins from the Store | Store-packaged app | Proprietary, free with in-app purchases | Microsoft Store | Store 4.5 avg / 5,262 ratings (US); listed since 2013-10-09, updated 2026-06-12 |
| BeWidgets | Ready-made customisable desktop widgets | Not user-scriptable | Store-packaged app | Proprietary, free with in-app purchases | Microsoft Store | Store 4.4 avg / 1,788 ratings (US); released 2021-09-30, updated 2026-11-13 |
| Smart Widgets | Ready-made widgets | Not user-scriptable | Store-packaged app | Free with in-app purchases | Microsoft Store | Store 4.5 avg / 965 ratings (US); released 2024-01-24 |
| Widgets - Desktop Gadgets (Retro Gameplay) | Gadget-style widgets | Not user-scriptable | Store-packaged app | Free | Microsoft Store | Store 4.3 avg / 1,648 ratings (US) in about 16 months (released 2025-07-22) |
| Widget Pro (Good2Create) | Ready-made widgets | Not user-scriptable | Store-packaged app | Free with in-app purchases | Microsoft Store | Store 3.8 avg / 99 ratings (US) |
| DeskBox (2026 newcomer) | Desktop organiser with native WinUI 3 widgets (files, todo, weather, music...) | Built-in widgets only; no plugin SDK; external PRs not merged | No sandbox described | GPL-3.0 (earlier versions MIT), free | GitHub, deskbox.fun, possibly Store | 9,237 stars after about 5 months (created 2026-06-11) |
| GadgetPack (formerly 8GadgetPack) | Restores Vista/7 sidebar gadgets on Windows 10/11 | Legacy gadget format (HTML/JScript in `.gadget`) | None (the reason Microsoft retired gadgets) | Freeware | gadgetpack.net, winget | v42.0 released 2026-05-11; no download figure found |
| XWidget | Widget engine with visual editor and online gallery | Visual editor + scripting | Unknown | Freemium, pay-once Pro | xwidget.com, Steam | Listed as discontinued, latest 1.9.28 (Oct 2022) by AlternativeTo; conflicting signals |
| PowerToys Command Palette Dock | Optional second "taskbar" with pinned extension widgets | Command Palette extensions (C#/.NET API) | Extension model, not a script sandbox | MIT, free | Store, GitHub, winget | PowerToys repo 141,075 stars |
| Infinite Widgets | Paid widget builder on Steam, no-code editor plus JS and Lua | JS (web widgets), Lua, no-code | Unknown | Proprietary, US$3.99 | Steam | SteamSpy owners 0-20,000 (estimate), 10 positive / 2 negative reviews |
| widget-js/widgets | React-based desktop widgets for Windows | React/TypeScript | Unknown | No licence file detected | GitHub | 740 stars |
| WinWidgets (beyluta) | HTML/CSS/JS desktop widgets | HTML/CSS/JS in Chromium | None described | GPL-3.0 per GitHub API | GitHub | 168 stars |

#### Individual findings

- Rainmeter: 6,153 stars, GPL-2.0, C++, last push 2026-11-16; latest stable v4.5.28 (2026-10-12) and a 5.0.0 pre-release line (builds 2026-10-12 and 2026-11-15); 75,661,771 release-asset downloads across the latest 100 releases (GitHub API, 2026-11-16). — [rainmeter/rainmeter](https://github.com/rainmeter/rainmeter)
- Rainmeter skins are text and images, but skins that bundle plugins contain executable code, and a malicious plugin can run arbitrary code when loaded; some skin packages bundling executables or custom DLLs have been confirmed as malware (antivirus-vendor blog, search summary; treat as secondary). — [Gridinsoft](https://blog.gridinsoft.com/rainmeter-virus/)
- Seelen UI: 18,529 stars, AGPL-3.0, Rust, last push 2026-11-16, v2.8.11 released 2026-11-16; 3,973,509 release-asset downloads across the latest 100 releases (GitHub API, 2026-11-16). — [eythaann/Seelen-UI](https://github.com/eythaann/Seelen-UI)
- Seelen UI on the Microsoft Store: free, 4.5 average from 660 ratings, no in-app purchases flagged, listed 2024-04-11, updated 2026-11-16 (Store API, US, 2026-11-16). The README recommends the Store as the install channel (search summary). — [Microsoft Store: Seelen UI](https://apps.microsoft.com/detail/9p67c2d4t9fb)
- Seelen Sky is a subscription (monthly and annual plans; prices not shown on the page) with cloud sync of settings/themes/widget configurations, exclusive widgets (first one: "Better Clipboard"), exclusive themes, an ad-free website and priority support. — [seelen.io/sky](https://seelen.io/sky)
- Zebar: 3,126 stars, GPL-3.0, Rust, last push 2026-09-26, v3.3.1 2026-03-16, 90,875 release downloads (GitHub API, 2026-11-16). Widgets "consist of an HTML file, and any surrounding assets (e.g. CSS, JS, images, etc.)", run in native webviews, are grouped into packs defined by `zpack.json`, and can be installed from an in-app marketplace; downloads exist for Windows, macOS and Linux. The README does not describe a permission model. — [glzr-io/zebar](https://github.com/glzr-io/zebar)
- Zebar v3.2.0 (2026-01-23) release notes: "Add permissions for vibrancy and cursor events APIs on the Tauri window", i.e. some capability gating exists at the Tauri level (GitHub API release body). — [Zebar releases](https://github.com/glzr-io/zebar/releases)
- GlazeWM: 13,003 stars, GPL-3.0, 395,032 release downloads, v3.10.1 2026-03-21; repo description now says "tiling window manager for macOS and Windows" (GitHub API, 2026-11-16). — [glzr-io/glazewm](https://github.com/glzr-io/glazewm)
- YASB (amnweb fork, the active one): 5,804 stars, MIT licence file, Python, v2.0.8 2026-11-07, 517,606 release downloads; recent releases add built-in widgets (notifications, audio visualiser, "Codex Usage") rather than a third-party widget format (GitHub API, 2026-11-16). The original da-rth/yasb is archived at 1,578 stars. — [amnweb/yasb](https://github.com/amnweb/yasb)
- komorebi: 15,383 stars, custom "Komorebi License 2.0.0" (GitHub API, 2026-11-16). — [LGUG2Z/komorebi](https://github.com/LGUG2Z/komorebi)
- Lively Wallpaper: repository moved to `lively-community/lively`; 20,125 stars, GPL-3.0, last push 2026-09-30; 22,382,179 release downloads, of which 2,790,175 for the latest release v2.2.1.0 (2025-09-18) (GitHub API, 2026-11-16). — [lively-community/lively](https://github.com/rocksdanister/lively)
- Lively Wallpaper on the Microsoft Store: free, 4.6 average from 19,230 ratings, in-app purchases flagged, updated 2026-11-10 (Store API, US, 2026-11-16). — [Microsoft Store: Lively Wallpaper](https://apps.microsoft.com/detail/9ntm2qc6qws7)
- Wallpaper Engine: US$4.99, released from early access 16 Nov 2018 (Steam API, 2026-11-16). SteamSpy estimate: 20,000,000-50,000,000 owners, 932,961 positive and 23,477 negative reviews, 108,471 concurrent users at query time (SteamSpy API, 2026-11-16; estimate). — [SteamSpy: Wallpaper Engine](https://steamspy.com/app/431960)
- Wallpaper Engine's free Android companion app has roughly 9M+ installs and about 18K ratings (AppGoblin, third-party estimate, search summary). It imports the user's desktop wallpaper collection to the phone, a precedent for a desktop-to-phone companion in this category. — [AppGoblin](https://appgoblin.info/apps/io.wallpaperengine.weclient)
- Widget Launcher (Chan Software Solutions): free with in-app purchases, 4.5 average from 5,262 ratings, listed since 2013-10-09, updated 2026-06-12 (Store API, US, 2026-11-16). — [Microsoft Store: Widget Launcher](https://apps.microsoft.com/detail/9wzdncrdqfbt); a third-party blog instead reports "4.3 out of 5 from more than 17,600 ratings" (search summary, undated) — [TechDows](https://techdows.com/?p=35756). The two figures conflict; the Store API figure may be US-only.
- BeWidgets (BeXCool): free with in-app purchases, 4.4 average from 1,788 ratings, released 2021-09-30, updated 2026-11-13 (Store API, US, 2026-11-16). — [Microsoft Store: BeWidgets](https://apps.microsoft.com/detail/9nq07fg50h2q)
- Other Store "widgets on desktop" apps (Store API, US, 2026-11-16): Smart Widgets 4.5 / 965 ratings — [Store](https://apps.microsoft.com/detail/9p3vxwm0wht4); Widgets - Desktop Gadgets 4.3 / 1,648 ratings, released 2025-07-22 — [Store](https://apps.microsoft.com/detail/9nhnts78stqq); Widget Pro 3.8 / 99 ratings — [Store](https://apps.microsoft.com/detail/9nv0n2fwq00d); Desktop Gadgets (Chan Software) 3.8 / 116 ratings — [Store](https://apps.microsoft.com/detail/9p23v641rqml).
- DeskBox: "A free, open-source, local-first Windows desktop organizer with native-feeling WinUI 3 widgets"; C#, WinUI 3, .NET 10 Native AOT plus a Rust shell layer; no plugin SDK, and "External pull requests are not being merged at this time"; GPL-3.0 (earlier versions MIT). 9,237 stars, created 2026-06-11, last push 2026-11-10 (GitHub API, 2026-11-16). — [Tianyu199509/DeskBox](https://github.com/Tianyu199509/DeskBox)
- GadgetPack (formerly 8GadgetPack) is still maintained: v41.0 on 2026-03-30 and v42.0 on 2026-05-11 per the official changelog (search summary). — [gadgetpack.net changelog](https://mail.gadgetpack.net/changelog.html)
- XWidget: AlternativeTo lists it as discontinued with latest version 1.9.28 from October 2022, freemium with a pay-once Pro tier; a Steam listing also exists (search summary; status conflicting). — [AlternativeTo: XWidget](https://alternativeto.net/software/xwidget/about); [Steam: XWidget](https://store.steampowered.com/app/967130)
- PowerToys: 141,075 stars, MIT (GitHub API, 2026-11-16) — [microsoft/PowerToys](https://github.com/microsoft/PowerToys). PowerToys 0.98 (17 March 2026) introduced the Command Palette Dock as an optional mode with pinned extensions and a Performance Monitor extension bringing Dev Home-style performance widgets. — [Microsoft DevBlogs: PowerToys 0.98](https://devblogs.microsoft.com/commandline/powertoys-0-98-is-here-new-keyboard-manager-ux-the-command-palette-dock-and-better-cursorwrap/). 0.100 (9 June 2026) added pinning of individual metrics (CPU, memory, GPU, network, battery), per-monitor Dock layouts and an extension gallery (search summary). — [Microsoft DevBlogs: PowerToys 0.100](https://devblogs.microsoft.com/commandline/powertoys-0-100-is-here-new-shortcut-guide-command-palette-improvements-and-much-more/)
- Microsoft Dev Home (which hosted widgets for developers) is archived on GitHub; last push 2025-02-21 (GitHub API, 2026-11-16). — [microsoft/devhome](https://github.com/microsoft/devhome)
- Übersicht itself is macOS-only (5,021 stars, GPL-3.0, last push 2025-06-28; GitHub API, 2026-11-16) — [felixhageloh/uebersicht](https://github.com/felixhageloh/uebersicht). Windows tools with the same "widget = web page" idea: Zebar (above); WinWidgets, 168 stars — [beyluta/WinWidgets](https://github.com/beyluta/WinWidgets); widget-js, 740 stars, "Desktop widgets for windows. built with react" — [widget-js/widgets](https://github.com/widget-js/widgets); Wigify, "create and display custom HTML/CSS/JS widgets right on your desktop" — [AlternativeTo: Wigify](https://alternativeto.net/software/wigify); HTWind, 11 stars, created 2026-02-24 — [sametcn99/HTWind](https://github.com/sametcn99/HTWind).
- 2026 newcomers on GitHub (GitHub API, 2026-11-16): FullWidget, created 2026-11-02, 66 stars, "38 built-in widgets, themes, and an HTML/CSS/JS SDK" — [hmgvibe/FullWidget](https://github.com/hmgvibe/FullWidget); atrium-desktop, created 2026-10-31, 342 stars, native glass taskbar and widgets — [wynter-yaxley/atrium-desktop](https://github.com/wynter-yaxley/atrium-desktop); desk-widgets, created 2026-10-30, 41 stars, "Apple-style desktop widgets for Windows 11" — [whoissaaif/desk-widgets](https://github.com/whoissaaif/desk-widgets); themia, created 2026-04-04, 64 stars — [crazy-rabbit-software/themia](https://github.com/crazy-rabbit-software/themia); token-monitor, created 2026-05-19, 3,714 stars, a single-purpose AI-usage desktop widget — [Javis603/token-monitor](https://github.com/Javis603/token-monitor).
- 2026 newcomers on Steam, all unreleased as of 2026-11-16 (Steam API): "DeskDash: Desktop Widgets" (coming soon) — [Steam](https://store.steampowered.com/app/5385210); "Wisp: Desktop Widgets" (coming soon, "no coding needed", 850+ wallpapers) — [Steam](https://store.steampowered.com/app/5265790); "Widget Engine" (Q1 2027, "900+ live widgets ... Build your own from function blocks") — [Steam](https://store.steampowered.com/app/5325820).
- AlternativeTo's Rainmeter alternatives list also names MyDesktopWidget (with an experimental Rainmeter skin importer), DeskDash (community marketplace), OpenAnima (MIT, since 2026), XMeters and Widget Manager (AGPL) (search summary). — [AlternativeTo: Rainmeter alternatives](https://alternativeto.net/software/rainmeter/)

### Inferences
- The largest audiences sit with products that are not scriptable by ordinary users (Wallpaper Engine, Lively, Widget Launcher) or scriptable only in an unsafe way (Rainmeter). The "scriptable and safe" quadrant is empty among products with meaningful reach.
- DeskBox reaching about 9.2k stars in five months, three Steam widget apps queued for release, and several GitHub projects created in Oct-Nov 2026 indicate that demand for desktop widgets on Windows 11 is currently rising, and that new entrants are betting on polished ready-made widgets rather than on an authoring platform.
- The tiling-WM ecosystem (GlazeWM 13k, komorebi 15k, YASB 5.8k, Zebar 3.1k stars) is where the "write your widget in web tech" audience lives; it is technically sophisticated but small in absolute numbers (Zebar: about 91k release downloads in total).
- Rainmeter's 75.7M downloads figure is inflated by updates (each release is re-downloaded by existing users); it indicates a very large active base but is not a unique-user count.
- Agent-usage widgets (token-monitor at 3.7k stars, YASB's "Codex Usage" widget, quota-float) are a visible 2026 widget use case.

### Gaps
- Exact per-widget permission behaviour of Seelen UI, Lively and Wallpaper Engine web wallpapers was not verified from primary documentation.
- No download or user figure was found for GadgetPack, XWidget, BeWidgets, Widget Launcher or Smart Widgets beyond Store rating counts. The Microsoft Store does not publish install counts.
- Widget Launcher's rating count conflicts between the Store API (5,262, US) and a third-party blog (17,600+); not resolved.
- Seelen Sky prices and subscriber numbers are not published on the page read.
- Steam review totals from the official Steam reviews endpoint could not be retrieved (the endpoint returned an HTML page); SteamSpy's mirrored counts are used instead.
- Wigify, MyDesktopWidget, OpenAnima and Widget Manager were not checked individually for activity or audience.

## 2. Does any product run the same widget on Windows and on phones?

### Takeaway
No established product was found that runs one user-authored widget package on Windows and on iOS/Android home screens. The nearest things are a developer library (tauri-plugin-widgets, one JSON config rendered natively per platform for the developer's own app) and Wallpaper Engine's Android companion (wallpapers, not widgets); the scriptable mobile tools stay on their own platform.

### Cited Findings
- `tauri-plugin-widgets` (Tauri v2 plugin) declares one JSON widget config and renders it with SwiftUI on Apple platforms, Jetpack Glance on Android and HTML on desktop; desktop widget windows are frameless transparent Tauri webviews; its Windows integration also targets the Widgets Board via Adaptive Cards (search summary of the crate README). It is a library for app developers, not an end-user widget tool. — [docs.rs: tauri-plugin-widgets](https://docs.rs/tauri-plugin-widgets)
- Zebar is cross-platform only across desktops (Windows, macOS, Linux). — [glzr-io/zebar](https://github.com/glzr-io/zebar)
- Xenon (created 2026-04-30, 123 stars) describes "Free widgets for your PC on any screen: desktop, second monitor, tablet or phone", i.e. PC dashboards displayed on a phone screen rather than native phone widgets; Windows first, macOS and Linux in beta (GitHub API, 2026-11-16). — [marcimastro98/Xenon](https://github.com/marcimastro98/Xenon)
- Wallpaper Engine ships a free Android app that imports the user's desktop wallpaper collection to the phone (about 9M+ installs per AppGoblin, third-party estimate, search summary). — [AppGoblin](https://appgoblin.info/apps/io.wallpaperengine.weclient)
- Tauri 2 itself targets "desktop and mobile applications with a web frontend" (112,934 stars; GitHub API, 2026-11-16), which is the stack Seelen UI and Zebar build on, but neither project ships a mobile widget runtime. — [tauri-apps/tauri](https://github.com/tauri-apps/tauri)
- A web search for a write-once JavaScript widget spanning Windows desktop, iPhone and Android returned no mature product; the results were general app frameworks (Tabris.js, NativeScript) rather than widget tools. — [docs.rs: tauri-plugin-widgets README](https://docs.rs/crate/tauri-plugin-widgets/0.4.2/source/README.md)

### Inferences
- "The widget you write once also runs on your phone" appears to be an unoccupied position on Windows as of November 2026. The absence in search results is evidence of absence only for products with visible reach; small or non-English projects could exist.
- Wallpaper Engine's 9M+ Android installs against 20-50M estimated desktop owners suggests that a meaningful fraction of desktop-customisation users will install a phone companion when one exists.

### Gaps
- Scriptable (iOS), KWGT/KLWP (Android), Widgy (iOS) and Widgetsmith were not re-verified in this session; the statement that they are single-platform comes from the task brief and general knowledge, not from a source opened here.
- No source was found that explicitly surveys cross-device widget tools, so this conclusion rests on negative search results.

## 3. Demand signals

### Takeaway
Demand is visible in product traction (Rainmeter's tens of millions of downloads, Lively's 19k Store ratings, DeskBox's fast growth) and in Microsoft's own 2026 admission that the Widgets Board needed fixing; subreddit sizes can no longer be read publicly.

### Cited Findings
- Reddit removed public member counts from subreddit pages in September 2025, replacing them with 28-day visitor and 7-day contribution metrics (search summary). — [Tubefilter](https://www.tubefilter.com/2025/09/10/reddit-new-performance-metrics-member-count-visitors-contributions/amp/)
- Complaints about the Windows 11 Widgets Board: it opened when the cursor merely brushed the taskbar icon, the MSN news feed felt overwhelming, many called it bloatware, and third-party tools emerged solely to disable it (search summary across outlets). — [Windows Forum](https://windowsforum.com/news/windows-11-widgets-go-quieter-click-to-open-less-msn-discover.416611/); [Pureinfotech](https://pureinfotech.com/windows-11-widgets-remove-msn-feed/)
- Microsoft announced on 1 May 2026 a quieter Widgets experience: opening to user-selected widgets instead of the MSN feed, less hover-triggered opening, more meaningful taskbar badges; rolling out to Insiders with wider release expected in 2026. Sources differ on whether hover-to-open is removed or only made optional (search summary). — [windowsnews.ai](https://www.windowsnews.ai/article/windows-11-widgets-revamped-quiet-hover-custom-news-less-msn-clutter.416330); [TWiT](https://twit.tv/posts/tech/windows-11-widgets-update-how-new-experience-makes-your-desktop-less-annoying)
- Third-party widget supply for the official board is thin: Windows Central wrote that the selection of widgets for Windows 11 is poor and that developers evidently do not value making them (search summary; article undated in the result). — [Windows Central](https://www.windowscentral.com/microsoft/windows-11/microsoft-build-ignored-the-most-barren-part-of-windows-11-and-its-one-only-third-party-developers-can-fix)
- The official third-party widget route is a packaged Win32 or PWA app providing Adaptive Cards-based widgets through the Windows App SDK (1.2 and later). — [Windows Central](https://www.windowscentral.com/software-apps/windows-11/windows-11-preview-build-25217-rolls-out-with-support-for-third-party-widgets)
- Win11Debloat, a script whose features include removing/disabling Windows components such as widgets, has 63,057 stars (GitHub API, 2026-11-16), an indicator of dissatisfaction with defaults. — [Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat)
- Widgets pinned to the desktop is the feature press coverage highlights for Widget Launcher and BeWidgets ("what Windows 11 widgets should be"). — [Beebom](https://beebom.com/bewidgets-is-what-windows-11-widgets-should-be); [Windows Central](https://www.windowscentral.com/app-lets-you-add-customizable-widgets-windows-11-desktop)

### Inferences
- The recurring user request is "widgets on the desktop itself, without the news feed", which Microsoft's board does not provide; that is exactly the niche Store apps and DeskBox fill.
- Because official third-party widgets must be Adaptive Cards from a packaged app, a script-driven widget host could in principle also surface widgets in the official board, but nothing found shows users asking for that specifically.

### Gaps
- Current sizes of r/Rainmeter, r/desktops, r/Windows11 could not be obtained: Reddit's JSON endpoints refused the requests and public member counts were removed in 2025. No figure is given rather than quoting stale numbers from memory.
- No specific Reddit threads listing user wishes were opened; the complaint summary relies on tech-press reporting.
- Whether the redesigned Widgets Board reached general availability by November 2026 was not confirmed.

## 4. Market size context

### Takeaway
The addressable base is roughly a billion-plus Windows 11 devices (Microsoft, early 2026) out of 1.4-1.6 billion monthly active Windows devices; Windows 11 is about 70% of Windows per StatCounter. Hard data on PC-plus-phone combinations is old (2015, 2019, US only) but consistently says most iPhone owners use a Windows PC.

### Cited Findings
- Microsoft confirmed on its fiscal Q2 2026 earnings call that Windows 11 runs on more than a billion devices, reached in 1,576 days versus 1,706 for Windows 10. — [TechSpot](https://www.techspot.com/news/111114-windows-11-hits-one-billion-users-less-time.html)
- Microsoft said in a 24 June 2025 Windows Experience Blog post that Windows runs on more than 1.4 billion monthly active devices, and later clarified that an "over a billion" phrasing was not a decline. — [Windows Latest](https://www.windowslatest.com/2025/07/01/microsoft-confirms-windows-11-did-not-lose-400-million-monthly-active-pcs)
- A later statement attributed to Satya Nadella puts Windows at 1.6 billion monthly active devices (search summary; the exact call and date were not verified in the page). — [Windows Latest, 30 April 2026](https://www.windowslatest.com/2026/04/30/satya-nadella-admits-microsoft-needs-to-win-back-windows-11-fans-improve-performance-for-low-ram-pcs/)
- StatCounter-based reporting: Windows 11 at 69.92% of Windows desktop versions in June 2026, 68.93% in July 2026, and 71.5% of Windows installs in September 2026 (secondary reports, search summary; StatCounter revises its data). — [TechRadar](https://www.techradar.com/computing/windows/has-the-death-of-windows-10-finally-begun-windows-11s-popularity-is-suddenly-skyrocketing); [TechSpot forum: "Windows 11 hits 72% share"](https://www.techspot.com/community/topics/windows-11-hits-72-share-as-windows-10-fades-but-not-everyone-is-happy.296620/)
- US survey, 2015: 76% of iPhone owners owned a Windows PC and 28% a Mac; 94% of Android phone owners owned a Windows PC (search summary). — [MarketingProfs](https://marketingprofs.com/charts/2015/27235/how-loyal-are-consumers-to-apples-platform)
- US survey, 2019 (PCMag, 2,033 consumers): 63% of iOS users used Windows PCs and 34% used Macs (secondary citation, search summary). — [AskWonder research outline](https://start.askwonder.com/insights/apple-phone-consumers-use-windows-computers-xoa0ly0n6)
- Phone Link gained iPhone support in May 2023 (texts, calls, notifications over Bluetooth on Windows 11) with limits: no group iMessage and no sending photos or videos at launch. — [CNBC](https://www.cnbc.com/2023/05/15/microsoft-windows-update-allows-iphone-users-to-text.html)

### Inferences
- If the 2015/2019 US ratios still hold roughly, a majority of iPhone owners and a large majority of Android owners who have a PC have a Windows PC, so "Windows PC + phone" is the common case rather than a niche; this is an extrapolation from old US-only surveys.
- Phone Link shows Microsoft treats the Windows-plus-iPhone user as a real segment, but Phone Link offers nothing widget-related, so it is context rather than competition.

### Gaps
- No StatCounter figure for October 2026 was found, and StatCounter's own pages were not opened; all StatCounter numbers here are via press reports.
- Windows' share of all desktop operating systems in 2026 was not retrieved.
- No survey from 2023-2026 on phone/PC ownership combinations was found; no global data at all.
- No Phone Link usage figure was found.

## 5. Monetization

### Takeaway
Only Wallpaper Engine is known to make serious money (a one-time US$4.99 Steam purchase at a scale of tens of millions of owners); everything else is free open source living on donations, freemium Store apps with in-app purchases, or, in Seelen UI's case, a new optional subscription. No revenue figure was found for any widget product.

### Cited Findings
- Wallpaper Engine sells for US$4.99 on Steam (Steam API, 2026-11-16) with an estimated 20M-50M owners (SteamSpy, estimate). — [SteamSpy](https://steamspy.com/app/431960)
- Third-party revenue estimates for Wallpaper Engine conflict: GameSensor lists about US$117M gross / US$70M net and 30.4M copies; VaporLens estimates about 50.15M sales and about US$250M revenue (both are model-based estimates, search summary; the developer publishes no figures). — [GameSensor](https://gamesensor.info/app/431960); [VaporLens](https://vaporlens.app/app/431960/wallpaper_engine/stats/details)
- Seelen UI is free and AGPL; it takes donations (Ko-fi, Buy Me a Coffee; search summary) and sells the Seelen Sky subscription (cloud sync, exclusive widgets and themes, ad-free site, priority support). Its website carries ads for non-subscribers, implied by "No ads across the website" as a Sky benefit. — [seelen.io/sky](https://seelen.io/sky); [eythaann/Seelen-UI](https://github.com/eythaann/Seelen-UI)
- Widget Launcher, BeWidgets, Smart Widgets, Widget Pro and Lively Wallpaper are free on the Microsoft Store with in-app purchases flagged (Store API, US, 2026-11-16). For Widget Launcher, some add-ons are paid (search summary). — [Microsoft Store: Widget Launcher](https://apps.microsoft.com/detail/9wzdncrdqfbt); [TechDows](https://techdows.com/?p=35756)
- Infinite Widgets (paid widget builder with JS/Lua and a no-code editor) costs US$3.99 on Steam, released 30 Sep 2024, and has reached only the lowest SteamSpy bracket (0-20,000 owners; 10 positive / 2 negative reviews) (Steam API and SteamSpy, 2026-11-16; estimate). — [Steam: Infinite Widgets](https://store.steampowered.com/app/1743370)
- XWidget uses a freemium model with a pay-once Pro tier (search summary). — [AlternativeTo: XWidget](https://alternativeto.net/software/xwidget/about)
- Rainmeter, Zebar, GlazeWM, YASB, DeskBox and PowerToys are free under open-source licences (GitHub API, 2026-11-16). — [rainmeter/rainmeter](https://github.com/rainmeter/rainmeter); [amnweb/yasb](https://github.com/amnweb/yasb); [Tianyu199509/DeskBox](https://github.com/Tianyu199509/DeskBox)
- komorebi uses a custom non-OSI "Komorebi License" (GitHub API licence file, 2026-11-16), a monetisation-adjacent choice in the same ecosystem. — [LGUG2Z/komorebi](https://github.com/LGUG2Z/komorebi)

### Inferences
- The paid-up-front model has worked once, at very large scale and low price, on Steam with a Workshop (Wallpaper Engine). A paid scriptable widget builder on Steam without that scale (Infinite Widgets) has barely sold, so "paid authoring tool" alone is weak; three more Steam widget apps launching in 2026-2027 will test the channel again.
- The prevailing Store pattern is free app plus in-app purchases for extra widgets/skins; the prevailing open-source pattern is donations, with Seelen UI the first notable move to a subscription for sync and exclusive content.
- User expectation in this category is "free"; a Windows version of a cross-platform widget app would more plausibly monetise through the existing mobile apps or optional extras than through a Windows price tag.

### Gaps
- No verified revenue or sales figure exists for any product here; Wallpaper Engine numbers are third-party estimates that disagree by a factor of about two.
- Prices of in-app purchases for Widget Launcher, BeWidgets and Smart Widgets, and of Seelen Sky, were not retrieved.
- Donation income for Rainmeter, Lively, YASB, Zebar/GlazeWM is not published in any source found.
