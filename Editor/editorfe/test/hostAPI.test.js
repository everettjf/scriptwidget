import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import { EditorState } from "@codemirror/state";
import { javascript } from "@codemirror/lang-javascript";
import { readHostAPI } from "../src/hostAPI.js";
import { scriptWidgetAPI } from "../src/scriptWidgetAPI.js";
import { scriptWidgetCompletionOptions, scriptWidgetCompletions } from "../src/scriptWidgetCompletions.js";
import { scriptWidgetDiagnostics, scriptWidgetHover } from "../src/scriptWidgetLanguage.js";

function context(text, explicit = false) {
  return {
    pos: text.length,
    explicit,
    state: { doc: { sliceString: (from, to) => text.slice(from, to) } },
    matchBefore(pattern) {
      const match = text.match(pattern);
      if (!match || match.index + match[0].length !== text.length) return null;
      return { from: match.index, to: text.length, text: match[0] };
    },
  };
}

function view(source) {
  return { state: EditorState.create({ doc: source, extensions: [javascript({ jsx: true })] }) };
}

const inputs = [
  ["const view = <VS", false], ["const view = <li", false], ["<Progress val", false], ["<list sp", false],
  ['<Progress style="cir', false], ['<Text color="', false], ['<vstack background="material.', false],
  ['<Progress trackColor="ma', false], ["const feed = $xml.pa", false], ["const value", false], ["", true],
];
const sources = ['const a = <list spacing="2" bogus="1"><Text text="a" /></list>;', '<Progress bogus="1" />', "<VStack><list/></VStack>"];

function snapshot() {
  return JSON.stringify({
    completions: inputs.map(([text, explicit]) => scriptWidgetCompletions(context(text, explicit))),
    diagnostics: sources.map((source) => scriptWidgetDiagnostics(view(source))),
    hovers: sources.map((source) => [...source].map((_, position) => scriptWidgetHover(view(source), position)?.pos ?? null)),
  }, (key, value) => (value instanceof RegExp ? String(value) : value));
}

function withHost(value, run) {
  globalThis.ScriptWidgetHostAPI = value;
  try { return run(); } finally { delete globalThis.ScriptWidgetHostAPI; }
}

const android = {
  components: { list: { documentation: "Scrolls.", children: true, properties: { spacing: { type: "number", documentation: "Gap." } } } },
  colors: ["material.primary", "material.onSurface"],
};

test("without the global the editor offers exactly the built-in metadata", () => {
  assert.equal(globalThis.ScriptWidgetHostAPI, undefined);
  const tags = scriptWidgetCompletions(context("const view = <li"));
  assert.deepEqual(tags.options.map((option) => option.template), scriptWidgetCompletionOptions.map((option) => option.template));
  assert.deepEqual(tags.options.map((option) => option.label), Object.keys(scriptWidgetAPI.components));
  assert.equal(scriptWidgetCompletions(context('<Text color="')), null);
  assert.equal(scriptWidgetCompletions(context('<vstack background="material.')), null);
  assert.deepEqual(scriptWidgetCompletions(context("<list sp")).options, []);
  assert.deepEqual(scriptWidgetDiagnostics(view(sources[0])), []);
  assert.equal(scriptWidgetHover(view(sources[0]), 11), null);
  assert.deepEqual(scriptWidgetCompletions(context('<Progress style="cir')), {
    from: '<Progress style="'.length,
    options: [{ label: "linear", type: "enum" }, { label: "circular", type: "enum" }],
    validFor: /^[\w-]*$/,
  });
});

test("a global that is absent, empty or malformed changes nothing", () => {
  const plain = snapshot();
  class Other { constructor() { this.components = android.components; this.colors = android.colors; } }
  const malformed = [
    undefined, null, 0, "list", [], {}, { components: [], colors: {} }, { components: null, colors: "material.primary" },
    { components: { "": {}, "1x": {}, "a b": {}, "__proto__": {} }, colors: [1, null, "", "a b", "<x>", "a.b.c", "x".repeat(60)] },
    { components: { VStack: { documentation: "replaced", properties: {} }, vstack: { properties: {} }, Text: null } },
    { components: { list: "x" } }, new Other(), () => android,
    { get components() { throw new Error("no"); } },
  ];
  for (const value of malformed) assert.equal(withHost(value, snapshot), plain, `malformed[${malformed.indexOf(value)}]`);
  assert.equal(snapshot(), plain);
});

test("the host's tag completes, with its attributes, hover and attribute check", () => {
  withHost(android, () => {
    const tags = scriptWidgetCompletions(context("const view = <li"));
    assert.equal(tags.from, "const view = <".length);
    const labels = tags.options.map((option) => option.label);
    assert.deepEqual(labels, [...Object.keys(scriptWidgetAPI.components), "list"]);
    const list = tags.options.find((option) => option.label === "list");
    assert.equal(list.template, "<list>\n  ${}\n</list>");
    assert.equal(typeof list.apply, "function");
    assert.equal(list.info, "Scrolls.");

    const attributes = scriptWidgetCompletions(context("<list sp")).options;
    assert.equal(attributes.find((option) => option.label === "spacing").template, "spacing={${}}");
    assert.ok(attributes.some((option) => option.label === "padding"));

    const diagnostics = scriptWidgetDiagnostics(view(sources[0]));
    assert.deepEqual(diagnostics.map((item) => item.message), ["“bogus” is not supported by <list>."]);
    assert.equal(scriptWidgetHover(view(sources[0]), 11).pos, 11);
  });
  assert.equal(scriptWidgetCompletionOptions.some((option) => option.label === "list"), false);
});

test("the host's color names complete in a color value and nowhere else", () => {
  withHost(android, () => {
    const text = '<vstack background="material.';
    const result = scriptWidgetCompletions(context(text));
    assert.equal(result.from, '<vstack background="'.length);
    assert.deepEqual(result.options, [{ label: "material.primary", type: "constant" }, { label: "material.onSurface", type: "constant" }]);
    assert.ok(result.validFor.test("material.onSur"));
    assert.deepEqual(scriptWidgetCompletions(context('<Progress value={1} trackColor="')).options.map((option) => option.label), android.colors);
    assert.deepEqual(scriptWidgetCompletions(context("<text color='mat")).options.map((option) => option.label), android.colors);
    // Not after an opacity or inside a gradient, and not in other attributes.
    assert.equal(scriptWidgetCompletions(context('<text color="material.primary,0.')), null);
    assert.equal(scriptWidgetCompletions(context('<Text text="material.')), null);
    assert.deepEqual(scriptWidgetCompletions(context('<Progress style="')).options.map((option) => option.label), ["linear", "circular"]);
  });
});

test("the description is copied, bounded and never trusted for more than names and text", () => {
  const properties = Object.fromEntries(Array.from({ length: 50 }, (_, index) => [`p${index}`, { type: "string" }]));
  const result = readHostAPI({
    components: {
      list: { documentation: "d".repeat(5000), children: "yes", extra: 1, properties: { ...properties } },
      row: { properties: { a: { type: "function" }, b: { type: "enum" }, c: { type: "enum", values: ["x", 2, "y z"] }, d: { type: "number", required: true, conflicts: ["a"] } } },
    },
    colors: ["material.primary", "material.primary", "accent"],
  });
  assert.equal(result.components.list.documentation.length, 600);
  assert.equal(result.components.list.children, false);
  assert.deepEqual(Object.keys(result.components.list), ["documentation", "children", "properties"]);
  assert.equal(Object.keys(result.components.list.properties).length, 32);
  assert.deepEqual(result.components.row.properties, { c: { type: "enum", values: ["x"] }, d: { type: "number", required: true } });
  assert.deepEqual(result.colors, ["material.primary", "accent"]);
});

test("the Android bridge describes <list> and the material colors in a form the editor accepts", async () => {
  const source = await readFile(new URL("../../../Android/app/src/main/assets/studio/android-bridge.js", import.meta.url), "utf8");
  const window = { ScriptWidgetAndroid: { postMessage() {}, reply() {} } };
  vm.runInNewContext(source, { window });
  const supplied = JSON.parse(JSON.stringify(window.ScriptWidgetHostAPI));
  const read = readHostAPI(supplied);
  assert.deepEqual(read.components, supplied.components, "nothing the bridge supplies is dropped");
  assert.deepEqual(read.colors, supplied.colors);
  assert.deepEqual(Object.keys(read.components), ["list"]);
  assert.deepEqual(Object.keys(read.components.list.properties), ["spacing"]);
  assert.equal(read.colors.length, 25);
  assert.ok(read.colors.every((name) => name.startsWith("material.")));
  withHost(supplied, () => {
    assert.ok(scriptWidgetCompletions(context("<li")).options.some((option) => option.label === "list"));
    assert.ok(scriptWidgetCompletions(context('<text color="material.')).options.some((option) => option.label === "material.onSurfaceVariant"));
  });
  // Outside the Android WebView the bridge does nothing.
  const elsewhere = {};
  vm.runInNewContext(source, { window: elsewhere });
  assert.equal(elsewhere.ScriptWidgetHostAPI, undefined);
});

test("accepting a completion writes the tag once and leaves no snippet marks", async () => {
  const { EditorState } = await import("@codemirror/state");
  const { scriptWidgetCompletions: complete } = await import("../src/scriptWidgetCompletions.js");
  // Runs a completion's apply function against a minimal view and returns the document.
  function accept(text, label) {
    let state = EditorState.create({ doc: text, selection: { anchor: text.length } });
    const view = { get state() { return state; }, dispatch(...specs) { state = state.update(...specs).state; } };
    const result = complete({
      state, pos: text.length, explicit: false,
      matchBefore(expression) {
        const line = state.doc.lineAt(text.length);
        const before = line.text.slice(0, text.length - line.from);
        const found = before.match(expression);
        return found ? { from: line.from + found.index, to: text.length, text: found[0] } : null;
      },
    });
    const option = result.options.find((candidate) => candidate.label === label);
    option.apply(view, option, result.from, text.length);
    return state.doc.toString();
  }
  assert.equal(accept("const view = <VS", "VStack"), "const view = <VStack>\n  \n</VStack>");
  assert.equal(accept("<Text col", "color"), '<Text color=""');
});
