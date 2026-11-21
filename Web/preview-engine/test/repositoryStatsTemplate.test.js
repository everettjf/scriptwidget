import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs";
import {executePackageInNode} from "../src/node.js";
const root=new URL("../../../Shared/ScriptWidgetRuntime/Resource/Script.bundle/template/GitHub Repo Stats/",import.meta.url);
const now=Date.parse("2026-01-01T12:15:00Z"),hour=3600000,day=24*hour,key="github.stats.v1";
const config={repository:"everettjf/scriptwidget",accent:"blue"};
const url=repo=>`https://api.github.com/repos/${repo.toLowerCase()}`;
const body=(repo=config.repository,stars=1280)=>({full_name:repo,private:false,stargazers_count:stars,forks_count:96,open_issues_count:18});
const response=(overrides={})=>({url:url(config.repository),status:200,body:JSON.stringify(body()),headers:{"cache-control":"public, max-age=3600","last-modified":"Thu, 01 Jan 2026 12:00:00 GMT"},...overrides});
async function run({settings=config,storage={},time=now,responses=[response()],inspect=true,size="medium",projection=false,prefix="",atomic=true}={}){
 const files=Object.fromEntries(["main.jsx","widget.json","lib/repository.js"].map(path=>[path,fs.readFileSync(new URL(path,root),"utf8")]));
 const trace='const calls=[];const realGet=$http.getResponse;$http.getResponse=(url,options)=>{calls.push({url,headers:options.headers});return realGet(url,options);};';
 if(inspect)files["main.jsx"]='const realRender=$render;$render=()=>{};'+trace+prefix+files["main.jsx"]+'\nrealRender(<text>{JSON.stringify({stats,calls,raw:$storage.getString("github.stats.v1")})}</text>);';
 else files["main.jsx"]=prefix+files["main.jsx"];
 const result=await executePackageInNode({files,prelude:`Date.now=()=>${time};`,fixtures:{fetch:responses,storage,storageAtomicAvailable:atomic},environments:{"widget-size":size,"widget-param":typeof settings==="string"?settings:settings===null?"":JSON.stringify(settings),"timeline-is-projection":String(projection)}});
 if(!inspect)return result;
 assert.equal(result.error,null,result.error?.message);return JSON.parse(JSON.parse(result.tree).children.join(""));
}
test("valid public responses preserve exact counts, cache and legacy repository parameter",async()=>{
 const first=await run({settings:config.repository});assert.equal(first.stats.stars,1280);assert.equal(first.stats.issues,18);assert.equal(first.calls[0].url,url(config.repository));assert.equal(first.stats.history.length,1);
 const saved=await run({storage:{[key]:first.raw},responses:[]});assert.equal(saved.calls.length,0);assert.equal(saved.stats.status,"Saved counts");
 const next=await run({storage:{[key]:first.raw},time:now+2*hour,responses:[response({status:304,body:""})]});assert.equal(next.stats.stars,1280);assert.equal(next.calls[0].headers["If-Modified-Since"],"Thu, 01 Jan 2026 12:00:00 GMT");assert.equal(next.stats.age,"Checked just now");
});
test("network failure and rate limiting retain labelled cache and respect backoff",async()=>{
 const first=await run();
 const limited=await run({storage:{[key]:first.raw},time:now+2*hour,responses:[response({status:429,body:"{}",headers:{"retry-after":"7200"}})]});
 assert.match(limited.stats.status,/rate limit/);const packet=JSON.parse(limited.raw).entries[0];assert.equal(packet.nextRequestAt,now+4*hour);
 const retry=await run({storage:{[key]:limited.raw},time:now+3*hour,responses:[]});assert.equal(retry.calls.length,0);
 const offline=await run({storage:{[key]:first.raw},time:now+2*hour,responses:[]});assert.equal(offline.stats.stars,1280);assert.match(offline.stats.status,/refresh unavailable/);
 const expired=await run({storage:{[key]:first.raw},time:now+8*day,responses:[]});assert.equal(expired.stats.available,false);
});
test("missing repositories discard old counts and history rather than showing a private/deleted project",async()=>{
 const first=await run();const missing=await run({storage:{[key]:first.raw},time:now+2*hour,responses:[response({status:404,body:"{}"})]});
 assert.equal(missing.stats.available,false);assert.match(missing.stats.heading,/unavailable/);const packet=JSON.parse(missing.raw).entries[0];assert.equal(packet.values,null);assert.deepEqual(packet.history,[]);
});
test("invalid and private payloads do not fabricate numeric zeros",async()=>{
 for(const patch of [{private:true},{stargazers_count:undefined},{forks_count:-1},{open_issues_count:"18"},{full_name:"other/repo"}]){
  const result=await run({responses:[response({body:JSON.stringify({...body(),...patch})})]});assert.equal(result.stats.available,false);assert.match(result.stats.heading,/Invalid/);
 }
 const zero=await run({responses:[response({body:JSON.stringify({...body(),stargazers_count:0})})]});assert.equal(zero.stats.stars,0);
});
test("history contains real daily checks, replaces the same day and caps at fourteen days",async()=>{
 let raw="";
 for(let index=0;index<18;index++){
  const result=await run({storage:{[key]:raw},time:now+index*day,responses:[response({body:JSON.stringify(body(config.repository,1000+index))})]});raw=result.raw;
 }
 const packet=JSON.parse(raw).entries[0];assert.equal(packet.history.length,14);assert.equal(packet.history[0].stars,1004);assert.equal(packet.history.at(-1).stars,1017);
 const sameDay=await run({storage:{[key]:raw},time:now+17*day+2*hour,responses:[response({body:JSON.stringify(body(config.repository,1020))})]});assert.equal(sameDay.stats.history.length,14);assert.equal(sameDay.stats.history.at(-1).stars,1020);
});
test("repository cache cardinality, corruption recovery, atomic failures and projection are bounded",async()=>{
 let raw="";
 for(let index=0;index<6;index++) {const repository=`owner/repo${index}`;raw=(await run({settings:{...config,repository},storage:{[key]:raw},time:now+index,responses:[response({url:url(repository),body:JSON.stringify(body(repository))})]})).raw;}
 assert.equal(JSON.parse(raw).entries.length,4);
 const repaired=await run({storage:{[key]:'{"version":1,"entries":[{}]}'}});assert.equal(repaired.stats.available,true);
 const unsaved=await run({atomic:false});assert.equal(unsaved.stats.saved,false);assert.equal(unsaved.stats.status,"Cache unavailable");
 const projection=await run({projection:true});assert.equal(projection.calls.length,0);assert.equal(projection.raw,"");
 const saved=await run();const projected=await run({projection:true,storage:{[key]:saved.raw}});assert.equal(projected.calls.length,0);assert.equal(projected.raw,saved.raw);
});
test("settings reject traversal, credentials, unknown fields and invalid names",async()=>{
 for(const repository of ["owner/..","owner/a/b","https://github.com/owner/repo","user:token/repo","-owner/repo","owner/repo?x=1","owner/","owner/repo%2fother"]){const result=await run({settings:{...config,repository},inspect:false});assert.ok(result.error,repository);}
 for(const settings of [{...config,accent:"red"},{...config,token:"secret"}])assert.ok((await run({settings,inspect:false})).error);
});
test("all eight families render normal and unavailable states in both appearances",async()=>{
 for(const size of ["small","medium","large","extraLarge","extraLargePortrait","accessoryInline","accessoryCircular","accessoryRectangular"])for(const available of [true,false])for(const dark of [true,false]){
  const result=await run({size,inspect:false,responses:available?[response()]:[],prefix:`$device.isdarkmode=()=>${dark};`});assert.equal(result.error,null,result.error?.message);assert.ok(result.tree);
 }
});

test("repository states match native canonical trees across all families",async()=>{
 const fixture=JSON.parse(fs.readFileSync(new URL("parity/repository-stats-trees.json",import.meta.url),"utf8"));
 for(const mode of ["fresh","history","saved","rate","missing","unavailable"])for(const size of ["small","medium","large","extraLarge","extraLargePortrait","accessoryInline","accessoryCircular","accessoryRectangular"]){
  let prefix=`let repoClock=${now},repoStars=1280,repoStatus=200;Date.now=()=>repoClock;$device.isdarkmode=()=>false;
    $http.getResponse=()=>({then(resolve,reject){if(repoStatus===0){reject("isolated offline");return;}resolve({status:repoStatus,headers:{"cache-control":"public, max-age=3600","last-modified":"Thu, 01 Jan 2026 12:00:00 GMT","retry-after":"7200"},body:JSON.stringify({full_name:"everettjf/scriptwidget",private:false,stargazers_count:repoStars,forks_count:96,open_issues_count:18})});}});`;
  if(["history","saved","rate","missing"].includes(mode)){
   if(mode!=="saved")prefix+='repoClock-=172800000;repoStars=1200;';
   prefix+=`if(!$import('lib/repository.js'))throw new Error('fixture import');await repositoryStats.load(repositoryStats.options('',''),repoClock,false);repoClock=${now};repoStars=1280;`;
  }
  if(mode==="rate")prefix+='repoStatus=429;';if(mode==="missing")prefix+='repoStatus=404;';if(mode==="unavailable")prefix+='repoStatus=0;';
  const result=await run({settings:null,size,prefix,inspect:false});assert.equal(result.error,null,result.error?.message);assert.equal(result.tree,fixture.trees[mode+"/"+size]);
 }
});

test("a late failed refresh cannot overwrite a simultaneous successful cache result",async()=>{
 const initial=await run({time:now-2*hour});
 const concurrent={version:1,entries:[{repository:config.repository.toLowerCase(),checkedAt:now,observedAt:now,nextRequestAt:now+hour,lastModified:"",reason:"",values:{stars:1400,forks:100,issues:19},history:[{time:now,stars:1400}]}]};
 const prefix=`const originalCAS=$storage.compareAndSetString;let firstCAS=true;$storage.compareAndSetString=(key,expected,next)=>{if(firstCAS){firstCAS=false;$storage.setString(key,${JSON.stringify(JSON.stringify(concurrent))});return false;}return originalCAS(key,expected,next);};`;
 const failed=await run({storage:{[key]:initial.raw},responses:[],prefix});
 const packet=JSON.parse(failed.raw).entries[0];assert.equal(packet.values.stars,1400);assert.equal(packet.observedAt,now);
 const reopened=await run({storage:{[key]:failed.raw},projection:true,responses:[]});assert.equal(reopened.stats.available,true);assert.equal(reopened.stats.stars,1400);
});
