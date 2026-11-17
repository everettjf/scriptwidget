// Builds the JavaScript assets that the QuickJS hosts (Android and Windows)
// share with the web preview engine: the execution kernel, the package
// preparation bundle, the runtime contract, the support scripts, the host
// files and the renderer bundle. Also writes the parity corpus the hosts'
// tests run.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const engine = path.join(repository, "Web/preview-engine");
const support = path.join(repository, "Shared/ScriptWidgetRuntime/Widget/Resource/support.bundle");
const hostSources = path.join(repository, "Android/core/src/main/js");
const load = (file) => import(pathToFileURL(path.join(engine, file)).href);

function moduleBody(file) {
  return fs.readFileSync(path.join(engine, "src", file), "utf8")
    .replace(/^import[^;]+;\n/gm, "")
    .replace(/^export \{[^}]*\}[^;]*;\n/gm, "")
    .replace(/^export (const|function|async function|class) /gm, "$1 ");
}

function findEsbuild() {
  const names = process.platform === "win32" ? ["esbuild.cmd"] : ["esbuild"];
  for (const directory of ["Web/studio/node_modules/.bin", "Editor/editorfe/node_modules/.bin"]) {
    for (const name of names) {
      const file = path.join(repository, directory, name);
      if (fs.existsSync(file)) return file;
    }
  }
  throw new Error("esbuild not found: run npm install in Web/studio first");
}

/// `output`: directory for the assets. `banner`: first line of generated
/// files. `compilerFingerprint`: identifies the host's compiler in caches.
/// `hostFiles`: maps a file in Android/core/src/main/js to its output name.
/// `bundleDirectory`: working directory of esbuild; module paths in the
/// bundle are relative to it, so it is fixed per host.
/// `corpusOutput`: where to write parity-corpus.json.
export async function buildSharedJS({ output, banner, compilerFingerprint, hostFiles, bundleDirectory, corpusOutput }) {
  const { scriptWidgetKernel } = await load("src/kernel.js");
  const { runtimeContract, errorCategories } = await load("src/contract.js");

  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, "kernel.js"), `${banner}globalThis.__swKernel = ${scriptWidgetKernel.toString()};\n`);

  const prepareModules = ["contract.js", "packageFiles.js", "timeZones.js", "timeline.js", "package/manifest.js", "compiler.js", "prepare.js"];
  fs.writeFileSync(path.join(output, "prepare.js"),
    `${banner}globalThis.__swPrepareBundle = (function () {\n${prepareModules.map(moduleBody).join("\n")}\n` +
    "return { createCompiler, preparePackage, buildTimelinePlan, decodeManifest, validateManifest, normalizePackagePath };\n})();\n");

  // A QuickJS host is a native host: it implements the native API version.
  const contract = { ...runtimeContract, apiVersion: runtimeContract.nativeAPIVersion, compilerFingerprint };
  fs.writeFileSync(path.join(output, "contract.json"), JSON.stringify({ contract, errorCategories }, null, 2) + "\n");

  for (const name of ["core.js", "util.js", "moment.min.js"]) fs.copyFileSync(path.join(support, name), path.join(output, name));
  for (const [source, target] of hostFiles) fs.copyFileSync(path.join(hostSources, source), path.join(output, target));

  // The shared web renderer, bundled for QuickJS with a recording document.
  const esbuild = findEsbuild();
  const entry = path.join(hostSources, "render/entry.mjs");
  const outfile = path.join(output, "render.js");
  const args = [entry, "--bundle", "--format=iife", "--global-name=__swRenderBundle", "--target=es2022", "--charset=utf8", "--log-level=warning", `--outfile=${outfile}`];
  if (process.platform === "win32") execFileSync(`"${esbuild}" ${args.map((value) => `"${value}"`).join(" ")}`, { stdio: "inherit", cwd: bundleDirectory, shell: true });
  else execFileSync(esbuild, args, { stdio: "inherit", cwd: bundleDirectory });

  // Parity corpus: every bundled package that needs no live data, with the
  // tree JavaScriptCore produced for it.
  const { corpusPackages, readNativeTrees, usesLiveData } = await load("test/parity/corpus.js");
  const { readPackageDirectory } = await load("src/node.js");
  const native = readNativeTrees();
  const corpus = corpusPackages()
    .map(({ name, directory }) => {
      const files = readPackageDirectory(directory);
      const text = {}, binaries = [];
      for (const [file, content] of Object.entries(files)) { if (typeof content === "string") text[file] = content; else binaries.push(file); }
      return { name, files: text, binaries, expected: native.entries[name] ?? null };
    })
    .filter((item) => !usesLiveData(item.files["main.jsx"]));
  fs.mkdirSync(corpusOutput, { recursive: true });
  fs.writeFileSync(path.join(corpusOutput, "parity-corpus.json"),
    JSON.stringify({ timeZone: native.timeZone, locale: native.javaScriptLocale, prelude: fs.readFileSync(path.join(engine, "test/parity/prelude.js"), "utf8"), corpus }));

  console.log(`assets -> ${path.relative(repository, output)} (${fs.readdirSync(output).join(", ")})`);
  console.log(`parity corpus: ${corpus.length} packages, time zone ${native.timeZone}`);
}

export { repository, hostSources };
