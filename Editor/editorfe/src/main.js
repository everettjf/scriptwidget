import { EditorState, Compartment } from "@codemirror/state";
import {
  EditorView,
  ViewUpdate,
  keymap,
  lineNumbers,
  highlightActiveLine,
  highlightActiveLineGutter,
  highlightSpecialChars,
  drawSelection,
  dropCursor,
  rectangularSelection,
  crosshairCursor,
  hoverTooltip,
} from "@codemirror/view";
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
} from "@codemirror/commands";
import {
  bracketMatching,
  foldGutter,
  foldKeymap,
  indentOnInput,
} from "@codemirror/language";
import { closeBrackets, closeBracketsKeymap, autocompletion, completionKeymap } from "@codemirror/autocomplete";
import { javascript } from "@codemirror/lang-javascript";
import { searchKeymap, highlightSelectionMatches } from "@codemirror/search";
import { lintGutter, linter, setDiagnostics } from "@codemirror/lint";
import { connectNativeBridge, announceReady, callNative } from "./bridge.js";
import { STUDIO_PROTOCOL_VERSION, StudioMessage } from "./studioProtocol.js";
import { scriptWidgetCompletions } from "./scriptWidgetCompletions.js";
import { scriptWidgetDiagnostics, scriptWidgetHover } from "./scriptWidgetLanguage.js";
import { studioTheme } from "./studioTheme.js";
import "./style.css";

const readOnly = new Compartment();
const theme = new Compartment();
let bridge = null;
let documentID = null;
let documentVersion = 0;
let suppressChanges = false;
let saveTimer = null;

function systemTheme() {
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function scheduleSave() {
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => {
    const content = view.state.doc.toString();
    callNative(bridge, StudioMessage.documentSave, { content, version: documentVersion }, documentID);
  }, 700);
}

function onEditorUpdate(update) {
  if (!update.docChanged || suppressChanges) return;
  documentVersion += 1;
  const changes = [];
  update.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
    changes.push({ from: fromA, to: toA, insert: inserted.toString(), newFrom: fromB, newTo: toB });
  });
  callNative(bridge, StudioMessage.documentChanged, { changes, version: documentVersion }, documentID);
  scheduleSave();
}

const extensions = [
  lineNumbers(),
  highlightActiveLineGutter(),
  highlightSpecialChars(),
  history(),
  foldGutter(),
  drawSelection(),
  dropCursor(),
  EditorState.allowMultipleSelections.of(true),
  indentOnInput(),
  bracketMatching(),
  closeBrackets(),
  autocompletion({ override: [scriptWidgetCompletions], activateOnTyping: true }),
  rectangularSelection(),
  crosshairCursor(),
  highlightActiveLine(),
  highlightSelectionMatches(),
  lintGutter(),
  linter(scriptWidgetDiagnostics, { delay: 350 }),
  hoverTooltip(scriptWidgetHover),
  javascript({ jsx: true }),
  keymap.of([
    indentWithTab,
    ...closeBracketsKeymap,
    ...defaultKeymap,
    ...searchKeymap,
    ...historyKeymap,
    ...foldKeymap,
    ...completionKeymap,
  ]),
  readOnly.of(EditorState.readOnly.of(false)),
  theme.of(studioTheme(systemTheme())),
  EditorView.updateListener.of(onEditorUpdate),
  EditorView.contentAttributes.of({ autocapitalize: "off", autocomplete: "off", spellcheck: "false" }),
];

const view = new EditorView({
  state: EditorState.create({ doc: "", extensions }),
  parent: document.querySelector("#editor"),
});

function replaceDocument(content, nextDocumentID = documentID, version = 0) {
  suppressChanges = true;
  documentID = nextDocumentID;
  documentVersion = version;
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: content ?? "" },
    selection: { anchor: 0 },
    scrollIntoView: true,
  });
  suppressChanges = false;
}

function insertText(content) {
  if (view.state.readOnly) return false;
  const range = view.state.selection.main;
  view.dispatch({
    changes: { from: range.from, to: range.to, insert: content },
    selection: { anchor: range.from + content.length },
    userEvent: "input",
  });
  view.focus();
  return true;
}

async function formatDocument() {
  if (view.state.readOnly) return false;
  try {
    const [{ format }, { default: babelPlugin }, { default: estreePlugin }] = await Promise.all([
      import("prettier/standalone"),
      import("prettier/plugins/babel"),
      import("prettier/plugins/estree"),
    ]);
    const formatted = await format(view.state.doc.toString(), {
      parser: "babel",
      plugins: [babelPlugin, estreePlugin],
      semi: true,
      singleQuote: true,
      trailingComma: "es5",
    });
    replaceDocument(formatted, documentID, documentVersion + 1);
    scheduleSave();
    return true;
  } catch (error) {
    callNative(bridge, "diagnostics.publish", { message: String(error), severity: "error" }, documentID);
    return false;
  }
}

function setReadOnly(value) {
  view.dispatch({ effects: readOnly.reconfigure(EditorState.readOnly.of(Boolean(value))) });
}

function setTheme(mode) {
  const resolved = mode === "dark" || mode === "light" ? mode : systemTheme();
  document.documentElement.dataset.theme = resolved;
  view.dispatch({ effects: theme.reconfigure(studioTheme(resolved)) });
}

function publishDiagnostics(items = []) {
  const diagnostics = items.map((item) => ({
    from: Math.max(0, Math.min(item.from ?? 0, view.state.doc.length)),
    to: Math.max(0, Math.min(item.to ?? item.from ?? 0, view.state.doc.length)),
    severity: item.severity ?? "error",
    message: item.message ?? "Unknown error",
  }));
  view.dispatch(setDiagnostics(view.state, diagnostics));
}

function register(name, handler) {
  bridge.registerHandler(name, async (data = {}, callback = () => {}) => {
    try {
      callback({ result: "ok", ...(await handler(data)) });
    } catch (error) {
      callback({ result: "failed", message: String(error) });
    }
  });
}

connectNativeBridge((nativeBridge) => {
  bridge = nativeBridge;

  register(StudioMessage.documentOpen, ({ payload = {}, documentID: id }) => {
    replaceDocument(payload.content, id, payload.version ?? 0);
    setReadOnly(payload.readOnly);
    return { protocolVersion: STUDIO_PROTOCOL_VERSION };
  });
  register(StudioMessage.documentReplace, ({ payload = {}, documentID: id }) => {
    replaceDocument(payload.content, id, payload.version ?? documentVersion);
    return {};
  });
  register(StudioMessage.documentSetReadOnly, ({ payload = {} }) => {
    setReadOnly(payload.readOnly);
    return { readOnly: Boolean(payload.readOnly) };
  });
  register(StudioMessage.editorInsert, ({ payload = {} }) => ({ inserted: insertText(payload.content ?? "") }));
  register(StudioMessage.editorFormat, async () => ({ formatted: await formatDocument() }));
  register(StudioMessage.editorSetTheme, ({ payload = {} }) => {
    setTheme(payload.theme);
    return {};
  });
  register(StudioMessage.editorGetState, () => ({
    content: view.state.doc.toString(),
    version: documentVersion,
    documentID,
    selection: { from: view.state.selection.main.from, to: view.state.selection.main.to },
  }));
  register(StudioMessage.diagnosticsPublish, ({ payload = {} }) => {
    publishDiagnostics(payload.items);
    return {};
  });

  // Legacy handlers allow iOS and macOS to migrate independently.
  register("editor_setValue", ({ value }) => { replaceDocument(value); return {}; });
  register("editor_insertValue", ({ value }) => ({ inserted: insertText(value ?? "") }));
  register("editor_getValue", () => ({ value: view.state.doc.toString() }));
  register("editor_setReadonly", ({ readonly }) => { setReadOnly(readonly); return { readonly: Boolean(readonly) }; });
  register("editor_formatCode", async () => ({ formatted: await formatDocument() }));

  announceReady(bridge);
});

window.matchMedia?.("(prefers-color-scheme: dark)").addEventListener("change", () => setTheme("system"));

// Browser development mode remains useful without a native bridge.
if (!window.webkit) {
  replaceDocument(`// ScriptWidget Studio\nconst widget = (\n  <VStack>\n    <Text text="Hello, ScriptWidget" />\n  </VStack>\n);\n`);
}
