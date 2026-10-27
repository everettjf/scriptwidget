import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { executePackageInNode } from "../../preview-engine/src/node.js";
import { exportPackage, importPackage, newManifest } from "../../preview-engine/src/package/index.js";
import { addSampleMocks, defaultFixtures, mockAPIs, parseMocks, permissionScenario, responseFor, setResponse } from "../src/mockData.ts";
import type { WidgetManifest } from "../../preview-engine/src/types.js";
import { createProject } from "../src/project.ts";
import { dataAPICatalog } from "../../../Editor/editorfe/src/dataAPICatalog.js";
const execute = (source: string, fixtures = parseMocks(defaultFixtures)) => {
  const manifest: WidgetManifest = { ...newManifest("API Mocks"), minimumRuntimeVersion: "1.6", permissions: ["calendar", "calendarWrite", "reminders", "photos", "location", "health", "services", "music", "network", "notifications", "maps", "weather", "alarms", "documents", "contacts", "home"], networkDomains: ["api.github.com", "api.met.no"] };
  return executePackageInNode({ files: { "main.jsx": source, "widget.json": JSON.stringify(manifest) }, fixtures, manifest });
};

test("new projects can read healthy system samples and authorize without setup", async () => {
  const result = await execute(`
    const steps = await $health.stepCountToday();
    const energy = await $health.activeEnergyToday();
    const heart = await $health.heartRateLatest();
    const location = await $location.current();
    $render(<text>{JSON.stringify({ health: $health.isAvailable(), authorized: await $health.requestAuthorization(),
      locationAuthorized: await $location.requestAuthorization(), steps, energy, heart, location,
      battery: $device.battery(), memory: $system.memory() })}</text>);
  `);
  assert.equal(result.error, null);
  const output = JSON.parse(JSON.parse(result.tree!).children[0]);
  assert.equal(output.health, true);
  assert.equal(output.authorized, true);
  assert.equal(output.locationAuthorized, true);
  assert.equal(output.steps.value, 6840);
  assert.equal(output.steps.unit, "count");
  assert.equal(output.energy.unit, "kcal");
  assert.equal(output.heart.unit, "bpm");
  assert.equal(output.location.latitude, 37.3349);
  assert.equal(output.battery.level, 0.8);
  assert.equal(output.memory.physical, 8589934592);
});

function mockCall(api: {id:string}, fixtures: ReturnType<typeof parseMocks>): string {
  if(api.id.startsWith("$services."))return `${api.id}("github")`;
  const value=(fixtures.api as any)[api.id]?.value;
  const inputs: Record<string,unknown> = {
    "$health.dailyStatistics":{metric:"steps",days:7}, "$weather.forecast":{latitude:37.33,longitude:-122.01,hours:24},
    "$maps.search":{query:"park",latitude:37.33,longitude:-122.01}, "$maps.geocode":"park", "$maps.reverseGeocode":{latitude:37.33,longitude:-122.01}, "$maps.snapshot":{latitude:37.33,longitude:-122.01,size:256},
    "$documents.readJSON":"550e8400-e29b-41d4-a716-446655440000", "$documents.readCSV":"550e8400-e29b-41d4-a716-446655440001"
  };
  if(api.id in inputs)return `${api.id}(${JSON.stringify(inputs[api.id])})`;

  const options=api.id==="$health.sleepSummary"||api.id==="$health.workouts"?{start:value.start,end:value.end}:api.id==="$health.activitySummary"?{date:value.date}:null;
  return `${api.id}(${options?JSON.stringify(options):""})`;
}

test("every read API returns its configured value with the right sync or async shape", async () => {
  // One execution per API: catalog growth must not bypass the real entry budget.
  for(const api of mockAPIs.filter(api=>api.id!=="$device.isdarkmode"&&api.operation!=="write")) {
    const fixtures=parseMocks(defaultFixtures);
    const result=await execute(`$render(<text>{JSON.stringify(await ${mockCall(api,fixtures)})}</text>);`,fixtures);
    assert.equal(result.error,null,api.id);
    const configured=(fixtures.api as any)[api.id].value;
    const expected=api.id==="$weather.forecast"?{...configured,hours:configured.hours.slice(0,24)}:configured;
    assert.deepEqual(JSON.parse(JSON.parse(result.tree!).children[0]),expected,api.id);
  }
});

test("catalog Promise semantics hold before awaiting, including simulated failures", async () => {
  for(const api of dataAPICatalog) {
    const fixtures=parseMocks(defaultFixtures);
    const code=`const response=${mockCall(api,fixtures)};const asynchronous=response!==null&&typeof response==='object'&&typeof response.then==='function';if(asynchronous!==${api.asynchronous})throw new Error('Promise shape mismatch');${api.operation==="write"?"try{await response;throw new Error('unexpected write');}catch(e){if(!/permission_denied|read_only/.test(String(e)))throw e;}":"await response;"}$render(<text>ok</text>);`;
    const result=await execute(code,fixtures);assert.equal(result.error,null,api.id);
  }
  for (const id of ["$health.stepCountToday", "$location.current", "$system.locale", "$device.battery", "$services.profile"]) {
    const api = dataAPICatalog.find((item) => item.id === id)!;
    const fixtures = parseMocks(setResponse(defaultFixtures, id, { error: "Simulated failure" }));
    const failure = await execute(`
      let synchronous = false, asynchronous = false;
      try {
        const response = ${id}(${id.startsWith("$services.") ? JSON.stringify("github") : ""});
        try { await response; } catch { asynchronous = true; }
      } catch { synchronous = true; }
      $render(<text>{JSON.stringify({ synchronous, asynchronous })}</text>);
    `, fixtures);
    assert.equal(failure.error, null);
    assert.deepEqual(JSON.parse(JSON.parse(failure.tree!).children[0]), { synchronous: !api.asynchronous, asynchronous: api.asynchronous }, id);
  }
});

test("per-method editing preserves custom rules, false, zero, and legacy data", () => {
  const text = JSON.stringify({ fetch: [{ url: "https://example.com/custom", body: "custom" }], location: { latitude: 0, longitude: 0 }, health: false, custom: { keep: true }, api: { "$device.battery": { value: { level: 0, state: "charging" } } } });
  const added = parseMocks(addSampleMocks(text));
  const location = mockAPIs.find((item) => item.id === "$location.current")!;
  assert.deepEqual(responseFor(added, location).value, { latitude: 0, longitude: 0 });
  assert.deepEqual(added.fetch, JSON.parse(text).fetch);
  assert.deepEqual(added.custom, { keep: true });
  const updated = parseMocks(setResponse(JSON.stringify(added), "$system.brightness", { value: 0 }));
  assert.deepEqual(updated.api && (updated.api as Record<string, unknown>)["$device.battery"], { value: { level: 0, state: "charging" } });
  assert.deepEqual((updated.api as Record<string, unknown>)["$health.requestAuthorization"], { value: false });
  assert.throws(() => setResponse("{broken", "$device.name", { value: "x" }));
});

test("location denial and service unavailability preserve native promise behavior", async () => {
  for (const group of ["health", "location"] as const) for (const mode of ["denied", "unavailable"] as const) {
    if (group === "health" && mode === "denied") continue;
    const method = group === "health" ? "stepCountToday" : "current";
    const result = await execute(`
      let message, authorizationError, authorized;
      try { await $${group}.${method}(); } catch(error) { message = String(error); }
      try { authorized = await $${group}.requestAuthorization(); } catch(error) { authorizationError = String(error); }
      $render(<text>{JSON.stringify({ available: $${group}.isAvailable(), authorized, authorizationError, message })}</text>);
    `, parseMocks(permissionScenario(defaultFixtures, group, mode)));
    assert.equal(result.error, null);
    const value = JSON.parse(JSON.parse(result.tree!).children[0]);
    assert.equal(value.available, mode === "denied");
    if (mode === "denied") assert.equal(value.authorized, false);
    else assert.match(value.authorizationError, /unavailable/);
    assert.match(value.message, mode === "denied" ? /permission denied/ : /unavailable/);
  }
});

test("Health no-shared-data preserves completed review without claiming read denial", async () => {
  for (const mode of ["empty", "denied"] as const) {
    const result = await execute(`
      $render(<text>{JSON.stringify({ available: $health.isAvailable(), reviewed: await $health.requestAuthorization(),
        status: $health.authorizationStatus(), steps: await $health.stepCountToday(), energy: await $health.activeEnergyToday(), heart: await $health.heartRateLatest() })}</text>);
    `, parseMocks(permissionScenario(defaultFixtures, "health", mode)));
    assert.equal(result.error, null);
    const value = JSON.parse(JSON.parse(result.tree!).children[0]);
    assert.equal(value.available, true);
    assert.equal(value.reviewed, true);
    assert.equal(value.status, "notDisclosed");
    assert.equal(value.steps.value, 0);
    assert.equal(value.energy.value, 0);
    assert.deepEqual(value.heart, { value: 0, unit: "bpm", hasSamples: false, start: "", end: "" });
  }
});

test("invalid mock documents are diagnosed before execution", () => {
  for (const value of ["null", "[]", '{"storageAtomicAvailable":"false"}', '{"api":[]}', '{"api":{"$device.name":{"value":1,"error":"x"}}}', '{"fetch":[null]}', '{"dataSource":[{"url":"https://example.com"}]}']) assert.throws(() => parseMocks(value));
});

test("project export contains no preview mocks or mock health values", async () => {
  const project = createProject("Mock example");
  assert.deepEqual(parseMocks(project.fixtures), parseMocks(defaultFixtures));
  const archive = exportPackage(project.files);
  assert.equal(archive.error, undefined);
  const imported = await importPackage(archive.bytes!);
  assert.equal(imported.error, undefined);
  assert.deepEqual(Object.keys(imported.files!).sort(), Object.keys(project.files).sort());
  assert.ok(!Object.keys(imported.files!).some((key) => /fixture|mock/i.test(key)));
});

test("HTTP metadata mocks accept status/cache headers and reject invalid metadata types",()=>{
 assert.equal((parseMocks('{"fetch":[{"url":"https://example.com","status":304,"headers":{"Expires":"later"},"body":""}]}').fetch as unknown[] | undefined)?.length,1);
 for(const rule of [{status:0},{status:200.5},{status:"200"},{headers:[]},{headers:{Expires:42}}]) assert.throws(()=>parseMocks(JSON.stringify({fetch:[{url:"https://example.com",...rule}]})));
});


test("default editable mocks render healthy current-day bundled health cards", async () => {
  const root = new URL("../../../Shared/ScriptWidgetRuntime/Resource/Script.bundle/template/Health Steps Ring/", import.meta.url);
  const files = Object.fromEntries(["main.jsx", "widget.json", "lib/health.js"].map(path => [path, fs.readFileSync(new URL(path, root), "utf8")]));
  for (const [metric, value] of [["steps", "6840"], ["energy", "420"], ["heart", "72"]] as const) {
    const result = await executePackageInNode({files, fixtures: parseMocks(defaultFixtures), environments: {"widget-size":"medium", "widget-param":JSON.stringify({metric})}});
    assert.equal(result.error, null);
    assert.ok(result.tree?.includes(value));
    assert.ok(!result.tree?.includes("No readable data"));
  }
});


test("default editable mocks render the bundled public repository panel", async () => {
  const root=new URL("../../../Shared/ScriptWidgetRuntime/Resource/Script.bundle/template/GitHub Repo Stats/",import.meta.url);
  const files=Object.fromEntries(["main.jsx","widget.json","lib/repository.js"].map(path=>[path,fs.readFileSync(new URL(path,root),"utf8")]));
  const result=await executePackageInNode({files,fixtures:parseMocks(defaultFixtures),environments:{"widget-size":"medium"}});
  assert.equal(result.error,null);assert.ok(result.tree?.includes("1280"));assert.ok(result.tree?.includes("Checked just now"));
});
