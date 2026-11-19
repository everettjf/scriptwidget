import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { runtimeContract, wrappedSource } from "../src/contract.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const runtimeSwift = fs.readFileSync(path.join(root, "Shared/ScriptWidgetRuntime/Widget/Runtime/ScriptWidgetRuntime.swift"), "utf8");
const packageSwift = fs.readFileSync(path.join(root, "Shared/ScriptWidgetRuntime/Common/ScriptWidgetPackage.swift"), "utf8");

test("runtime limits and native API version match ScriptWidgetRuntimeContract", () => {
  assert.match(runtimeSwift, /static let apiVersion = ScriptWidgetBuildContract.nativeRuntimeAPIVersion/);
  assert.ok(packageSwift.includes(`static let nativeRuntimeAPIVersion = "${runtimeContract.nativeAPIVersion}"`));
  assert.match(runtimeSwift, /static let maximumSourceBytes = 512 \* 1_024/);
  assert.match(runtimeSwift, /static let maximumTranspiledBytes = 2 \* 1_024 \* 1_024/);
  assert.match(runtimeSwift, /static let executionTimeout: DispatchTimeInterval = \.seconds\(5\)/);
  assert.match(runtimeSwift, /static let maximumElementNodes = 1_000/);
  assert.match(runtimeSwift, new RegExp(`static let maximumMaterialBackgrounds = ${runtimeContract.maximumMaterialBackgrounds}`));
  assert.match(runtimeSwift, /static let maximumElementDepth = 64/);
  assert.match(runtimeSwift, /static let maximumPropsPerElement = 128/);
  const globals = /static let globalAPIs = \[([\s\S]*?)\]/.exec(runtimeSwift)[1].match(/"[^"]+"/g).map((item) => JSON.parse(item));
  assert.deepEqual(globals, [...runtimeContract.globalAPIs]);
});

test("native compiler fingerprint and entry wrapper match ScriptWidgetCompiler", () => {
  assert.match(packageSwift, new RegExp(`static let compilerFingerprint = "${runtimeContract.nativeCompilerFingerprint}"`));
  assert.ok(runtimeSwift.includes('var result = "async function $main() { try {"'));
  assert.ok(runtimeSwift.includes('result += "} catch(e){ console.error(e); $error(`${e}`) } }"'));
  assert.ok(runtimeSwift.includes('result += "\\n"'));
  assert.equal(wrappedSource("X"), "async function $main() { try {X\n} catch(e){ console.error(e); $error(`${e}`) } }");
  assert.equal(wrappedSource("X // note", "render"), "async function $main() { try {X // note\nawait render();} catch(e){ console.error(e); $error(`${e}`) } }");
});
