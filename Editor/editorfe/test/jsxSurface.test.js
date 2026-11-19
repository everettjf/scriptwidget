import assert from "node:assert/strict";
import test from "node:test";
import { jsxSurfaceText, staleOutputs } from "../scripts/generate-jsx-surface.mjs";

test("the generated tag and attribute lists are current", async () => {
  assert.deepEqual(await staleOutputs(), [], "run `npm run docs` in Editor/editorfe");
});

test("the list names every tag in lower case and only checks values of closed lists", () => {
  const lines = jsxSurfaceText().split("\n");
  assert.ok(lines.includes("tag date date style=time|date|relative|offset|timer"));
  assert.ok(lines.includes("tag vstack spacing"));
  assert.ok(lines.includes("tag@android list spacing"));
  assert.ok(lines.includes("global font"), "font takes more forms than the metadata lists");
  assert.ok(lines.some((line) => line.startsWith("global weight=")));
  assert.ok(lines.every((line) => /^(global|tag|tag@[a-z]+|leaf) /.test(line)));
  const leaf = lines.find((line) => line.startsWith("leaf ")).split(" ");
  assert.ok(leaf.includes("text") && leaf.includes("date") && !leaf.includes("vstack") && !leaf.includes("link"));
});
