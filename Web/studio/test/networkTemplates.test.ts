import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { executePackageInNode, readPackageDirectory } from "../../preview-engine/src/node.js";
import { exportPackage, importPackage } from "../../preview-engine/src/package/index.js";
import type { Appearance, PackageFiles, WidgetSize } from "../../preview-engine/src/types.js";
import { isObject, parseMocks, type MockObject } from "../src/mockData.ts";
import { bytesToBase64, packageReport, previewFamilies, projectFromTemplate } from "../src/project.ts";

const bundledTemplates = new URL("../../../Shared/ScriptWidgetRuntime/Resource/Script.bundle/template/", import.meta.url);

interface FixtureCase {
  name: string;
  hosts: string[];
  sample: RegExp;
  unavailable: RegExp;
}

const cases: FixtureCase[] = [
  { name: "Air Quality Now", hosts: ["air-quality-api.open-meteo.com"], sample: /\b42\b/, unavailable: /Air quality unavailable/ },
  { name: "Crypto Price Ticker", hosts: ["api.coingecko.com"], sample: /64,?000\.00/, unavailable: /Price unavailable/ },
  { name: "Currency Pulse", hosts: ["open.er-api.com"], sample: /7\.21/, unavailable: /Rates unavailable/ },
  { name: "Daily Quote", hosts: ["zenquotes.io"], sample: /Small steps make room for big ideas\./, unavailable: /Quote unavailable/ },
  { name: "New Episode Tracker", hosts: ["www.episodate.com", "static.episodate.com"], sample: /The Rings of Power/, unavailable: /Schedule unavailable/ },
  { name: "Stock Snapshot", hosts: ["stooq.com"], sample: /188\.36/, unavailable: /Quote unavailable/ },
  { name: "Sunrise & Sunset", hosts: ["api.sunrise-sunset.org"], sample: /"title":"\d{1,2}:\d{2}/, unavailable: /Times unavailable/ },
  { name: "Weather", hosts: ["api.open-meteo.com"], sample: /12.*km\/h/, unavailable: /Weather unavailable/ },
  { name: "Weather Display", hosts: ["api.open-meteo.com"], sample: /Feels like.*21/, unavailable: /Weather unavailable/ },
];

function makeDraft(name: string) {
  const directory = new URL(encodeURIComponent(name) + "/", bundledTemplates);
  const files = readPackageDirectory(fileURLToPath(directory));
  assert.ok(typeof files["widget.json"] === "string", `${name} must ship a manifest`);
  const catalogFiles = Object.fromEntries(Object.entries(files).map(([path, value]) => [
    path, typeof value === "string" ? value : { base64: bytesToBase64(value) },
  ]));
  return projectFromTemplate({ id: `template/${name}`, source: "template", name, description: "", category: "", files: catalogFiles });
}

function run(files: PackageFiles, fixtures: MockObject, family: WidgetSize = "medium", appearance: Appearance = "light") {
  return executePackageInNode({
    files, fixtures, preview: { appearance },
    environments: { "widget-size": family, "widget-param": "", "widget-rendering-mode": "fullColor" },
  });
}

function networkRules(fixtures: MockObject, hosts: string[]): MockObject[] {
  assert.ok(Array.isArray(fixtures.fetch));
  return fixtures.fetch.filter(isObject).filter(rule => typeof rule.url === "string" && hosts.includes(new URL(rule.url).hostname));
}

for (const { name, hosts, sample, unavailable } of cases) {
  test(`${name} copies and exports a scoped widget that renders sample data`, async () => {
    const draft = makeDraft(name);
    const { manifest, valid } = packageReport(draft);
    assert.ok(valid && manifest, `${name} needs a valid Package 2.0 manifest`);
    assert.equal(manifest.name, name);
    assert.deepEqual(manifest.supportedFamilies, ["systemSmall", "systemMedium", "systemLarge"]);
    assert.deepEqual(manifest.permissions, ["network"]);
    assert.deepEqual([...manifest.networkDomains].sort(), [...hosts].sort());

    const archive = exportPackage(draft.files);
    assert.equal(archive.error, undefined);
    assert.ok(archive.bytes);
    const imported = await importPackage(archive.bytes);
    assert.equal(imported.error, undefined);
    assert.deepEqual(imported.files, draft.files, "Preview fixtures must stay outside the exported widget");
    assert.ok(imported.files);

    const fixtures = parseMocks(draft.fixtures);
    assert.ok(networkRules(fixtures, hosts).length, `${name} needs an offline sample from its declared host`);
    for (const family of previewFamilies(manifest, "iphone-393")) {
      for (const appearance of ["light", "dark"] as const) {
        const label = `${name} ${family} ${appearance}`;
        const result = await run(imported.files, fixtures, family, appearance);
        assert.equal(result.error, null, label);
        assert.ok(result.tree, label);
        assert.match(result.tree, sample, label);
        assert.doesNotMatch(result.tree, unavailable, label);
        assert.ok(!result.diagnostics.some(item => item.code === "fixture.fetch.missing"), label);
      }
    }
  });

  test(`${name} displays an unavailable state for missing, invalid or denied responses`, async () => {
    const draft = makeDraft(name);
    const { manifest } = packageReport(draft);
    assert.ok(manifest);
    const fixtures = parseMocks(draft.fixtures);
    const mutate = (change: MockObject): MockObject => ({
      ...fixtures,
      fetch: networkRules(fixtures, hosts).map(rule => ({ ...rule, ...change })),
    });
    const denied = { ...draft.files, "widget.json": JSON.stringify({ ...manifest, networkDomains: ["example.com"] }) };
    const undeclared = { ...draft.files, "widget.json": JSON.stringify({ ...manifest, permissions: [], networkDomains: [] }) };
    const failures: Array<[string, PackageFiles, MockObject]> = [
      ["missing sample", draft.files, { ...fixtures, fetch: [] }],
      ["request error", draft.files, mutate({ error: "Simulated failure" })],
      ["malformed body", draft.files, mutate({ body: "<html>Unavailable</html>" })],
      ["wrong response shape", draft.files, mutate({ body: "null" })],
      ["denied host", denied, fixtures],
      ["no network permission", undeclared, fixtures],
    ];
    for (const [scenario, files, data] of failures) {
      const label = `${name}, ${scenario}`;
      const result = await run(files, data);
      assert.equal(result.error, null, label);
      assert.ok(result.tree, label);
      assert.match(result.tree, unavailable, label);
      assert.doesNotMatch(result.tree, sample, label);
    }
  });
}
