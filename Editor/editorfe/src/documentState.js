const prefix = "scriptwidget.studio.document-state.v1.";

export function saveDocumentState(storage, documentID, state) {
  if (!storage || !documentID) return false;
  try {
    storage.setItem(`${prefix}${documentID}`, JSON.stringify({
      anchor: Number(state.anchor) || 0,
      head: Number(state.head) || 0,
      scrollTop: Number(state.scrollTop) || 0,
    }));
    return true;
  } catch {
    return false;
  }
}

export function loadDocumentState(storage, documentID, documentLength) {
  if (!storage || !documentID) return null;
  try {
    const value = JSON.parse(storage.getItem(`${prefix}${documentID}`));
    if (!value || typeof value !== "object") return null;
    const clamp = (number) => Math.max(0, Math.min(Number(number) || 0, documentLength));
    return { anchor: clamp(value.anchor), head: clamp(value.head), scrollTop: Math.max(0, Number(value.scrollTop) || 0) };
  } catch {
    return null;
  }
}
