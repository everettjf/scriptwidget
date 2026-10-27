import assert from "node:assert/strict";
import test from "node:test";
import { executePackageInNode } from "../src/node.js";
const manifest = { formatVersion: 2, id: "example.cloud-json", name: "Cloud JSON", version: "1.0.0", runtimeVersion: "1.0", minimumRuntimeVersion: "1.5", entry: "main.jsx", supportedFamilies: ["systemMedium"], permissions: ["icloud"], networkDomains: [], actions: [{ id: "save", title: "Save", systemImage: "icloud", function: "save" }] };
const run = (source, options = {}) => executePackageInNode({ files: { "main.jsx": source, "widget.json": JSON.stringify(manifest) }, fixtures: { icloud: { connected: true, available: true, documents: {} } }, ...options });
const value = (result) => { assert.equal(result.error, null); return JSON.parse(JSON.parse(result.tree).children[0]); };

test("cloud preview is cache-only, does not claim upload and requires a native grant model", async () => {
  assert.equal(value(await run(`$render(<text>{JSON.stringify(await $icloud.status())}</text>);`)).uploaded, null);
  const denied = await run(`$render(<text>{JSON.stringify(await $icloud.status())}</text>);`, { fixtures: { icloud: { connected: false } } });
  assert.match(denied.error.message, /notConnected/);
});
test("ordinary rendering cannot change cloud records or sync", async () => {
  for (const source of [`await $icloud.writeJSON('a.json',{},'');`, `await $icloud.resolveJSON('a.json',{},'');`, `await $icloud.sync();`]) {
    assert.match((await run(source + '$render(<text>never</text>);')).error.message, /read_only/);
  }
});
test("an action can save, reread, and reject a stale revision without overwriting", async () => {
  const result = await run(`async function save(){
    const written = await $icloud.writeJSON('a.json',{keep:true},'');
    let stale=false; try {await $icloud.writeJSON('a.json',{lost:true},'');}catch(e){stale=String(e).includes('staleRevision');}
    console.log(JSON.stringify({written,read:await $icloud.readJSON('a.json'),stale}));
  } $render(<text>Action</text>);`, { actionID: "save" });
  assert.equal(result.error, null);
  const saved = JSON.parse(result.logs.find(log => log.level === "log").message);
  assert.equal(saved.stale, true);
  assert.deepEqual(saved.read.value, { keep: true });
  assert.equal(saved.read.revision, saved.written.revision);
});
test("conflicts are visible and only explicit resolution may replace heads", async () => {
  const fixtures = { icloud: { connected: true, documents: { "a.json": { value: null, revision: "both", state: "conflict", conflicts: [{ id: "a", value: { n: 1 } }, { id: "b", value: { n: 2 } }] } } } };
  const read = value(await run(`$render(<text>{JSON.stringify(await $icloud.readJSON('a.json'))}</text>);`, { fixtures }));
  assert.equal(read.conflicts.length, 2);
  const result = await run(`async function save(){let blocked=false;try{await $icloud.writeJSON('a.json',{},'both');}catch(e){blocked=true;}const r=await $icloud.resolveJSON('a.json',{n:3},'both');console.log(JSON.stringify({blocked,r}));}$render(<text>Action</text>);`, { fixtures, actionID: "save" });
  assert.equal(result.error, null);
  const resolved = JSON.parse(result.logs.find(log => log.level === "log").message);
  assert.equal(resolved.blocked, true);
  assert.deepEqual(resolved.r.value, { n: 3 });
  assert.equal(resolved.r.state, "pending");
});
test("missing permission and too-old minimum runtime fail closed", async () => {
  for (const m of [{ ...manifest, permissions: [] }, { ...manifest, minimumRuntimeVersion: "1.4" }]) {
    const result = await run(`await $icloud.status();$render(<text>never</text>);`, { files: { "main.jsx": `await $icloud.status();$render(<text>never</text>);`, "widget.json": JSON.stringify(m) } });
    assert.ok(result.error);
  }
});

test("cloud calls retain the shared data-query budget", async () => {
  const result = await run(`for(let i=0;i<9;i++) await $icloud.status();$render(<text>never</text>);`);
  assert.match(result.error.message, /query_limit/);
});
