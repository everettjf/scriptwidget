import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { coverage, generalProps, ignoredProp } from "../src/render/coverage.js";
import { scriptWidgetAPI } from "../../../Editor/editorfe/src/scriptWidgetAPI.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const component = path.join(root, "Shared/ScriptWidgetRuntime/Widget/Component");
const read = (relative) => fs.readFileSync(path.join(component, relative), "utf8");
const propKeys = (source) => new Set([...source.matchAll(/getProp(?:String|Double|Int|Bool)\("([^"]+)"(?:, or: "([^"]+)")?/g)].flatMap((match) => [match[1], match[2]].filter(Boolean)));

// Properties documented in scriptWidgetAPI.js that no native builder reads.
const documentedButIgnored = [];

test("every tag in the native element switch has a coverage entry", () => {
  const tags = [...read("ScriptWidgetElementView.swift").matchAll(/case "([A-Za-z]+)":/g)].map((match) => match[1]);
  assert.ok(tags.length >= 29);
  for (const tag of [...tags, "Fragment"]) assert.ok(coverage.tags[tag], `missing coverage for <${tag}>`);
});

test("every property a native builder reads has a coverage entry", () => {
  const files = {
    "Elements/ScriptWidgetElementTagStack.swift": ["vstack", "hstack", "list"],
    "Elements/ScriptWidgetElementTagGrid.swift": ["hgrid", "vgrid"],
    "Elements/ScriptWidgetElementTagShape.swift": ["rect", "capsule", "ellipse", "circle"],
    "Elements/ScriptWidgetElementTagImage.swift": ["image"],
    "Elements/ScriptWidgetElementTagDate.swift": ["date"],
    "Elements/ScriptWidgetElementTagGif.swift": ["gif"],
    "Elements/ScriptWidgetElementTagGauge.swift": ["gauge"],
    "Elements/ScriptWidgetElementTagChart.swift": ["chart"],
    "Elements/ScriptWidgetElementTagButton.swift": ["button"],
    "Elements/ScriptWidgetElementTagToggle.swift": ["toggle"],
    "Elements/ScriptWidgetElementTagExtras.swift": ["divider", "line", "roundedrect", "icon", "label", "progress", "ring", "badge", "chip", "stat"],
    "Attributes/Text/ScriptWidgetAttributeTextAlignmentModifier.swift": ["text", "date"],
    "Attributes/Text/ScriptWidgetAttributeFontModifier.swift": ["text", "date"],
    "Attributes/Text/ScriptWidgetAttributeForegroundModifier.swift": ["text", "date"],
    "Attributes/Image/ScriptWidgetAttributeImageModifier.swift": ["image"],
  };
  for (const [file, tags] of Object.entries(files)) {
    for (const key of propKeys(read(file))) {
      const covered = tags.some((tag) => coverage.tags[tag].props[key]) || generalProps[key];
      assert.ok(covered, `${key} read in ${file} has no coverage entry for ${tags.join("/")}`);
    }
  }
  const general = fs.readdirSync(path.join(component, "Attributes/General")).map((file) => read(`Attributes/General/${file}`)).join("\n")
    + read("Attributes/ScriptWidgetAttributeGeneral.swift") + read("Attributes/Effect/ScriptWidgetAttributeRotationEffectModifier.swift")
    + read("Attributes/Effect/ScriptWidgetAttributeRotation3DEffectModifier.swift") + read("Attributes/Effect/ScriptWidgetAttributeShadowModifier.swift")
    + read("Attributes/Animation/ScriptWidgetAttributeAnimationModifier.swift");
  for (const key of propKeys(general)) assert.ok(generalProps[key], `general modifier property ${key} has no coverage entry`);
});

test("Studio completion metadata matches the coverage matrix", () => {
  for (const name of Object.keys(scriptWidgetAPI.components)) assert.ok(coverage.tags[name.toLowerCase()], `missing coverage for documented component ${name}`);
  const nativeSources = fs.readdirSync(component, { recursive: true }).filter((file) => file.endsWith(".swift")).map((file) => read(file)).join("\n");
  for (const key of Object.keys(scriptWidgetAPI.globalProperties)) {
    if (documentedButIgnored.includes(key)) {
      assert.ok(!nativeSources.includes(`"${key}"`), `${key} is now read natively; remove it from documentedButIgnored and add coverage`);
      assert.match(ignoredProp("text", key), /ignored by the native runtime/);
      continue;
    }
    const covered = generalProps[key] || Object.values(coverage.tags).some((entry) => entry.props[key]);
    assert.ok(covered, `documented property ${key} has no coverage entry`);
  }
});

test("<list> is a native tag with the attribute Android reads", () => {
  assert.match(read("ScriptWidgetElementView.swift"), /case "list": return ScriptWidgetElementTagList\.buildView/);
  assert.deepEqual(Object.keys(coverage.tags.list.props), ["spacing"]);
  assert.equal(ignoredProp("list", "spacing"), null);
  assert.equal(ignoredProp("list", "padding"), null);
  assert.match(ignoredProp("list", "alignment"), /ignored/);
});

test("properties the native runtime never reads are reported as ignored", () => {
  assert.equal(ignoredProp("text", "weight"), null);
  assert.match(ignoredProp("text", "fontSize"), /ignored/);
  assert.match(ignoredProp("spacer", "background"), /Spacer reads only frame/);
  assert.equal(ignoredProp("text", "padding"), null);
  assert.equal(ignoredProp("vstack", "spacing"), null);
});

test("the published coverage document is current", async () => {
  const { coverageMarkdown } = await import("../scripts/coverage-report.mjs");
  assert.equal(fs.readFileSync(path.join(root, "docs/browser-preview-coverage.md"), "utf8"), coverageMarkdown(), "Run node scripts/coverage-report.mjs");
});
