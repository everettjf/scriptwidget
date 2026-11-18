import test from "node:test";
import assert from "node:assert/strict";
import { EditorState } from "@codemirror/state";
import { history, undo, redo, isolateHistory } from "@codemirror/commands";
import { parseVisualLayout, editVisualLayout } from "../src/visualLayout.js";

function apply(model, operation, current = model.source) {
  const edit = editVisualLayout(model, current, operation);
  const state = EditorState.create({doc: current}).update({changes: edit.changes}).state;
  return state.doc.toString();
}
const source = '// Keep my comments and logic exactly.\nconst value = "a";\n$render(\n  <vstack spacing="8" alignment="leading">\n    <text color="#abc">Hello &amp; world</text>\n    <hstack spacing={4}><text>{value}</text><spacer/></hstack>\n  </vstack>\n);\n// Keep my footer\n';
test("opening the range model preserves source byte-for-byte, including dynamic content", () => {
  const model = parseVisualLayout(source);
  assert.equal(model.issue, ""); assert.equal(model.source, source);
  assert.deepEqual(model.nodes.map(node => node.component), ["VStack", "Text", "HStack", "Text", "Spacer"]);
  assert.equal(model.nodes[1].text, "Hello & world");
  assert.equal(model.nodes[3].textEditable, false);
  assert.equal(model.nodes[0].structure, true);
});
test("property changes touch only their range, encode literal text safely and reject stale models", () => {
  const model = parseVisualLayout(source), id = model.nodes[1].id;
  const next = apply(model, {type:"property",id,name:"color",value:"#123456"});
  assert.equal(next, source.replace('color="#abc"','color={"#123456"}'));
  assert.throws(() => apply(model, {type:"property",id,name:"color",value:"red"}, source + " "), /changed/);
  const injected = '<text>{fetch("https://example.test")}</text> & "';
  const text = apply(model, {type:"text",id,value:injected});
  assert.equal(text, source.replace("Hello &amp; world", `{${JSON.stringify(injected)}}`));
  assert.equal(parseVisualLayout(text).nodes[1].text,injected);
});
test("dynamic attributes, spreads, duplicate props, unknown components and code are preserved", () => {
  for (const content of ['<text color={palette.ink}>Hi</text>','<text {...props}>Hi</text>','<text color="red" color="blue">Hi</text>','<Custom color="red"/>']) {
    const model = parseVisualLayout(`const x = true; $render(${content});`), node = model.nodes[0];
    assert.equal(model.issue, "");
    assert.throws(() => apply(model,{type:"property",id:node.id,name:"color",value:"green"}), /Code|locked/);
    assert.equal(model.source, `const x = true; $render(${content});`);
  }
  const dynamic = parseVisualLayout('$render(<vstack>{items.map(item => <text>{item}</text>)}</vstack>);');
  assert.equal(dynamic.nodes[0].structure,false);
  assert.throws(()=>apply(dynamic,{type:"add",id:dynamic.nodes[0].id,kind:"text"}),/literal/);
});
test("reordering and moving layers preserve literal source and stay in the same render scope", () => {
  let model = parseVisualLayout(source);
  const first = model.nodes[1], stack = model.nodes[2], dynamic = model.nodes[3];
  const moved = apply(model,{type:"move",id:first.id,parentID:stack.id,index:1});
  // The moved layer's own line goes with it; no line of spaces is left behind.
  assert.equal(moved,source.replace('    <text color="#abc">Hello &amp; world</text>\n','').replace('<spacer/>','<text color="#abc">Hello &amp; world</text><spacer/>'));
  assert.ok(moved.includes('<text>{value}</text>'));
  assert.throws(()=>apply(model,{type:"move",id:stack.id,parentID:stack.id,index:0}),/outside/);
  const reordered = apply(model,{type:"move",id:stack.id,parentID:model.roots[0],index:0});
  assert.ok(reordered.indexOf('<hstack') < reordered.indexOf('Hello &amp;'));
  model = parseVisualLayout('function a(){const x=1;$render(<vstack><text>{x}</text></vstack>);}function b(){const x=2;$render(<vstack></vstack>);}');
  assert.throws(()=>apply(model,{type:"move",id:model.nodes[1].id,parentID:model.roots[1],index:0}),/scopes/);
  assert.equal(dynamic.textEditable,false);
});
test("add and remove are explicit, bounded operations and retain outside JavaScript", () => {
  const model = parseVisualLayout(source), root = model.roots[0];
  const added = apply(model,{type:"add",id:root,kind:"text"});
  // In code with a layer a line, the new layer gets a line at its neighbours' indentation.
  assert.equal(added,source.replace('  </vstack>','    <text font="headline">New text</text>\n  </vstack>'));
  const next = parseVisualLayout(added), last = next.nodes.at(-1);
  assert.equal(apply(next,{type:"remove",id:last.id}),source);
  assert.throws(()=>apply(model,{type:"add",id:root,kind:'<script>alert(1)</script>'}),/Unsupported/);
});
test("unsupported roots, malformed JSX and model limits fail closed without replacing source", () => {
  for (const code of ['$render(widget);','$render(<vstack></hstack>);','$render(<vstack>);','// hi', '$render(<vstack>'+'<vstack>'.repeat(34)+'</vstack>'.repeat(34)+'</vstack>);']) {
    const model = parseVisualLayout(code); assert.ok(model.issue); assert.equal(model.source,code); assert.equal(model.roots.length && model.nodes.length,0);
  }
  const huge = " ".repeat(512*1024+1); assert.ok(parseVisualLayout(huge).issue);
});
test("literal values obey property types, enums and bounds", () => {
  const model = parseVisualLayout('$render(<vstack spacing="8"><text font="headline">Hi</text></vstack>);');
  const id = model.nodes[1].id;
  for (const [name,value] of [["opacity",-1],["opacity",2],["font","giant"],["color",true],["unknown","x"],["rotation",Infinity]]) assert.throws(()=>apply(model,{type:"property",id,name,value}));
  assert.ok(apply(model,{type:"property",id,name:"padding",value:0}).includes('padding={0}'));
  assert.ok(apply(model,{type:"property",id,name:"widgetAccentable",value:false}).includes('widgetAccentable={false}'));
  for (const name of ["__proto__", "constructor", "toString"]) assert.throws(()=>apply(model,{type:"property",id,name,value:"x"}),/unsupported/);
});
test("layout edits share the editor undo/redo history as isolated transactions", () => {
  let state = EditorState.create({doc:source,extensions:[history()]});
  const model = parseVisualLayout(source), operation = {type:"property",id:model.roots[0],name:"alignment",value:"trailing"};
  const edit = editVisualLayout(model,source,operation);
  state = state.update({changes:edit.changes,annotations:isolateHistory.of("full")}).state;
  const changed = state.doc.toString();
  const target = {get state(){return state;},dispatch(transaction){state=transaction.state;}};
  assert.equal(undo(target),true); assert.equal(state.doc.toString(),source);
  assert.equal(redo(target),true); assert.equal(state.doc.toString(),changed);
});

test("component dependencies and mutually exclusive action properties remain valid", () => {
  let model = parseVisualLayout('$render(<button action="reload"><text>Refresh</text></button>);');
  assert.throws(()=>apply(model,{type:"property",id:model.roots[0],name:"action",remove:true}),/required/);
  assert.throws(()=>apply(model,{type:"property",id:model.roots[0],name:"actionID",value:"refresh"}),/conflicts/);
  model = parseVisualLayout('$render(<toggle on={true} actionID="focus" stateKey="focus"/>);');
  assert.throws(()=>apply(model,{type:"property",id:model.roots[0],name:"stateKey",remove:true}),/requires/);
});
