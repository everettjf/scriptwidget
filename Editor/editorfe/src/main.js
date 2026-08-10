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
import { initialStudioState, recoverableDraft, reduceStudioState, removeDraft, writeDraft } from "./webStudioState.js";
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
let webStudioController = null;

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
      if (isWebStudio) return;
      setSaveStatus(response.result === "ok" || response.result === "unavailable" ? "Saved" : "Save failed", response.result === "failed" ? "error" : "saved");
    });
  }, 700);
}

function onEditorUpdate(update) {
  if (update.selectionSet || update.viewportChanged || update.docChanged) persistEditorState();
  if (!update.docChanged || suppressChanges) return;
  documentVersion += 1;
  webStudioController?.documentChanged();
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
  const grid = document.querySelector("#studio-grid");
  const editorColumn = document.querySelector(".editor-column");
  const recoveryBanner = document.querySelector("#recovery-banner");
  const conflictBanner = document.querySelector("#conflict-banner");
  const commandDialog = document.querySelector("#command-dialog");
  const commandSearch = document.querySelector("#command-search");
  const commandList = document.querySelector("#command-list");
  const compareDialog = document.querySelector("#compare-dialog");
  let token = window.sessionStorage.getItem("scriptwidget.web-studio.token") || "";
  let packages = [];
  let heartbeatTimer = null;
  let diagnosticsTimer = null;
  let remoteRevision = "";
  let serverContent = "";
  let conflict = null;
  let studioState = initialStudioState();

  class StudioAPIError extends Error {
    constructor(message, status, body = {}) {
      super(message);
      this.status = status;
      this.body = body;
    }
  }

  function requirePairing(message = "Session ended. Enter the new code shown on your device.") {
    token = "";
    window.sessionStorage.removeItem("scriptwidget.web-studio.token");
    disconnectButton.hidden = true;
    updateState({ type: "DISCONNECTED" });
    connectionStatus.textContent = message;
    setReadOnly(true);
    if (!dialog.open) dialog.showModal();
  }

  function updateState(event) {
    studioState = reduceStudioState(studioState, event);
    const labels = { connecting: "Connecting", connected: "Connected", offline: "Offline", disconnected: "Disconnected" };
    const saveLabels = { idle: "Ready", draft: "Draft saved locally", saving: "Saving…", saved: "Saved", error: "Save failed", conflict: "Conflict" };
    connectionStatus.dataset.state = studioState.connection;
    document.querySelector("#status-connection").textContent = labels[studioState.connection] || studioState.connection;
    setSaveStatus(saveLabels[studioState.save] || studioState.save, studioState.save);
    document.querySelector("#dirty-indicator").hidden = !["draft", "saving", "error", "conflict"].includes(studioState.save);
    document.querySelector("#status-preview").textContent = studioState.preview === "requested" ? "Preview requested" : "Preview idle";
    document.querySelector("#preview-detail").textContent = studioState.preview === "requested" ? "Requested on device" : "Not requested";
  }

  async function api(path, options = {}) {
    const response = await fetch(path, {
      ...options,
      headers: { "Content-Type": "application/json", "X-Studio-Token": token, ...(options.headers || {}) },
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = new StudioAPIError(body.message || `Request failed (${response.status})`, response.status, body);
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
    updateState({ type: "CONNECTED" });
    startHeartbeat();
  }

  function startHeartbeat() {
    window.clearInterval(heartbeatTimer);
    heartbeatTimer = window.setInterval(async () => {
      if (!token) return;
      try {
        const session = await api("/api/v1/session");
        if (!navigator.onLine) return;
        applySession(session);
        updateState({ type: "CONNECTED" });
      } catch (error) {
        if (error.status !== 401) {
          connectionStatus.textContent = `Interrupted · ${error.message}`;
          updateState({ type: "OFFLINE" });
        }
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
    const nextID = `${packageSelect.value}/${fileSelect.value}`;
    remoteRevision = result.revision;
    serverContent = result.content;
    conflict = null;
    conflictBanner.hidden = true;
    replaceDocument(result.content, nextID, 0);
    setReadOnly(Boolean(result.readOnly));
    updateDocumentChrome(result);
    const draft = recoverableDraft(window.localStorage, nextID, result.content, result.revision);
    recoveryBanner.hidden = !draft;
    recoveryBanner._draft = draft;
    document.querySelector("#recovery-message").textContent = draft?.isStale ? "The device version also changed. Review before saving." : "Restore it or keep the device version.";
    connectionStatus.textContent = "Connected";
    updateState({ type: "CONNECTED" });
    disconnectButton.hidden = false;
    renderProblems();
    startHeartbeat();
  }

  function updateDocumentChrome(result) {
    document.querySelector("#breadcrumb-package").textContent = result.packageName || packageSelect.value;
    document.querySelector("#breadcrumb-file").textContent = fileSelect.value;
    document.querySelector("#editor-tab-name").textContent = fileSelect.value;
    document.querySelector("#revision-detail").textContent = remoteRevision ? remoteRevision.slice(0, 8) : "—";
    document.querySelector("#access-detail").textContent = result.readOnly ? "Read only" : "Editable";
  }

  function applySession(session) {
    if (session.device) {
      document.querySelector("#device-name").textContent = session.device.name || session.device.model;
      document.querySelector("#device-system").textContent = `${session.device.model} · ${session.device.system}`;
    }
    if (session.preview?.package) document.querySelector("#preview-target").textContent = session.preview.package;
  }

  function renderProblems() {
    const items = scriptWidgetDiagnostics(view);
    const list = document.querySelector("#problems-list");
    list.replaceChildren(...items.map((item) => {
      const line = view.state.doc.lineAt(item.from);
      const li = document.createElement("li");
      li.className = `problem-item ${item.severity}`;
      const button = document.createElement("button");
      button.type = "button";
      button.innerHTML = `<span class="problem-severity">${item.severity === "error" ? "●" : "▲"}</span><span></span><span class="problem-location">Ln ${line.number}</span>`;
      button.children[1].textContent = item.message;
      button.addEventListener("click", () => { view.dispatch({ selection: { anchor: item.from }, scrollIntoView: true }); view.focus(); });
      li.append(button);
      return li;
    }));
    document.querySelector("#problems-count").textContent = String(items.length);
    document.querySelector("#status-problem-count").textContent = String(items.length);
    document.querySelector("#problems-summary").textContent = items.length ? `${items.filter((x) => x.severity === "error").length} errors, ${items.filter((x) => x.severity !== "error").length} warnings` : "No problems detected";
  }

  async function saveWebDocument(content, callback, overrideRevision = null) {
    updateState({ type: "SAVING" });
    try {
      const result = await api("/api/v1/document", { method: "PUT", body: JSON.stringify({ package: packageSelect.value, path: fileSelect.value, content, baseRevision: overrideRevision ?? remoteRevision }) });
      remoteRevision = result.revision;
      serverContent = content;
      removeDraft(window.localStorage, documentID);
      conflict = null;
      conflictBanner.hidden = true;
      document.querySelector("#revision-detail").textContent = remoteRevision.slice(0, 8);
      updateState({ type: "SAVED", preview: result.preview?.state });
      callback({ result: "ok", ...result });
    } catch (error) {
      if (error.status === 409) {
        conflict = error.body;
        conflictBanner.hidden = false;
        updateState({ type: "CONFLICT", conflict });
      } else {
        updateState({ type: "SAVE_FAILED" });
      }
      callback({ result: "failed", message: error.message });
    }
  }

  bridge = {
    registerHandler() {},
    callHandler(name, envelope, callback = () => {}) {
      if (name === StudioMessage.documentSave) {
        saveWebDocument(envelope.payload.content, callback);
      } else {
        callback({ result: "ok" });
      }
    },
  };

  webStudioController = {
    documentChanged() {
      writeDraft(window.localStorage, documentID, view.state.doc.toString(), remoteRevision);
      updateState({ type: "EDITED" });
      window.clearTimeout(diagnosticsTimer);
      diagnosticsTimer = window.setTimeout(renderProblems, 380);
    },
  };

  packageSelect.addEventListener("change", () => loadFiles().catch(showError));
  fileSelect.addEventListener("change", () => loadDocument().catch(showError));
  function showError(error) { connectionStatus.textContent = error.message || String(error); updateState({ type: "SAVE_FAILED" }); }

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

  document.querySelector("#restore-draft").addEventListener("click", () => {
    const draft = recoveryBanner._draft;
    if (!draft) return;
    replaceDocument(draft.content, draft.documentID, documentVersion + 1);
    recoveryBanner.hidden = true;
    writeDraft(window.localStorage, documentID, draft.content, remoteRevision);
    updateState({ type: "EDITED" });
    renderProblems();
  });
  document.querySelector("#discard-draft").addEventListener("click", () => { removeDraft(window.localStorage, documentID); recoveryBanner.hidden = true; });
  document.querySelector("#reload-server").addEventListener("click", () => { if (!conflict) return; removeDraft(window.localStorage, documentID); remoteRevision = conflict.currentRevision; serverContent = conflict.currentContent; replaceDocument(serverContent, documentID, documentVersion + 1); conflict = null; conflictBanner.hidden = true; updateState({ type: "SAVED" }); renderProblems(); });
  document.querySelector("#keep-local").addEventListener("click", () => { if (conflict) saveWebDocument(view.state.doc.toString(), () => {}, conflict.currentRevision); });
  document.querySelector("#compare-conflict").addEventListener("click", () => { document.querySelector("#compare-local").textContent = view.state.doc.toString(); document.querySelector("#compare-server").textContent = conflict?.currentContent || serverContent; compareDialog.showModal(); });
  compareDialog.querySelector("button").addEventListener("click", () => compareDialog.close());

  function toggleProblems() { const collapsed = editorColumn.classList.toggle("problems-collapsed"); document.querySelector("#problems-toggle").setAttribute("aria-expanded", String(!collapsed)); }
  function togglePanel(name) { grid.classList.toggle(`show-${name}`); }
  document.querySelector("#problems-toggle").addEventListener("click", toggleProblems);
  document.querySelector("#status-problems").addEventListener("click", () => { editorColumn.classList.remove("problems-collapsed"); });
  document.querySelector("#explorer-button").addEventListener("click", () => togglePanel("explorer"));
  document.querySelector("#inspector-button").addEventListener("click", () => togglePanel("inspector"));
  document.querySelectorAll("[data-close-panel]").forEach((button) => button.addEventListener("click", () => grid.classList.remove(`show-${button.dataset.closePanel}`)));

  const commands = [
    { name: "Save Document", keys: "⌘S", run: () => { window.clearTimeout(saveTimer); saveWebDocument(view.state.doc.toString(), () => {}); } },
    { name: "Format Document", keys: "⇧⌥F", run: formatDocument },
    { name: "Toggle Problems", keys: "⌘J", run: toggleProblems },
    { name: "Toggle Explorer", keys: "⌘⇧E", run: () => togglePanel("explorer") },
    { name: "Toggle Inspector", keys: "", run: () => togglePanel("inspector") },
    { name: "Use Light Theme", keys: "", run: () => setTheme("light") },
    { name: "Use Dark Theme", keys: "", run: () => setTheme("dark") },
  ];
  function renderCommands(query = "") {
    const filtered = commands.filter((command) => command.name.toLowerCase().includes(query.toLowerCase()));
    commandList.replaceChildren(...filtered.map((command) => { const li = document.createElement("li"); const button = document.createElement("button"); button.type = "button"; button.className = "command"; const name = document.createElement("span"); name.textContent = command.name; const keys = document.createElement("kbd"); keys.textContent = command.keys; button.append(name, keys); button.addEventListener("click", () => { commandDialog.close(); command.run(); }); li.append(button); return li; }));
  }
  function openCommands() { renderCommands(); commandDialog.showModal(); commandSearch.value = ""; commandSearch.focus(); }
  document.querySelector("#command-button").addEventListener("click", openCommands);
  commandSearch.addEventListener("input", () => renderCommands(commandSearch.value));
  document.addEventListener("keydown", (event) => {
    const command = event.metaKey || event.ctrlKey;
    if (command && event.shiftKey && event.key.toLowerCase() === "p") { event.preventDefault(); openCommands(); }
    else if (command && event.key.toLowerCase() === "s") { event.preventDefault(); commands[0].run(); }
    else if (command && event.key.toLowerCase() === "j") { event.preventDefault(); toggleProblems(); }
    else if (command && event.shiftKey && event.key.toLowerCase() === "e") { event.preventDefault(); togglePanel("explorer"); }
    else if (event.shiftKey && event.altKey && event.key.toLowerCase() === "f") { event.preventDefault(); formatDocument(); }
  });

  view.dom.addEventListener("keyup", updateCursor);
  view.dom.addEventListener("mouseup", updateCursor);
  function updateCursor() { const head = view.state.selection.main.head; const line = view.state.doc.lineAt(head); document.querySelector("#cursor-position").textContent = `Ln ${line.number}, Col ${head - line.from + 1}`; }

  window.addEventListener("offline", () => {
    connectionStatus.textContent = "Computer is offline";
    updateState({ type: "OFFLINE" });
  });
  window.addEventListener("online", () => {
    if (token) api("/api/v1/session").then((session) => { applySession(session); updateState({ type: "CONNECTED" }); return loadPackages(); }).catch(showError);
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
