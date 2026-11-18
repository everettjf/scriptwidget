#!/usr/bin/env node
// Finds text that does not fit in the bundled templates when it is drawn with
// Inter, the font of Android, Windows and Linux, which is wider than Apple's
// system font. Every package of Script.bundle is run at the four desktop
// families on a handful of dates chosen for the longest strings, laid out by
// the shared renderer with Skia's Inter metrics, and the recorded elements
// are searched for:
//
//   truncated  a text the layout cut and ended with "…"
//   clipped    a text narrower than "…" that the layout cut at its frame
//   wrapped    a short text (one or two words) broken over more than one line
//   outside    a text whose box leaves the widget
//
// A finding is a candidate, not a verdict: a long title elided on purpose is
// reported too. Look at the picture (--pictures) before changing a template.
//
//   node Linux/scripts/build-shared-js.mjs
//   cd Linux && cargo build --release -p sw-cli && cargo build --release -p sw-render --example layout_tree
//   node Linux/scripts/find-truncated-text.mjs [--only <text in the package path>] [--pictures <folder>] [--json <file>] [--keep <folder>]
//
// On macOS the cargo commands need PKG_CONFIG_PATH="$(brew --prefix icu4c)/lib/pkgconfig".
// The script's clock is fixed by putting a `Date` whose "now" is the chosen
// moment in front of each source file of a temporary copy of the package;
// the templates themselves are not touched. Packages that need the network or
// an API Linux lacks draw their fallback or fail; the ones that fail are
// listed as not checked. Exit code 1 when anything was found.

import { execFile, spawn } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const bundle = join(root, "Shared/ScriptWidgetRuntime/Resource/Script.bundle");
const assets = process.env.SCRIPTWIDGET_RUNTIME_ASSETS ?? join(root, "Linux/assets/scriptwidget");
const cli = join(root, "Linux/target/release/scriptwidget");
const layoutTree = join(root, "Linux/target/release/examples/layout_tree");
const timeZone = "UTC";

// The families of the Linux, Windows and Mac desktops (see FAMILY_SIZES in sw-render).
const families = ["small", "medium", "large", "extraLarge"];
// The moments, in UTC, that give the longest strings the templates format.
const moments = {
  // "Wednesday", "September", "12:59 PM", day 259 of the year with 106 left.
  "wed-sep-16-1259": Date.UTC(2026, 8, 16, 12, 59, 58),
  // "Wednesday", "November", a wide 24-hour time.
  "wed-nov-18-2048": Date.UTC(2026, 10, 18, 20, 48, 38),
  // A month of six weeks, "Saturday", day 241.
  "sat-aug-29-2248": Date.UTC(2026, 7, 29, 22, 48, 8),
  // The end of the year: "December", 100 % and 364 days gone.
  "wed-dec-30-2359": Date.UTC(2026, 11, 30, 23, 59, 59),
  // The start of the year: "12:00 AM", 0 % and 364 days left.
  "thu-jan-01-0000": Date.UTC(2026, 0, 1, 0, 0, 5),
};

function option(name) {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? null : process.argv[index + 1] ?? null;
}
const only = option("only");
const pictures = option("pictures");
const jsonFile = option("json");
const keep = option("keep");

for (const file of [cli, layoutTree, join(assets, "render.js")]) {
  if (!existsSync(file)) { console.error(`${relative(root, file)} is missing; see the top of this script for the commands that build it.`); process.exit(2); }
}

function packages() {
  const found = [];
  const walk = (directory) => {
    const names = readdirSync(directory);
    if (names.includes("main.jsx") || names.includes("widget.json")) { found.push(directory); return; }
    for (const name of names) if (statSync(join(directory, name)).isDirectory()) walk(join(directory, name));
  };
  walk(bundle);
  return found.map((directory) => relative(bundle, directory)).filter((name) => !only || name.includes(only)).sort();
}

/// A `Date` whose "now" is `moment`, on one line so that line numbers stay.
const clock = (moment) => `if (!globalThis.__fixedClock) { globalThis.__fixedClock = true; const RealDate = Date; const fixed = ${moment}; globalThis.Date = class Date extends RealDate { constructor(...values) { if (values.length) super(...values); else super(fixed); } static now() { return fixed; } }; } `;

function withClock(source, target, moment) {
  cpSync(source, target, { recursive: true });
  const walk = (directory) => {
    for (const name of readdirSync(directory)) {
      const file = join(directory, name);
      if (statSync(file).isDirectory()) walk(file);
      else if (/\.jsx?$/.test(name)) writeFileSync(file, clock(moment) + readFileSync(file, "utf8"));
    }
  };
  walk(target);
}

const environment = { ...process.env, TZ: timeZone, LC_ALL: "en_US.UTF-8", LANG: "en_US.UTF-8", SCRIPTWIDGET_RUNTIME_ASSETS: assets };

function run(arguments_) {
  return new Promise((done) => {
    execFile(cli, arguments_, { env: environment, maxBuffer: 256 * 1024 * 1024, timeout: 120_000 }, (error, stdout) => {
      try { done(JSON.parse(stdout)); } catch { done({ ok: false, error: { message: String(error ?? "no report") } }); }
    });
  });
}

async function inParallel(items, limit, work) {
  let next = 0;
  await Promise.all(Array.from({ length: limit }, async () => { while (next < items.length) { const item = items[next++]; await work(item); } }));
}

const pixels = (value) => (typeof value === "string" && value.endsWith("px") ? Number.parseFloat(value) : 0);
const texts = (tree, into = []) => {
  if (tree === null || typeof tree !== "object") { if (tree !== null && tree !== undefined) into.push(String(tree)); return into; }
  if (Array.isArray(tree)) { for (const item of tree) texts(item, into); return into; }
  texts(tree.children ?? [], into);
  return into;
};

/// The findings of one laid-out tree. `sources` are the texts of the canonical tree.
function inspect(layout, sources) {
  const findings = [];
  const walk = (element, left, top, clipped) => {
    if (element.t === "style" || element.g === 1) return;
    const style = element.s ?? {};
    const positioned = style.position === "absolute";
    const x = left + (positioned ? pixels(style.left) : 0);
    const y = top + (positioned ? pixels(style.top) : 0);
    const content = (element.c ?? []).find((child) => typeof child.x === "string" && child.t === "div");
    if (style.fontSize && content) {
      const drawn = content.x;
      const width = pixels(style.width); const height = pixels(style.height); const lineHeight = pixels(style.lineHeight);
      const size = pixels(style.fontSize);
      const box = { x: Math.round(x * 10) / 10, y: Math.round(y * 10) / 10, width, height, size, weight: style.fontWeight ?? "400", inter: /^"ScriptWidget Inter"/.test(style.fontFamily ?? "") };
      const cut = content.s?.whiteSpace === "pre" && content.s?.overflow === "hidden";
      const source = () => {
        const prefix = drawn.split("\n").at(-1).replace(/…$/, "");
        return sources.find((text) => text !== drawn && text.replace(/\s+/g, " ").includes(prefix)) ?? null;
      };
      if (cut && style.overflow !== "hidden" && drawn.endsWith("…")) findings.push({ kind: "truncated", drawn, source: source(), ...box });
      // Narrower than "…": the frame cuts the text. One character in its own width is the usual harmless case.
      else if (style.overflow === "hidden" && [...drawn.trim()].length > 1) findings.push({ kind: "clipped", drawn, ...box });
      else if (!cut && lineHeight > 0 && height > lineHeight * 1.5 && !drawn.includes("\n") && drawn.trim().split(/\s+/).length <= 2) findings.push({ kind: "wrapped", drawn, ...box });
      if (drawn.trim() !== "" && width > 0 && !clipped && (x < -1 || y < -1 || x + width > layout.width + 1 || y + height > layout.height + 1)) findings.push({ kind: "outside", drawn, ...box });
      return;
    }
    // What a clipping ancestor hides is not drawn outside the widget.
    const clips = clipped || (element !== layout.root && (style.overflow === "hidden" || style.overflowY === "auto" || Boolean(style.clipPath)));
    for (const child of element.c ?? []) walk(child, x, y, clips);
  };
  walk(layout.root, 0, 0, false);
  return findings;
}

const work = keep ? resolve(keep) : mkdtempSync(join(tmpdir(), "scriptwidget-truncation-"));
mkdirSync(work, { recursive: true });
const names = packages();
const jobs = [];
for (const [index, name] of names.entries()) {
  for (const [label, moment] of Object.entries(moments)) {
    const directory = join(work, label, String(index).padStart(3, "0"), name.split("/").at(-1));
    mkdirSync(dirname(directory), { recursive: true });
    rmSync(directory, { recursive: true, force: true });
    withClock(join(bundle, name), directory, moment);
    for (const family of families) jobs.push({ name, label, moment, family, directory, tree: join(dirname(directory), `${family}.tree.json`), layout: join(dirname(directory), `${family}.layout.json`) });
  }
}

// Run every package; a run that returns no tree is not checked.
const notChecked = new Map();
await inParallel(jobs, 8, async (job) => {
  const report = await run(["run", job.directory, "--family", job.family]);
  if (report.tree === undefined || report.tree === null || report.ok === false) {
    notChecked.set(job.name, String(report.error?.message ?? report.errors?.[0]?.message ?? report.status ?? "no tree").slice(0, 200));
    return;
  }
  job.sources = texts(report.tree);
  job.logs = (report.logs ?? []).filter((entry) => entry.level === "error").map((entry) => entry.message);
  writeFileSync(job.tree, JSON.stringify(report.tree));
});

// Lay all of them out in one process.
const ran = jobs.filter((job) => job.sources);
function layOut(lines) {
  return new Promise((done, failed) => {
    const child = spawn(layoutTree, [assets], { env: environment, stdio: ["pipe", "pipe", "inherit"] });
    let output = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.on("error", failed);
    child.on("close", () => done(output.split("\n").filter(Boolean)));
    child.stdin.end(lines.map((line) => line.join("\t")).join("\n") + "\n");
  });
}
const answers = await layOut(ran.map((job) => [job.tree, job.family, job.moment, job.directory, job.layout]));
const offenders = [];
for (const [index, job] of ran.entries()) {
  if (answers[index] !== "ok") { notChecked.set(job.name, `layout ${answers[index] ?? "did not answer"}`.slice(0, 200)); continue; }
  const findings = inspect(JSON.parse(readFileSync(job.layout, "utf8")), job.sources);
  if (findings.length) offenders.push({ name: job.name, family: job.family, moment: job.label, directory: job.directory, findings });
}

// Measure each text alone, to say how much room it needed. A text in a frame
// narrower than "…" is recorded as clipped even when it has all the width it
// needs ("11" in a calendar cell); those are dropped here.
const weights = { 100: "ultralight", 200: "thin", 300: "light", 400: "regular", 500: "medium", 600: "semibold", 700: "bold", 800: "heavy", 900: "black" };
const whole = (finding) => (finding.kind === "truncated" ? finding.source : finding.drawn);
const probeKey = (finding) => `${finding.size}|${finding.weight}|${whole(finding)}`;
const measured = new Map();
for (const offender of offenders) {
  for (const finding of offender.findings) if (finding.inter && whole(finding) && !whole(finding).includes("\n")) measured.set(probeKey(finding), null);
}
const probes = [...measured.keys()].map((key, index) => {
  const [size, weight, ...text] = key.split("|");
  const tree = join(work, `probe-${index}.tree.json`);
  // Wide enough for any line: the probe is a horizontal stack that may grow past the widget.
  writeFileSync(tree, JSON.stringify({ $element: "hstack", props: { frame: "4000,100" }, children: [{ $element: "text", props: { font: size, fontWeight: weights[weight] ?? "regular" }, children: [text.join("|")] }] }));
  return { key, job: [tree, "extraLarge", "-", "-", join(work, `probe-${index}.layout.json`)] };
});
if (probes.length) {
  const probed = await layOut(probes.map((probe) => probe.job));
  for (const [index, probe] of probes.entries()) {
    if (probed[index] !== "ok") continue;
    const find = (element) => (element.s?.fontSize ? pixels(element.s.width) : (element.c ?? []).map(find).find((width) => width !== undefined));
    measured.set(probe.key, find(JSON.parse(readFileSync(probe.job[4], "utf8")).root) ?? null);
  }
  for (const offender of offenders) {
    offender.findings = offender.findings.filter((finding) => {
      finding.natural = measured.get(probeKey(finding)) ?? null;
      return finding.kind !== "clipped" || finding.natural === null || finding.natural > finding.width + 0.75;
    });
  }
}
for (let index = offenders.length - 1; index >= 0; index--) if (!offenders[index].findings.length) offenders.splice(index, 1);

if (pictures) {
  mkdirSync(resolve(pictures), { recursive: true });
  await inParallel(offenders, 8, async (offender) => {
    offender.picture = join(resolve(pictures), `${offender.name.replace(/[^A-Za-z0-9]+/g, "-")}.${offender.family}.${offender.moment}.png`);
    await run(["render", offender.directory, "--family", offender.family, "--now", String(moments[offender.moment]), "--output", offender.picture]);
  });
}

// One line for each distinct finding of a package and family, with the moments that show it.
const lines = new Map();
for (const offender of offenders) {
  for (const finding of offender.findings) {
    const key = `${offender.name}\t${offender.family}\t${finding.kind}\t${finding.drawn.replace(/\n/g, "⏎")}`;
    const line = lines.get(key) ?? { ...finding, name: offender.name, family: offender.family, moments: [] };
    if (!line.moments.includes(offender.moment)) line.moments.push(offender.moment);
    lines.set(key, line);
  }
}
for (const line of [...lines.values()].sort((a, b) => a.name.localeCompare(b.name) || a.family.localeCompare(b.family))) {
  const source = line.source ? ` (of "${line.source.replace(/\n/g, "⏎").slice(0, 60)}")` : "";
  console.log(`${line.name} [${line.family}] ${line.kind}: "${line.drawn.replace(/\n/g, "⏎")}"${source} ${line.size} pt at ${line.x},${line.y} ${line.width}x${line.height}${line.natural ? `, needs ${line.natural}` : ""} — ${line.moments.join(", ")}`);
}
const withErrors = [...new Set(ran.filter((job) => job.logs.length).map((job) => job.name))];
console.log(`\n${names.length} packages, ${ran.length} of ${jobs.length} runs laid out (${families.length} families, ${Object.keys(moments).length} moments, ${timeZone}); ${new Set(offenders.map((offender) => offender.name)).size} packages with findings.`);
if (notChecked.size) console.log(`Not checked (no tree on at least one run):\n${[...notChecked].map(([name, reason]) => `  ${name}: ${reason}`).join("\n")}`);
if (withErrors.length) console.log(`Drew after logging an error (their content may be a fallback):\n${withErrors.map((name) => `  ${name}`).join("\n")}`);
if (jsonFile) writeFileSync(resolve(jsonFile), JSON.stringify({ offenders: offenders.map(({ directory, ...rest }) => rest), notChecked: Object.fromEntries(notChecked) }, null, 2));
if (!keep) rmSync(work, { recursive: true, force: true });
process.exit(lines.size ? 1 : 0);
