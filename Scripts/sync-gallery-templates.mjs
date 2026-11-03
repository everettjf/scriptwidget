import { readFile, readdir, mkdir, writeFile, lstat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join, dirname } from "node:path";
import { createHash } from "node:crypto";

// Explicit curator list: discovering a new template never publishes it automatically.
const curated = [
  ["Countdown", "countdown"],
  ["GitHub Repo Stats", "github-repo-stats"],
  ["GitHub Profile", "github-profile"],
  ["Habit Heatmap", "habit-heatmap"],
  ["Habit Streak Tracker", "habit-streak"],
  ["Health Steps Ring", "health-card"],
  ["Health Overview", "health-overview"],
  ["Hydration Goal", "hydration-goal"],
  ["Hydration Goal iCloud", "hydration-goal-icloud"],
  ["Local Weather (Location)", "local-weather"],
  ["Layout Starter", "layout-starter"],
  ["Material Study", "material-study"],
  ["Mood Check-in", "mood-check-in"],
  ["Music Playback", "music-playback"],
  ["Packing Checklist", "packing-checklist"],
  ["Photo Card", "photo-card"],
  ["Photo Album Rotator", "photo-album-rotator"],
  ["Reminders Agenda", "reminders-agenda"],
  ["Plant Care", "plant-care"],
  ["Pocket Pet", "pocket-pet"],
  ["Quick Launcher", "quick-launcher"],
  ["Wallpaper Match", "wallpaper-match"],
  ["Weather Now (MET Norway)", "weather-now"],
];
const root = fileURLToPath(new URL("../", import.meta.url));
const write = process.argv.includes("--write");
const rawRoot = "https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/";
const sourceRoot = "https://github.com/everettjf/scriptwidget/tree/main/Gallery/";
const indexPath = join(root, "Gallery/index.json");
const index = JSON.parse(await readFile(indexPath, "utf8"));
const failures = [];

async function filesAt(directory, prefix = "") {
  const status = await lstat(directory);
  if (!status.isDirectory() || status.isSymbolicLink()) throw new Error(`Gallery directory must not be a link: ${directory}`);
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = prefix + entry.name;
    if (entry.isSymbolicLink()) throw new Error(`Gallery sources cannot contain links: ${path}`);
    if (entry.isDirectory()) result.push(...await filesAt(join(directory, entry.name), path + "/"));
    else if (entry.isFile()) {
      if ((await lstat(join(directory, entry.name))).nlink !== 1) throw new Error(`Gallery sources cannot contain hard links: ${path}`);
      result.push(path);
    }
    else throw new Error(`Gallery source is not a regular file: ${path}`);
  }
  return result.sort();
}

for (const [name, slug] of curated) {
  const source = join(root, "Shared/ScriptWidgetRuntime/Resource/Script.bundle/template", name);
  const destination = join(root, "Gallery/widgets", slug);
  const manifest = JSON.parse(await readFile(join(source, "widget.json"), "utf8"));
  const metadata = JSON.parse(await readFile(join(source, "meta.json"), "utf8"));
  const files = [];
  // Template README links are relative to the native source tree, not the Gallery.
  const paths = (await filesAt(source)).filter((path) => path !== "README.md");
  const existingPaths = await filesAt(destination).catch((error) => {
    if (error.code === "ENOENT") return [];
    throw error;
  });
  for (const path of existingPaths) {
    if (!paths.includes(path)) throw new Error(`${slug}/${path}: unindexed stale file; review and remove explicitly`);
  }
  for (const path of paths) {
    const data = await readFile(join(source, path));
    if (write) {
      await mkdir(dirname(join(destination, path)), { recursive: true });
      await writeFile(join(destination, path), data);
    } else {
      const actual = await readFile(join(destination, path)).catch(() => null);
      if (!actual?.equals(data)) failures.push(`${slug}/${path}: differs from the reviewed native template`);
    }
    files.push({ bytes: data.length, path, sha256: createHash("sha256").update(data).digest("hex"), url: rawRoot + `widgets/${slug}/${path}` });
  }
  const item = {
    author: "ScriptWidget", featured: metadata.featured !== false, files, id: manifest.id, kind: "widget", license: "MIT",
    // Gallery 1.0's field denotes the runtime contract, just like widget.json's runtimeVersion.
    // The independently verified package retains its actual minimum API requirement (1.3).
    minimumRuntimeVersion: manifest.runtimeVersion, name: manifest.name,
    sourceURL: sourceRoot + `widgets/${slug}`,
    summary: `Requires Runtime API ${manifest.minimumRuntimeVersion ?? manifest.runtimeVersion}. ${manifest.description ?? metadata.description}`,
    symbol: manifest.icon ?? metadata.icon, tags: manifest.tags ?? [metadata.category], version: manifest.version,
  };
  if (item.summary.length > 240) throw new Error(`${slug}: summary exceeds Gallery limits`);
  const position = index.items.findIndex((entry) => entry.id === item.id);
  if (write) {
    if (position < 0) index.items.push(item);
    else index.items[position] = item;
  } else if (position < 0 || JSON.stringify(index.items[position]) !== JSON.stringify(item)) {
    failures.push(`${slug}: index metadata, hashes or API requirement differs; run node Scripts/sync-gallery-templates.mjs --write`);
  }
}
if (failures.length) throw new Error(failures.join("\n"));
if (write) {
  index.generatedAt = new Date().toISOString();
  await writeFile(indexPath, JSON.stringify(index, null, 2) + "\n");
}
console.log(`✓ ${curated.length} curated Gallery templates match their complete native packages`);
