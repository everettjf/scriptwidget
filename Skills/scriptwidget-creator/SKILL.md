---
name: scriptwidget-creator
description: Create or edit ScriptWidget JavaScript/JSX widget packages, validate them with the ScriptWidget CLI, and inspect native preview images. Use for ScriptWidget widgets and package fixes; not for React web apps or other widget frameworks.
---

# Author ScriptWidget packages

Use the user's Coding Agent and model. ScriptWidget supplies the runtime contract and verification tools; this skill does not grant permissions, install dependencies or connect accounts.

## Before editing

Read [authoring](references/authoring.md) for the JSX dialect and a working starting point. For a specific tag or API, search [runtime API](references/runtime-api.md); read only the relevant section. Read [package format](references/package-format.md) when changing manifests, permissions, imports or resources. The included references target runtime API 1.6.

Keep work in a separate package directory. Preserve the user's existing files and package identity when editing. Prefer `widget.json` and `main.jsx` for new work. Never replace an invalid present manifest with a legacy package.

## Target systems

One package installs on iPhone, iPad, Mac, Android, Windows and Linux, but not every API has something behind it on every system. Before using a data API, read [platform support](references/platform-support.md) and compare its row with the systems the user named; when they named none, ask, or assume all of them and say so.

- `$device`, `$system`, `$storage`, `$file`, `fetch`, `$http`, `$xml`, `$dataSource` and `$weather` work on all five. Health, location, music and alarms are not on Mac; no personal-data API (calendar, photos, health, location, music and the like) is on Windows or Linux; reminders and Home are Apple only.
- An API a system lacks answers `false` from `isAvailable()` and rejects with `[unsupported_platform]`. Check `isAvailable()` first and render a real fallback card. Branch on `$system.platform()` only for what cannot be feature-detected.
- Tell the user which systems the finished widget shows real data on. Do not describe a widget that needs `$health` as working on Windows or Linux.
- Android, Windows and Linux draw text in Inter, which is wider than Apple's system font, and cut text that does not fit. Leave room: short labels, and a layout for each declared family chosen with `$getenv("widget-size")`, not one layout scaled down. A render on the Mac does not show the other systems' text widths.
- Lock Screen families, Live Activities, Control Widgets and `backgroundMaterial` are system-specific; the same page lists them.

The steps below use the Mac command line. The Linux app installs a command of the same name with its own options (`check`, `run`, `render --output`, `pack`; no Web Studio handoff): read `scriptwidget --help` there instead of assuming the Mac flags. Windows installs no command line.

## Generate, check, preview, repair

1. Discover `scriptwidget --version --format json` and `scriptwidget doctor --format json`. Use CLI 0.2.x/report v1 for browser handoff. If unavailable, explain the dependency and provide the documented Homebrew command; do not install without the user's authorization.
2. Create or modify the package using native ScriptWidget JSX and documented APIs. Use package-relative resources, minimum permissions and declared network domains. Do not embed credentials or assume access to real system data.
3. Run `scriptwidget check PACKAGE --format json`. Read the diagnostics; fix actual errors before rendering. A successful static check is not an execution result.
4. When the user requests a browser preview, run `scriptwidget preview PACKAGE --format json`. This validates and packs a snapshot, then opens Web Studio with the widget automatically loaded as a new project. Use `--no-open` only when browser launching is unavailable or the user requests a link. Do not log/share the returned URL beyond the requested local workflow: it contains source/resources. Browser import clears the fragment and does not overwrite existing projects. A launched browser is not proof the preview rendered; inspect it when browser tools are available. Links are limited to 45,000 compressed package bytes; report `preview.link_limit` and offer native rendering or explicit .swt import for larger packages. Do not silently discard resources or upload to a server.
5. For native macOS verification, run `scriptwidget render PACKAGE --family medium --appearance both --output OUTPUT --format json`, choosing a declared small/medium/large family. OUTPUT must be outside PACKAGE. Optional mock data uses `--fixtures fixtures.json`.
6. Read the current report and inspect both PNGs when image viewing is available. Check labels, values, clipping, contrast, density and requested behavior. Verify source hashes and artifact paths belong to the latest run. Never use a previous successful screenshot after a failed edit.
7. Repair and rerun the affected checks. Stop after three unsuccessful repair attempts and explain the remaining concrete error; do not weaken runtime limits or hide warnings to make a result pass.
8. Once the requested behavior is reviewed, run `scriptwidget pack PACKAGE --output OUTPUT/Widget.swt --format json` if the user wants an installable package. Packing does not install or modify App data. Let the user import it through the existing ScriptWidget app.

The CLI runs locally without the App, Node or Chrome, and uses offline mocks for system/network APIs. Real authorization, server availability, persistent real records and WidgetKit behavior require separate acceptance. The native PNG is a macOS SwiftUI snapshot, not a certificate of iPhone or desktop WidgetKit correctness.

## Interpret results precisely

Read [CLI behavior and mocks](references/cli.md). Distinguish package/compile/execute/render/export; `notRun` is not passed. Keep warnings and known unsupported APIs visible. Native CLI currently accepts `api`, `fetch` and string-valued `storage` fixtures. Data Source Plugin execution and browser-specific fixture sections are explicitly unsupported; report this instead of inventing a success.

When the model cannot view images, report that limitation and give the user the preview paths. When using the Web Studio instead, label it a browser approximation with mock data. It is available at https://asp.run/scriptwidget/studio/ and does not require uploading code to an execution server.
