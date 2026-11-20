# ScriptWidget for Windows: what was tested

Every entry says what ran, on which machine, and what the result was. A check that did not run is listed as not run; it is never described as passing.

## Machines

| Name | System | Notes |
| --- | --- | --- |
| Dev PC | Windows 11 Home build 26200, x64, one 3840×2160 display at 150% | Visual Studio 2026 (MSVC 14.51), Windows SDK 26100, .NET SDK 10.0.401, Node 26.13.1, Developer Mode on |
| CI x64 | GitHub Actions `windows-2025` (Windows Server 2025), x64 | `.github/workflows/windows.yml` |
| CI ARM64 | GitHub Actions `windows-11-arm` (Windows 11, ARM64) | Same workflow, job "Build and test (ARM64)" |

ARM64 runs on the CI ARM64 machine only; no ARM64 PC was available to a person, and the MSVC ARM64 tools are not installed on the Dev PC.

## 2026-11-19, Windows alignment work (Dev PC, in progress)

Windows 11 build 26200 x64, .NET SDK 10.0.401, Node 26.13.1. These are local working-tree results, not a published release or CI certification.

| Check | Result / evidence |
| --- | --- |
| Shared JavaScript and native engine | `node Windows/scripts/build-shared-js.mjs` and `powershell -NoProfile -File Windows/scripts/build-native.ps1 -Arch x64` passed. |
| Baseline Core suite | 239 passed, 0 failed or skipped before changes. |
| Release Core suite after template/diagnostic/animation changes | 260 passed, 0 failed or skipped; `Windows/artifacts/test-results/release.trx`. Later Skills changes require another complete run. |
| New animation tests | 12 passed: clock zones and DST, signed/custom periods, swing axes, draw order, rounded corners, moving click regions, GIF loop/budgets, static layouts. `Windows/artifacts/test-results/animation.trx`. |
| Skills store tests | 25 passed: built-ins, persistent selection, replacement rollback, schema/UTF-8/duplicate keys, size limits, disk tampering, links, ZIP round trip and traversal/device names. `Windows/artifacts/test-results/skills.trx`. CLI and Studio acceptance are separate and still in progress. |
| Solution build | `dotnet build Windows/ScriptWidget.slnx -c Debug -p:Platform=x64 --nologo -v minimal` passed with 0 warnings and 0 errors after the Skills page was added. |
| Desktop checks | Extended `Windows/scripts/desktop-check.ps1` passed with the Debug host. `Windows/artifacts/desktop-animation.log` and `Windows/artifacts/checks-20261119-desktop-animation/` contain the output and captures. Six animation captures change, package storage proves one script run across ticks; posted lock/unlock messages pause/resume playback; removing the widget removes its window. The scratch settings disable full-screen pausing so a foreground program cannot idle this test. This does not test real sign-out, physical sleep, or full-screen pausing. |
| Studio visual inspection | Computer Use opened the Debug Studio and inspected the English library and templates pages. Native preview cards render correctly. This was before the Skills page; it does not verify the new page. |
| Cross-platform release gate | `SCRIPTWIDGET_SKIP_XCODE=1 sh Scripts/release-readiness.sh` passed under Git Bash. Includes metadata, Gallery synchronization, editor tests/release, preview-engine and Web Studio suites/builds, browser smokes, GIF and animation smokes; log: `Windows/artifacts/release-readiness.log`. Apple/Xcode checks explicitly skipped. |

During the release gate, `validate-release.mjs` first constructed `D:\D:\...` from a file URL, then matched itself as a legacy-editor reference because a relative Windows path used backslashes. Both platform-path errors were fixed; the complete non-Xcode gate then passed. The editor dependencies were installed with `npm ci` before rerunning.

The first animation desktop fixture used nonexistent `$storage.get/set` methods; it was corrected to the documented `getString/setString` API and an explicit `storage` manifest permission. Another fixture revision wrote a UTF-8 BOM in JSON, correctly refused by the manifest reader; fixture files now use UTF-8 without a BOM. With the foreground-busy pause explicitly disabled in scratch data, the final desktop run passed. None of these failed attempts is counted as a passing check.

Still unverified for this working tree: AOT/package/installer acceptance, real ARM64 hardware, mixed-DPI displays, real login/logout, Store certification and Store-signed installation, and the remaining AI/Gallery features. Generated artifacts and test captures stay ignored.

## 2026-11-20, creation tools and desktop animation (Dev PC, in progress)

These results supersede the incomplete rows above. Windows 11 build 26200 x64, .NET SDK 10.0.401, Node 26.13.1; all changes are local and uncommitted. No release was published or Store submission changed.

| Check | Result / local evidence |
| --- | --- |
| Complete Core regression | **375 passed, 0 failed/skipped** after durable manual-edit reconciliation; `Windows/artifacts/test-results/windows-reconciled.trx` and `windows-reconciled-tests.log`. Previous complete runs passed 363, then 369 cases as coverage was added. |
| AI deterministic coverage | 40 initial client/core cases and 11 conversation/runner cases: Anthropic/OpenAI request separation; streaming UTF-8/SSE and plain fallback; cancellation, bounds, redirects/auth refusal; secret echo redaction; exact edits/diffs; JSX/frame validation; four attempts with actual QuickJS and Win2D trial rendering; failed turns preserve versions; retry/fork/manual edits; saved interrupted requests; archive apply preserves files/identity/permissions. Additional persistence cases reject field-type tampering and cycles, and exercise actual symbolic links/linked directories and poisoned fixed temporary paths. |
| Windows credentials | A unique synthetic test resource passed PasswordVault set/get/remove. The owner's DeepSeek key was entered without echo through `ai key set --stdin` and stored in Windows Credential Locker. Neither its value nor credentials appear in checked-in files or test fixtures. Provider metadata contains no key field. |
| Real DeepSeek | Model listing succeeded. `deepseek-flash` generated an offline FOCUS TODAY card, then changed only its accent and task count in a second turn. Both passed the local compile/execute/draw gate on attempt 1. Apply, fork and small/medium/large renders succeeded. A separate existing widget first failed with `ReferenceError: missingTaskCount is not defined`; real generation repaired it and the saved package rendered successfully. These are repair requests for existing code; no automatic retry was needed in these live calls. Automatic repair was separately tested with scripted responses and real local execution. Evidence root is recorded in `Windows/artifacts/ai-live-path.txt`; result JSON, source and PNGs remain ignored. The medium focus PNG was visually inspected. |
| Skills acceptance | 25 store tests passed. Real CLI list/show/import/export/enable/disable/remove round trip succeeded in isolated data. Studio showed all five built-ins; Responsive Layout instructions were read-only, export was available and builtin removal disabled. No user-owned Skill was removed. |
| Gallery acceptance | 27 tests passed, including trust/path/hash/byte/origin refusals, offline cache, replacement identity/rollback and user-owned Skill protection. Live CLI loaded 25 items, installed a verified Hello Card and privacy-review Skill into scratch data; Hello Card executed. Studio loaded the real catalog and item details. |
| Studio builds | Current Debug and Release solution builds passed with 0 warnings and 0 errors. The full Core test compilation reports the existing xUnit1031 warning in `PainterTests.PngKeepsStraightColorsOfTranslucentPixels`; no test was skipped. |
| AI UI acceptance | Editor panel, standalone assistant and provider settings compile. Computer Use found their accessibility controls, but the screenshot showed the Windows lock screen; input stopped and desktop unlock was requested. A subsequent read-only WTS session-flags query confirmed it was still locked. The application's existing `--page ai --screenshot` export rendered an isolated synthetic conversation: `Windows/artifacts/ai-conversation-native.png`. The inspected body shows versions, the manual-edit record, readable history, tabs, request field and action buttons without overflow. The native export omits the composition-backed navigation area and is not a final product screenshot. Generation/send/cancel/version/apply and settings **interaction** acceptance are not yet passed. Earlier Gallery/Skills inspection was performed while unlocked. |
| Reopened AI conversations and external edits | A static check found that the panel's in-memory source snapshot could miss edits made between sessions. Conversations now persist an optional SHA-256 fingerprint of the last observed installed entry, separate from their selected draft. Six regressions cover reopen, legacy files, version pruning, forks, strict fingerprint parsing and the actual runner prompt. The real DeepSeek CLI test kept an unapplied FOCUS DRAFT version, refused Apply after the installed source was manually changed to MANUAL FOCUS, continued from that manual code, changed 45 to 50 minutes, and applied/rendered it. Four versions and one manual turn remained; the old draft was preserved. Evidence: `reconcile-acceptance.json`, `reconcile-final-state.json` and `reconciled-medium.png` under the isolated live-test root; the PNG was inspected. Release solution rebuild passed with 0 warnings/errors (`reconcile-build.log`). |
| Release gate | Latest `SCRIPTWIDGET_SKIP_XCODE=1 bash Scripts/release-readiness.sh` completed successfully after reconciliation changes, including editor release/reproducibility, preview-engine/Web Studio suites/builds, browser layout/persistence/material/wallpaper tests, GIF and animation smokes; `Windows/artifacts/release-readiness-reconciled.log`. This direct rerun used the actual Git index; rebuilt editor bundles are unchanged. Apple/Xcode explicitly skipped. |
| Local packaging | `powershell -NoProfile -File Windows/scripts/package.ps1 -Arch x64 -Version 0.1.1.0` succeeded, including native rebuild, AOT host and self-contained Studio, producing a local test MSIX. `Windows/artifacts/package-reconciled.log` is the successful rebuild including the durable manual-edit fix and final UI/first-frame hit-region fixes. It emitted the existing four QuickJS C4098 wrapper warnings. This is not a signed release or Store install. |
| AOT desktop check and resource sample | AOT host passed the extended desktop check with `-AnimationStressSeconds 30`; `Windows/artifacts/desktop-aot-final.log`, `checks-aot-final/animation-performance.json`. Actual window pixels changed without rerunning package code. Over 30.13 seconds the entire scratch host used 1.84 CPU seconds (6.12% of one core); private memory was 141.21 MiB after warm-up, 143.26 MiB at the end, peak 160.38 MiB; handles went from 705 to 689. This short sample is not a long-duration leak test. The latest rebuilt AOT host also passes the separate GIF-only playback, removal and full desktop rerun: `Windows/artifacts/desktop-aot-reconciled.log`, `checks-aot-reconciled/`. Posted lock/unlock, click/action, drag, display/theme/time events and clean quit pass; these do not represent physical sleep or real sign-in. |
| Current installer acceptance | `powershell -NoProfile -File Windows/scripts/installer-check.ps1 -Installer Windows/artifacts/ScriptWidget-0.1.1-x64-setup.exe -Output Windows/artifacts/installer-reconciled-check` passed all checks after the latest rebuild. First install, installed host/Studio startup and native Studio capture, version/path/file association, update over a running host with graceful shutdown, uninstall, unrelated-file preservation, startup cleanup and scratch-widget preservation all passed. `Windows/artifacts/installer-reconciled-check.log` records results. The pre-existing `.swt` registry subtree was exported before and after and is byte-identical; original user data was not the test data. Installer UI pages were not clicked or visually reviewed. |

NSIS was absent. A Chocolatey install failed because this process cannot write the system Chocolatey directory; no elevation was attempted. Official NSIS 3.13 portable ZIP was downloaded to ignored `Windows/artifacts/tools`, validated as a ZIP and used to build the local installer. The latest installer is 53,979,708 bytes, SHA-256 `5ff1d7266c46df285be7305c83cbbf90a5b46716931854f36ea4f11d58dc578d`. Its MSIX sibling is 79,148,631 bytes. Version 0.1.1 here is a local test build override; no tag, commit, upload or release was made.

The first independent GIF desktop fixture omitted required `supportedFamilies`; the manifest validator correctly refused installation. Adding `systemSmall` fixed the fixture, and the complete desktop rerun then passed. The failed fixture run is retained as `desktop-aot-current.log`, not counted as passing. The user-data host was gracefully stopped for isolated desktop/installer checks and restarted afterwards; no user package or stored AI credential was removed.

Remaining environment checks: unlock the desktop for new AI UI interaction/screenshots; real ARM64 hardware, mixed-DPI displays, actual sign-out/sign-in, physical sleep/Explorer restoration for this new build, a clean machine without development tools, Microsoft certification and Store-signed installation. The owner-only Simplified Chinese Store listing change remains untouched.

## 2026-11-20 additional work while the desktop was locked

The owner requested failure recovery, repeatable CLI acceptance, a multi-widget stress run and publication drafts. Thirty minutes is the agreed stress-test standard; the existing completed run is sufficient and is not extended to 60 minutes. All work below ran on the same Dev PC without unlocking or sending real pointer/keyboard input.

| Work | Evidence and result |
| --- | --- |
| Publication recovery | `AiPublication.Complete` updates the conversation's in-memory package binding and always notifies the editor/host after a widget has been published, even if conversation persistence fails. Studio shows an explicit applied-but-unsaved warning; the CLI returns `ok: true` with `conversationSaved: false` and the actual saved widget name. A real read-only conversation file in CLI acceptance reproduced that partial failure and verified the saved source remained available. |
| Provider/key recovery | `AiProfileManager` compensates credential writes/removals when metadata cannot be saved, handles partially failed vault operations, refuses stale profile edits and requires a newly entered key plus a separate vault identity for a changed endpoint. A committed endpoint change with failed old-key cleanup is reported as a warning. Fourteen new tests pass, including compensation against a unique real Windows PasswordVault resource; no owner credential was modified. `Windows/artifacts/test-results/ai-recovery.trx`. |
| Complete Core regression | **389 passed, 0 failed/skipped**; `Windows/artifacts/test-results/windows-advance.trx` and `windows-advance-tests.log`. |
| Repeatable CLI acceptance | Added `Windows/scripts/creation-check.ps1` and [its instructions](creation-validation.md). Final offline run: **41 checks pass** (`creation-recovery.log`). Final real Gallery/DeepSeek run: **60 checks pass**, including deliberate source failure/repair and terminating its own test CLI after a durable running turn, then reading it as interrupted in another process (`creation-services-final.log`). Roots are recorded in `creation-recovery-path.txt` and `creation-services-final-path.txt`. Credentials are read through the existing active profile and never supplied as command-line arguments or written into these fixtures. |
| CLI defect found by acceptance | `AiCommands.cs` lacked the Core JSON extension import: its array `Append` calls silently selected LINQ's non-mutating operation, making `ai list` and `ai profiles` return empty arrays. The import is fixed and the process-level script now asserts actual nonempty results. The harness initially also assumed `pack` returned JSON; it now handles its documented path output separately. Failed exploratory runs are not counted as passing. |
| CI configuration | Offline creation acceptance and synthetic result artifacts were added to the x64 and native ARM64 workflow jobs. These workflow edits have not been pushed or run remotely; they do not prove current ARM64 execution. `list --data` and `install --data` now support isolated library acceptance and suppress desktop notifications for an explicit data folder. |
| Long stress phase | **1,800.40 seconds** with four widgets each playing a GIF and native swing, alongside the desktop check's baseline widgets. All four windows remained; the script counter stayed at four, proving animation ticks did not rerun their code. The whole scratch host used **393.72 CPU seconds**, averaging **21.87% of one core**. Private memory was **125.77 MiB at 60 seconds**, **124.23 MiB at the end**, peak **163.42 MiB**; handles went from **696 to 665**. The 3,514 half-second samples and final report are under the root recorded in `Windows/artifacts/stress-30m-path.txt`; summary: `stress-30m-summary.json`. Core/browser tests and packaging also ran on this machine during the interval, so this is an observed resource sample, not a controlled performance comparison. |
| Stress artifact and scope | The long run used a copied AOT layout, SHA-256 `9d01857700cf96e7ecf99ff8e3000f09f49888f507c70c6ed2e98a23fbd3d035`. Rendering/animation source did not change during this work; the new recovery code affects authoring. The latest packaged host was separately checked with four animated copies after rebuilding. This is not evidence of a long run on ARM64 or other display configurations. |
| Stress harness correction | Every timed stress-phase check passed. The original script then failed during its final independent GIF smoke because a generic “drawn” log could refer to a different pending widget; capture ran before the new bitmap existed. `Wait-WidgetCapture` now waits for the new window and nonempty native pixels. The corrected complete desktop check, with four copies and a 10-second interval against the latest packaged host, passes (`desktop-advance-final.log`, `checks-advance-final/`). The original overall script exit was nonzero (`stress-30m.log`); only its completed 30-minute phase is described as passing. |
| Builds and release gate | Release solution, Studio and CLI builds pass. The non-Xcode release-readiness gate passes (`release-readiness-advance.log`); Apple/Xcode remains skipped. Latest Studio error handling was republished into the layout and MSIX, and NSIS rebuilt. The final artifact checks are recorded below. |
| Publication drafts | [release-draft.md](release-draft.md) contains English release notes, a Windows privacy section and Store description/certification copy, with Microsoft policy and Credential Locker references. The Company website was read locally for context but not changed or deployed. No Store account, listing, Git tag or remote release was changed. |

The generated fixture data and logs are ignored, and all source/documentation changes remain uncommitted. Unlocked UI and physical-device acceptance remain separate items in [TODO.md](TODO.md).

Final artifacts for this additional work: the MSIX is **79,151,079 bytes** and the NSIS installer is **54,008,339 bytes**, SHA-256 `cdf4daf7446a949642f00ff8487facfa34872449701c31b4d0cfce4a24cab718`. These supersede the earlier local 0.1.1 artifacts above. Logs: `package-advance.log`, `advance-studio-publish.log`, `package-advance-final.log`, `installer-advance-build.log`. The latest installer passes first installation, startup, update over a running copy, graceful shutdown, uninstall, unrelated-file/data preservation and registry cleanup (`installer-advance-check.log`). The pre-existing `.swt` registry subtree is byte-identical before/after. The original user-data host was restored after the checks; the test installation was removed. No commit, upload, Store action or website deployment was performed.

## 2026-11-20, unlocked AI interface acceptance (Dev PC)

The owner unlocked the desktop. Computer Use then exercised the real Release Studio on the same x64 PC and display listed above, using an isolated `SCRIPTWIDGET_DATA` library and synthetic offline widgets. These results supersede the earlier pending-unlock entry; the earlier lock-screen attempts are still excluded.

| Check | Observed result |
| --- | --- |
| Conversation Skills | Selected Responsive Layout in the conversation dialog, saved it, and verified the saved conversation contained `responsive-layout`. Fork preserved that selection. |
| Real send, cancellation and retry | Sent a responsive-layout request through the existing DeepSeek profile. The UI disabled editing and enabled Cancel while receiving code. Cancel preserved the previous version and enabled Retry. Retry succeeded and created version 5; the completed conversation survived restart. |
| Preview and diff | Small, medium and large native previews rendered. The responsive widget kept both task/minute values visible at small size. Changes displayed additions/removals and skipped context. Fixed preview upscaling by retaining native point dimensions and allowing only downscaling. Added explicit localized accessibility names to the three tabs, so Changes no longer announces the full diff. |
| Apply and history | Applied the generated widget to the isolated library, reopened it in the actual WebView2 editor, switched versions and created an independent Fork. Historical selection/Fork did not modify the installed source. |
| WinUI crash found and fixed | Selecting an older version reproduced a fail-fast in `Microsoft.UI.Xaml.dll` (`0xc000027b`, WER underlying `8000ffff`), after the version selection had saved successfully. Merely deferring the reload did not fix it. Reload now preserves existing ComboBox item containers instead of clearing and recreating the selected item. The original standalone version 4 → 5 → 4 sequence passed after that change. Editor selection also passed while recording a newly formatted manual version and returning to it. Evidence of the original failure: `Windows/artifacts/ai-ui-version-crash-before.txt`. |
| Manual edits and editor Apply | Typed a manual source change in the editor, then opened its AI panel: the saved conversation recorded a manual version. A real request changed only `50 min` to `55 min`, retaining `UI MANUAL FOCUS` and `5 tasks`. Before Apply the installed source hash stayed unchanged; after Apply, installed source equalled the selected version, the applied fingerprint matched, and the editor/preview showed the new value. Assertions: `Windows/artifacts/ai-ui-editor-apply.json`. |
| Provider settings | Inspected the existing DeepSeek profile and saved-key status, without displaying or changing the key. Load models returned “Connected. Found 2 models.” Fixed a missing English `action.remove` label. Credential editing/removal and permission prompts were not driven through Computer Use. |
| Visual evidence | Live desktop screenshots confirmed the complete window, narrow editor panel, native previews and readable controls. Exported XAML evidence: `Windows/artifacts/ai-ui-editor-final.png`; WebView2 source capture: `ai-ui-editor-final.editor.png`. The development XAML exporter omits the WebView and transparent Mica/sidebar backdrop, so the separate editor capture and observed live window must be used together. |

No long stress test was repeated: these changes affect Studio interface behavior, and the recorded 30-minute animation phase remains the stress evidence. Core/CLI suites and the non-Xcode release gate above remain the relevant runtime evidence. Real ARM64, mixed-DPI, login/logout and Store-signed installation remain unverified.

Final Release Studio publish passed (`Windows/artifacts/ui-polish-publish.log`); the earlier focused build reported 0 warnings/errors (`ui-polish-build.log`). Every static AI interface localization key resolves. Documentation links, release metadata validation and `git diff --check` pass. Refreshed local artifacts supersede the package sizes above: MSIX **79,152,137 bytes**; NSIS **53,992,924 bytes**, SHA-256 `00b1e84b4d668d1bf4eb02b4a384ee22304dc5d776015080a6b4fe16dbf4f0d4`. Build logs: `package-ui-final.log`, `installer-ui-final.log`. The refreshed installer passed the complete install/start/update/uninstall/preservation check (`installer-ui-final-check.log`). The original host was quit gracefully before the check and restored afterward; the original `.swt` registry subtree is byte-identical before/after. No commit or publication was performed.

## 2026-11-20, Ollama and LM Studio connections (Dev PC)

Added local presets to Settings and `swcli ai configure --provider ollama|lmstudio`. They use the existing OpenAI-compatible client with default addresses `http://localhost:11434` and `http://localhost:1234`. Profiles may be saved before choosing a model, and Load models does not require a model or local token. Remote HTTPS profiles still require a key for requests. Local HTTP is confined to loopback, bypasses proxies and resolves localhost directly to loopback addresses; redirects remain refused. The change does not expand package/widget networking permissions. Endpoint changes retain separate credential identities, including when switching from a keyed remote profile to a local profile without a key.

| Check | Result / evidence |
| --- | --- |
| New regression coverage | **27 new cases**: local defaults and metadata round trip; HTTP/HTTPS loopback; remote HTTP, misleading hostnames and unsafe URL refusals; remote key requirement and local bearer tokens; actual IPv4/IPv6/localhost sockets; model discovery without a selected model; actual HTTP streaming through the AI runner and native execution/render validation; cancellation; redirects/auth failures; endpoint-change credential isolation and compensation. Initial local-only run: 24 pass (`Windows/artifacts/ai-local-tests.log`); three recovery cases were then added to the full suite. |
| Complete Core suite | **416 passed, 0 failed/skipped**, including all 27 additions; `Windows/artifacts/test-results/ai-local-full.trx`, `ai-local-full-tests.log`. |
| Build | Release solution build and self-contained Studio publish pass (`ai-local-build.log`, `ai-local-studio-publish.log`). The solution reports the existing xUnit1031 warning in PainterTests; no new build error. |
| Actual LM Studio server | Installed `lms` CLI commit `71bd99c`. The server was initially stopped; started it on `127.0.0.1:1234` for acceptance, then stopped it. In isolated data, `ai configure --provider lmstudio`, `ai key status` and `ai models` succeeded without a key or selected model. The real server returned `text-embedding-nomic-embed-text-v1.5`. Evidence: `ai-local-lmstudio-configure.json`, `ai-local-lmstudio-key.json`, `ai-local-lmstudio-models.json`; isolated root in `ai-local-lmstudio-path.txt`. |
| Studio interaction | On the unlocked display, inspected both saved local presets, their HTTP addresses, blank model and optional-key explanation. Load models in the actual LM Studio profile returned one model with no key entered. XAML export: `Windows/artifacts/ai-local-settings.png`. No owner provider/key was changed; local acceptance used a separate library. |
| Existing offline CLI acceptance | **41 checks pass** with the new CLI; `Windows/artifacts/creation-local-ai.log`, root in `creation-local-ai-path.txt`. |
| Cross-platform gate | Non-Xcode `Scripts/release-readiness.sh` passes (`Windows/artifacts/release-readiness-local-ai.log`). Apple/Xcode is explicitly skipped. Shared JavaScript runtime source was not changed. |
| Refreshed local packages | Full x64 native/AOT/Studio packaging passed (`package-local-ai.log`); rebuilt NSIS (`installer-local-ai.log`). MSIX: **79,153,720 bytes**; installer: **53,967,631 bytes**, SHA-256 `d2eb07ee478d89210a2ac90f42ddd9c8b481eeddd6ba3fc2f9b1eb0c953fd1a7`. These supersede the earlier local artifacts. The current installer passed installation, startup, update over a running host, graceful shutdown, uninstall and data/unrelated-file preservation (`installer-local-ai-check.log`). The original host was restored; original `.swt` registration is byte-identical before/after and no test installation remains. |

Local **model inference is not claimed**: LM Studio had only an embedding model, not a chat model, and Ollama was not installed. No model or additional server software was downloaded. Local generation/stream/cancel behavior was verified using synthetic responses over real sockets and the actual compiler/renderer. See [README.md](README.md#ollama-and-lm-studio) for connection steps. No long stress phase was repeated, and nothing was committed, uploaded or submitted to the Store.

## 2026-11-18, first Microsoft Store submission (Dev PC)

Built from commit `97d4d51` on the Dev PC (Windows 11 build 26200, x64). No runtime source changes were made for this submission.

| Check | Result |
| --- | --- |
| `powershell -NoProfile -File Windows/scripts/package.ps1 -Arch x64 -Version 0.1.0.0 -FrameworkDependent -IdentityName '20370everettjf.ScriptWidget' -Publisher 'CN=560214DD-F83C-484D-87A6-0E0454EE64B0' -PublisherDisplayName 'AtomSprout'` | Pass; rebuilt shared JavaScript, native engine, host and Studio; produced the unsigned Store package, 57,302,627 bytes |
| `dotnet test tests/ScriptWidget.Core.Tests -c Release -p:Platform=x64 --nologo -v minimal` from `Windows` | 239 passed, 0 failed, 0 skipped |
| Partner Center package processing | `ScriptWidget_0.1.0.0_x64-store.msix`, version `0.1.0.0`, X64, minimum OS `10.0.22000.0`: **Validated** |
| Required submission sections | Pricing, properties, age ratings, packages and Store listings all showed **Complete** before submission |
| Final submission | Partner Center showed **In certification**, with **Submission: Complete**, **Pre-processing: In progress**, and certification/publishing not started |

Package SHA-256: `08A41C495DACB500FB00B94B404D982354213AD5AACC0DA4849F8990457F25C2`.

Store ID: `9MVR97B9C938`; package family: `20370everettjf.ScriptWidget_93hpgtfr9gyfj`; submission ID: `1152921505702441674`. Review the submission in [Partner Center](https://partner.microsoft.com/en-us/dashboard/products/9MVR97B9C938/overview). The public [Store link](https://apps.microsoft.com/detail/9MVR97B9C938) is reserved; successful submission is not evidence that the listing is live.

The submission is free, publicly discoverable, and configured for all 240 markets and publication as soon as certification passes. It targets Windows Desktop only; future device-family availability was disabled. English (United States) and Chinese (China) listings each contain a localized description, six feature bullets, seven keywords, four existing Windows screenshots with localized captions, and the native 300-by-300 app icon. The privacy URL is `https://atomsprout.com/scriptwidget/privacy/` (HTTP 200 checked on this PC). The IARC questionnaire was saved after the owner explicitly accepted its terms and confirmed adulthood; the preview returned ESRB Everyone, PEGI 3 and Microsoft 3+.

Certification notes were saved and verified after reloading. They explain offline testing without credentials, the `runFullTrust` and `internetClient` uses, the opt-in startup task, bounded in-process QuickJS execution, permissions and platform limitations. No AI-generation or external-purchase capability was declared for the Windows preview.

Not run for this submission: ARM64 packaging, installation of the Store-signed package, a fresh desktop smoke suite, and the cross-platform release-readiness gate. Microsoft certification and public availability were still pending when this entry was written. Existing build warnings were emitted by QuickJS C wrappers, Studio C# code and the test analyzer; the build and tests nevertheless exited successfully.

## How to run the automated checks

```
node Windows/scripts/build-shared-js.mjs          # needs `npm ci` in Web/studio once
powershell -File Windows/scripts/build-native.ps1 -Arch x64
cd Windows
dotnet test tests/ScriptWidget.Core.Tests -c Debug
```

`build-native.ps1 -Asan` builds swcore with AddressSanitizer; pass `-p:SwNativeSuffix=-asan --filter "FullyQualifiedName~QuickJs"` to `dotnet test` to run the engine binding tests against it.

## 2026-11-17, Dev PC

**The Dev PC was locked for the whole session.** Programs ran and windows existed on the desktop, but the screen showed the lock screen and no real mouse or keyboard input was possible. The desktop checks below therefore read what the windows themselves show (`PrintWindow`), read the window order (`GetWindow`), post pointer and system messages to the windows, and drive the management window through UI Automation. What that still leaves unchecked is listed under "Not run" and in [TODO.md](TODO.md).

### Automated

| Check | Result |
| --- | --- |
| Preview engine tests on Windows (`npm test` in `Web/preview-engine`) | 199 of 199 pass, after adding `.gitattributes` (a CRLF checkout broke the shared build scripts before) |
| `dotnet test` of `ScriptWidget.Core.Tests`, Debug, x64 | 235 of 235 pass |
| Parity: bundled packages that need no live data, element tree compared byte for byte with the JavaScriptCore reference | 127 of 127 identical |
| Renderer: every parity package drawn at 170×170, 329×170 and 329×345, scale 2 | No exception, no empty bitmap |
| Engine limits: memory limit, deadline, stack limit | Each raises its error (in `QuickJsTests`) |
| Local time across a daylight-saving change | Correct with the ICU-based offset (in `QuickJsTests`); the upstream Windows code returns today's offset for every date |
| Engine binding tests with AddressSanitizer in swcore | 15 of 15 pass |
| The rest of the suite with AddressSanitizer | Not run: the parity test did not finish in 9 minutes with a sanitized QuickJS inside the .NET test host |
| Native AOT: `swcli` published ahead of time, all 140 bundled packages run and drawn at medium size | 137 drawn; 3 hit the 5-second limit waiting for the network; no crash. Two of the three use `api.open-meteo.com`, which this network cannot reach (`curl` times out too); the third (`Daily Quote`) passed on a second run |
| `node Scripts/validate-doc-links.mjs` | Passes (its repository-boundary check assumed `/` separators and failed on Windows before) |

The shared-JavaScript build was refactored into `Scripts/lib/shared-js.mjs`; regenerating the Android assets with it changes one file, `android-apis.js`, by the two lines that take the platform name from the host. `render.js`, `kernel.js`, `prepare.js` and `contract.json` are byte-identical. After the change, in CI: the Android workflow regenerates the assets and finds no difference from the checked-in ones, and `:core:testDebugUnitTest` passes (run 44081171658). The core instrumented suite, which includes the QuickJS parity with JavaScriptCore and the renderer on the parity corpus, passes 30 of 30 on an API 35 x86_64 emulator (run 44094364212, the hand-started job "Device tests on an emulator"), and the app suite (`foss` flavor) passes 63 of 63 there. Not run: the two instrumented suites on a phone.

### Found and fixed by these runs

- **Native AOT broke every layout.** Win2D's array of line metrics cannot be marshalled under native AOT. The text engine now uses a fixed line box and hit-testing instead; the JIT and AOT builds draw the same picture.
- **A packaged program could not install a package.** Windows redirects `%LOCALAPPDATA%` for a packaged program and the redirection does not support moving a directory. Packaged, the data now lives in the package's real local folder.
- **The code editor asked to pair with a phone.** The shared editor bundle tells an embedding app from the Web Studio site by a marker object, which the Windows bridge now provides.
- **Requests without a user agent.** The GitHub API answered 403. Requests now send `ScriptWidget-Windows/<version>` unless the script sets its own.
- **Size names.** `supportedFamilies` uses `systemMedium`; it was compared with `medium`.
- **The taskbar icon of the installed app had an edge in the accent color** (the owner saw it after switching to the dark theme with a pink accent). The package held one plain image per logo, so the taskbar drew the icon on its colored plate, which showed around the rounded corners. The images with their scale, target-size and unplated variants are now part of the management window's project and indexed in its `resources.pri`; a picture of the taskbar afterwards shows the icon without the plate.
- **Show desktop was missed on the real desktop, twice.** See "On the unlocked desktop": the desktop window is raised later than it becomes the foreground window, and lowered later than it stops being it.
- **Bundled network templates could not reach the network** once copied into the library. See the same section.
- **Show desktop was looked for in the wrong window.** Only a WorkerW that takes over the desktop icons was recognized, which is how Windows showed the desktop before 11 24H2. On 24H2 and later (this PC) Progman itself is raised; both are handled now.
- **Widgets were underneath the desktop.** `HWND_BOTTOM` put the widget windows below `Progman` in the window order on this Windows build, where they would be neither seen nor clicked. They are now inserted directly above the desktop window.

### Desktop host (`ScriptWidget.exe`)

`powershell -File Windows/scripts/desktop-check.ps1` runs these checks against a scratch data folder and saves pictures of the widget windows. It passed, 34 of 34, with the debug build and with the native AOT build from the package layout.

| Check | Result |
| --- | --- |
| First start: installs the clock template and places one widget | Yes |
| Windows accepts the tray icon | Yes |
| The actions of the tray menu and of the right-click menu of a widget, run through the host's debugging requests (the popup itself was not shown) | Size changes the window (494 to 255 pixels wide for small); "Lock positions" stops a drag and turns off again; "Add widget" adds one; "Refresh all" redraws; "Remove from desktop" removes the widget and its window; "Quit" ends the host with exit code 0 |
| What each widget window shows, captured from the window | The rendered widget, 494×255 pixels (329×170 points at 150%), with transparent rounded corners; the clock shows the current time |
| Window order with two widgets on the desktop | Both widget windows directly above `Progman` (the desktop) and below every other visible window; a window opened afterwards goes above them |
| Drag (posted pointer messages) | The widget moves by the dragged distance, snaps to the top edge of the screen, and the new place is saved in `widgets.json` |
| A click on a button (posted pointer messages) | "Check in" on Habit Heatmap ran the declared action `checkInRead`; the package storage then held the date of the day and the widget drew "Done today" |
| Import of a `.swt` archive and placing it, requests over the pipe | Work (`swcli pack`, `install`, `add`, `widgets`) |
| Display change, clock change, resume from sleep, session lock and unlock, theme change (the messages posted to the host) | Each is handled and the widgets are redrawn; the widget keeps its place |
| Explorer restart (the `TaskbarCreated` message posted to the host) | Handled: the window order is applied again and the tray icon is added again |
| A real sleep on the Dev PC (Modern Standby, entered with `SetSuspendState` and ended by a wake timer after 107 seconds, native AOT host running) | The host kept running, logged the time change and the resume, redrew the widget within a quarter of a second of the resume, and the widget window was still directly above the desktop window. Nobody saw the screen, so the clock was not read by a person |
| A real Explorer restart on the Dev PC (Explorer ended with the native AOT host running; Windows started it again by itself) | The host kept running, logged the new taskbar and added its tray icon again (Windows accepted it), and the widget window was directly above the new desktop window and still drew its content. Nobody saw the screen |
| A new widget when another sits at the default place | Lands on the next free step instead of exactly on top (it did land on top before) |
| Redraw cost after the first render | Layout 3 to 35 ms, paint 1 to 65 ms |
| Idle cost, native AOT build, two widgets, one of them a clock | 85 MB private memory, 93 MB working set; 0.05 s of processor time in 30 s |
| Idle cost, native AOT build, one widget without dates | 22 MB private memory, 58 MB working set, 10 threads; 0.00 s of processor time in 30 s |
| "Show desktop", acted out with a stand-in for the desktop window (`--selftest-showdesktop`) | 19 of 19 (five were added for the late raise and late drop found on the real desktop). The first 14: a click on the wallpaper is not mistaken for it; when the desktop window is raised and is the foreground window the widget becomes topmost in front of it; afterwards the widget is back directly above the desktop and behind ordinary windows; a second round behaves the same |
| "Show desktop" for real | Done on the unlocked desktop, see "On the unlocked desktop" below |

### Management window (`ScriptWidgetStudio.exe`)

Driven through UI Automation (the real controls are invoked, with no pointer), and checked from captures of the window.

| Check | Result |
| --- | --- |
| Opening the window starts the desktop host | Yes |
| "My widgets": cards with previews drawn by the desktop renderer, "On desktop" count from the host | Drawn correctly |
| "New widget": name dialog, the package is created, the editor opens on it | Works; the starter widget is drawn in the preview |
| Editor: file list, code editor with the file loaded and highlighted, preview, output | Drawn correctly; the editor reported ready and returned the text of the file |
| "Add to desktop" with a size from its menu | The host shows one more widget |
| "Save" | Works |
| "Templates": groups, search box, previews; "Use this template" | Drawn correctly, 130 templates; the template is installed, placed on the desktop and opened in the editor |
| "Settings": "Lock positions" | Written to `settings.json` |
| The interface in Simplified Chinese (`SCRIPTWIDGET_LANGUAGE=zh`) | "My widgets", the editor and "Settings" are drawn correctly; nothing is cut off |
| Accessible names | The back button, the "more actions" button, the switches and the inputs had none; they have now |
| Typing in the code editor, file pickers (import, export), rename, duplicate, delete | Not run |

### MSIX package

Both forms were built, registered from their layout folder in Developer Mode, tried, and removed again.

| Check | Result |
| --- | --- |
| `package.ps1 -Arch x64` | `ScriptWidget_0.1.0.0_x64.msix`, 74.7 MB, with the Windows App SDK and the .NET runtime inside |
| `package.ps1 -Arch x64 -FrameworkDependent` (the Store form) | `ScriptWidget_0.1.0.0_x64-store.msix`, 54.3 MB, depends on the Windows App Runtime 1.6 framework package |
| Store form started the way the Start menu starts it (`shell:AppsFolder\<family>!ScriptWidget`) | The management window opens and starts the host; both have the package identity; data in `…\Packages\<family>\LocalState\ScriptWidget`; the first start installs and places the clock widget |
| Opening a `.swt` file (file association) | Goes to the running management window, which asks for confirmation; "Import" installs the package |
| "Start when I sign in" in the packaged app | Turns the startup task on and off. Signing out and in was not done |
| Signed install, install from the Store, upgrade | Not run: needs the Partner Center identity |

The Store form at first showed "This application could not be started": the bootstrapper for unpackaged programs ran inside the package. It is switched off for that form now.

### Installer for GitHub Releases (Dev PC, 17 November 2026)

`installer.ps1` built `ScriptWidget-0.1.0-x64-setup.exe` (51.1 MB) with NSIS 3.12, and `installer-check.ps1` ran it on the Dev PC, where the copy registered from the MSIX layout was quit first. All 26 checks passed:

| Step | What was checked |
| --- | --- |
| Silent install (`/S`) | Exit code 0; host, management window and `resources.pri` in `%LOCALAPPDATA%ProgramsScriptWidget`; no `AppxManifest.xml`; the uninstaller; the Start menu shortcut; the entry in Installed apps with version and folder; `.swt` opens the management window |
| The installed program | The host starts and logs `packaged False`; the first start puts the clock widget on the desktop; the management window opens and draws the Templates page (a picture was saved) |
| Installing again over the running host | Exit code 0; the host was asked to quit and logged `host stopped`; the files are there; the widgets are kept |
| Silent uninstall while the host runs | The host is stopped; the program files, the shortcut, the entry in Installed apps, the file type and the start-at-sign-in value are gone; a file the installer did not put into the folder is left alone; the widgets are kept |

Three mistakes in the installer script were found by this check and fixed before anything was published: the command that closes the running copy was cut off at its first single quote; a script text longer than 1024 characters is cut off by NSIS; and the 32-bit installer started a 32-bit PowerShell, which cannot read the path of a 64-bit process and so did not find the running host.

Not run: the pages of the installer on screen (a picture of the window came out black), the question about deleting the widgets in a non-silent uninstall, a double-click on a `.swt` file with this installation, signing out and in with its start-at-sign-in value, a PC that never had the development tools, and the ARM64 installer on a PC (it runs in the "Windows installers" workflow only).

The "Windows installers" workflow then built both installers from commit `0bbec5a` and ran the same 26 checks on the CI x64 and CI ARM64 machines; all passed on both. Those two files are the ones attached to the release `windows-v0.1.0`: `ScriptWidget-0.1.0-x64-setup.exe` (51.1 MB) and `ScriptWidget-0.1.0-arm64-setup.exe` (46.6 MB). The files of the release were not installed again on a PC after downloading them from the release page.

## 2026-11-17, CI

GitHub Actions run 44076023162 on `windows-2025` (Windows Server 2025, x64, 100% scale, no graphics card).

| Check | Result |
| --- | --- |
| Build of swcore, the shared JavaScript and the solution for x64; build for ARM64 | Pass |
| Preview engine tests on Windows | Pass |
| `dotnet test`, Release, x64 | Pass |
| Engine binding tests with AddressSanitizer in swcore | Pass |
| `desktop-check.ps1` on the build agent's desktop | 24 of 24, with the 14 show-desktop stand-in checks: the widgets were drawn (329×170 pixels), sat directly above the desktop window, were dragged and clicked, and Windows accepted the tray icon. The uploaded pictures show the clock and the habit widget drawn correctly |

This is a second machine and another Windows version, but nobody looked at its screen either.

Run 44077877354 added the ARM64 machine (`windows-11-arm`, image `windows-11-vs2026-arm64`): swcore and the solution were built natively for ARM64, `dotnet test` passed 235 of 235 (the parity packages and the renderer included), and `desktop-check.ps1` passed with both widgets drawn correctly in the uploaded pictures.

### On the unlocked desktop (Dev PC, 17 November 2026)

The owner signed in and the desktop was unlocked, so the host ran on the real desktop with nine widgets (Datetime Current, Month Calendar, World Clock Faces, Animation Clock, Year in Dots, Daily Quote, Day Rhythm, Portfolio Pulse, Habit Heatmap) placed between the desktop icons and an open window. Pictures were taken from the screen, and the keyboard and mouse input was real input (`keybd_event`, `SetCursorPos`, `mouse_event`), not posted messages. The pictures were sent to the owner; this section records what the pictures and the window order showed, not a person's judgement.

![Widgets on the desktop](images/desktop.png)

| Check | Result |
| --- | --- |
| The widgets against the wallpaper and icons | Drawn with rounded corners and no border or halo against the wallpaper; text is sharp at 150% |
| Widgets stay behind ordinary windows | Yes: a widget dragged under an open window is covered by it |
| Win+D, first try | **Failed.** The widgets disappeared until Win+D was pressed again. Windows made the desktop the foreground window first and raised it later, after the host had stopped looking at the window order. Fixed: the order is looked at again for as long as the desktop is the foreground window |
| Leaving Win+D, after that fix | **Failed.** The widgets were left above ordinary windows that were not in front, because the desktop window was still raised when they were put "directly above the desktop". Fixed: the placing is repeated for two seconds after the desktop is left |
| Win+D, with both fixes (debug build, then the rebuilt native AOT build) | All widgets visible and topmost while the desktop is shown; afterwards directly above the desktop window again, below every other window |
| Dragging with the mouse | The widget moved by exactly the distance the pointer moved (37, 290 pixels) and the new position was saved |
| Right-click on a widget | The menu opened at the pointer (Refresh, Size, Edit…, Lock positions, Remove from desktop) and closed with Esc |
| Pointer shape | An arrow over the widget, a hand over the "Check in" button |
| Clicking a button | "Check in" of Habit Heatmap ran its action: the widget showed "Done today", "1 day", "1 total" |
| A template that uses the network, copied into the library | **Failed** for Daily Quote: "Network host is not declared in widget.json". A bundled template without `widget.json` got a manifest without the `network` permission when it was copied into the library. Nine bundled templates were affected. Fixed in `Library.BundledManifest`: the hosts the template names in its own source are declared. With the host declared, Daily Quote showed the quote of the day |

Not seen there: the tray icon's own menu (the same menu class as the right-click menu), a link opening the browser, a full-screen program in front, a scale change.

### Templates and examples in the management window (Dev PC, 17 November 2026)

The templates page was split after the owner tried it, in three rounds: the sidebar has "Templates" (the widgets, as cards the size of a widget), "Components" (one example per component, as small tiles) and "APIs" (a reference: globals on the left, the functions of the chosen one on the right). A template or example opens a page with the preview and the read-only code, and the one button that copies it is on that page. Driven through UI Automation on the unlocked desktop, with pictures of the window:

| Check | Result |
| --- | --- |
| Templates page | Widgets only, no group tabs, no button on the cards |
| Clicking a card | Opens the template: preview, size and dark switch, read-only code, "Connects to …" with the hosts the copy will declare, "Use this template" |
| Back, and clicking the selected sidebar entry | Returns to the list it was opened from |
| APIs | 111 functions in 24 globals from the editor's metadata. Choosing `$device` lists its 9 functions with arguments and return types; `$xml`, which has no bundled example, shows no "View example"; `console`, which has only an example, says so; `$health` is listed last and says it is not available on Windows. "View example" opens the example and Back returns with the same global chosen. Searching "battery" lists `$device.battery() → json` |
| Components | Small tiles, five to a row at the default window size. Opening `toggle` shows its description, its four properties with their types (`on` is marked required), the attributes every component takes, a preview and the example's code. `attribute-frame` shows the `frame` attribute |
| An example that draws nothing | Shows what it printed instead of "#UI Not Found#" |
| "Copy code" | The clipboard holds the example's code |
| "Open a copy in the editor" | A copy named after the example is in the library and open in the editor; nothing is added to the desktop |
| Chinese interface | The new pages and buttons are in Chinese |

Two things seen while doing this, neither changed:

- **Daily Quote's preview said "Script exceeded the 5-second execution limit" four times in a row** in the management window while the command line ran the same template in 0.3 seconds, and then worked every time. Timing added to the request and to the run showed nothing wrong once it worked. The cause was not found.
- **The Weather templates time out** because `api.open-meteo.com` did not answer from this PC at the time (a plain request from PowerShell timed out after 20 seconds too). The message is the same "5-second execution limit"; it does not say that a request is what was slow.

### Not run on any machine

- Watching the desktop over time for flicker; the pictures above are single moments.
- The tray icon's menu on screen.
- Signing out and in, a second display, a scale change, a full-screen program in front.
- ARM64 in a person's hands: it ran on the CI ARM64 machine only.
- The Android instrumented suites on a phone after the shared-JavaScript refactor. The JVM tests and both suites on an emulator pass in CI.

19 November 2026: the Simplified Chinese interface (management window, desktop host, installer, the `zh-cn` language of the package) was removed; the interface is English only on every platform. The change was made on a Mac and has not been built or run on Windows, so the rows above about the Chinese interface describe earlier versions.
