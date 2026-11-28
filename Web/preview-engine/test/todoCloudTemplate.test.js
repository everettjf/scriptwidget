import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { executePackageInNode, readPackageDirectory } from "../src/node.js";

const folder = new URL("../../../Shared/ScriptWidgetRuntime/Resource/Script.bundle/template/To-do List iCloud/", import.meta.url);
const files = readPackageDirectory(fileURLToPath(folder));
const item = (change, done) => ({ change, done });
const document = (items) => ({ version: 1, items });
const cached = (items, revision = "cached-1") => ({
  value: document(items), revision, state: "cached", conflicts: [],
});
const fixture = (snapshot) => ({
  icloud: { connected: true, available: true, documents: snapshot ? { "todo.json": snapshot } : {} },
});
const run = (options = {}) => executePackageInNode({ files, fixtures: fixture(), ...options });
const events = (result) => result.logs.filter(({ level }) => level === "log").map(({ message }) => JSON.parse(message));

test("the cloud to-do template renders an empty, saved, and disconnected board", async () => {
  const empty = await run();
  assert.equal(empty.error, null);
  assert.match(empty.tree, /0\/2/);
  assert.match(empty.tree, /addPublish/);

  const saved = await run({ fixtures: fixture(cached({ publish: item(1, false), outline: item(1, true) })) });
  assert.equal(saved.error, null);
  assert.match(saved.tree, /1\/3.*reopenOutline.*finishPublish/);
  assert.doesNotMatch(saved.tree, /addPublish/);

  const disconnected = await run({ fixtures: { icloud: { connected: false } } });
  assert.equal(disconnected.error, null);
  assert.match(disconnected.tree, /Open iCloud Data in ScriptWidget to connect/);
});

test("declared Add, finish, and reopen actions can write in the preview bridge", async () => {
  for (const [actionID, snapshot] of [
    ["addPublish", undefined],
    ["finishOutline", cached({})],
    ["reopenOutline", cached({ outline: item(1, true) })],
  ]) {
    const result = await run({ actionID, fixtures: fixture(snapshot) });
    assert.equal(result.error, null, result.error?.message);
  }
});

test("a stale completion retries on the newer list and repeated completion is a no-op", async () => {
  const snapshots = [cached({}, "old"), cached({ review: item(1, true) }, "new")];
  const result = await run({
    actionID: "finishOutline",
    prelude: [
      "let reads = 0; let writes = 0;",
      "$icloud.readJSON = async () => (" + JSON.stringify(snapshots) + ")[reads++];",
      "$icloud.writeJSON = async (name, next, revision) => {",
      "  console.log(JSON.stringify({ name, next, revision }));",
      "  if (++writes === 1) throw new Error('[icloud:staleRevision]');",
      "};",
    ].join("\n"),
  });
  assert.equal(result.error, null, result.error?.message);
  assert.deepEqual(events(result), [
    { name: "todo.json", next: document({ outline: item(1, true) }), revision: "old" },
    { name: "todo.json", next: document({ outline: item(1, true), review: item(1, true) }), revision: "new" },
  ]);
  const repeated = await run({
    actionID: "finishOutline",
    prelude: [
      "$icloud.readJSON = async () => (" + JSON.stringify(cached({ outline: item(4, true) })) + ");",
      "$icloud.writeJSON = async () => { throw new Error('Unexpected revision'); };",
    ].join("\n"),
  });
  assert.equal(repeated.error, null, repeated.error?.message);
});

test("a conflict renders read-only rows and Sync merges changes per task", async () => {
  const snapshot = {
    state: "conflict", revision: "fork", value: null,
    conflicts: [
      { id: "left", value: document({ outline: item(2, false), review: item(1, true) }) },
      { id: "right", value: document({ outline: item(2, true), review: item(2, false), publish: item(1, false) }) },
    ],
  };
  const render = await run({ fixtures: fixture(snapshot) });
  assert.equal(render.error, null);
  assert.match(render.tree, /1\/3.*Sync to merge/);
  assert.doesNotMatch(render.tree, /reopenOutline|finishReview|finishPublish/);

  const result = await run({
    actionID: "syncTasks",
    prelude: [
      "$icloud.sync = async () => console.log(JSON.stringify('sync'));",
      "$icloud.readJSON = async () => (" + JSON.stringify(snapshot) + ");",
      "$icloud.resolveJSON = async (name, value, revision) => console.log(JSON.stringify({ name, value, revision }));",
    ].join("\n"),
  });
  assert.equal(result.error, null, result.error?.message);
  assert.deepEqual(events(result), [
    "sync",
    {
      name: "todo.json", revision: "fork",
      value: document({ outline: item(2, true), review: item(2, false), publish: item(1, false) }),
    },
  ]);
});
