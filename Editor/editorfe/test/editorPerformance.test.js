import test from "node:test";
import assert from "node:assert/strict";
import { performance } from "node:perf_hooks";
import { EditorState } from "@codemirror/state";
import { javascript } from "@codemirror/lang-javascript";

function sourceOfSize(bytes) {
  const line = "const value = <text color=\"#ffffff\">Hello ScriptWidget</text>;\n";
  return line.repeat(Math.ceil(bytes / Buffer.byteLength(line))).slice(0, bytes);
}

function median(values) {
  const ordered = [...values].sort((a, b) => a - b);
  return ordered[Math.floor(ordered.length / 2)];
}

for (const [label, bytes, budget] of [["100 KiB", 100 * 1024, 50], ["1 MiB", 1024 * 1024, 100]]) {
  test(`CodeMirror opens and edits ${label} within the release budget`, () => {
    const source = sourceOfSize(bytes);
    const timings = [];
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const started = performance.now();
      let state = EditorState.create({ doc: source, extensions: [javascript({ jsx: true })] });
      state = state.update({ changes: { from: state.doc.length, insert: " " } }).state;
      assert.equal(state.doc.length, source.length + 1);
      timings.push(performance.now() - started);
    }
    assert.ok(median(timings) < budget, `${label} median ${median(timings).toFixed(1)} ms exceeded ${budget} ms`);
  });
}
