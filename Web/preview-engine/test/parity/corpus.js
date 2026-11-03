import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { executePackageInNode, readPackageDirectory } from "../../src/node.js";

export const parityDirectory = path.dirname(fileURLToPath(import.meta.url));
export const repositoryRoot = path.resolve(parityDirectory, "../../../..");

/// Mirrors BrowserPreviewParityTests.corpusPackages().
export function corpusPackages() {
  const roots = [
    ["api", "Shared/ScriptWidgetRuntime/Resource/Script.bundle/api"],
    ["component", "Shared/ScriptWidgetRuntime/Resource/Script.bundle/component"],
    ["template", "Shared/ScriptWidgetRuntime/Resource/Script.bundle/template"],
    ["gallery", "Gallery/widgets"],
  ];
  const result = [];
  for (const [prefix, relative] of roots) {
    const root = path.join(repositoryRoot, relative);
    for (const name of fs.readdirSync(root).filter((item) => !item.startsWith(".")).sort()) {
      const directory = path.join(root, name);
      if (fs.existsSync(path.join(directory, "main.jsx"))) result.push({ name: `${prefix}/${name}`, directory });
    }
  }
  return result;
}

export function usesLiveData(source) {
  return ["$getenv(\"timeline-date\")", "fetch(", "$http.", "$location.", "$health.", "$calendar.", "$reminders.", "$photos.", "$services.", "$music.", "$dataSource.", "$icloud.", "cloudHydration."].some((token) => source.includes(token));
}

export function readNativeTrees() {
  return JSON.parse(fs.readFileSync(path.join(parityDirectory, "native-trees.json"), "utf8"));
}

export async function runParity() {
  const native = readNativeTrees();
  const prelude = fs.readFileSync(path.join(parityDirectory, "prelude.js"), "utf8");
  const results = [];
  for (const { name, directory } of corpusPackages()) {
    const files = readPackageDirectory(directory);
    const expected = native.entries[name];
    if (usesLiveData(files["main.jsx"])) {
      results.push({ name, status: expected?.skipped ? "skipped" : "corpus-mismatch" });
      continue;
    }
    const manifest = files["widget.json"] ? JSON.parse(files["widget.json"]) : null;
    const actual = await executePackageInNode({ files, manifest, prelude, timeZone: native.timeZone });
    let status;
    if (!expected) status = "missing-native";
    else if (expected.tree !== undefined) status = actual.tree === expected.tree ? "match" : "tree-differs";
    else status = actual.error?.kind === expected.error ? "match" : "error-differs";
    results.push({ name, status, expected, actual: { tree: actual.tree, error: actual.error?.kind, message: actual.error?.message } });
  }
  return { native, results };
}
