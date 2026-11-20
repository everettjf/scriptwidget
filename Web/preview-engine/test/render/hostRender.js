// Renders trees the way the QuickJS hosts do (Android, Windows, Linux): through
// the Android render entry, with a recording document and a text measurer that
// needs no system fonts. appleFallback.test.js compares the digests with the
// ones recorded in host-baseline.json, so a change to the shared renderer that
// alters what those three hosts draw cannot go unnoticed.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { render } from "../../../../Android/core/src/main/js/render/entry.mjs";
import { renderWidget } from "../../src/render/renderer.js";
import { readNativeTrees } from "../parity/corpus.js";

export const baselineFile = path.join(path.dirname(fileURLToPath(import.meta.url)), "host-baseline.json");

/// A stand-in for the host's text engine: every character is 0.55 em wide.
function nativeCall(name, payload) {
  if (name === "text.measure") {
    const { text, size, width } = JSON.parse(payload);
    const lines = String(text).split("\n").map((line) => line.length * size * 0.55);
    const widest = Math.max(0, ...lines);
    if (width === null || widest <= width) return JSON.stringify({ width: widest, lines: lines.length });
    return JSON.stringify({ width, lines: lines.reduce((sum, line) => sum + Math.max(1, Math.ceil(line / Math.max(1, width))), 0) });
  }
  if (name === "text.baseline") return String(JSON.parse(payload).size * 0.8);
  return null; // image.size: no image is decoded
}

/// What a phone with a wallpaper palette supplies; Windows and Linux supply none and draw the fixed table.
export const hostPalette = {
  light: { primary: [10, 20, 30, 1], onSurface: [1, 2, 3, 1], onSurfaceVariant: [4, 5, 6, 1], surfaceContainer: [240, 241, 242, 1], primaryContainer: [200, 201, 202, 1], onPrimaryContainer: [7, 8, 9, 1] },
  dark: { primary: [210, 220, 230, 1], onSurface: [251, 252, 253, 1], onSurfaceVariant: [204, 205, 206, 1], surfaceContainer: [40, 41, 42, 1], primaryContainer: [90, 91, 92, 1], onPrimaryContainer: [247, 248, 249, 1] },
};

const element = (tag, props, ...children) => ({ $element: tag, props, children });
const row = (index) => element("toggle", { stateKey: `check.${index}`, on: index % 2 === 0, padding: "4,2,4,2" }, element("text", { font: "subheadline", color: index % 2 ? "material.onSurface" : "material.onSurfaceVariant" }, `Row ${index}`));

/// Trees that use what only Android had: the scrolling list and the wallpaper colors.
export const extensionTrees = {
  "extension/list": JSON.stringify(element("vstack", { frame: "max,topLeading", alignment: "leading", spacing: "8", padding: "14", background: "material.surfaceContainer" },
    element("text", { font: "headline", color: "material.onSurface" }, "Checklist"),
    element("list", { spacing: "2" }, Array.from({ length: 20 }, (_, index) => row(index))))),
  "extension/long-list": JSON.stringify(element("list", { spacing: "1", padding: "6", background: "material.primaryContainer,0.5" }, ...Array.from({ length: 120 }, (_, index) => element("button", { action: "reload" }, element("text", null, `Button ${index}`))))),
  "extension/two-lists": JSON.stringify(element("hstack", null, element("list", null, element("text", null, "a"), element("text", null, "b")), element("list", { frame: "60,40" }, element("rect", { color: "material.primary", frame: "20,30" }), element("rect", { color: "material.unknownRole", frame: "20,30" })))),
  "extension/colors": JSON.stringify(element("vstack", { background: "material.surfaceContainer" },
    element("rect", { color: "material.primary", frame: "max,26" }), element("rect", { color: "material.primary,0.5", frame: "max,26" }),
    element("icon", { systemName: "paintpalette.fill", size: "18", color: "material.onPrimaryContainer" }), element("text", { color: "material.nothing" }, "plain"))),
};

export async function hostRender(tree, { dark = false, colors = null, family = "medium", width = 338, height = 158 } = {}) {
  return render(nativeCall, JSON.stringify({ tree, family, width, height, dark, now: 1767268800000, colors }));
}

/// A document that only records what the renderer builds.
function recordingDocument() {
  class Element {
    constructor(tag) { this.tagName = tag; this.style = { setProperty(name, value) { this[name] = String(value); } }; this.dataset = {}; this.attributes = {}; this.children = []; this.text = null; this.ownerDocument = document; }
    appendChild(child) { this.children.push(child); return child; }
    replaceChildren(...children) { this.children = children; }
    remove() {}
    setAttribute(name, value) { this.attributes[name] = String(value); }
    getAttribute(name) { return this.attributes[name] ?? null; }
    querySelector() { return null; }
    set textContent(value) { this.text = String(value); }
    get textContent() { return this.text ?? ""; }
    set innerHTML(value) { this.markup = String(value); }
  }
  const document = { createElement: (tag) => new Element(tag), createElementNS: (_, tag) => new Element(tag), createTextNode: (text) => ({ textNode: String(text) }), body: null };
  document.body = new Element("body");
  return document;
}

const measurer = {
  measure: (text, style, width) => JSON.parse(nativeCall("text.measure", JSON.stringify({ text, size: style.size, width: width === null || width === Infinity ? null : width }))),
  baseline: (style) => style.size * 0.8,
  emojiSize: () => null,
  textAdjustments: () => ({ emoji: null, han: null }),
  ellipsisWidth: (style) => style.size * 0.55,
  dispose() {},
};

/// Renders a tree the way the browser preview does for iPhone, iPad and Mac:
/// no host options. Returns the recorded element, the size and the diagnostics.
export async function appleRender(tree, { profile = "iphone-393", family = "medium", appearance = "light" } = {}) {
  return renderWidget(tree, { profile, family, appearance, lockScreen: false, document: recordingDocument(), now: 1767268800000, animations: "firstFrame", textMeasurer: measurer });
}

/// Every recorded element below `element`, itself included, in drawing order.
export function elements(element) {
  return [element, ...(element.children ?? []).flatMap((child) => (child.textNode === undefined ? elements(child) : []))];
}

/// A timer, a relative date or an offset is drawn from the real clock, so its picture changes between runs.
const clockDependent = (tree) => /"style":"(timer|relative|offset)"/.test(tree);

/// Two digests per tree, each over light and dark and both sizes: `palette` is
/// what a host that supplies colors draws (Android), `plain` what a host
/// without any draws (Windows, Linux).
export async function hostDigests() {
  const trees = { ...extensionTrees };
  for (const [name, entry] of Object.entries(readNativeTrees().entries)) if (entry.tree !== undefined && !clockDependent(entry.tree)) trees[name] = entry.tree;
  const digests = {};
  for (const name of Object.keys(trees).sort()) {
    digests[name] = {};
    for (const [kind, colors] of [["palette", hostPalette], ["plain", null]]) {
      const hash = crypto.createHash("sha256");
      for (const dark of [false, true]) {
        for (const [family, width, height] of [["medium", 338, 158], ["large", 338, 354]]) {
          hash.update(await hostRender(trees[name], { dark, colors, family, width, height }).catch((error) => `error: ${error?.message ?? error}`));
          hash.update("\n");
        }
      }
      digests[name][kind] = hash.digest("hex");
    }
  }
  return digests;
}

/// Whether a tree names a "material.<role>" color.
export function usesMaterialColors(name) {
  const tree = extensionTrees[name] ?? readNativeTrees().entries[name].tree;
  return /"material\.[A-Za-z]/.test(tree);
}

// node test/render/hostRender.js --record writes the baseline. Do that only for
// a change that is meant to alter what Android, Windows and Linux draw.
if (process.argv[1] === fileURLToPath(import.meta.url) && process.argv.includes("--record")) {
  fs.writeFileSync(baselineFile, JSON.stringify(await hostDigests(), null, 1) + "\n");
}
