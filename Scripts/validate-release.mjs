import { readFile, readdir, stat } from "node:fs/promises";
import { join, relative } from "node:path";

const root = new URL("../", import.meta.url).pathname;
const templateRoot = join(root, "Shared/ScriptWidgetRuntime/Resource/Script.bundle/template");
const schema = JSON.parse(await readFile(join(root, "Shared/ScriptWidgetRuntime/ScriptWidgetAPI.json"), "utf8"));
const packageSchema = JSON.parse(await readFile(join(root, "Shared/ScriptWidgetRuntime/Resource/widget.schema.json"), "utf8"));
const failures = [];
const names = (await readdir(templateRoot)).sort();

if (names.length < 60) failures.push(`expected at least 60 templates, found ${names.length}`);
for (const name of names) {
  const directory = join(templateRoot, name);
  if (!(await stat(directory)).isDirectory()) continue;
  let source, meta;
  try { source = await readFile(join(directory, "main.jsx"), "utf8"); }
  catch { failures.push(`${name}: missing main.jsx`); continue; }
  try { meta = JSON.parse(await readFile(join(directory, "meta.json"), "utf8")); }
  catch { failures.push(`${name}: invalid or missing meta.json`); continue; }
  for (const key of ["description", "category", "difficulty", "icon"]) {
    if (!meta[key]) failures.push(`${name}: missing ${key}`);
  }
  if (source.includes("fetch(") && !["weather", "finance", "productivity"].includes(meta.category)) {
    failures.push(`${name}: network template must use a network-related category`);
  }
  if (Buffer.byteLength(source) > 512 * 1024) failures.push(`${name}: source exceeds runtime limit`);
}

const generatedDocs = await readFile(join(root, "docs/scriptwidget-runtime-api.md"), "utf8");
if (!generatedDocs.includes(`schema v${schema.schemaVersion}`) || !generatedDocs.includes(`runtime ${schema.runtimeVersion}`)) {
  failures.push("runtime docs do not match schema/runtime version");
}
if (packageSchema.properties?.formatVersion?.const !== 2 || packageSchema.properties?.runtimeVersion?.const !== "1.0") {
  failures.push("Package 2.0 schema does not match the runtime contract");
}
const packageDocs = await readFile(join(root, "docs/package-format.md"), "utf8");
for (const required of ["widget.json", "32 MiB", "64 MiB", "symbolic links", "legacy package"]) {
  if (!packageDocs.includes(required)) failures.push(`package documentation is missing ${required}`);
}

const iosInfo = await readFile(join(root, "iOS/ScriptWidget/Info.plist"), "utf8");
for (const key of ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription", "NSLocationWhenInUseUsageDescription"]) {
  if (!iosInfo.includes(`<key>${key}</key>`)) failures.push(`iOS Info.plist is missing ${key}`);
}

const aiSettings = await readFile(join(root, "Shared/ScriptWidgetRuntime/AI/AISettings.swift"), "utf8");
if (!aiSettings.includes("apiKey is intentionally omitted") || !aiSettings.includes("AIKeychain.live")) {
  failures.push("AI credentials must remain Keychain-backed and omitted from UserDefaults JSON");
}

const packageSource = await readFile(join(root, "Shared/ScriptWidgetRuntime/Common/ScriptWidgetPackage.swift"), "utf8");
if (!packageSource.includes("write(to: fullPath, options: .atomic)")) {
  failures.push("script source saves must remain atomic");
}
const managerSource = await readFile(join(root, "Shared/ScriptWidgetRuntime/Common/ScriptManager.swift"), "utf8");
for (const guardrail of ["ScriptPackageArchivePreflight", "maximumExpandedBytes", "isSymbolicLinkKey", "WidgetPackageManifestValidator"]) {
  if (!managerSource.includes(guardrail)) failures.push(`secure package import is missing ${guardrail}`);
}

const releaseDocs = await readFile(join(root, "docs/release-readiness.md"), "utf8");
for (const command of ["./Scripts/release-readiness.sh", "./Scripts/device-matrix.sh", "./Scripts/ipad-icloud-tests.sh"]) {
  if (!releaseDocs.includes(command)) failures.push(`release documentation is missing ${command}`);
}

async function walk(directory) {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (["node_modules", ".git", "build", "dist", "StudioEditor.bundle"].includes(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) result.push(...await walk(path)); else result.push(path);
  }
  return result;
}
for (const path of await walk(root)) {
  if (!/\.(swift|js|jsx|mjs|html)$/.test(path)) continue;
  const contents = await readFile(path, "utf8");
  if (path !== new URL(import.meta.url).pathname && /monaco-editor|Monaco editor/.test(contents)) {
    failures.push(`${relative(root, path)}: legacy Monaco editor reference`);
  }
}

if (failures.length) {
  console.error(failures.map(value => `✗ ${value}`).join("\n"));
  process.exit(1);
}
console.log(`✓ release metadata, ${names.length} templates, API docs and editor sources validated`);
