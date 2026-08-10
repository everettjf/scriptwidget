import test from "node:test";
import assert from "node:assert/strict";
import { EditorState } from "@codemirror/state";
import { javascript } from "@codemirror/lang-javascript";
import { readFile } from "node:fs/promises";
import { scriptWidgetAPI } from "../src/scriptWidgetCompletions.js";
import { scriptWidgetDiagnostics, openingTags } from "../src/scriptWidgetLanguage.js";

function viewFor(source) {
  return { state: EditorState.create({ doc: source, extensions: [javascript({ jsx: true })] }) };
}

test("editor metadata has unique component names and documented properties", () => {
  const names = Object.keys(scriptWidgetAPI.components);
  assert.equal(new Set(names).size, names.length);
  assert.ok(names.length >= 25);
  for (const [name, component] of Object.entries(scriptWidgetAPI.components)) {
    assert.ok(component.documentation, `${name} needs documentation`);
    for (const [property, definition] of Object.entries(component.properties ?? {})) {
      assert.ok(definition.type, `${name}.${property} needs a type`);
    }
  }
});

test("JSX opening tags are read from the CodeMirror syntax tree", () => {
  const tags = openingTags(viewFor('<VStack spacing={4}><Text text="Hi" /></VStack>').state);
  assert.deepEqual(tags.map((tag) => tag.name), ["VStack", "Text"]);
});

test("diagnostics report unsupported and missing required properties", () => {
  const diagnostics = scriptWidgetDiagnostics(viewFor('<Progress mystery="x" />'));
  assert.ok(diagnostics.some((item) => item.message.includes("not supported")));
  assert.ok(diagnostics.some((item) => item.message.includes("requires the “value”")));
});

test("custom components are accepted by diagnostics", () => {
  assert.deepEqual(scriptWidgetDiagnostics(viewFor("<MyComponent custom />")), []);
});

test("editor metadata stays aligned with the authoritative native runtime switch", async () => {
  const source = await readFile(new URL("../../../Shared/ScriptWidgetRuntime/Widget/Component/ScriptWidgetElementView.swift", import.meta.url), "utf8");
  const runtimeTags = [...source.matchAll(/case "([a-z]+)"\s*:/g)].map((match) => match[1]).sort();
  const metadataTags = Object.keys(scriptWidgetAPI.components).map((name) => name.toLowerCase()).sort();
  assert.deepEqual(metadataTags, runtimeTags);
});
