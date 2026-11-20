// What the systems without Android's extensions draw for them. On iPhone, iPad
// and Mac a <list> shows the rows that fit. "material.<role>" is a fixed palette
// wherever the host supplies no wallpaper color: iPhone, iPad, Mac, Windows and
// Linux, and a role an Android palette leaves out. The QuickJS hosts (Android,
// Windows, Linux) run the same renderer with the `android` option; what they
// draw is recorded in render/host-baseline.json.
import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { executePackageInNode, readPackageDirectory } from "../src/node.js";
import { FittingListNode, FixedNode, SpacerNode, StackNode } from "../src/render/layout.js";
import { fixedMaterialColors, parseColor } from "../src/render/props.js";
import { appleRender, baselineFile, elements, extensionTrees, hostDigests, hostPalette, hostRender, usesMaterialColors } from "./render/hostRender.js";

const roles = [
  "primary", "onPrimary", "primaryContainer", "onPrimaryContainer", "secondary", "onSecondary", "secondaryContainer", "onSecondaryContainer",
  "tertiary", "onTertiary", "tertiaryContainer", "onTertiaryContainer", "background", "onBackground", "surface", "onSurface",
  "surfaceVariant", "onSurfaceVariant", "surfaceContainerLowest", "surfaceContainerLow", "surfaceContainer", "surfaceContainerHigh",
  "surfaceContainerHighest", "outline", "outlineVariant",
];
const element = (tag, props, ...children) => JSON.stringify({ $element: tag, props, children });
const node = (tag, props, ...children) => ({ $element: tag, props, children });
const pixels = (value) => Number.parseFloat(value);
const rgba = ([r, g, b, a]) => `rgba(${r}, ${g}, ${b}, ${a})`;
const list = (rendered) => elements(rendered.element).find((item) => item !== rendered.element && item.style.overflow === "hidden");

test("Android, Windows and Linux draw every corpus tree exactly as recorded", async () => {
  const baseline = JSON.parse(fs.readFileSync(baselineFile, "utf8"));
  const digests = await hostDigests();
  assert.ok(Object.keys(baseline).length >= 120);
  assert.deepEqual(Object.keys(digests), Object.keys(baseline));
  // With a palette (Android) and without one (Windows, Linux).
  for (const kind of ["palette", "plain"]) assert.deepEqual(Object.keys(digests).filter((name) => digests[name][kind] !== baseline[name][kind]), [], kind);
  // The trees that name a material color are the ones that test the extensions.
  assert.deepEqual(Object.keys(digests).filter(usesMaterialColors), Object.keys(extensionTrees).sort());
});

const marked = (root) => { const found = []; (function walk(item) { if (item.d?.swList) found.push(item); (item.c ?? []).forEach(walk); })(root); return found; };

test("the hosts keep the scrolling list; a host without a palette draws the fixed colors", async () => {
  const without = JSON.parse(await hostRender(extensionTrees["extension/list"]));
  const [hostList] = marked(without.root);
  assert.equal(hostList.s.overflowY, "auto");
  assert.equal(hostList.c.filter((row) => row.d?.swListRow).length, 20);
  assert.ok(JSON.parse(hostList.d.swList).contentHeight > pixels(hostList.s.height));
  // No palette (Windows, Linux): the fixed table, in light and in dark.
  assert.equal(without.root.s.backgroundColor, rgba(fixedMaterialColors.light.surfaceContainer));
  assert.equal(without.root.s.backgroundColor, "rgba(243, 237, 247, 1)");
  assert.ok(JSON.stringify(without).includes(rgba(fixedMaterialColors.light.onSurface)));
  const dark = JSON.parse(await hostRender(extensionTrees["extension/list"], { dark: true }));
  assert.equal(dark.root.s.backgroundColor, rgba(fixedMaterialColors.dark.surfaceContainer));
  // A palette (Android) wins, and nothing of the table shows.
  const withPalette = JSON.parse(await hostRender(extensionTrees["extension/list"], { colors: hostPalette }));
  assert.equal(withPalette.root.s.backgroundColor, rgba(hostPalette.light.surfaceContainer));
  for (const role of ["surfaceContainer", "onSurface", "onSurfaceVariant"]) assert.ok(!JSON.stringify(withPalette).includes(rgba(fixedMaterialColors.light[role])), role);
  assert.deepEqual(without.diagnostics.filter((item) => /list/.test(item.message)), []);
  // An unknown role is ignored with or without a palette.
  const plain = await hostRender(JSON.stringify(node("vstack", null, node("text", null, "x"))));
  for (const colors of [null, hostPalette]) {
    assert.equal(await hostRender(JSON.stringify(node("vstack", { background: "material.nothing" }, node("text", { color: "material.constructor" }, "x"))), { colors }), plain);
  }
});

test("a role the host palette leaves out or spoils is the fixed color, role by role", async () => {
  const tree = JSON.stringify(node("vstack", { background: "material.surface" }, node("rect", { color: "material.primary", frame: "20,20" }), node("rect", { color: "material.outline,0.5", frame: "20,20" })));
  const fixed = await hostRender(tree);
  assert.ok(fixed.includes(rgba(fixedMaterialColors.light.primary)) && fixed.includes(rgba([...fixedMaterialColors.light.outline.slice(0, 3), 0.5])));
  // Android before 14 defines no role: its palette is empty and draws what no palette draws.
  for (const colors of [{ light: {}, dark: {} }, {}, { light: null }, { light: { surface: "red", primary: [1, 2], outline: [1, 2, 3, Number.NaN] } }]) {
    for (const dark of [false, true]) assert.equal(await hostRender(tree, { colors, dark }), await hostRender(tree, { dark }), JSON.stringify(colors));
  }
  // One role supplied: that one is the host's, the others are fixed.
  const partial = JSON.parse(await hostRender(tree, { colors: { light: { primary: [9, 8, 7, 1] }, dark: { primary: [7, 8, 9, 1] } } }));
  assert.equal(partial.root.s.backgroundColor, rgba(fixedMaterialColors.light.surface));
  assert.ok(JSON.stringify(partial).includes("rgba(9, 8, 7, 1)") && !JSON.stringify(partial).includes(rgba(fixedMaterialColors.light.primary)));
  assert.ok(JSON.stringify(partial).includes(rgba([...fixedMaterialColors.light.outline.slice(0, 3), 0.5])));
  // A palette for one appearance only leaves the other to the table.
  const lightOnly = JSON.parse(await hostRender(tree, { dark: true, colors: { light: { surface: [1, 1, 1, 1] } } }));
  assert.equal(lightOnly.root.s.backgroundColor, rgba(fixedMaterialColors.dark.surface));
});

test("a fitting list draws whole rows only, and always its first row", () => {
  const rows = [new FixedNode(100, 30), new FixedNode(80, 30), new FixedNode(120, 40), new FixedNode(60, 10)];
  const fitting = new FittingListNode(rows, 4);
  // It is sized like the scrolling list: what it is offered, or its rows.
  assert.deepEqual(fitting.size(200, 70), [200, 70]);
  assert.deepEqual(fitting.size(200, null), [200, 122]);
  assert.deepEqual(fitting.size(null, null), [120, 122]);
  fitting.place(0, 0, 200, 70);
  assert.deepEqual(fitting.children, rows.slice(0, 2));
  assert.deepEqual(fitting.children.map((row) => [row.frame.x, row.frame.y, row.frame.width, row.frame.height]), [[0, 0, 100, 30], [0, 34, 80, 30]]);
  // The size does not depend on what the last placement drew, and a later placement can draw more.
  assert.deepEqual(fitting.size(200, null), [200, 122]);
  fitting.place(0, 0, 200, 122);
  assert.equal(fitting.children.length, 4);
  // A short row after one that does not fit is not drawn either: the rows stay in order.
  fitting.place(0, 0, 200, 100);
  assert.equal(fitting.children.length, 2);
  fitting.place(0, 0, 200, 10);
  assert.deepEqual(fitting.children, [rows[0]]);
  assert.equal(new FittingListNode([], 4).size(200, null)[1], 0);
  // Under a header it gets the room the header leaves.
  const below = new FittingListNode([new FixedNode(100, 60), new FixedNode(100, 60)], 0);
  const stack = new StackNode("v", [new FixedNode(100, 20), below], { alignment: "start", spacing: () => 8 });
  stack.place(0, 0, 160, 100);
  assert.equal(below.frame.height, 72);
  assert.equal(below.children.length, 1);
  assert.equal(new StackNode("v", [below, new SpacerNode("v")], { alignment: "start", spacing: () => 0 }).size(160, 100)[1], 100);
});

test("the Apple preview draws the rows of a <list> that fit instead of an unknown tag", async () => {
  for (const profile of ["iphone-393", "mac"]) {
    for (const family of ["medium", "large"]) {
      const rendered = await appleRender(extensionTrees["extension/list"], { profile, family });
      const texts = elements(rendered.element).map((item) => item.text).filter(Boolean);
      assert.ok(!texts.includes("UnknownTagName"), `${profile} ${family}`);
      assert.ok(texts.includes("Row 0"));
      const drawn = list(rendered);
      const height = pixels(drawn.style.height);
      assert.ok(drawn.children.length >= 1 && drawn.children.length < 20, `${profile} ${family}: ${drawn.children.length} rows`);
      assert.equal(texts.filter((text) => /^Row \d+$/.test(text)).length, drawn.children.length);
      for (const row of drawn.children) assert.ok(pixels(row.style.top) + pixels(row.style.height) <= height + 0.01);
      // One more row would not have fitted.
      const last = drawn.children.at(-1), step = pixels(last.style.height) + 2;
      assert.ok(pixels(last.style.top) + pixels(last.style.height) + step > height);
      // Nothing is left for a host to scroll.
      assert.ok(elements(rendered.element).every((item) => !item.dataset.swList && !item.dataset.swListRow && item.style.overflowY !== "auto"));
      assert.deepEqual(rendered.diagnostics.filter((item) => item.code === "tag.android_only"), []);
      assert.ok(rendered.diagnostics.some((item) => item.severity === "info" && /draw the rows that fit/.test(item.message)));
    }
  }
  const large = list(await appleRender(extensionTrees["extension/list"], { family: "large" })).children.length;
  const medium = list(await appleRender(extensionTrees["extension/list"], { family: "medium" })).children.length;
  assert.ok(large > medium);
});

test("the Apple preview reads spacing, the general props and the 100-row limit of a <list>", async () => {
  const rows = (count) => Array.from({ length: count }, () => node("rect", { color: "#ff0000", frame: "50,20" }));
  const rendered = await appleRender(element("list", { spacing: "5", padding: "10", background: "#0000ff" }, ...rows(30)), { family: "small" });
  const drawn = list(rendered);
  assert.deepEqual(drawn.children.map((row) => pixels(row.style.top)), drawn.children.map((_, index) => index * 25));
  assert.ok(drawn.children.every((row) => pixels(row.style.height) === 20 && pixels(row.style.left) === 0));
  assert.equal(pixels(drawn.style.height), rendered.size.height - 20);
  assert.equal(drawn.children.length, Math.floor((rendered.size.height - 20 + 5) / 25));
  assert.ok(elements(rendered.element).some((item) => item.style.backgroundColor === "rgba(0, 0, 255, 1)"));
  const long = await appleRender(element("list", null, ...rows(120)));
  assert.ok(long.diagnostics.some((item) => item.code === "list.truncated"));
  assert.equal((await appleRender(element("list", null))).diagnostics.filter((item) => item.severity === "error").length, 0);
});

test("the Apple preview and a host without a palette resolve every material role to the fixed palette, in light and dark", async () => {
  assert.deepEqual(Object.keys(fixedMaterialColors.light), roles);
  assert.deepEqual(Object.keys(fixedMaterialColors.dark), roles);
  // The Android host names the same roles.
  const kotlin = fs.readFileSync(fileURLToPath(new URL("../../../Android/core/src/main/java/com/everettjf/scriptwidget/core/api/ThemeColors.kt", import.meta.url)), "utf8");
  for (const role of roles) assert.ok(kotlin.includes(`"${role}" to `), role);
  for (const appearance of ["light", "dark"]) {
    for (const role of roles) {
      const color = fixedMaterialColors[appearance][role];
      assert.ok(color.length === 4 && color.slice(0, 3).every((value) => Number.isInteger(value) && value >= 0 && value <= 255) && color[3] === 1, role);
      const rendered = await appleRender(element("zstack", { background: `material.${role}` }, node("rect", { color: `material.${role},0.5`, frame: "20,20" })), { appearance });
      assert.equal(rendered.element.style.backgroundColor, rgba(color), `${role} ${appearance}`);
      const half = rgba([...color.slice(0, 3), 0.5]);
      assert.ok(elements(rendered.element).some((item) => Object.values(item.style).includes(half) || Object.values(item.attributes).includes(half)), `${role} ${appearance} with opacity`);
      // Windows and Linux: the same color through the host entry.
      const host = JSON.parse(await hostRender(element("zstack", { background: `material.${role}` }, node("rect", { color: `material.${role},0.5`, frame: "20,20" })), { dark: appearance === "dark" }));
      assert.equal(host.root.s.backgroundColor, rgba(color), `${role} ${appearance} on a host`);
      assert.ok(JSON.stringify(host).includes(half), `${role} ${appearance} with opacity on a host`);
    }
  }
  assert.notDeepEqual(fixedMaterialColors.light.surface, fixedMaterialColors.dark.surface);
  assert.deepEqual(fixedMaterialColors.light.primary, [0x67, 0x50, 0xa4, 1]);
  assert.deepEqual(fixedMaterialColors.dark.primary, [0xd0, 0xbc, 0xff, 1]);
});

test("an unknown material role stays ignored, and the palette is not left behind", async () => {
  for (const appearance of ["light", "dark"]) {
    const plain = await appleRender(element("vstack", null, node("text", null, "x")), { appearance });
    for (const name of ["material.unknownRole", "material.", "material.Primary", "materialprimary", "material.unknownRole,0.5"]) {
      const rendered = await appleRender(element("vstack", { background: name }, node("text", { color: name }, "x")), { appearance });
      assert.equal(rendered.element.style.backgroundColor, plain.element.style.backgroundColor, name);
    }
  }
  // Outside a render the names are unknown, as before.
  assert.equal(parseColor("material.primary"), null);
});

test("the Android-only templates render on the Apple preview", async () => {
  const templates = new URL("../../../Android/app/src/main/assets/Script.android/android/", import.meta.url);
  for (const name of ["Scrolling Checklist", "Wallpaper Colors"]) {
    const files = readPackageDirectory(fileURLToPath(new URL(`${name}/`, templates)));
    const manifest = JSON.parse(files["widget.json"]);
    // As written (the branch for the other systems), and as a widget written only for Android would run.
    const androidOnly = { ...files, "main.jsx": files["main.jsx"].replace('$system.platform() === "android"', "true") };
    assert.notEqual(androidOnly["main.jsx"], files["main.jsx"]);
    for (const [variant, source] of [["as written", files], ["Android branch", androidOnly]]) {
      for (const family of ["small", "medium", "large"]) {
        const result = await executePackageInNode({ files: source, manifest, environments: { "widget-size": family, "widget-param": "" } });
        assert.equal(result.error, null, `${name} ${variant} ${family}`);
        assert.equal(result.tree.includes('"$element":"list"'), name === "Scrolling Checklist" && variant === "Android branch");
        for (const profile of ["iphone-393", "mac"]) {
          for (const appearance of ["light", "dark"]) {
            const rendered = await appleRender(result.tree, { profile, family, appearance });
            const label = `${name} ${variant} ${family} ${profile} ${appearance}`;
            assert.equal(rendered.element.style.backgroundColor, rgba(fixedMaterialColors[appearance].surfaceContainer), label);
            const texts = elements(rendered.element).map((item) => item.text).filter(Boolean);
            assert.ok(!texts.includes("UnknownTagName"), label);
            assert.ok(texts.some((text) => /^(Check|Wall)/.test(text)), label);
            assert.deepEqual(rendered.diagnostics.filter((item) => item.severity === "error" || item.severity === "warning"), [], label);
            if (result.tree.includes('"$element":"list"')) {
              const shown = list(rendered).children.length;
              assert.ok(shown >= 1 && shown < 20, `${label}: ${shown} rows`);
            }
          }
        }
      }
    }
  }
});
