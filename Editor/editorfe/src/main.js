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
import { loadDocumentState, saveDocumentState } from "./documentState.js";
import "./style.css";

const isWebStudio = /^https?:$/.test(window.location.protocol);
const editorParent = document.querySelector(isWebStudio ? "#editor" : "#native-editor");

const readOnly = new Compartment();
const theme = new Compartment();
let bridge = null;
let documentID = null;
let documentVersion = 0;
let suppressChanges = false;
let saveTimer = null;
let stateTimer = null;
const saveStatus = document.querySelector("#save-status");

function setSaveStatus(value, state = "idle") {
  saveStatus.textContent = value;
  saveStatus.dataset.state = state;
}

function persistEditorState() {
  window.clearTimeout(stateTimer);
  stateTimer = window.setTimeout(() => {
    const selection = view.state.selection.main;
    saveDocumentState(window.localStorage, documentID, {
      anchor: selection.anchor,
      head: selection.head,
      scrollTop: view.scrollDOM.scrollTop,
    });
  }, 180);
}

function systemTheme() {
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function scheduleSave() {
  window.clearTimeout(saveTimer);
  setSaveStatus("Saving…", "saving");
  saveTimer = window.setTimeout(() => {
    const content = view.state.doc.toString();
    callNative(bridge, StudioMessage.documentSave, { content, version: documentVersion }, documentID, (response = {}) => {
      setSaveStatus(response.result === "ok" || response.result === "unavailable" ? "Saved" : "Save failed", response.result === "failed" ? "error" : "saved");
    });
  }, 700);
}

function onEditorUpdate(update) {
  if (update.selectionSet || update.viewportChanged || update.docChanged) persistEditorState();
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
  parent: editorParent,
});

function replaceDocument(content, nextDocumentID = documentID, version = 0) {
  const previousSelection = view.state.selection.main;
  saveDocumentState(window.localStorage, documentID, { anchor: previousSelection.anchor, head: previousSelection.head, scrollTop: view.scrollDOM.scrollTop });
  suppressChanges = true;
  documentID = nextDocumentID;
  documentVersion = version;
  const restored = loadDocumentState(window.localStorage, documentID, (content ?? "").length);
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: content ?? "" },
    selection: restored ? { anchor: restored.anchor, head: restored.head } : { anchor: 0 },
    scrollIntoView: true,
  });
  if (restored) window.requestAnimationFrame(() => { view.scrollDOM.scrollTop = restored.scrollTop; });
  suppressChanges = false;
  setSaveStatus("Saved", "saved");
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

if (isWebStudio) {
  document.querySelector("#native-editor").hidden = true;
  document.querySelector("#web-studio").hidden = false;
  startWebStudio();
}

async function startWebStudio() {
  const dialog = document.querySelector("#pair-dialog");
  const form = document.querySelector("#pair-form");
  const errorOutput = document.querySelector("#pair-error");
  const packageSelect = document.querySelector("#package-select");
  const fileSelect = document.querySelector("#file-select");
  const connectionStatus = document.querySelector("#connection-status");
  const disconnectButton = document.querySelector("#disconnect-button");
  let token = window.sessionStorage.getItem("scriptwidget.web-studio.token") || "";
  let packages = [];
  let heartbeatTimer = null;

  class StudioAPIError extends Error {
    constructor(message, status) {
      super(message);
      this.status = status;
    }
  }

  function requirePairing(message = "Session ended. Enter the new code shown on your device.") {
    token = "";
    window.sessionStorage.removeItem("scriptwidget.web-studio.token");
    disconnectButton.hidden = true;
    connectionStatus.textContent = message;
    setReadOnly(true);
    if (!dialog.open) dialog.showModal();
  }

  async function api(path, options = {}) {
    const response = await fetch(path, {
      ...options,
      headers: { "Content-Type": "application/json", "X-Studio-Token": token, ...(options.headers || {}) },
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = new StudioAPIError(body.message || `Request failed (${response.status})`, response.status);
      if (response.status === 401 && path !== "/api/v1/pair") requirePairing();
      throw error;
    }
    return body;
  }

  async function pair(code) {
    const result = await api("/api/v1/pair", { method: "POST", body: JSON.stringify({ code }) });
    token = result.token;
    window.sessionStorage.setItem("scriptwidget.web-studio.token", token);
    disconnectButton.hidden = false;
    startHeartbeat();
  }

  function startHeartbeat() {
    window.clearInterval(heartbeatTimer);
    heartbeatTimer = window.setInterval(async () => {
      if (!token) return;
      try {
        await api("/api/v1/session");
        if (!navigator.onLine) return;
        connectionStatus.dataset.state = "connected";
      } catch (error) {
        if (error.status !== 401) connectionStatus.textContent = `Connection interrupted · ${error.message}`;
      }
    }, 5000);
  }

  async function loadPackages() {
    const result = await api("/api/v1/packages");
    packages = result.packages || [];
    packageSelect.replaceChildren(...packages.map((item) => new Option(item.name, item.id)));
    if (!packages.length) {
      connectionStatus.textContent = "No editable widgets";
      setReadOnly(true);
      return;
    }
    await loadFiles();
  }

  async function loadFiles() {
    const selected = packages.find((item) => item.id === packageSelect.value);
    const files = selected?.files || [];
    fileSelect.replaceChildren(...files.map((path) => new Option(path, path)));
    const preferred = files.includes(selected?.entry) ? selected.entry : files[0];
    if (preferred) fileSelect.value = preferred;
    await loadDocument();
  }

  async function loadDocument() {
    if (!packageSelect.value || !fileSelect.value) return;
    const query = new URLSearchParams({ package: packageSelect.value, path: fileSelect.value });
    const result = await api(`/api/v1/document?${query}`);
    replaceDocument(result.content, `${packageSelect.value}/${fileSelect.value}`, result.version || 0);
    setReadOnly(Boolean(result.readOnly));
    connectionStatus.textContent = `Connected · Previewing ${result.packageName}`;
    disconnectButton.hidden = false;
    startHeartbeat();
  }

  bridge = {
    registerHandler() {},
    callHandler(name, envelope, callback = () => {}) {
      if (name === StudioMessage.documentSave) {
        const body = JSON.stringify({
          package: packageSelect.value,
          path: fileSelect.value,
          content: envelope.payload.content,
          baseVersion: envelope.payload.version,
        });
        api("/api/v1/document", { method: "PUT", body })
          .then((result) => callback({ result: "ok", ...result }))
          .catch((error) => callback({ result: "failed", message: String(error) }));
      } else {
        callback({ result: "ok" });
      }
    },
  };

  packageSelect.addEventListener("change", () => loadFiles().catch(showError));
  fileSelect.addEventListener("change", () => loadDocument().catch(showError));
  function showError(error) { connectionStatus.textContent = String(error); }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    errorOutput.textContent = "";
    try {
      await pair(document.querySelector("#pair-code").value);
      dialog.close();
      await loadPackages();
    } catch (error) { errorOutput.textContent = error.message; }
  });

  disconnectButton.addEventListener("click", async () => {
    try { await api("/api/v1/session", { method: "DELETE" }); } catch {}
    requirePairing("Disconnected. Start a new session with the code on your device.");
  });

  window.addEventListener("offline", () => {
    connectionStatus.textContent = "Computer is offline";
  });
  window.addEventListener("online", () => {
    if (token) api("/api/v1/session").then(loadPackages).catch(showError);
  });

  try {
    await loadPackages();
  } catch {
    requirePairing("Pair with the code shown on your device.");
  }
}

window.matchMedia?.("(prefers-color-scheme: dark)").addEventListener("change", () => setTheme("system"));

// Browser development mode remains useful without a native bridge.
if (!window.webkit) {
  replaceDocument(`// ScriptWidget Studio\nconst widget = (\n  <VStack>\n    <Text text="Hello, ScriptWidget" />\n  </VStack>\n);\n`);
}
