# Five-minute widget tutorial

ScriptWidget for Mac includes an interactive five-step tutorial that appears on first launch. It creates a real local project and walks through the same Studio workflow used for production widgets. You can skip it safely or reopen it later from **Help → Five-Minute Tutorial…** (`⇧⌘?`). Progress resumes at the last viewed step until the tutorial is finished or skipped.

## 1. Understand the workspace

The sidebar contains widget projects and creation shortcuts. Studio combines the project file tree, CodeMirror editor, multi-family native preview, runtime diagnostics, package configuration, and AI Copilot.

## 2. Create the tutorial project

Choose **Create Tutorial Widget**. ScriptWidget creates `My First Widget` (or a numbered name if it already exists) with an offline example and a Package 2.0 manifest. It is an ordinary project and can be edited, renamed, exported, or deleted.

## 3. Make one edit

Finish or move the tutorial aside, select the project in the Scripts sidebar, and open `main.jsx`. Replace `Hello, ScriptWidget!` with your own text and press `⌘S`. Completion and diagnostics use the versioned runtime API contract, so unsupported components and properties are visible while editing.

## 4. Preview before installing

In Studio's Preview pane, switch between small, medium, and large families. Press `⌘R` to evaluate the current source. Use the Config pane for display metadata, parameters, permissions, and `widget.json` rather than hand-editing package metadata.

## 5. Add it to macOS

1. Control-click the desktop and choose **Edit Widgets**.
2. Find ScriptWidget, choose a size, and drag it to the desktop or Notification Center.
3. Control-click the widget, choose **Edit ScriptWidget**, and select the tutorial project.
4. If it is not listed yet, keep ScriptWidget open and choose **File → Update iCloud Scripts**.

Saved changes appear on a subsequent widget refresh. The same project can sync to iPhone and iPad when the configured iCloud container and App Group are available.
