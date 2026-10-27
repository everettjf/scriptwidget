import { decodeManifest, legacyManifest, newManifest, validateManifest } from "./manifest.js";
import { packageDirectoryName, readArchive, writeArchive } from "./archive.js";

export * from "./manifest.js";
export * from "./archive.js";

const textFile = /\.(jsx?|mjs|json|txt|md|csv|svg|xml)$/i;
const decoder = new TextDecoder("utf-8", { fatal: true });

/// Splits extracted bytes into UTF-8 text files and binary resources.
export function classifyFiles(files) {
  const result = {};
  for (const [path, bytes] of Object.entries(files)) {
    if (textFile.test(path)) {
      try { result[path] = decoder.decode(bytes); continue; } catch { /* keep as binary */ }
    }
    result[path] = bytes;
  }
  return result;
}

/// Imports .swt/.zip bytes like ScriptManager.importScriptPackage, except a
/// present but malformed widget.json fails closed instead of being replaced.
export async function importPackage(bytes, options) {
  const archive = await readArchive(bytes, options);
  if (archive.error) return archive;
  const files = classifyFiles(archive.files);
  if (Object.keys(files).some((path) => path.toLowerCase() === "widget.json" && path !== "widget.json")) return { error: "[package:invalid_manifest_case] Use the exact file name widget.json." };
  let manifest;
  if (typeof files["widget.json"] === "string") {
    const decoded = decodeManifest(files["widget.json"]);
    if (decoded.error) return { error: decoded.error };
    manifest = decoded.manifest;
  } else if (files["widget.json"] !== undefined) return { error: "widget.json must be UTF-8 text." };
  else {
    let metadata = {};
    try { if (typeof files["meta.json"] === "string") metadata = JSON.parse(files["meta.json"]) ?? {}; } catch { metadata = {}; }
    manifest = legacyManifest(archive.rootName ?? "Imported Widget", metadata);
    files["widget.json"] = `${JSON.stringify(manifest, null, 2)}\n`;
  }
  const report = validateManifest(manifest, Object.keys(files));
  if (!report.valid) return { error: report.issues.filter((issue) => issue.severity === "error").map((issue) => issue.message).join("\n"), report };
  return { manifest, files, report };
}

/// Validates and exports a project as .swt bytes under its manifest name.
export function exportPackage(files) {
  const decoded = typeof files["widget.json"] === "string" ? decodeManifest(files["widget.json"]) : { error: "widget.json is missing." };
  if (decoded.error) return { error: decoded.error };
  const report = validateManifest(decoded.manifest, Object.keys(files));
  if (!report.valid) return { error: report.issues.filter((issue) => issue.severity === "error").map((issue) => issue.message).join("\n"), report };
  const directory = packageDirectoryName(decoded.manifest.name);
  return { bytes: writeArchive(directory, files), fileName: `${directory}.swt`, manifest: decoded.manifest, report };
}

export function newProjectFiles(name, source = "$render(\n  <vstack>\n    <text font=\"title\">Hello ScriptWidget :)</text>\n  </vstack>\n);\n") {
  const manifest = newManifest(name);
  return { "widget.json": `${JSON.stringify(manifest, null, 2)}\n`, "main.jsx": source };
}
