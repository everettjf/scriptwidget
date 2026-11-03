import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const source = await readFile(new URL("../../Shared/ScriptWidgetRuntime/Resource/Script.bundle/template/Hydration Goal iCloud/lib/cloud-hydration.js", import.meta.url), "utf8");
const id = (digit) => digit.repeat(32);
const event = (digit, ml = 250) => ({id: id(digit), at: "2026-11-03T08:08:00.000Z", day: "2026-11-03", ml});
const value = (events) => ({version: 1, events});
const cached = (events, revision = "r1") => ({state: "cached", value: value(events), revision, conflicts: []});

function helper(cloud) {
  const context = vm.createContext({$icloud: cloud, Date, Math, Set, Map, Number, Object, Array, JSON, String, Error});
  vm.runInContext(source, context);
  return context.cloudHydration;
}

test("an added glass keeps an individual UTC timestamp and local day", async () => {
  let saved;
  const hydration = helper({
    readJSON: async () => ({state: "cached", value: null, revision: "", conflicts: []}),
    writeJSON: async (_name, next, revision) => { saved = {next, revision}; },
  });
  await hydration.add(250);
  assert.equal(saved.revision, "");
  assert.equal(saved.next.events.length, 1);
  assert.equal(saved.next.events[0].ml, 250);
  assert.match(saved.next.events[0].at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  assert.match(saved.next.events[0].day, /^\d{4}-\d{2}-\d{2}$/);
});

test("two offline additions merge by event ID before another tap", async () => {
  let resolved;
  const hydration = helper({
    readJSON: async () => ({state: "conflict", value: null, revision: "fork", conflicts: [
      {id: "left", value: value([event("a")])}, {id: "right", value: value([event("b")])},
    ]}),
    resolveJSON: async (_name, next, revision) => { resolved = {next, revision}; },
  });
  await hydration.add(250);
  assert.equal(resolved.revision, "fork");
  assert.equal(resolved.next.events.length, 3);
  assert.equal(resolved.next.events.reduce((sum, item) => sum + item.ml, 0), 750);
  assert.equal(new Set(resolved.next.events.map((item) => item.id)).size, 3);
});

test("a stale revision retries without inventing a second tap", async () => {
  let reads = 0;
  let writes = 0;
  const ids = [];
  const hydration = helper({
    readJSON: async () => { reads++; return cached([], String(reads)); },
    writeJSON: async (_name, next) => {
      writes++;
      ids.push(next.events[0].id);
      if (writes === 1) throw new Error("[icloud:staleRevision]");
    },
  });
  await hydration.add(250);
  assert.equal(reads, 2);
  assert.equal(writes, 2);
  assert.equal(ids[0], ids[1]);
});

test("invalid or ambiguous cloud history is rejected without a write", async () => {
  let writes = 0;
  const hydration = helper({
    readJSON: async () => cached([{...event("a"), ml: -1}]),
    writeJSON: async () => { writes++; },
  });
  await assert.rejects(hydration.add(250), /invalid/);
  assert.equal(writes, 0);

  const conflict = helper({readJSON: async () => ({state: "conflict", value: null, revision: "fork", conflicts: [
    {id: "left", value: value([event("a", 250)])}, {id: "right", value: value([event("a", 500)])},
  ]})});
  await assert.rejects(conflict.read(), /invalid/);

  const missingHead = helper({readJSON: async () => ({state: "conflict", value: null, revision: "fork", conflicts: [
    {id: "left", value: value([event("a")])}, {id: "right", value: null},
  ]})});
  await assert.rejects(missingHead.read(), /invalid/);

  const missingValue = helper({readJSON: async () => ({state: "cached", value: null, revision: "existing", conflicts: []})});
  await assert.rejects(missingValue.read(), /invalid/);
});

test("manual sync resolves an additive fork and keeps original events", async () => {
  let exchanged = 0;
  let resolved;
  const hydration = helper({
    sync: async () => { exchanged++; },
    readJSON: async () => ({state: "conflict", value: null, revision: "fork", conflicts: [
      {id: "left", value: value([event("a")])}, {id: "right", value: value([event("b")])},
    ]}),
    resolveJSON: async (_name, next) => { resolved = next; },
  });
  await hydration.sync();
  assert.equal(exchanged, 1);
  assert.deepEqual(resolved.events.map((item) => item.id).sort(), [id("a"), id("b")]);
});
