import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { executePackageInNode, readPackageDirectory } from "../src/node.js";

const root = new URL("../../../Shared/ScriptWidgetRuntime/Resource/Script.bundle/template/", import.meta.url);
const filesFor = (name) => readPackageDirectory(fileURLToPath(new URL(`${name}/`, root)));
const sunday = "2026-11-22T23:59:00-08:00";
const monday = "2026-11-23T00:00:00-08:00";
const fixedMonday = "Date = class extends Date { constructor(...args) { super(...(args.length ? args : ['2026-11-23T12:00:00-08:00'])); } };";

async function render(files, { date = monday, parameter = "", ...options } = {}) {
  const result = await executePackageInNode({
    files,
    timeZone: "America/Los_Angeles",
    environments: {
      "widget-size": "small",
      "widget-param": parameter,
      "timeline-date": date,
      "timeline-is-projection": options.actionID ? "false" : "true",
    },
    ...options,
  });
  assert.equal(result.error, null, result.error?.message);
  return result;
}

test("Week Progress follows the planned local midnight across a week boundary", async () => {
  const files = filesFor("Week Progress");
  assert.match((await render(files, { date: sunday })).tree, /"Sunday".*"Nov 22".*"Day 7 of 7"/);
  assert.match((await render(files)).tree, /"Monday".*"Nov 23".*"Day 1 of 7"/);
});

test("Daily Focus records toggles by label and shows an unchecked list on the next projected day", async () => {
  const files = filesFor("Daily Focus Checklist");
  const parameter = "Read,Walk";
  const toggled = await render(files, { parameter, actionID: "toggleTwo", prelude: fixedMonday });
  const storage = toggled.mockState.storage;
  assert.match((await render(files, { storage, parameter: "Walk,Read" })).tree, /"1\/2".*"checkmark.square.fill".*"Walk"/);
  assert.match((await render(files, { storage, parameter, date: "2026-11-24T00:00:00-08:00" })).tree, /"0\/2"/);
  const undone = await render(files, { storage, parameter, actionID: "toggleTwo", prelude: fixedMonday });
  assert.match((await render(files, { storage: undone.mockState.storage, parameter })).tree, /"0\/2"/);
});

test("Desk Vitals shows a dash when the device reports an unknown battery", async () => {
  const files = filesFor("Desk Vitals");
  const result = await render(files, {
    prelude: '$device.battery = () => ({ level: 0, state: "unknown" });',
  });
  assert.match(result.tree, /"—".*"Battery"/);
});

test("Daily Pause rotates offline at midnight and accepts a custom line", async () => {
  const files = filesFor("Daily Pause");
  const before = await render(files, { date: sunday });
  const after = await render(files);
  assert.notEqual(after.tree, before.tree);
  assert.match((await render(files, { parameter: "A line of my own." })).tree, /"A line of my own\."/);
});

test("Mac Desktop Tools routes only its fixed tool destinations", async () => {
  const files = filesFor("Mac Desktop Tools");
  const prelude = '$system.platform = () => "macos";';
  const small = await render(files, { parameter: "translation", prelude });
  assert.match(small.tree, /scriptwidget:\/\/desktop-tools\/translation/);
  assert.doesNotMatch(small.tree, /desktop-tools\/music/);

  const unknown = await render(files, { parameter: "file:///etc/hosts", prelude });
  assert.match(unknown.tree, /scriptwidget:\/\/desktop-tools\/launcher/);
  assert.doesNotMatch(unknown.tree, /file:/);

  const medium = await render(files, { environments: { "widget-size": "medium" }, prelude });
  for (const tool of ["launcher", "system", "music", "translation", "appearance"]) {
    assert.ok(medium.tree.includes("scriptwidget://desktop-tools/" + tool));
  }
  const elsewhere = await render(files, { prelude: '$system.platform = () => "ios";' });
  assert.match(elsewhere.tree, /Desktop Tools opens on Mac/);
  assert.doesNotMatch(elsewhere.tree, /scriptwidget:/);
});
