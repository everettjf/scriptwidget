# ScriptWidget Studio

ScriptWidget Studio is the macOS development environment for ScriptWidget. It is the primary place to create, edit, preview, debug, and manage widgets that sync through iCloud to iPhone, iPad, and Mac.

## Create a widget

1. Choose **New from Template**, **Generate with AI**, or **Blank Widget**.
2. Edit `main.jsx` with ScriptWidget component, property, and enum completion.
3. Use **All Sizes** to verify Small, Medium, and Large layouts together.
4. Check **Problems** for the latest runtime failure and **Console** for script output.
5. Press **Command-R** to run or **Command-S** to save and refresh.

## AI Copilot

Open the **Copilot** tab beside the editor, describe a focused change, and choose **Propose Change**. Studio sends the current document and the latest local runtime diagnostic as context, then shows the original and proposed JSX before anything is changed.

- **Apply** replaces the editor document, saves it, and refreshes preview. The CodeMirror transaction remains available to Undo.
- **Reject** discards the proposal without touching the document.
- **Fix Runtime Error** asks Copilot to repair the latest error shown by the preview.
- Review generated code before applying it, especially networking, imported packages, and data handling.

## Skills

Skills are reusable, version-controlled expert instructions that can be combined with a Generate or Copilot request. Studio currently includes Responsive Layout, Accessible Design, Resilient Data, Visual Polish, and Runtime Debugger.

Select only the skills relevant to the request. Skills shape the prompt but do not execute code, access credentials, grant network access, or change ScriptWidget's runtime security boundaries. The built-in catalog lives in source control so contributors can review and improve every instruction.

## Studio workspace

- **Scripts** lists user widgets stored in the shared ScriptWidget location.
- **Editor** uses the same CodeMirror 6 and StudioBridge implementation as iPhone and iPad.
- **Preview** can render one family or a multi-size canvas.
- **Problems** presents the latest transform or runtime diagnostic.
- **Console** contains output emitted by the script runtime.
- **Copilot** proposes reviewable edits against the live document and runtime diagnostic.
- **Images** and **Files** manage package resources.

## Platform scope

ScriptWidget currently targets iOS, iPadOS, and macOS. watchOS and visionOS are not part of the current product roadmap.

## Sync model

Widgets use the existing ScriptWidget package storage and iCloud synchronization. A widget created on Mac is available to the iPhone, iPad, and Mac apps when the same iCloud container and app group are configured.
