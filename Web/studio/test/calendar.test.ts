import assert from "node:assert/strict";
import test from "node:test";
import { executePackageInNode } from "../../preview-engine/src/node.js";
import { decodeManifest, newManifest } from "../../preview-engine/src/package/index.js";
import { defaultFixtures, parseMocks, permissionScenario } from "../src/mockData.ts";
import type { WidgetManifest } from "../../preview-engine/src/types.js";

const manifest: WidgetManifest = { ...newManifest("Calendar"), permissions: ["calendar"] };
const execute = (source: string, declared = true, fixtures = parseMocks(defaultFixtures)) => executePackageInNode({ files: { "main.jsx": source }, manifest: declared ? manifest : { ...manifest, permissions: [] }, fixtures });
const output = (tree: string) => JSON.parse(JSON.parse(tree).children[0]);

test("calendar declaration round-trips but unknown permissions still fail closed", () => {
  assert.equal(decodeManifest(JSON.stringify(manifest)).error, undefined);
  assert.match(decodeManifest(JSON.stringify({ ...manifest, permissions: ["calendarWriteUnknown"] })).error!, /unknown permission/);
});

test("best-state calendar mocks cannot bypass package permission", async () => {
  const result = await execute(`
    let denied = 0;
    for (const call of [() => $calendar.events(), () => $calendar.calendars(), () => $calendar.requestAuthorization()]) {
      try { await call(); } catch(error) { if(String(error).includes('[permission_denied]')) denied++; }
    }
    $render(<text>{JSON.stringify({status: $calendar.authorizationStatus(), denied})}</text>);
  `, false);
  assert.equal(result.error, null);
  assert.deepEqual(output(result.tree!), { status: "undeclared", denied: 3 });
});

test("calendar queries reject invalid ranges, options and identifier budgets before returning mocks", async () => {
  const cases = [
    { unknown: true }, { limit: true }, { limit: 0 }, { limit: 51 }, { limit: 1.5 },
    { maxAgeSeconds: -1 }, { maxAgeSeconds: true }, { calendarIDs: [] }, { calendarIDs: ["same", "same"] },
    { calendarIDs: [1] }, { calendarIDs: ["日".repeat(86)] }, { calendarIDs: Array.from({ length: 17 }, (_, index) => String(index)) },
    { start: "bad" }, { start: "2026-01-01" }, { start: 123 },
    { start: "2026-01-02T00:00:00Z", end: "2026-01-01T00:00:00Z" },
    { start: "2026-01-01T00:00:00Z", end: "2026-03-01T00:00:00Z" },
  ];
  const result = await execute(`
    let invalid = 0;
    for (const options of ${JSON.stringify(cases)}) {
      try { await $calendar.events(options); } catch(error) { if (String(error).includes('[invalid_options]')) invalid++; }
    }
    $render(<text>{JSON.stringify({invalid})}</text>);
  `);
  assert.equal(result.error, null);
  assert.equal(output(result.tree!).invalid, cases.length);
});

test("calendar query budget is shared across read methods and resets per execution", async () => {
  const source = `
    let allowed = 0, denied = 0;
    for(let index = 0; index < 10; index++) {
      try { if(index % 2) await $calendar.events(); else await $calendar.calendars(); allowed++; }
      catch(error) { if(String(error).includes('[query_limit]')) denied++; }
    }
    $render(<text>{JSON.stringify({allowed, denied})}</text>);
  `;
  for (let run = 0; run < 2; run++) {
    const result = await execute(source);
    assert.equal(result.error, null);
    assert.deepEqual(output(result.tree!), { allowed: 8, denied: 2 });
  }
});

test("calendar denial and unavailable scenarios return no event data", async () => {
  for (const scenario of ["denied", "unavailable"] as const) {
    const result = await execute(`
      let message; try { await $calendar.events(); } catch(error) { message = String(error); }
      $render(<text>{JSON.stringify({available: $calendar.isAvailable(), authorized: await $calendar.requestAuthorization(), status: $calendar.authorizationStatus(), message})}</text>);
    `, true, parseMocks(permissionScenario(defaultFixtures, "calendar", scenario)));
    assert.equal(result.error, null);
    const value = output(result.tree!);
    assert.equal(value.available, scenario === "denied");
    assert.equal(value.authorized, false);
    assert.equal(value.status, scenario);
    assert.match(value.message, scenario === "denied" ? /permission_denied/ : /unavailable/);
  }
});

test("calendar source selection constrains response overrides, metadata and explicit queries", async () => {
  const fixtures = parseMocks(defaultFixtures);
  const api = fixtures.api as Record<string, {value: any}>;
  api["$calendar.calendars"]!.value = [{id:"sample.personal",title:"Personal"},{id:"sample.work",title:"Private Work"}];
  const event = api["$calendar.events"]!.value.items[0];
  api["$calendar.events"]!.value.items = [event,{...event,id:"private",calendarID:"sample.work",title:"private-event"}];
  fixtures.calendarSelection = ["sample.personal"];
  const result = await execute(`
    const sources=await $calendar.calendars(),events=await $calendar.events();
    let blocked=false;try{await $calendar.events({calendarIDs:['sample.work']});}catch(e){blocked=String(e).includes('invalid_options');}
    $render(<text>{JSON.stringify({sources,events,blocked})}</text>);
  `, true, fixtures);
  assert.equal(result.error,null);
  const value=output(result.tree!);
  assert.deepEqual(value.sources,[{id:"sample.personal",title:"Personal"}]);
  assert.equal(value.events.items.length,1);assert.equal(value.events.items[0].calendarID,"sample.personal");
  assert.equal(value.blocked,true);assert.doesNotMatch(result.tree!,/private-event|Private Work/);
});

test("no selected calendars blocks event reads despite healthy success mocks", async () => {
  const fixtures=parseMocks(defaultFixtures);fixtures.calendarSelection=[];
  const result=await execute(`
    const calendars=await $calendar.calendars();let denied=false;
    try{await $calendar.events();}catch(e){denied=String(e).includes('No Calendar sources');}
    $render(<text>{JSON.stringify({count:calendars.length,denied,authorized:await $calendar.requestAuthorization()})}</text>);
  `,true,fixtures);
  assert.equal(result.error,null);assert.deepEqual(output(result.tree!),{count:0,denied:true,authorized:true});
});

test("calendar selection validation rejects malformed scopes without granting all sources", async () => {
  for(const calendarSelection of [true,"all",{},[""],["a","a"],["日".repeat(86)],Array.from({length:65},(_,i)=>String(i))]) {
    const fixtures={...parseMocks(defaultFixtures),calendarSelection};
    assert.throws(()=>parseMocks(JSON.stringify(fixtures)),/Calendar selection/);
    const result=await execute(`let denied=false;try{await $calendar.events();}catch(e){denied=String(e).includes('permission_denied');}$render(<text>{JSON.stringify({denied})}</text>);`,true,fixtures as any);
    assert.equal(result.error,null);assert.equal(output(result.tree!).denied,true);
  }
});

test("calendar source scope persists through mock editing and explicit all remains the default", async () => {
  const fixtures=parseMocks(defaultFixtures);fixtures.calendarSelection=["sample.personal"];
  const {addSampleMocks,setResponse}=await import("../src/mockData.ts");
  const edited=setResponse(addSampleMocks(JSON.stringify(fixtures)),"$device.name",{value:"My preview"});
  assert.deepEqual(parseMocks(edited).calendarSelection,["sample.personal"]);
  for(const calendarSelection of [undefined,null]) {
    const result=await execute("$render(<text>{JSON.stringify((await $calendar.calendars()).length)}</text>);",true,{...fixtures,calendarSelection} as any);
    assert.equal(result.error,null);assert.equal(output(result.tree!),1);
  }
});

test("opaque source identifiers remain byte exact rather than Unicode normalized",async()=>{
  const fixtures=parseMocks(defaultFixtures),selected="caf\u00e9",outside="cafe\u0301";
  const api=fixtures.api as Record<string,{value:any}>;
  api["$calendar.calendars"]!.value=[{id:selected,title:"Personal"},{id:outside,title:"private-source"}];
  const event=api["$calendar.events"]!.value.items[0];
  api["$calendar.events"]!.value.items=[{...event,calendarID:selected},{...event,id:"outside",calendarID:outside,title:"private-event"}];
  fixtures.calendarSelection=[selected];
  const result=await execute("$render(<text>{JSON.stringify({sources:await $calendar.calendars(),events:await $calendar.events()})}</text>);",true,fixtures);
  assert.equal(result.error,null);assert.doesNotMatch(result.tree!,/private-source|private-event/);
  assert.equal(output(result.tree!).events.items.length,1);
});
