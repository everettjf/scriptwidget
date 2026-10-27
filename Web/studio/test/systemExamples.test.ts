import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { executePackageInNode } from "../../preview-engine/src/node.js";
import { defaultFixtures, parseMocks } from "../src/mockData.ts";

const examples = ["notification-reminder", "health-history", "calendar-focus", "weather-forecast", "alarm-focus-timer", "document-data", "selected-contacts", "map-place", "home-light"];
function filesFor(name: string) {
  const root = new URL(`../../../docs/examples/${name}/`, import.meta.url);
  return Object.fromEntries(["widget.json", "main.jsx"].map(file => [file, fs.readFileSync(new URL(file, root), "utf8")]));
}
for (const name of examples) test(`system example ${name} renders healthy data and rejects missing permissions`, async () => {
  const files = filesFor(name);
  const healthy = await executePackageInNode({ files, fixtures: parseMocks(defaultFixtures) });
  assert.equal(healthy.error, null, name);
  assert.ok(healthy.tree, name);
  assert.deepEqual(healthy.logs.filter(row => row.level === "error"), [], name);
  const manifest = JSON.parse(files["widget.json"]!);
  const denied = await executePackageInNode({ files: { ...files, "widget.json": JSON.stringify({ ...manifest, permissions: [], networkDomains: [] }) }, fixtures: parseMocks(defaultFixtures) });
  // Examples display setup guidance instead of an empty Home Screen widget.
  assert.equal(denied.error, null, name);
  assert.ok(denied.tree, name);
  assert.ok(denied.logs.some(row => row.level === "error"), name);
});
for (const [name, actionID] of [["notification-reminder", "schedule"], ["calendar-focus", "create"], ["alarm-focus-timer", "start"], ["home-light", "on"]] as const) {
  test(`system example ${name} executes its declared action`, async () => {
    const result = await executePackageInNode({ files: filesFor(name!), actionID, fixtures: parseMocks(defaultFixtures) });
    assert.equal(result.error, null, name);
    assert.deepEqual(result.logs.filter(row => row.level === "error"), [], name);
  });
}
