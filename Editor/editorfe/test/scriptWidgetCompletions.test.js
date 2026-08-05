import test from "node:test";
import assert from "node:assert/strict";
import { scriptWidgetCompletionOptions, scriptWidgetCompletions } from "../src/scriptWidgetCompletions.js";

function context(text, explicit = false) {
  return {
    pos: text.length,
    explicit,
    matchBefore(pattern) {
      const match = text.match(pattern);
      if (!match || match.index + match[0].length !== text.length) return null;
      return { from: match.index, to: text.length, text: match[0] };
    },
  };
}

test("component completions appear after an opening JSX bracket", () => {
  const result = scriptWidgetCompletions(context("const view = <VS"));
  assert.equal(result.from, "const view = <".length);
  assert.ok(result.options.some((option) => option.label === "VStack"));
});

test("component completions stay quiet in ordinary JavaScript", () => {
  assert.equal(scriptWidgetCompletions(context("const value")), null);
});

test("completion labels are unique", () => {
  const labels = scriptWidgetCompletionOptions.map((option) => option.label);
  assert.equal(new Set(labels).size, labels.length);
});
