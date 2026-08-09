import { readFile, readdir, stat } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const roots = [
  "README.md", "README_CN.md", "CONTRIBUTING.md", "SECURITY.md",
  "CODE_OF_CONDUCT.md", "GOVERNANCE.md", "ROADMAP.md", "CHANGELOG.md", "docs"
];
const failures = [];

async function markdownFiles(path) {
  const info = await stat(path);
  if (info.isFile()) return path.endsWith(".md") ? [path] : [];
  const result = [];
  for (const entry of await readdir(path, { withFileTypes: true })) {
    const child = join(path, entry.name);
    if (entry.isDirectory()) result.push(...await markdownFiles(child));
    else if (entry.name.endsWith(".md")) result.push(child);
  }
  return result;
}

for (const entry of roots) {
  const sourcePath = join(root, entry);
  for (const markdownPath of await markdownFiles(sourcePath)) {
    const contents = await readFile(markdownPath, "utf8");
    for (const match of contents.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/g)) {
      let target = match[1].trim();
      if (target.startsWith("<") && target.endsWith(">")) target = target.slice(1, -1);
      target = target.split(/\s+["']/)[0].split("#")[0];
      if (!target || /^(?:https?:|mailto:|tel:)/i.test(target)) continue;
      let decoded;
      try { decoded = decodeURIComponent(target); }
      catch { failures.push(`${relative(root, markdownPath)}: invalid URL encoding in ${target}`); continue; }
      const destination = resolve(dirname(markdownPath), decoded);
      if (destination !== root && !destination.startsWith(`${root}/`)) {
        failures.push(`${relative(root, markdownPath)}: link escapes repository: ${target}`);
        continue;
      }
      try { await stat(destination); }
      catch { failures.push(`${relative(root, markdownPath)}: missing local link ${target}`); }
    }
  }
}

if (failures.length) {
  console.error(failures.map(value => `✗ ${value}`).join("\n"));
  process.exit(1);
}
console.log("✓ documentation links and images resolve locally");
