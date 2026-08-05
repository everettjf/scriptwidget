import test from "node:test";
import assert from "node:assert/strict";
import { loadDocumentState, saveDocumentState } from "../src/documentState.js";

function memoryStorage() {
  const values = new Map();
  return { setItem: (key, value) => values.set(key, value), getItem: (key) => values.get(key) ?? null };
}

test("document cursor and scroll state round trips", () => {
  const storage = memoryStorage();
  assert.equal(saveDocumentState(storage, "/widget/main.jsx", { anchor: 12, head: 18, scrollTop: 240 }), true);
  assert.deepEqual(loadDocumentState(storage, "/widget/main.jsx", 100), { anchor: 12, head: 18, scrollTop: 240 });
});

test("restored selections are clamped after a document shrinks", () => {
  const storage = memoryStorage();
  saveDocumentState(storage, "doc", { anchor: 90, head: 120, scrollTop: -5 });
  assert.deepEqual(loadDocumentState(storage, "doc", 20), { anchor: 20, head: 20, scrollTop: 0 });
});
