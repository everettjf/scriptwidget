import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { dataAPICatalog } from "../src/dataAPICatalog.js";
import { scriptWidgetAPI } from "../src/scriptWidgetAPI.js";

test("editor metadata uses the native public API version rather than an app version", async () => {
  const source = await readFile(new URL("../../../Shared/ScriptWidgetRuntime/Common/ScriptWidgetPackage.swift", import.meta.url), "utf8");
  assert.ok(source.includes(`static let nativeRuntimeAPIVersion = "${scriptWidgetAPI.runtimeVersion}"`));
  for (const api of dataAPICatalog) assert.ok(["1.0", "1.3", "1.4", "1.6"].includes(api.minimumRuntimeVersion));
});

test("data catalog exactly covers native JSExport data methods and Promise semantics", async () => {
  assert.equal(new Set(dataAPICatalog.map((item) => item.id)).size, dataAPICatalog.length);
  for (const group of [...new Set(dataAPICatalog.map((item) => item.group))]) {
    const entries = dataAPICatalog.filter((item) => item.group === group);
    const source = await readFile(new URL(`../../../${entries[0].nativeSource}`, import.meta.url), "utf8");
    const protocol = source.match(/@objc protocol \w+Exports: JSExport \{([\s\S]*?)\n\}/)?.[1];
    assert.ok(protocol, group);
    const methods = [...protocol.matchAll(/static func (\w+)\(([^\n]*)\) -> ([^\n]+)/g)];
    assert.deepEqual(entries.map((item) => item.id).sort(), methods.map((match) => `$${group}.${match[1]}`).sort(), group);
    for (const [, method, args, result] of methods) {
      const entry = entries.find((item) => item.id === `$${group}.${method}`);
      assert.equal(entry.asynchronous, result.trim() === "ScriptWidgetRuntimePromise", entry.id);
      assert.equal(entry.arguments.length, args.trim() ? 1 : 0, entry.id);
      assert.ok(scriptWidgetAPI.functions[entry.id], `${entry.id} missing from completion metadata`);
      assert.ok(entry.notes.length > 20);
      assert.ok(entry.platforms.length);
      assert.ok(["none", "healthRead", "locationWhenInUse", "calendarRead", "remindersRead", "remindersWrite", "photosRead", "serviceAccount", "musicRead", "systemAccess"].includes(entry.authorization));
      assert.ok(["availability", "authorization", "read", "write"].includes(entry.operation));
      assert.equal(entry.mock, "editable");
      assert.notEqual(JSON.stringify(entry.value), undefined, entry.id);
    }
  }
});
