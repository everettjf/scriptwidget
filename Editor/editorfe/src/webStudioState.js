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

export class DocumentSaveCoordinator {
  constructor(send) {
    this.send = send;
    this.epoch = 0;
    this.context = null;
    this.inFlight = null;
    this.needsFlush = false;
  }

  open({ documentID, packageID, path, revision, content }) {
    this.epoch += 1;
    this.context = { documentID, packageID, path, revision, content, generation: 0, savedGeneration: 0 };
    this.needsFlush = false;
    return this.snapshot();
  }

  edit(content) {
    if (!this.context) return null;
    this.context.content = content;
    this.context.generation += 1;
    return this.snapshot();
  }

  rebase(revision) {
    if (this.context) this.context.revision = revision;
    return this.snapshot();
  }

  get isDirty() {
    return Boolean(this.context && this.context.generation !== this.context.savedGeneration);
  }

  snapshot() {
    return this.context ? { ...this.context, dirty: this.isDirty } : null;
  }

  async flush() {
    if (!this.context || !this.isDirty) return { skipped: true, snapshot: this.snapshot() };
    if (this.inFlight) {
      this.needsFlush = true;
      return this.inFlight.then(() => (this.isDirty ? this.flush() : { skipped: true, snapshot: this.snapshot() }));
    }

    const epoch = this.epoch;
    const request = { ...this.context };
    this.needsFlush = false;
    this.inFlight = this.send({
      documentID: request.documentID,
      packageID: request.packageID,
      path: request.path,
      content: request.content,
      baseRevision: request.revision,
    }).then((result) => {
      if (this.epoch !== epoch || this.context?.documentID !== request.documentID) {
        return { ignored: true, result, snapshot: this.snapshot() };
      }
      this.context.revision = result.revision;
      this.context.savedGeneration = request.generation;
      return { result, snapshot: this.snapshot() };
    }).finally(() => {
      this.inFlight = null;
    });

    const completed = await this.inFlight;
    if (this.needsFlush && this.isDirty) return this.flush();
    return completed;
  }
}

export function shouldWarnBeforeLeaving(saveState) {
  return ["draft", "saving", "error", "conflict"].includes(saveState);
}
