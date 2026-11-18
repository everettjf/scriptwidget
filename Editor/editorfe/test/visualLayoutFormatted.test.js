import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseVisualLayout, editVisualLayout } from "../src/visualLayout.js";

// Code as a formatter writes it: the element on lines of its own, a comma
// after it, a comment child, and a text on its own line.
const formatted = `// A comment above.
$render(
  // A comment beside the element.
  <vstack frame="max">
    {/* A comment child. */}
    <text font="headline">
      Hello
    </text>
    <spacer />
  </vstack>,
);
`;

function apply(source, edit) {
  let next = source;
  for (const change of [...edit.changes].reverse()) next = next.slice(0, change.from) + change.insert + next.slice(change.to);
  return next;
}

test("formatted code opens in Layout: trailing comma, comments and text on its own line", () => {
  const model = parseVisualLayout(formatted);
  assert.equal(model.issue, "");
  assert.deepEqual(model.nodes.map(node => node.tag), ["vstack", "text", "spacer"]);
  const [stack, text] = model.nodes;
  assert.equal(stack.structure, true);
  assert.equal(text.text, "Hello");
  assert.equal(text.textEditable, true);
  // Ranges are those of the real source, not of the copy that was parsed.
  assert.equal(formatted.slice(text.from, text.to).startsWith('<text font="headline">'), true);
});

test("edits of formatted code keep the comments and stay inside Layout", () => {
  const model = parseVisualLayout(formatted), [stack, text, spacer] = model.nodes;
  const renamed = apply(formatted, editVisualLayout(model, formatted, { type: "text", id: text.id, value: "Bye" }));
  assert.match(renamed, /<text font="headline">\{"Bye"\}<\/text>/);
  assert.match(renamed, /\{\/\* A comment child\. \*\/\}/);
  assert.equal(parseVisualLayout(renamed).nodes[1].text, "Bye");

  const moved = apply(formatted, editVisualLayout(model, formatted, { type: "move", id: spacer.id, parentID: stack.id, index: 0 }));
  assert.deepEqual(parseVisualLayout(moved).nodes.map(node => node.tag), ["vstack", "spacer", "text"]);
  assert.match(moved, /\{\/\* A comment child\. \*\/\}/);

  const property = apply(formatted, editVisualLayout(model, formatted, { type: "property", id: text.id, name: "font", value: "title" }));
  assert.match(property, /<text font=\{"title"\}>/);
});

test("what is not a comment child is still refused or left alone", () => {
  // A second argument is not a trailing comma.
  assert.notEqual(parseVisualLayout("$render(<vstack></vstack>, 1);").issue, "");
  // A real expression child still makes the container code-only.
  const dynamic = parseVisualLayout("$render(<vstack>{items}<spacer /></vstack>);");
  assert.equal(dynamic.nodes[0].structure, false);
  // Text over several lines is not one text.
  const lines = parseVisualLayout("$render(<text>\n  one\n  two\n</text>);");
  assert.equal(lines.nodes[0].textEditable, false);
  // A broken script is still reported.
  assert.match(parseVisualLayout("$render(<vstack>);").issue, /syntax|Layout needs|match/i);
  // The text of a comment-like string is read from the real source.
  const quoted = parseVisualLayout('$render(<text font="headline">{"{/* x */}"}</text>);');
  assert.equal(quoted.nodes[0].text, "{/* x */}");
});

test("the bundled examples open in Layout as often as before they were formatted", () => {
  const bundle = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../Shared/ScriptWidgetRuntime/Resource/Script.bundle");
  let opened = 0, total = 0;
  const refused = [];
  for (const group of ["api", "component", "template"]) {
    for (const name of fs.readdirSync(path.join(bundle, group))) {
      const file = path.join(bundle, group, name, "main.jsx");
      if (!fs.existsSync(file)) continue;
      total += 1;
      const model = parseVisualLayout(fs.readFileSync(file, "utf8"));
      if (model.issue) refused.push(`${group}/${name}`); else opened += 1;
    }
  }
  // 136 of 140 opened before the examples were formatted and commented.
  assert.ok(total >= 140, `${total} examples`);
  assert.ok(opened >= total - 4, `only ${opened} of ${total} open; refused: ${refused.join(", ")}`);
});

const commented = `$render(
  <vstack frame="max">
    {/* The title. */}
    <text font="headline">
      Hello
    </text>

    {/* Two lines
        about the row. */}
    <hstack spacing="4">
      <text font="caption">{/* unit */}km</text>
      <spacer />
    </hstack>
    <spacer />
  </vstack>,
);
`;

// Every layer is selected where the edit says it is.
function selected(source, edit) {
  const next = apply(source, edit), model = parseVisualLayout(next);
  assert.equal(model.issue, "");
  assert.ok(model.nodes.some(node => node.from === edit.selectedFrom), "the selection is not a layer");
  return next;
}

test("a moved or removed layer takes the comment above it and its lines", () => {
  const model = parseVisualLayout(commented), [stack, title, row, unit, innerSpacer, lastSpacer] = model.nodes;
  assert.deepEqual([title.outerFrom < title.from, row.outerFrom < row.from, lastSpacer.outerFrom === lastSpacer.from], [true, true, true]);

  const removed = apply(commented, editVisualLayout(model, commented, { type: "remove", id: title.id }));
  assert.equal(removed.includes("The title."), false);
  assert.equal(removed, commented.replace('    {/* The title. */}\n    <text font="headline">\n      Hello\n    </text>\n', ""));

  // The row and its two-line comment go above the title, one layer a line.
  const moved = selected(commented, editVisualLayout(model, commented, { type: "move", id: row.id, parentID: stack.id, index: 0 }));
  assert.ok(moved.indexOf("about the row.") < moved.indexOf("The title."));
  assert.ok(moved.indexOf("about the row.") < moved.indexOf("<hstack"));
  assert.match(moved, /about the row\. \*\/\}\n    <hstack spacing="4">\n/);
  assert.match(moved, /    <\/hstack>\n    \{\/\* The title\. \*\/\}\n    <text font="headline">/);
  assert.equal(/\n[ \t]+\n/.test(moved), false, "a line of only spaces was left");

  // To the end: on its own line before the closing tag.
  const toEnd = selected(commented, editVisualLayout(model, commented, { type: "move", id: title.id, parentID: stack.id, index: 2 }));
  assert.match(toEnd, /    <spacer \/>\n    \{\/\* The title\. \*\/\}\n    <text font="headline">\n      Hello\n    <\/text>\n  <\/vstack>,/);

  // Into a deeper container: the lines are indented for their new place.
  const deeper = selected(commented, editVisualLayout(model, commented, { type: "move", id: title.id, parentID: row.id, index: 1 }));
  assert.match(deeper, /      \{\/\* The title\. \*\/\}\n      <text font="headline">\n        Hello\n      <\/text>\n      <spacer \/>\n    <\/hstack>/);

  // Moving a layer to where it already is changes nothing.
  assert.deepEqual(editVisualLayout(model, commented, { type: "move", id: row.id, parentID: stack.id, index: 1 }).changes, []);
});

test("a new layer gets a line of its own, and code on one line stays on one line", () => {
  const model = parseVisualLayout(commented), [stack, , row] = model.nodes;
  const added = selected(commented, editVisualLayout(model, commented, { type: "add", id: row.id, kind: "spacer" }));
  assert.match(added, /      <spacer \/>\n      <spacer\/>\n    <\/hstack>/);
  const outer = selected(commented, editVisualLayout(model, commented, { type: "add", id: stack.id, kind: "text" }));
  assert.match(outer, /    <spacer \/>\n    <text font="headline">New text<\/text>\n  <\/vstack>,/);

  const oneLine = "$render(<vstack><text>Hi</text></vstack>);";
  const flat = parseVisualLayout(oneLine);
  assert.equal(apply(oneLine, editVisualLayout(flat, oneLine, { type: "add", id: flat.nodes[0].id, kind: "spacer" })), "$render(<vstack><text>Hi</text><spacer/></vstack>);");
});

test("editing a text keeps a comment written inside it", () => {
  const model = parseVisualLayout(commented), unit = model.nodes.find(node => node.text === "km");
  assert.equal(unit.textEditable, true);
  const next = apply(commented, editVisualLayout(model, commented, { type: "text", id: unit.id, value: "mi" }));
  assert.match(next, /<text font="caption">\{\/\* unit \*\/\}\{"mi"\}<\/text>/);
  assert.equal(parseVisualLayout(next).nodes.find(node => node.text === "mi").textEditable, true);
});
