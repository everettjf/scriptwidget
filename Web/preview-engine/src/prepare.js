import { buildTimelinePlan } from "./timeline.js";
import { compilePackageEntry } from "./compiler.js";
import { decodeManifest, validateManifest } from "./package/manifest.js";
import { createPackageFileSystem } from "./packageFiles.js";

const scriptFile = /\.(jsx?|mjs)$/i;

/// Compiles the entry (wrapped in $main) and every script file (unwrapped,
/// like $import) before execution. Precompilation keeps the Babel bundle out
/// of the realm that runs user code and lets $import stay synchronous.
export function preparePackage(compiler, { files, entry, prelude = "", manifest = null, actionID = null, callFunction = null }) {
  const packageFiles = createPackageFileSystem(files);
  // The on-disk manifest is authoritative, even when a host supplies a more
  // permissive object. Reject invalid packages before Babel or any user code.
  const present = packageFiles.paths().includes("widget.json");
  if (packageFiles.paths().some((path) => path.toLowerCase() === "widget.json" && path !== "widget.json")) {
    return { ok: false, error: { kind: "scriptError", message: "[package:invalid_manifest_case] Use the exact file name widget.json." } };
  }
  let selected = null;
  if (present || manifest !== null) {
    let decoded;
    try { decoded = decodeManifest(present ? packageFiles.read("widget.json") : JSON.stringify(manifest)); }
    catch { decoded = { error: "invalid manifest" }; }
    if (decoded.error) return { ok: false, error: { kind: "scriptError", message: "[package:invalid_manifest] widget.json is invalid." } };
    const report = validateManifest(decoded.manifest, packageFiles.paths(), { checkEntryExists: false });
    const issue = report.issues.find((item) => item.severity === "error");
    if (issue) return { ok: false, error: { kind: "scriptError", message: `[package:${issue.code}] Review widget.json and update ScriptWidget if required.` } };
    selected = decoded.manifest;
  }
  entry ??= selected?.entry ?? "main.jsx";
  const source = packageFiles.read(entry);
  if (source === null) {
    return { ok: false, error: { kind: "internalError", message: `Entry file ${entry} not found` } };
  }
  const action = actionID === null ? null : selected?.actions?.find((item) => item.id === actionID);
  if (actionID !== null && !action) return { ok: false, error: { kind: "scriptError", message: "[action:not_declared] Select a declared package action." } };
  // Legacy <button onClick="name"> runs a named function after the entry
  // (ButtonActionAppIntent). Only a plain identifier is accepted.
  if (callFunction !== null && !/^[A-Za-z_$][A-Za-z0-9_$]{0,127}$/.test(callFunction)) return { ok: false, error: { kind: "scriptError", message: "[action:invalid_function] onClick must name a function." } };
  const main = compilePackageEntry(compiler, prelude + source, { callFunction: action?.function ?? callFunction ?? "" });
  if (!main.ok) return { ok: false, error: { kind: main.kind, message: main.message } };

  const imports = {};
  for (const path of packageFiles.paths()) {
    const source=packageFiles.read(path);
    if (!scriptFile.test(path) || source === null) continue;
    imports[path] = JSON.stringify(compilePackageEntry(compiler, source, { wrap: false }));
  }
  const textFiles = Object.create(null);
  for (const path of packageFiles.paths()) textFiles[path] = packageFiles.read(path);
  const timelineEnvironment = selected?.timeline ? buildTimelinePlan(selected.timeline).entries[0].environments : {};
  return { ok: true, code: main.code, imports, files: textFiles, manifest: selected, hasManifest: present || manifest !== null, actionID: action?.id ?? null, timelineEnvironment };
}
