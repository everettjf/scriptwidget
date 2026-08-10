const DRAFT_PREFIX = "scriptwidget.web-studio.draft.v1:";

export function draftKey(documentID) {
  return `${DRAFT_PREFIX}${documentID}`;
}

export function readDraft(storage, documentID) {
  if (!documentID) return null;
  try {
    const value = JSON.parse(storage.getItem(draftKey(documentID)) || "null");
    return value && typeof value.content === "string" && typeof value.baseRevision === "string" ? value : null;
  } catch {
    return null;
  }
}

export function writeDraft(storage, documentID, content, baseRevision, now = Date.now()) {
  if (!documentID || typeof baseRevision !== "string") return null;
  const draft = { documentID, content, baseRevision, updatedAt: now };
  storage.setItem(draftKey(documentID), JSON.stringify(draft));
  return draft;
}

export function removeDraft(storage, documentID) {
  if (documentID) storage.removeItem(draftKey(documentID));
}

export function recoverableDraft(storage, documentID, serverContent, serverRevision) {
  const draft = readDraft(storage, documentID);
  if (!draft || draft.content === serverContent) return null;
  return { ...draft, serverContent, serverRevision, isStale: draft.baseRevision !== serverRevision };
}

export function initialStudioState() {
  return { connection: "connecting", save: "idle", preview: "idle", conflict: null };
}

export function reduceStudioState(state, event) {
  switch (event.type) {
  case "CONNECTED": return { ...state, connection: "connected" };
  case "OFFLINE": return { ...state, connection: "offline", save: state.save === "saving" ? "draft" : state.save };
  case "DISCONNECTED": return { ...state, connection: "disconnected" };
  case "EDITED": return { ...state, save: "draft", conflict: null };
  case "SAVING": return { ...state, save: "saving" };
  case "SAVED": return { ...state, save: "saved", preview: event.preview || "requested", conflict: null };
  case "SAVE_FAILED": return { ...state, save: "error" };
  case "CONFLICT": return { ...state, save: "conflict", conflict: event.conflict };
  default: return state;
  }
}
