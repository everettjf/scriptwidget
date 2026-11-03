import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs";
import { executePackageInNode } from "../src/node.js";

const root = new URL("../../../Shared/ScriptWidgetRuntime/Resource/Script.bundle/template/Hydration Goal iCloud/", import.meta.url);
const files = Object.fromEntries(["main.jsx", "widget.json", "lib/cloud-hydration.js"].map((path) => [path, fs.readFileSync(new URL(path, root), "utf8")]));
const text = (tree) => typeof tree === "string" ? tree : Array.isArray(tree) ? tree.map(text).join("") : tree?.children ? text(tree.children) : "";
const connected = (events = []) => ({icloud: {connected: true, available: true, documents: {
  "hydration.json": {value: {version: 1, events}, revision: "r1", state: "cached", conflicts: []},
}}});
const run = (options = {}) => executePackageInNode({files, environments: {"widget-size": "large", "widget-param": ""}, fixtures: connected(), ...options});

test("cloud hydration renders cached daily totals without mutating them", async () => {
  const events = [
    {id: "a".repeat(32), at: "2026-11-03T08:08:00.000Z", day: "2026-11-03", ml: 250},
    {id: "b".repeat(32), at: "2026-11-03T10:08:00.000Z", day: "2026-11-03", ml: 250},
  ];
  const result = await run({fixtures: connected(events), prelude: "const OriginalDate=Date;Date=class extends OriginalDate{constructor(...args){super(...(args.length?args:[2026,10,3,12]));}};"});
  assert.equal(result.error, null);
  assert.match(text(JSON.parse(result.tree)), /500 \/ 2000 mL/);
});

test("cloud hydration renders a connection hint and its add action is declared", async () => {
  const disconnected = await run({fixtures: {icloud: {connected: false}}});
  assert.equal(disconnected.error, null);
  assert.match(text(JSON.parse(disconnected.tree)), /Connect iCloud Data/);

  const action = await run({actionID: "addGlass"});
  assert.equal(action.error, null);
  assert.match(text(JSON.parse(action.tree)), /Action completed/);
});
