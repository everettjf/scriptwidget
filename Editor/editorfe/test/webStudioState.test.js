import test from "node:test";
import assert from "node:assert/strict";
import { DocumentSaveCoordinator, initialStudioState, readDraft, recoverableDraft, reduceStudioState, removeDraft, shouldWarnBeforeLeaving, writeDraft } from "../src/webStudioState.js";

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

test("document saves are serialized and coalesce edits made during a request", async () => {
  const requests = [];
  const resolvers = [];
  const coordinator = new DocumentSaveCoordinator((request) => {
    requests.push(request);
    return new Promise((resolve) => resolvers.push(resolve));
  });
  coordinator.open({ documentID: "A/main.jsx", packageID: "A", path: "main.jsx", revision: "r0", content: "zero" });
  coordinator.edit("one");
  const first = coordinator.flush();
  coordinator.edit("two");
  const second = coordinator.flush();
  assert.equal(requests.length, 1);
  assert.deepEqual(requests[0], { documentID: "A/main.jsx", packageID: "A", path: "main.jsx", content: "one", baseRevision: "r0" });
  resolvers.shift()({ revision: "r1" });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(requests.length, 2);
  assert.equal(requests[1].content, "two");
  assert.equal(requests[1].baseRevision, "r1");
  resolvers.shift()({ revision: "r2" });
  const completions = await Promise.all([first, second]);
  assert.equal(coordinator.isDirty, false);
  assert.equal(coordinator.snapshot().revision, "r2");
  assert.equal(completions[0].result.revision, "r2");
  assert.equal(completions[1].snapshot.revision, "r2");
});

test("a response from a previous document cannot mutate the current document", async () => {
  let resolveSave;
  const coordinator = new DocumentSaveCoordinator(() => new Promise((resolve) => { resolveSave = resolve; }));
  coordinator.open({ documentID: "A/main.jsx", packageID: "A", path: "main.jsx", revision: "a0", content: "a" });
  coordinator.edit("a1");
  const saving = coordinator.flush();
  coordinator.open({ documentID: "B/main.jsx", packageID: "B", path: "main.jsx", revision: "b0", content: "b" });
  resolveSave({ revision: "a1" });
  const result = await saving;
  assert.equal(result.ignored, true);
  assert.equal(coordinator.snapshot().documentID, "B/main.jsx");
  assert.equal(coordinator.snapshot().revision, "b0");
});

test("only unsaved or conflicted states warn before navigation", () => {
  assert.equal(shouldWarnBeforeLeaving("saved"), false);
  assert.equal(shouldWarnBeforeLeaving("idle"), false);
  for (const state of ["draft", "saving", "error", "conflict"]) assert.equal(shouldWarnBeforeLeaving(state), true);
});
