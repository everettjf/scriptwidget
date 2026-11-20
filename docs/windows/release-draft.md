# Windows preview release draft

Prepared for the next Windows preview. These texts are for owner review and have not been published or submitted. Local candidate packages use version 0.1.1; choose the final release version and complete the remaining acceptance items in [testing.md](testing.md) before distribution.

## English release notes

Create and refine desktop widgets with the new AI assistant. Bring your own Anthropic or OpenAI-compatible provider, describe a widget, and review a native preview before applying its code. Conversations support multiple versions, focused edits, change comparisons, retries and forks. The assistant checks generated code locally and can try to repair execution errors. API keys are stored in Windows Credential Locker.

Browse the shared Gallery and import or export Skills. Gallery downloads are checked against their declared file sizes and SHA-256 hashes. Skills provide optional writing guidance for AI requests and do not grant widget permissions.

Connect to Ollama or LM Studio on the same computer using their local presets. Local servers can be used without an API key when their authentication is disabled. Select an installed chat model; ScriptWidget does not download models or start or stop the model server.

Desktop widgets now play GIFs, clock-hand animations and swings without rerunning their JavaScript on every animation frame. Studio previews and command-line PNG exports remain still images.

This preview also improves execution-timeout diagnostics, filters unsupported APIs in nested template source files, and protects manual code changes when reopening an AI conversation. If a widget was applied but its conversation could not be saved, the editor reflects the applied widget and explains how to retry saving. Provider changes recover their previous credential when a settings write fails.

Windows 11 is required. Widgets remain desktop windows rather than entries in the Windows Widgets board. Platform differences are listed in [Platform support](../platform-support.md).

## Windows privacy section

The following section is intended for the official [ScriptWidget privacy policy](https://atomsprout.com/scriptwidget/privacy/). When integrating it, scope the general credential-storage sentence by platform, for example: “AI provider credentials use the credential storage described for each platform below.”

### Windows

ScriptWidget for Windows stores widget packages, settings, widget storage, cached downloads, provider settings and AI conversations in your Windows user profile. The standalone application normally uses `%LOCALAPPDATA%\ScriptWidget`; the Microsoft Store package uses its Windows-managed local application-data folder. Windows does not provide ScriptWidget's iCloud sync features.

Widget code can read the package's own files and, when its package declares the necessary permissions, use package-specific storage, device/system information and network services. Network requests are limited to the hosts the package declares and are checked against private-address and request-size rules. The information a widget sends depends on the code you choose to run. Third-party services receive those requests under their own privacy practices.

When you send an AI request, ScriptWidget sends your request, the current widget entry code, relevant earlier requests and versions, selected Skills, and bounded diagnostic or console-log excerpts to the AI provider and endpoint you configure. Inputs are sent directly by the application to that endpoint. The provider processes them under its own terms and retention controls. Local validation executes candidate code and may make requests to its declared public hosts before you apply it to the installed widget. Validation uses temporary widget storage; it does not pass the installed widget's saved `$storage` values to the provider as an attachment. Code and log excerpts may themselves contain information you have placed in them.

Provider API keys are kept in Windows Credential Locker and used to authenticate provider requests. They are not included in widget exports, provider-settings JSON, AI conversation files or model prompts. Windows manages the locker; credential roaming may depend on your Windows account and settings, as described in Microsoft's [Credential Locker documentation](https://learn.microsoft.com/en-us/windows/apps/develop/security/credential-locker). Removing a provider in Settings requests removal of its key and reports failures. The standalone uninstaller does not explicitly clear Credential Locker entries, so remove provider profiles before uninstalling if you want the application to remove their keys.

You can choose an Ollama or LM Studio server running on this computer. These local AI connections use the OpenAI-compatible API and may use HTTP on localhost, 127.0.0.1 or the IPv6 loopback address; an API token is optional unless your server requires it. Local connections bypass system proxies and are confined to loopback. The server software and model you choose determine how inputs are processed; selecting a local server does not guarantee that the server itself avoids external services. Remote AI endpoints require HTTPS and an API key. Candidate widget code can still make its own declared network requests during validation.

Gallery browsing downloads the shared catalog from ScriptWidget's configured GitHub raw-content root. Installing a Gallery item downloads and verifies its declared files. Widget packages and Skills you import remain on your device unless you export them or their code makes a permitted request. Skills are prompt text and do not execute native code or grant additional access.

You can inspect local application files from Settings using Open folder. Conversations remain locally until removed from that folder or pruned by the application's history limits. Cancel stops an active AI request in the application; it does not delete information a provider has already received. Removing local files or a provider profile does not request deletion from that provider. The standalone uninstaller offers a choice about retaining local widget data; a silent uninstall retains it. Windows manages removal of Microsoft Store package data.

## Store description additions

ScriptWidget lets you write, import and edit JavaScript and JSX to create native widgets on the Windows 11 desktop. Review templates, code, package permissions and previews before adding a widget. Widgets can use supported device information, package-local files and declared network hosts; capabilities available on other ScriptWidget platforms may not be available on Windows.

Optional AI authoring works with a provider you configure using your own API key. Requests and widget code are sent to that provider. AI authoring is not required to use templates, edit code, import packages or run offline widgets. Gallery and Skills help you find examples and guide AI requests. Desktop GIF and clock/swing animation playback is supported; previews show a still frame.

## Notes for Microsoft certification

ScriptWidget is a desktop widget authoring and execution application. User-written, imported, Gallery-supplied and AI-generated JavaScript/JSX are part of the functionality described in the product listing. Packages are interpreted by the bundled QuickJS engine and rendered through the bundled renderer and Win2D. Imported packages do not install executables, load arbitrary native libraries or receive operating-system tools. Skills contain declarative prompt instructions; Data Source Plugins contain declarative request mappings.

The Windows desktop host draws and manages widget windows and a tray icon. This is why the MSIX declares `runFullTrust`. `internetClient` supports requests to user-declared widget hosts, verified Gallery downloads and the AI provider selected by the user. Startup is optional and disabled by default in the package manifest. The `.swt` association opens the application's reviewed import flow.

Package paths, archives and manifests are validated. Package code has no Node.js, browser DOM or shell interface. QuickJS execution has a 64 MiB JavaScript heap limit, a stack limit and a five-second execution deadline, including awaited requests. This is a JavaScript-context limit, not a promise that the entire native process uses 64 MiB. Code runs in the desktop host process; it is not a separate AppContainer process. Network access requires package permissions and matching domain declarations, refuses private/local destinations, and enforces request/response budgets. Remote AI provider requests use HTTPS; all AI requests refuse redirects.

AI credentials use Windows Credential Locker and do not enter packages, conversation JSON or prompt text. AI requests are explicit user actions. Candidate code is compiled, executed and painted locally before a successful version is offered. Applying a version is a separate action; new declared network hosts require confirmation. A failed request or cancellation keeps the previously selected successful version. A changed remote endpoint requires a newly entered key; endpoint changes create a separate credential identity.

For local Ollama/LM Studio, keys are optional. HTTP is restricted to loopback, where requests bypass proxies and DNS resolution; remote AI still uses HTTPS. Changing to a local endpoint creates a separate credential identity and does not inherit a previous remote key. This exception applies to explicitly configured AI servers only, not widget network permissions.

### Offline review steps

1. Open Templates and choose an offline clock or text template. Preview it, use a copy, and add it to the desktop.
2. Edit its text and save. Verify that the native preview and desktop widget update.
3. Open Components and APIs to inspect supported examples and platform limitations.
4. Open Skills to inspect built-in prompt instructions. No AI credential is needed.
5. Export an owned widget as `.swt`, then open that file and confirm its import.
6. For animation playback, use an animation or GIF example on the desktop; its Studio preview remains still.

AI review requires a reachable provider and a key entered by the reviewer in Settings. If Microsoft requests dedicated reviewer access, arrange it privately through Partner Center. Do not embed a production key in the package, repository or certification notes.

### Owner checks before submission

- Use the Partner Center package identity and Store framework-dependent package form documented in [testing.md](testing.md). The unsigned standalone NSIS installer is a separate distribution artifact.
- Publish the reviewed Windows privacy section on the Company website and update the policy's effective date. This repository does not own deployment of that page.
- Update the listing to disclose imported/interpreted code and optional AI authoring. Keep only languages the owner intends to support; the interface is English.
- Complete unlocked AI/editor/installer interaction, Store-signed installation and the remaining hardware checks. Link the exact tested package and successful CI run when available.

Microsoft's current [Store policies](https://learn.microsoft.com/en-us/windows/apps/publish/store-policies) cover described functionality and dynamic code (10.2.2), product testability (10.3), privacy disclosures (10.5) and capability declarations (10.6). These technical notes support review; they do not assert certification approval.
