import test from "node:test";
import assert from "node:assert/strict";
import { initialStudioState, readDraft, recoverableDraft, reduceStudioState, removeDraft, writeDraft } from "../src/webStudioState.js";

function memoryStorage() {
  const values = new Map();
  return { getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: (key) => values.delete(key) };
}

test("drafts round-trip and clear per document", () => {
  const storage = memoryStorage();
  writeDraft(storage, "Widget/main.jsx", "local", "r1", 42);
  assert.deepEqual(readDraft(storage, "Widget/main.jsx"), { documentID: "Widget/main.jsx", content: "local", baseRevision: "r1", updatedAt: 42 });
  removeDraft(storage, "Widget/main.jsx");
  assert.equal(readDraft(storage, "Widget/main.jsx"), null);
});

test("recovery identifies drafts based on an older server revision", () => {
  const storage = memoryStorage();
  writeDraft(storage, "Widget/main.jsx", "local", "r1");
  const recovery = recoverableDraft(storage, "Widget/main.jsx", "remote", "r2");
  assert.equal(recovery.isStale, true);
  assert.equal(recoverableDraft(storage, "Widget/main.jsx", "local", "r2"), null);
});

test("save state machine preserves an offline draft and exposes conflicts", () => {
  let state = reduceStudioState(initialStudioState(), { type: "CONNECTED" });
  state = reduceStudioState(state, { type: "EDITED" });
  state = reduceStudioState(state, { type: "SAVING" });
  state = reduceStudioState(state, { type: "OFFLINE" });
  assert.deepEqual({ connection: state.connection, save: state.save }, { connection: "offline", save: "draft" });
  state = reduceStudioState(state, { type: "CONFLICT", conflict: { currentRevision: "r2" } });
  assert.equal(state.save, "conflict");
  assert.equal(state.conflict.currentRevision, "r2");
});
