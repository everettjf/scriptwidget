import assert from "node:assert/strict";
import test from "node:test";
import { executePackageInNode } from "../src/node.js";
import { parseColor, parsePaint, setHostColors } from "../src/render/props.js";
import { FixedNode, ListNode, SpacerNode, StackNode } from "../src/render/layout.js";

test("material color names resolve only when the host supplies a palette", () => {
  assert.equal(parseColor("material.primary"), null);
  assert.equal(parseColor("material.primary,0.5", "dark"), null);
  const previous = setHostColors({ light: { primary: [10, 20, 30, 1] }, dark: { primary: [200, 210, 220, 1] } });
  try {
    assert.equal(previous, null);
    assert.deepEqual(parseColor("material.primary"), [10, 20, 30, 1]);
    assert.deepEqual(parseColor("material.primary", "dark"), [200, 210, 220, 1]);
    assert.deepEqual(parseColor("material.primary,0.5"), [10, 20, 30, 0.5]);
    assert.deepEqual(parsePaint("material.primary", "dark"), { color: [200, 210, 220, 1] });
    // A role the host does not define, and names outside the prefix, stay unknown.
    assert.equal(parseColor("material.unknownRole"), null);
    assert.equal(parseColor("material."), null);
    assert.equal(parseColor("materialprimary"), null);
    assert.deepEqual(parseColor("blue"), [0, 136, 255, 1]);
  } finally {
    setHostColors(previous);
  }
  assert.equal(parseColor("material.primary"), null);
});

test("a malformed host palette never yields a color", () => {
  for (const colors of [{ light: { primary: "red" } }, { light: { primary: [1, 2, 3] } }, { light: { primary: [1, 2, 3, NaN] } }, { light: null }, "x", 7]) {
    const previous = setHostColors(colors);
    try { assert.equal(parseColor("material.primary"), null); } finally { setHostColors(previous); }
  }
});

test("a list takes the size it is offered and stacks rows past its bottom edge", () => {
  const rows = [new FixedNode(100, 30), new FixedNode(80, 30), new FixedNode(120, 40)];
  const list = new ListNode(rows, 4);
  assert.deepEqual(list.size(200, 50), [200, 50]);
  // With no height offered it is as tall as its rows and the gaps between them.
  assert.deepEqual(list.size(200, null), [200, 108]);
  assert.deepEqual(list.size(null, null), [120, 108]);
  assert.deepEqual(list.size(200, 0), [200, 0]);
  list.place(0, 0, 200, 50);
  assert.deepEqual(rows.map((row) => row.frame.y), [0, 34, 68]);
  assert.deepEqual(rows.map((row) => row.frame.x), [0, 0, 0]);
  assert.equal(list.contentHeight, 108);
  assert.deepEqual(new ListNode([], 4).size(200, null), [200, 0]);
});

test("a list below a header gets the height the header leaves", () => {
  const header = new FixedNode(100, 20);
  const list = new ListNode([new FixedNode(100, 60), new FixedNode(100, 60), new FixedNode(100, 60)], 0);
  const stack = new StackNode("v", [header, list], { alignment: "start", spacing: () => 8 });
  assert.deepEqual(stack.size(160, 100), [160, 100]);
  stack.place(0, 0, 160, 100);
  assert.equal(list.frame.y, 28);
  assert.equal(list.frame.height, 72);
  assert.equal(list.contentHeight, 180);
  // A spacer still gets nothing while the list can use the room.
  assert.equal(new StackNode("v", [list, new SpacerNode("v")], { alignment: "start", spacing: () => 0 }).size(160, 100)[1], 100);
});

test("the kernel passes <list> through like any other tag", async () => {
  const result = await executePackageInNode({ files: { "main.jsx": '$render(<list spacing="2">{[1, 2, 3].map((n) => <text color="material.primary">{"Row " + n}</text>)}</list>);' } });
  assert.equal(result.error, null);
  const tree = JSON.parse(result.tree);
  assert.equal(tree.$element, "list");
  // Rows made with map() arrive as one nested array; the renderer flattens it.
  assert.equal(tree.children[0].length, 3);
  assert.equal(tree.children[0][0].props.color, "material.primary");
});
