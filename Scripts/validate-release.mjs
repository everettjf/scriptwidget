import { readFile, readdir, stat } from "node:fs/promises";
import { join, relative } from "node:path";

const root = new URL("../", import.meta.url).pathname;
const templateRoot = join(root, "Shared/ScriptWidgetRuntime/Resource/Script.bundle/template");
const schema = JSON.parse(await readFile(join(root, "Shared/ScriptWidgetRuntime/ScriptWidgetAPI.json"), "utf8"));
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
