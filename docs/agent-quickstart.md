# Use ScriptWidget with Claude Code

## Install the Skill

Install the Mac CLI, then copy its entire bundled Skill folder (including references) to Claude Code's personal skills directory:

```sh
brew install everettjf/tap/scriptwidget-cli
mkdir -p ~/.claude/skills
# First installation: stop rather than overwrite an existing personal Skill.
test ! -e ~/.claude/skills/scriptwidget-creator && cp -R "$(brew --prefix scriptwidget-cli)/libexec/ScriptWidgetCLI.app/Contents/Resources/scriptwidget-creator" ~/.claude/skills/
```

The Skill was previously named `scriptwidget-author`. If you installed that version, back up any custom edits and remove its old personal/project folder after installing `scriptwidget-creator`, so Claude Code does not discover both copies.

The resulting file must be `~/.claude/skills/scriptwidget-creator/SKILL.md`. If that folder already exists, review/back up your local modifications before replacing it. For a project-only installation, use `.claude/skills/scriptwidget-creator/` instead. Claude Code documents these locations in its [official Skill guide](https://code.claude.com/docs/en/skills).

Without Homebrew, download the [Skill ZIP](https://github.com/everettjf/scriptwidget/releases/download/cli-v0.2.0/scriptwidget-creator-0.2.0.zip), unzip it, and copy the entire `scriptwidget-creator` folder to the same location. Browser preview does not require the Mac CLI; native checks do.

In Claude Code, invoke:

```text
/scriptwidget-creator Create a medium reading habit widget. Use clearly labeled demo data for preview, validate it, show me the result, and export a .swt package.
```

The folder structure follows the documented discovery contract. This release has validated folder copying and Skill contents; it does not claim end-to-end discovery testing in every Claude Code version or managed configuration.

## Preview in Web Studio

With CLI 0.2.0 or later, ask your Agent to run:

```sh
scriptwidget preview ./MyWidget --format json
```

The CLI validates the package and compiles its JS/JSX without executing it, then opens your default browser directly in [Web Studio](https://atomsprout.com/scriptwidget/studio/) with the generated widget loaded. Helpers, manifest and binary resources travel together. The browser adds a new project, preserves existing projects, and clears the package fragment before import. It does not duplicate the import on reload. Invalid links show an error and preserve your work.

No upload server or model service is needed: the ZIP travels in a URL fragment, which is not part of the HTTP request. The link itself contains the complete package; keep private code, resources and credentials out of shared links, logs or chat. The CLI supports up to 45,000 compressed archive bytes (60,000 base64url characters) to keep browser-launch URLs bounded. Larger packages fail explicitly; reduce assets, use [native render](mac-cli.md), or export a `.swt` for explicit import. Resources are never silently removed.

The default open command does not print the package-bearing URL into reports/logs. `--no-open` explicitly returns private `previewURL` without launching a browser, for agents in environments without a graphical browser. A successful report uses backend `web-handoff`; execute/render stay `notRun` because it only certifies compilation and package handoff, not browser rendering. An Agent with browser tools should inspect the loaded page, Problems, and preview before claiming it rendered correctly.

The browser uses its sample mocks; native CLI fixture files are not automatically embedded. Use the Studio mock editor for browser scenarios. For a draft without the Mac CLI, **Validate** still supports pasted JSX or manual `.swt` import.

## Import on iPhone/iPad

The device must have ScriptWidget installed. A Skill supplies authoring instructions; it does not install the iOS app.

- From Mac: send the exported `.swt` with AirDrop or iCloud Drive, then use the iOS share sheet to open it with ScriptWidget.
- From Web Studio on iPhone: choose **Install on iPhone**. When file sharing is supported, choose ScriptWidget in the share sheet. Otherwise save the downloaded `.swt` and share it from Files.
- Review the imported package and permissions. Add a ScriptWidget widget through the Home Screen widget gallery and select the imported package yourself. Importing a package does not place a widget on the Home Screen.

No App Store update is needed for this existing import workflow.

## Later: paired device delivery

The existing development-only [Node preview tool](browser-preview-engine.md) supports `--device` and `--pair-code`, using the App's manually started local [Web Studio server](web-studio.md). This is separate from the native Homebrew CLI. It requires the same trusted network, the App screen in the foreground, and an initial `.swt` import. It syncs text files into an existing editable package; binary resources are skipped, and revision conflicts must remain visible.

A future native `device` workflow should discover/pair with explicit user action, preview the target package and changes, transfer resources within existing limits, preserve revision checks and require confirmation before overwriting. Pairing credentials must stay local and out of Skills/logs/share links. Complete first-time paired device installation remains follow-up work; public Studio preview links are shipped in CLI 0.2.0.
