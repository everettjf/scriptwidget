import test from "node:test";
import assert from "node:assert/strict";
import { executePackageInNode } from "../src/node.js";
import { systemAPICatalog } from "../../../Editor/editorfe/src/systemAPICatalog.js";
const permissions=["notifications","calendar","calendarWrite","health","maps","weather","alarms","documents","contacts","home","network"];
const manifest={formatVersion:2,id:"example.system-services",name:"System Services",version:"1.0.0",runtimeVersion:"1.0",minimumRuntimeVersion:"1.6",entry:"main.jsx",supportedFamilies:["systemMedium"],permissions,networkDomains:["api.met.no"],actions:[{id:"test",title:"Test",systemImage:"play",function:"testAction"}]};
const fixtures=()=>({api:Object.fromEntries(systemAPICatalog.map(api=>[api.id,{value:api.value}]))});
const run=(code,options={})=>executePackageInNode({files:{"widget.json":JSON.stringify(manifest),"main.jsx":code},fixtures:fixtures(),...options});
const action=(code,options={})=>run(`async function testAction(){${code}}$render(<text>Ready</text>);`,{actionID:"test",...options});
const log=result=>{assert.equal(result.error,null);return JSON.parse(result.logs.find(l=>l.level==="log").message);};
const request="11111111-1111-4111-8111-111111111111";

test("every new capability denies missing manifest permission even with healthy mocks",async()=>{
  for(const source of ["await $notifications.status()","await $alarms.status()","await $contacts.selected()","await $documents.list()","await $home.items()","await $maps.geocode('park')","await $weather.forecast({latitude:0,longitude:0})","await $health.dailyStatistics({metric:'steps'})"]){
    const m={...manifest,permissions:[],networkDomains:[]};
    const result=await run(source+';$render(<text>never</text>);',{files:{"widget.json":JSON.stringify(m),"main.jsx":source+';$render(<text>never</text>);'}});
    assert.match(result.error.message,/permission_denied/);
  }
});
test("per-installation simulated grants deny access before fixture replies",async()=>{
  const f=fixtures();f.systemAccess={permissions:[]};
  assert.match((await run('await $contacts.selected();$render(<text>never</text>);',{fixtures:f})).error.message,/permission_denied/);
});
test("normal render cannot schedule, change calendar, alarm or home",async()=>{
  for(const source of ["$notifications.schedule({})","$notifications.cancel('daily')","$calendar.create({})","$alarms.schedule({})","$home.setPower({})","$home.runScene({})"]){
    assert.match((await run(`await ${source};$render(<text>never</text>);`)).error.message,/read_only/);
  }
});
test("notification actions schedule, replace and cancel their named slot",async()=>{
  const date=new Date(Date.now()+3600000).toISOString();
  const result=await action(`await $notifications.schedule({key:'daily',title:'Read',body:'One chapter',date:'${date}'});await $notifications.schedule({key:'daily',title:'Read now',body:'One chapter',date:'${date}'});const pending=await $notifications.pending();await $notifications.cancel('daily');console.log(JSON.stringify({pending,after:await $notifications.pending()}));`);
  const value=log(result);assert.equal(value.pending.length,1);assert.equal(value.pending[0].title,"Read now");assert.equal(value.after.length,0);
});
test("calendar writes are scoped, owned and replay-safe",async()=>{
  const input={requestID:request,calendarID:"sample.calendar",title:"Focus",start:"2026-10-28T12:00:00Z",end:"2026-10-28T13:00:00Z"};
  const result=await action(`const a=await $calendar.create(${JSON.stringify(input)});const b=await $calendar.create(${JSON.stringify(input)});let denied=false;try{await $calendar.update({...${JSON.stringify(input)},id:'someone-elses-event'});}catch(e){denied=true;}console.log(JSON.stringify({a,b,denied}));`);
  const value=log(result);assert.equal(value.a.id,value.b.id);assert.equal(value.b.replayed,true);assert.equal(value.denied,true);
  const f=fixtures();f.calendarSelection=[];
  assert.match((await action(`await $calendar.create(${JSON.stringify(input)});`,{fixtures:f})).error.message,/permission_denied/);
});
test("uncertain native-style mutation results cannot be blindly replayed",async()=>{
  const f=fixtures();f.systemCommitUncertain=true;
  const result=await action(`try{await $alarms.schedule({requestID:'${request}',key:'focus',title:'Focus',seconds:1500});}catch(e){console.log(JSON.stringify({error:String(e)}));}`,{fixtures:f});
  assert.match(log(result).error,/outcome_unknown/);
  const next=fixtures();next.systemState=result.mockState.systemState;
  const replay=await action(`await $alarms.schedule({requestID:'${request}',key:'focus',title:'Focus',seconds:1500});`,{fixtures:next});
  assert.match(replay.error.message,/outcome_unknown/);
});
test("alarm lifecycle preserves named identity and rejects replacing active alarms",async()=>{
  const result=await action(`const a=await $alarms.schedule({requestID:'${request}',key:'focus',title:'Focus',seconds:1500});await $alarms.pause('focus');const paused=await $alarms.pending();await $alarms.resume('focus');await $alarms.cancel('focus');console.log(JSON.stringify({a,paused,after:await $alarms.pending()}));`);
  const value=log(result);assert.equal(value.paused[0].state,"paused");assert.equal(value.after.length,0);
});
test("home selection filters sensors and actions set absolute power",async()=>{
  const f=fixtures();f.systemAccess={permissions:["home"],home:["sample.light"]};
  const result=await action(`await $home.setPower({id:'sample.light',on:false});console.log(JSON.stringify(await $home.items()));`,{fixtures:f});
  const value=log(result);assert.equal(value.length,1);assert.equal(value[0].value,false);
  assert.match((await action(`await $home.setPower({id:'unselected',on:true});`,{fixtures:f})).error.message,/permission_denied/);
});
test("documents use opaque imported IDs and contacts obey their selected scope",async()=>{
  assert.match((await run(`await $documents.readJSON('../private');$render(<text>never</text>);`)).error.message,/permission_denied/);
  const result=await run(`const rows=await $contacts.selected();$render(<text>{rows.length}</text>);`,{fixtures:{...fixtures(),systemAccess:{permissions:["contacts"],contacts:[]}}});
  assert.equal(result.error,null);assert.match(result.tree,/0/);
});
test("bounded query inputs and shared budgets cannot be bypassed by mocks",async()=>{
  for(const source of ["$health.dailyStatistics({metric:'unknown'})","$health.dailyStatistics({metric:'steps',days:32})","$maps.search({query:'park',latitude:91,longitude:0})","$maps.snapshot({latitude:0,longitude:0,size:10000})","$weather.forecast({latitude:0,longitude:0,hours:49})"]){assert.match((await run(`await ${source};$render(<text>never</text>);`)).error.message,/invalid_options/);}
  assert.match((await run('for(let n=0;n<9;n++)await $notifications.status();$render(<text>never</text>);')).error.message,/query_limit/);
});

test("daily notifications are one named repeating slot with strict clock bounds",async()=>{
 const result=await action(`await $notifications.schedule({key:'daily',title:'Read',body:'One chapter',daily:{hour:20,minute:0}});console.log(JSON.stringify(await $notifications.pending()));`);
 assert.equal(log(result)[0].repeats,true); assert.ok(Date.parse(log(result)[0].date)>Date.now());
 const invalid=await action(`await $notifications.schedule({key:'daily',title:'Read',body:'One chapter',daily:{hour:24,minute:0}});`);
 assert.match(invalid.error.message,/invalid_options/);
});

test("health metric defaults preserve units and availability",async()=>{
 const result=await run(`$render(<text>{JSON.stringify(await $health.dailyStatistics({metric:'bodyMass',days:7}))}</text>);`);
 assert.equal(result.error,null);const value=JSON.parse(JSON.parse(result.tree).children[0]);assert.equal(value.unit,'kg');assert.equal(value.aggregation,'average');assert.ok(value.items[0].value<200);
 const f=fixtures();f.api['$health.isAvailable']={value:false};
 assert.match((await run(`await $health.dailyStatistics({metric:'steps'});$render(<text>never</text>);`,{fixtures:f})).error.message,/unavailable/);
});
