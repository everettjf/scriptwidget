import { StateEffect, StateField } from "@codemirror/state";
import { parseVisualLayout } from "./visualLayout.js";
import { parseWidgetTheme, widgetThemePresets } from "./widgetTheme.js";

// Names only: image bytes remain in the package/renderer, not the editor bridge.
export function visualImageResources(paths) {
  if (!Array.isArray(paths) || paths.length > 4096) return [];
  const result = new Map(), ambiguous = new Set();
  for (const path of paths) {
    if (typeof path !== "string" || new TextEncoder().encode(path).length > 1024 || /[\\\u0000-\u001f\u007f-\u009f]/.test(path)) continue;
    const parts = path.split("/");
    if (parts.length !== 2 || parts[0] !== "image" || !parts[1] || new TextEncoder().encode(parts[1]).length > 255 || parts[1] !== parts[1].trim() || parts[1].includes("..") || !/\.(png|jpe?g|webp)$/i.test(parts[1])) continue;
    const identity = path.normalize("NFC").toLowerCase();
    if (result.has(identity) && result.get(identity) !== path) ambiguous.add(identity);
    result.set(identity, path);
  }
  return [...result].filter(([identity]) => !ambiguous.has(identity)).map(([, path]) => path).sort().slice(0, 256);
}
export const visualResourcesChanged = StateEffect.define();
export const visualResources = StateField.define({
  create: () => [],
  update(value, transaction) {
    for (const effect of transaction.effects) if (effect.is(visualResourcesChanged)) value = visualImageResources(effect.value);
    return value;
  },
});
export function setVisualLayoutResources(view, paths) {
  if (view.state.field(visualResources, false) !== undefined) view.dispatch({ effects: visualResourcesChanged.of(paths) });
}

// Original geometric compositions. No downloaded art, SF Symbols or code execution.
// Provenance and MIT reuse terms: docs/studio-assets.md.
export const visualAssetCatalog = Object.freeze({
  bloom: Object.freeze({ name: "Bloom mark", description: "A small four-petal flower", kind: "icon" }),
  leaf: Object.freeze({ name: "Leaf mark", description: "A tilted leaf and stem", kind: "icon" }),
  pebble: Object.freeze({ name: "Pebble friend", description: "A quiet, round-eared companion", kind: "pet" }),
});
// Keep provenance/reuse terms with exported JSX, not only in Studio's UI.
export const visualAssetLicense = `/*
ScriptWidget original geometric assets 1: Bloom mark, Leaf mark, Pebble friend.
Source: https://github.com/everettjf/scriptwidget (Editor/editorfe/src/visualAssets.js)
SPDX-License-Identifier: MIT
Copyright (c) 2021-2022 AtomSprout

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
`;
function originalSource(kind, themed) {
  const color = name => themed ? `{widgetTheme.${name}}` : JSON.stringify(widgetThemePresets.Meadow[name]);
  if (kind === "bloom") return `<zstack frame="40,40"><ellipse frame="15,36" color=${color("accent")}/><ellipse frame="15,36" rotation="90" color=${color("accent")}/><circle frame="11" color=${color("surface")}/></zstack>`;
  if (kind === "leaf") return `<zstack frame="40,40"><ellipse frame="21,34" rotation="40" color=${color("accent")}/><roundedrect frame="3,28" radius="2" rotation="40" color=${color("foreground")}/></zstack>`;
  if (kind === "pebble") return `<vstack spacing="0"><hstack spacing="20"><roundedrect frame="10,14" radius="5" rotation="-12" color=${color("accent")}/><roundedrect frame="10,14" radius="5" rotation="12" color=${color("accent")}/></hstack><zstack><ellipse frame="64,38" color=${color("accent")}/><hstack spacing="9"><circle frame="4" color=${color("foreground")}/><ellipse frame="9,3" color=${color("surface")}/><circle frame="4" color=${color("foreground")}/></hstack></zstack></vstack>`;
  throw new Error("Choose an original asset from the catalog.");
}
export function insertVisualAsset(model, source, { id, kind, path }, resources = []) {
  if (model.source !== source || model.issue) throw new Error("Layout changed. Select the container again.");
  const parent = model.nodes.find(node => node.id === id);
  if (!parent?.structure) throw new Error("Select a stack/grid with literal JSX children in Layout or Assets.");
  let insert;
  if (kind === "photo") {
    if (!visualImageResources(resources).includes(path)) throw new Error("This image is no longer in the package resource list. Refresh images.");
    insert = `<image name={${JSON.stringify(path.slice("image/".length))}} mode="fill" frame="96,64" corner="12"/>`;
  } else {
    if (!Object.hasOwn(visualAssetCatalog, kind)) throw new Error("Choose an original asset from the catalog.");
    insert = originalSource(kind, Boolean(parseWidgetTheme(source).tokens));
  }
  const changes = [{ from: parent.contentTo, to: parent.contentTo, insert }];
  let selectedFrom = parent.contentTo;
  if (kind !== "photo" && !source.includes(visualAssetLicense)) {
    const from = source.startsWith("#!") ? source.indexOf("\n") + 1 : 0;
    changes.push({from,to:from,insert:visualAssetLicense});
    selectedFrom += visualAssetLicense.length;
  }
  changes.sort((a,b)=>a.from-b.from);
  let next = source;
  for (const change of [...changes].reverse()) next = next.slice(0,change.from)+change.insert+next.slice(change.to);
  const parsed = parseVisualLayout(next);
  if (parsed.issue) throw new Error("This asset would exceed the supported layout limits. Your source was preserved.");
  return { changes, selectedFrom };
}
