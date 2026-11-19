import assert from "node:assert/strict";
import test from "node:test";
import { executePackageInNode } from "../src/node.js";
import { newManifest } from "../src/package/manifest.js";
import { normalizePackagePath } from "../src/packageFiles.js";

const run = (source, { files = {}, ...options } = {}) =>
  executePackageInNode({ timeoutMilliseconds: 1000, ...options, files: { "main.jsx": source, ...files } });

test("props and children cross the bridge exactly like JavaScriptCore", async () => {
  // Same source and expectation as BrowserPreviewParityTests.testBridgeSemanticsProbe.
  const result = await run(`$render(<vstack a={1} b={1.5} c={true} d="x" e={null} f={undefined} g={() => 1} h={[1, undefined, null]} i={{ x: 1 }} j={new Date(0)}>
  {"s"}{1}{true}{null}{undefined}{[["n", [2]]]}
</vstack>);`);
  assert.equal(result.error, null);
  assert.equal(result.tree, '{"$element":"vstack","props":{"a":1,"b":1.5,"c":true,"d":"x","e":null,"g":{"$dict":{}},"h":[1,null,null],"i":{"$dict":{"x":1}},"j":{"$date":0}},"children":["s",1,true,null,null,[["n",[2]]]]}');
});

test("function components receive bridged props and lose function values", async () => {
  const result = await run(`const Card = (props) => <text>{typeof props.onTap}:{String(props.n)}:{props.children.length}</text>;
$render(<Card onTap={() => 1} n={2}><spacer /></Card>);`);
  assert.equal(result.error, null);
  assert.equal(result.tree, '{"$element":"text","props":null,"children":["object",":","2",":",1]}');
});

test("a single-child root fragment is unwrapped and nested fragments are kept", async () => {
  const root = await run("$render(<><text>a</text></>);");
  assert.equal(root.tree, '{"$element":"text","props":null,"children":["a"]}');
  const nested = await run("$render(<vstack><><text>a</text></></vstack>);");
  assert.match(nested.tree, /"\$element":"Fragment"/);
});

test("missing $render text yields the native placeholder element", async () => {
  const result = await run("const value = 1;");
  assert.equal(result.tree, '{"$element":"text","props":null,"children":["#UI Not Found#"]}');
});

test("a source that ends in a line comment without a line break runs", async () => {
  // The wrapper's closing code used to land inside the comment.
  const result = await run("$render(<text>ready</text>); // the end");
  assert.equal(result.error, null);
  assert.equal(result.tree, '{"$element":"text","props":null,"children":["ready"]}');
});

test("errors use the native categories", async () => {
  assert.equal((await run('throw new Error("boom")')).error.kind, "scriptException");
  assert.equal((await run("$render(<text>)")).error.kind, "scriptException");
  assert.equal((await run("const C = () => { throw new Error('inner') }; $render(<C />);")).error.kind, "scriptException");
  assert.equal((await run("const C = () => 5; $render(<C />);")).error.kind, "scriptError");
  assert.equal((await run("$render('text')")).error.message, "Transform result is not Element : nil");
  assert.equal((await run("$render(<text a={...[]} />)")).error.kind, "scriptException");
  assert.equal((await run("$render(<text />, 1); x();")).error, null);
});

test("primitive props throw the JavaScriptCore conversion error", async () => {
  const result = await run('$render(ScriptWidget.createElement("text", "bad"))');
  assert.equal(result.error.kind, "scriptException");
  assert.match(result.error.message, /Cannot convert primitive to NSDictionary/);
});

test("runaway synchronous and asynchronous work is terminated", async () => {
  const loop = await run("while (true) {} $render(<text />);", { timeoutMilliseconds: 300 });
  assert.equal(loop.error.kind, "resourceLimit");
  const hang = await run("await new Promise(() => {}); $render(<text />);", { timeoutMilliseconds: 300 });
  assert.equal(hang.error.kind, "resourceLimit");
  const microtasks = await run("const spin = () => Promise.resolve().then(spin); spin(); $render(<text />);", { timeoutMilliseconds: 300 });
  assert.notEqual(microtasks.tree === null && microtasks.error === null, true);
});

test("element tree limits match the native contract", async () => {
  const wide = await run("$render(<vstack>{Array.from({ length: 1000 }, (_, i) => <text>{i}</text>)}</vstack>);");
  assert.equal(wide.error.kind, "resourceLimit");
  const props = await run("const p = {}; for (let i = 0; i < 129; i++) p['k' + i] = i; $render(ScriptWidget.createElement('text', p));");
  assert.equal(props.error.kind, "resourceLimit");
  const deep = await run("let e = <text />; for (let i = 0; i < 64; i++) e = <vstack>{e}</vstack>; $render(e);");
  assert.equal(deep.error.kind, "resourceLimit");
});

test("$import shares one global lexical scope and reports missing files", async () => {
  const shared = await run('$import("lib.jsx"); $render(<text>{label}</text>);', { files: { "lib.jsx": "const label = 'from lib';" } });
  assert.equal(shared.tree, '{"$element":"text","props":null,"children":["from lib"]}');
  const missing = await run('const ok = $import("missing.js"); $render(<text>{String(ok)}</text>);');
  assert.equal(missing.tree, '{"$element":"text","props":null,"children":["false"]}');
  assert.equal(missing.diagnostics[0].code, "import.missing");
  const escape = await run('$render(<text>{String($import("../outside.js"))}</text>);');
  assert.match(escape.tree, /"false"/);
});

test("the user realm does not see host or browser-only globals", async () => {
  const result = await run("$render(<text>{[typeof Babel, typeof setTimeout, typeof process, typeof require, typeof TextEncoder, typeof console.warn].join(',')}</text>);");
  assert.equal(result.tree, '{"$element":"text","props":null,"children":["undefined,undefined,undefined,undefined,undefined,undefined"]}');
});

test("fetch is fixture-only and enforces native network policy", async () => {
  const fixtures = { fetch: [{ url: "https://api.example.com/v1", body: "{\"ok\":1}" }] };
  const allowed = await run('const body = await fetch("https://api.example.com/v1"); $render(<text>{body}</text>);', { fixtures });
  assert.equal(allowed.tree, '{"$element":"text","props":null,"children":["{\\"ok\\":1}"]}');

  const policy = (url, manifest) => run(`let r; try { r = await fetch(${JSON.stringify(url)}); } catch (e) { r = "rejected:" + e; } $render(<text>{r}</text>);`, { fixtures, manifest });
  assert.match((await policy("https://127.0.0.1/x")).tree, /Local and private network hosts are not allowed/);
  assert.match((await policy("file:///etc/passwd")).tree, /Only HTTP and HTTPS URLs are allowed/);
  const manifest = { ...newManifest("Network policy"), permissions: [], networkDomains: [] };
  assert.match((await policy("https://api.example.com/v1", manifest)).tree, /Network host is not declared in widget.json/);
  const declared = { ...newManifest("Network policy"), permissions: ["network"], networkDomains: ["*.example.com"] };
  assert.match((await policy("https://api.example.com/v1", declared)).tree, /ok/);

  const missing = await policy("https://other.example.org/");
  assert.equal(missing.diagnostics[0].code, "fixture.fetch.missing");
});

test("fetch returns the native then-only promise shim", async () => {
  const result = await run('const p = fetch("https://a.example.com/"); $render(<text>{[typeof p.then, typeof p.catch, String(p.then(() => {}, () => {}))].join(",")}</text>);');
  assert.equal(result.tree, '{"$element":"text","props":null,"children":["function,undefined,undefined"]}');
});

test("environment, appearance, and storage come from the preview context", async () => {
  const result = await run('$storage.setString("k", "v"); $render(<text>{$getenv("widget-size")}|{String($device.isdarkmode())}|{$storage.getString("k")}|{$getenv("nope")}</text>);', {
    environments: { "widget-size": "large" }, preview: { appearance: "dark" },
  });
  assert.equal(result.tree, '{"$element":"text","props":null,"children":["large","|","true","|","v","|",""]}');
});

test("package paths are normalized inside the package root", () => {
  assert.equal(normalizePackagePath("lib/../util.js"), "util.js");
  assert.equal(normalizePackagePath("./a/b.js"), "a/b.js");
  assert.equal(normalizePackagePath("../a.js"), null);
  assert.equal(normalizePackagePath("/etc/passwd"), null);
  assert.equal(normalizePackagePath("a\\b.js"), null);
  assert.equal(normalizePackagePath(""), null);
});

test("API mocks clone values, preserve async errors, and cannot replace rendering or policy", async () => {
  const locationAccess = {
    "$location.isAvailable": { value: true },
    "$location.authorizationStatus": { value: "authorizedWhenInUse" },
    "$location.isAuthorizedForWidgetUpdates": { value: true },
  };
  const fixtures = { api: {
    ...locationAccess,
    "$device.battery": { value: { level: 0, state: "charging" } },
    "$system.name": { value: "ignored unknown method" },
    "$system.brightness": { error: "sensor unavailable" },
    "$location.current": { error: "location permission denied" },
    "$render": { error: "must be ignored" },
  } };
  const output = await run(`
    const battery = $device.battery(); battery.level = 99;
    let syncError, asyncError;
    try { $system.brightness(); } catch(e) { syncError = e.message; }
    try { await $location.current(); } catch(e) { asyncError = String(e); }
    $render(<text>{JSON.stringify({ battery: $device.battery(), syncError, asyncError })}</text>);
  `, { fixtures });
  assert.equal(output.error, null);
  assert.deepEqual(JSON.parse(JSON.parse(output.tree).children[0]), { battery: { level: 0, state: "charging" }, syncError: "sensor unavailable", asyncError: "location permission denied" });
  const empty = await run('$render(<text>{String(await $location.current())}</text>);', { fixtures: { api: { ...locationAccess, "$location.current": { value: null } } } });
  assert.equal(JSON.parse(empty.tree).children[0], "null");
  const legacy = await run('const p = await $location.current(); $render(<text>{String(p.latitude)}</text>);', { fixtures: { location: { latitude: 9 } } });
  assert.equal(JSON.parse(legacy.tree).children[0], "9");
});

test("mock storage resets between runs and direct host values retain precedence", async () => {
  const fixtures = { storage: { count: "7", history: { days: ["today"] } }, device: { name: "Fixture" }, system: { brightness: 0.2 } };
  const source = `const initial = $storage.getString("count"); $storage.setString("count", "8"); $render(<text>{JSON.stringify({ initial, next: $storage.getString("count"), history: $storage.getJSON("history"), name: $device.name(), brightness: $system.brightness() })}</text>);`;
  for (let i = 0; i < 2; i++) {
    const result = await run(source, { fixtures, device: { name: "Host" } });
    assert.equal(result.error, null);
    assert.deepEqual(JSON.parse(JSON.parse(result.tree).children[0]), { initial: "7", next: "8", history: { days: ["today"] }, name: "Host", brightness: 0.2 });
  }
});

test("Data Source mocks require a matching operation and all package network declarations", async () => {
  const fixtures = { dataSource: [{ pluginID: "example.weather", operationID: "current", url: "https://api.example.com/weather", value: { temperature: 22 } }] };
  const manifest = { ...newManifest("Data Sources"), permissions: ["network"], networkDomains: ["api.example.com"], plugins: ["example.weather"] };
  const source = 'const value = await $dataSource.request("example.weather", "current", {city:"London"}); $render(<text>{JSON.stringify(value)}</text>);';
  const allowed = await run(source, { fixtures, manifest });
  assert.equal(allowed.error, null);
  assert.deepEqual(JSON.parse(JSON.parse(allowed.tree).children[0]), { temperature: 22 });
  for (const denied of [{ ...manifest, plugins: [] }, { ...manifest, permissions: [] }, { ...manifest, networkDomains: [] }, null]) {
    assert.notEqual((await run(source, { fixtures, manifest: denied })).error, null);
  }
  const privateMock = { dataSource: [{ ...fixtures.dataSource[0], url: "https://127.0.0.1/private" }] };
  assert.match((await run(source, { fixtures: privateMock, manifest })).error.message, /private|Local/);
  const mismatch = await run(source.replace('"current"', '"other"'), { fixtures, manifest });
  assert.ok(mismatch.diagnostics.some((item) => item.code === "fixture.dataSource.missing"));
  const failure = { dataSource: [{ ...fixtures.dataSource[0], error: "server down" }] };
  assert.match((await run(source, { fixtures: failure, manifest })).error.message, /server down/);
});

test("HTTP metadata reports status/cache headers and preserves legacy text responses",async()=>{
 const url="https://example.com/data";
 const result=await run(`const value=await $http.getResponse('${url}');const legacy=await $http.get('${url}');$render(<text>{JSON.stringify({value,legacy})}</text>);`,{
  fixtures:{fetch:[{url,status:503,body:"response text",headers:{"Content-Type":"text/plain","Expires":"Thu, 01 Jan 2026 13:00:00 GMT","Set-Cookie":"secret","Authorization":"secret","Retry-After":"x".repeat(2049)}}]}
 });
 assert.equal(result.error,null);const value=JSON.parse(JSON.parse(result.tree).children.join(""));
 assert.deepEqual(value,{value:{status:503,body:"response text",headers:{"content-type":"text/plain",expires:"Thu, 01 Jan 2026 13:00:00 GMT"}},legacy:"response text"});
 const blocked=await run("try { await $http.getResponse('https://example.com'); $render(<text>unexpected</text>); } catch(error) { $render(<text>{String(error)}</text>); }",{manifest:{...newManifest("No network"),permissions:[],networkDomains:[]}});
 assert.match(JSON.parse(blocked.tree).children.join(""),/Network host is not declared/);
});

test("Live Activity presentations deny network, plugins and location even when getenv is replaced",async()=>{
 const {executePackageInNode}=await import("../src/node.js");
 for(const size of ["live-activity","dynamic-island"]){
  const source=`$getenv=()=>"medium";const errors=[];for(const call of [()=>fetch("https://example.com"),()=>$http.getResponse("https://example.com"),()=>$dataSource.request("example.plugin","read",{}),()=>$location.current(),()=>$location.requestAuthorization()]){try{await call();errors.push("unexpected");}catch(error){errors.push(String(error));}}$render(<text>{JSON.stringify(errors)}</text>);`;
  const result=await executePackageInNode({files:{"main.jsx":source},environments:{"widget-size":size},fixtures:{location:{latitude:1,longitude:2},fetch:[{url:"https://example.com",body:"not allowed"}]}});
  assert.equal(result.error,null);const errors=JSON.parse(JSON.parse(result.tree).children.join(""));assert.equal(errors.length,5);assert.ok(errors.every(error=>error.includes("live_activity_unavailable")),JSON.stringify(errors));
 }
});


test("file.exists includes binary resources but never directories, prototype members or unsafe paths",async()=>{
 const paths=["image/test.png","empty.txt","missing","image","../outside","/etc/passwd","image/../image/test.png","image//test.png","C:/test.png","constructor","./empty.txt"];
 const result=await run(`$render(<text>{JSON.stringify(${JSON.stringify(paths)}.map(path=>$file.exists(path)))}</text>);`,{files:{"image/test.png":new Uint8Array([0,255,1]),"empty.txt":""}});
 assert.equal(result.error,null,result.error?.message);assert.deepEqual(JSON.parse(JSON.parse(result.tree).children[0]),[true,true,false,false,false,false,false,false,false,false,false]);
});
test("binary package paths stay present without decoding their bytes as text",async()=>{
 const result=await run('$render(<text>{JSON.stringify({exists:$file.exists("image/test.png"),read:$file.read("image/test.png"),missing:$file.read("constructor")})}</text>);',{files:{"image/test.png":new Uint8Array([0,255,1])}});
 assert.equal(result.error,null);assert.deepEqual(JSON.parse(JSON.parse(result.tree).children[0]),{exists:true,read:"",missing:""});
});

test("binary file presence cannot make its bytes executable as an imported module",async()=>{
 const result=await run('$render(<text>{String($import("binary.js"))}</text>);',{files:{"binary.js":new Uint8Array([0,255,1])}});
 assert.equal(result.error,null);assert.ok(result.tree.includes("false"));
});
