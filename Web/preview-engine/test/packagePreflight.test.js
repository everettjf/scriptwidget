import assert from "node:assert/strict";
import test from "node:test";
import { executePackageInNode } from "../src/node.js";
import { preparePackage } from "../src/prepare.js";
import { decodeManifest, newManifest, supportsMinimumRuntime, validateManifest } from "../src/package/manifest.js";

const files = (manifest, source = '$render(<text>ok</text>);') => ({ "widget.json": JSON.stringify(manifest), "main.jsx": source });

test("minimum API versions use canonical numeric same-major comparison", () => {
  for (const version of ["1.0", "1.1", "1.2", "1.3", "1.4", "1.5", "1.6"]) assert.equal(supportsMinimumRuntime(version), true, version);
  for (const version of ["1.7", "1.10", "2.0", "0.9", "01.3", "1.03", "1.3.0", "1", "1.9999", ">=1.3", " 1.3"]) assert.equal(supportsMinimumRuntime(version), false, version);
  assert.equal(supportsMinimumRuntime("1.9", "1.10"), true);
  assert.equal(supportsMinimumRuntime("1.10", "1.9"), false);
  for (const minimum of [undefined, null, "1.0", "1.3", "1.4", "2.0", "01.3"]) {
    const manifest = { ...newManifest("Minimum runtime"), minimumRuntimeVersion: minimum };
    const decoded = decodeManifest(JSON.stringify(manifest));
    assert.equal(decoded.error, undefined);
    assert.equal(validateManifest(decoded.manifest, ["main.jsx"]).valid, minimum == null || minimum === "1.0" || minimum === "1.3" || minimum === "1.4");
  }
  assert.match(decodeManifest(JSON.stringify({ ...newManifest("Bad minimum"), minimumRuntimeVersion: true })).error, /minimumRuntimeVersion/);
});

test("invalid packages are rejected before the compiler or script can run", () => {
  const compiler = new Proxy({}, { get() { throw new Error("Compiler must not run"); } });
  for (const patch of [{ minimumRuntimeVersion: "1.7" }, { minimumRuntimeVersion: "01.3" }, { formatVersion: 99 }, { extraCapability: true }]) {
    const result = preparePackage(compiler, { files: files({ ...newManifest("Preflight"), ...patch }, "while(true) {}") });
    assert.equal(result.ok, false);
    assert.equal(result.error.kind, "scriptError");
    assert.match(result.error.message, /\[package:/);
  }
});

test("file manifest is authoritative over a permissive host object", async () => {
  const host = { ...newManifest("Host grant"), permissions: ["calendar"] };
  for (const text of ["{bad", JSON.stringify({ ...host, formatVersion: 999 }), JSON.stringify({ ...host, minimumRuntimeVersion: "1.7" })]) {
    const result = await executePackageInNode({ files: { "widget.json": text, "main.jsx": 'throw new Error("executed");' }, manifest: host });
    assert.equal(result.error.kind, "scriptError");
    assert.match(result.error.message, /\[package:/);
    assert.doesNotMatch(result.error.message, /executed/);
  }
  const denied = { ...host, permissions: [] };
  const result = await executePackageInNode({ files: files(denied, '$render(<text>{$calendar.authorizationStatus()}</text>);'), manifest: host, fixtures: { api: { "$calendar.authorizationStatus": { value: "authorized" } } } });
  assert.equal(result.error, null);
  assert.match(result.tree, /undeclared/);
});

test("files-only jobs honor declared entry and minimum; legacy jobs still run", async () => {
  const manifest = { ...newManifest("Nested"), entry: "src/entry.jsx", minimumRuntimeVersion: "1.3" };
  const nested = await executePackageInNode({ files: { "widget.json": JSON.stringify(manifest), "src/entry.jsx": '$render(<text>nested</text>);' } });
  assert.equal(nested.error, null);
  assert.match(nested.tree, /nested/);
  const legacy = await executePackageInNode({ files: { "main.jsx": '$render(<text>legacy</text>);' } });
  assert.equal(legacy.error, null);
  assert.match(legacy.tree, /legacy/);
});
