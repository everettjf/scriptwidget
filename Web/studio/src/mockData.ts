import { dataAPICatalog } from "../../../Editor/editorfe/src/dataAPICatalog.js";

// Preview data only. Kept with the browser draft, never in exported packages.
export type MockValue = null | boolean | number | string | MockValue[] | { [key: string]: MockValue };
export type MockObject = { [key: string]: MockValue };
export interface MockAPI { operation?: string; id: string; group: string; value: MockValue; legacy?: string[] }
export const mockAPIs: MockAPI[] = dataAPICatalog;
// Dark appearance follows the preview setting until a user explicitly mocks it.
export const isObject = (value: unknown): value is MockObject => value !== null && typeof value === "object" && !Array.isArray(value);
export function sampleFixtures(): MockObject {
  const now = Date.now(), start = Math.floor(now / 3600000) * 3600000;
  const weather = {properties:{meta:{updated_at:new Date(start).toISOString(),units:{air_temperature:"celsius",relative_humidity:"%",wind_speed:"m/s"}},
    timeseries:Array.from({length:24},(_,index)=>({time:new Date(start+index*3600000).toISOString(),data:{instant:{details:{air_temperature:21+index/4,relative_humidity:62,wind_speed:2}},next_1_hours:{summary:{symbol_code:"partlycloudy_day"}}}}))}};
  const dayStart = new Date(now); dayStart.setHours(0,0,0,0);
  const zone=Intl.DateTimeFormat().resolvedOptions().timeZone;
  const day=`${dayStart.getFullYear()}-${String(dayStart.getMonth()+1).padStart(2,"0")}-${String(dayStart.getDate()).padStart(2,"0")}`;
  const healthSample=(id:string,value:MockValue):MockValue=>{
    if(!isObject(value))return value;
    if(id==="$health.sleepSummary")return {...value,start:new Date(now-86400000).toISOString(),end:new Date(now).toISOString(),timeZone:zone};
    if(id==="$health.activitySummary")return {...value,date:day,timeZone:zone};
    if(id==="$health.workouts")return {...value,start:new Date(now-7*86400000).toISOString(),end:new Date(now).toISOString(),timeZone:zone,items:[{id:"550e8400-e29b-41d4-a716-446655440000",activity:"running",start:new Date(now-3600000).toISOString(),end:new Date(now-900000).toISOString(),duration:2700,energyKcal:285,distanceMeters:5200}]};
    return {...value,start:dayStart.toISOString(),end:new Date(now).toISOString()};
  };
  return {
    api: Object.fromEntries(mockAPIs.filter((api) => api.id !== "$device.isdarkmode").map((api) => [api.id, { value: api.group === "health" && isObject(api.value) ? healthSample(api.id,api.value) : api.group === "photos" && api.id.endsWith(".items") ? {...api.value as MockObject,fetchedAt:new Date(now).toISOString()} : api.group === "reminders" && api.id.endsWith(".items") ? {...api.value as MockObject, fetchedAt: new Date(now).toISOString(), items: [{id:"sample.reminder",listID:"sample.reminders",title:"Read a chapter",due:new Date(dayStart.getTime()+16*3600000).toISOString(),hasTime:true,completed:false,completedAt:null,priority:0}]} : api.value }])),
    fetch: [{url:"https://api.github.com/repos/everettjf/scriptwidget",method:"GET",status:200,body:JSON.stringify({full_name:"everettjf/ScriptWidget",private:false,stargazers_count:1280,forks_count:96,open_issues_count:18}),headers:{"content-type":"application/json","cache-control":"public, max-age=3600"}}, { url: "https://api.example.com/data", method: "GET", body: '{"value":42}', status: 200, headers: {"content-type":"application/json"} },
      {url:"https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=37.33&lon=-122.01",method:"GET",status:200,body:JSON.stringify(weather),headers:{"content-type":"application/json",expires:new Date(now+3600000).toUTCString(),"last-modified":new Date(start).toUTCString()}}],
    storage: {}, icloud: { connected: true, available: true, documents: {} }, storageAtomicAvailable: true, dataSource: [], calendarSelection: null, remindersSelection: null, photosSelection: ["sample.photo", "sample.photo.2", "sample.photo.3", "sample.photo.4"], photosSnapshotPrepared: true,
  };
}
export const defaultFixtures = JSON.stringify(sampleFixtures(), null, 2);
export function parseMocks(text: string): MockObject {
  const value: unknown = JSON.parse(text || "{}");
  if (!isObject(value)) throw new Error("Mock data must be a JSON object.");
  for (const key of ["api", "device", "system", "storage", "icloud"]) {
    if (value[key] !== undefined && !isObject(value[key])) throw new Error(`${key} must be a JSON object.`);
  }
  if (value.remindersState !== undefined && (!isObject(value.remindersState) || value.remindersState.formatVersion !== 1 ||
      Object.keys(value.remindersState).some(key => !["formatVersion", "items", "receipts"].includes(key)) || !Array.isArray(value.remindersState.items) || !Array.isArray(value.remindersState.receipts))) throw new Error("Reminder action state needs formatVersion 1, items and receipts.");
  if (value.photosSelection !== undefined && (!Array.isArray(value.photosSelection) || value.photosSelection.length > 64 || new Set(value.photosSelection).size !== value.photosSelection.length || value.photosSelection.some(id => typeof id !== "string" || !id || new TextEncoder().encode(id).length > 1024 || /[\x00-\x1f\x7f]/.test(id)))) throw new Error("Photo selection needs up to 64 unique IDs; [] selects none.");
  if (value.photosSnapshotPrepared !== undefined && typeof value.photosSnapshotPrepared !== "boolean") throw new Error("photosSnapshotPrepared must be true or false.");
  if (value.remindersCommitUncertain !== undefined && typeof value.remindersCommitUncertain !== "boolean") throw new Error("remindersCommitUncertain must be true or false.");
  for (const key of ["calendarSelection", "remindersSelection"]) if (value[key] !== undefined && value[key] !== null) {
    const ids = value[key];
    if (!Array.isArray(ids) || ids.length > 64 || new Set(ids).size !== ids.length || ids.some((id) => typeof id !== "string" || !id || new TextEncoder().encode(id).length > 256)) {
      throw new Error(`${key === "calendarSelection" ? "Calendar" : "Reminder"} selection must be null (all sources) or up to 64 unique source IDs; [] selects none.`);
    }
  }
  if (value.storageAtomicAvailable !== undefined && typeof value.storageAtomicAvailable !== "boolean") throw new Error("storageAtomicAvailable must be true or false.");
  if (isObject(value.api)) for (const [name, response] of Object.entries(value.api)) {
    if (!isObject(response) || (("value" in response) === ("error" in response))) throw new Error(`${name} needs either value or error.`);
    if ("error" in response && typeof response.error !== "string") throw new Error(`${name} error must be text.`);
  }
  if (isObject(value.api)) {
    const musicStatus = value.api["$music.authorizationStatus"], music = value.api["$music.current"];
    if (isObject(musicStatus) && "value" in musicStatus && !["authorized", "denied", "restricted", "notDetermined", "unavailable"].includes(String(musicStatus.value))) throw new Error("Invalid Music authorization status.");
    if (isObject(music) && "value" in music) {
      const item = music.value, keys = ["provider", "state", "hasItem", "title", "artist", "album", "duration", "position", "capturedAt"];
      const text = (raw: MockValue | undefined) => raw === null || (typeof raw === "string" && new TextEncoder().encode(raw).length <= 512 && !/\p{Cc}/u.test(raw));
      const seconds = (raw: MockValue | undefined, minimum: number) => raw === null || (typeof raw === "number" && Number.isFinite(raw) && raw >= minimum && raw <= 604800);
      if (!isObject(item) || Object.keys(item).length !== keys.length || Object.keys(item).some(key => !keys.includes(key)) || item.provider !== "appleMusic" ||
          !["playing", "paused", "stopped", "interrupted", "seeking", "unknown"].includes(String(item.state)) || typeof item.hasItem !== "boolean" ||
          !["title", "artist", "album"].every(key => text(item[key])) || !seconds(item.duration, Number.MIN_VALUE) || !seconds(item.position, 0) ||
          (!item.hasItem && ["title", "artist", "album", "duration"].some(key => item[key] !== null)) || typeof item.capturedAt !== "string" ||
          !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(item.capturedAt) || !Number.isFinite(Date.parse(item.capturedAt))) throw new Error("Music playback needs the documented fields, nullable metadata and bounded seconds. Missing track details do not mean playback stopped.");
    }
    const status = value.api["$services.status"], profile = value.api["$services.profile"];
    if (isObject(status) && "value" in status && !["connected", "notConnected", "notGranted", "unavailable"].includes(String(status.value))) throw new Error("Service status must be connected, notConnected, notGranted or unavailable.");
    if (isObject(profile) && "value" in profile) {
      const item = profile.value, keys = ["service", "subject", "username", "displayName", "publicRepositories", "privateRepositories", "followers", "following"];
      const text = (raw: MockValue | undefined, max: number) => typeof raw === "string" && new TextEncoder().encode(raw).length <= max && !/[\p{Cc}\p{Cf}\p{Cs}]/u.test(raw);
      const count = (raw: MockValue | undefined, required = false) => (!required && raw === null) || (typeof raw === "number" && Number.isSafeInteger(raw) && raw >= 0);
      if (!isObject(item) || Object.keys(item).length !== keys.length || Object.keys(item).some(key => !keys.includes(key)) || item.service !== "github" ||
          typeof item.subject !== "string" || !/^[1-9][0-9]{0,15}$/.test(item.subject) || !Number.isSafeInteger(Number(item.subject)) ||
          !text(item.username,39) || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,38}$/.test(String(item.username)) || !(item.displayName === null || text(item.displayName,256)) ||
          !count(item.publicRepositories,true) || !["privateRepositories","followers","following"].every(key=>count(item[key]))) throw new Error("Service profile needs the documented GitHub fields only, bounded text and nonnegative safe counts. Do not put credentials in mock data.");
    }
  }
  for (const key of ["fetch", "dataSource"]) {
    if (value[key] !== undefined && !Array.isArray(value[key])) throw new Error(`${key} must be an array.`);
    if (Array.isArray(value[key])) for (const item of value[key]) {
      if (!isObject(item) || typeof item.url !== "string") throw new Error(`${key} rules need a URL.`);
      if (item.error !== undefined && typeof item.error !== "string") throw new Error(`${key} errors must be text.`);
      if (key === "fetch" && item.method !== undefined && (typeof item.method !== "string" || !["GET", "POST", "PUT", "PATCH", "DELETE"].includes(item.method.toUpperCase()))) throw new Error("Network methods must be GET, POST, PUT, PATCH or DELETE.");
      if (key === "fetch" && item.body !== undefined && typeof item.body !== "string") throw new Error("Network body must be response text.");
      if (key === "fetch" && item.status !== undefined && (typeof item.status !== "number" || !Number.isInteger(item.status) || item.status < 100 || item.status > 599)) throw new Error("HTTP mock status must be an integer from 100 to 599.");
      if (key === "fetch" && item.headers !== undefined && (!isObject(item.headers) || Object.values(item.headers).some(value => typeof value !== "string"))) throw new Error("HTTP mock headers must be an object of strings.");
      if (key === "dataSource" && (("value" in item) === ("error" in item))) throw new Error("Data Source rules need either value or error.");
      if (key === "dataSource" && (typeof item.pluginID !== "string" || typeof item.operationID !== "string")) throw new Error("Data Source rules need pluginID and operationID.");
    }
  }
  return value;
}
export function responseFor(data: MockObject, api: MockAPI): MockObject {
  const override = isObject(data.api) ? data.api[api.id] : undefined;
  if (isObject(override)) return override;
  let legacy: MockValue | undefined = data;
  for (const key of api.legacy ?? []) legacy = isObject(legacy) ? legacy[key] : undefined;
  if (api.legacy && legacy !== undefined) return { value: legacy };
  if (api.id === "$reminders.items") {
    const sample = (sampleFixtures().api as MockObject)[api.id];
    if (isObject(sample)) return sample;
  }
  return { value: api.value };
}
export function setResponse(text: string, id: string, response: MockObject): string {
  const data = parseMocks(text);
  data.api = { ...(isObject(data.api) ? data.api : {}), [id]: response };
  if (id === "$reminders.items" && isObject(data.remindersState) && isObject(response.value) && Array.isArray(response.value.items)) {
    data.remindersState = { ...data.remindersState, items: response.value.items };
  }
  return JSON.stringify(data, null, 2);
}
export function addSampleMocks(text: string): string {
  const data = parseMocks(text);
  const api = { ...(isObject(data.api) ? data.api : {}) };
  for (const item of mockAPIs) {
    if (item.id !== "$device.isdarkmode" && api[item.id] === undefined) api[item.id] = responseFor(data, item);
  }
  data.api = api;
  data.fetch ??= sampleFixtures().fetch!;
  data.storage ??= {};
  data.storageAtomicAvailable ??= true;
  data.dataSource ??= [];
  data.calendarSelection ??= null;
  data.remindersSelection ??= null;
  data.photosSelection ??= ["sample.photo", "sample.photo.2", "sample.photo.3", "sample.photo.4"]; data.photosSnapshotPrepared ??= true;
  return JSON.stringify(data, null, 2);
}
export function permissionScenario(text: string, group: "health" | "location" | "calendar" | "reminders" | "photos", mode: "granted" | "denied" | "unavailable" | "empty" | "widgetDenied"): string {
  if (mode === "widgetDenied") {
    if (group !== "location") throw new Error("Widget location authorization applies only to Location.");
    const granted = permissionScenario(text, "location", "granted");
    return setResponse(setResponse(granted, "$location.isAuthorizedForWidgetUpdates", { value: false }), "$location.requestAuthorization", { value: false });
  }
  let result = text;
  // HealthKit deliberately does not reveal denied read scopes. Its no-data
  // scenario keeps review completion true and returns zero/empty measurements.
  const scenario = group === "health" && mode === "denied" ? "empty" : mode;
  for (const api of mockAPIs.filter((item) => item.group === group)) {
    let response: MockObject;
    if (scenario === "granted") response = ["$reminders.items", "$photos.items", "$health.sleepSummary", "$health.activitySummary", "$health.workouts"].includes(api.id) ? responseFor(sampleFixtures(), api) : { value: api.value };
    else if (api.id.endsWith("isAvailable")) response = { value: scenario !== "unavailable" };
    else if (api.id.endsWith("isAuthorizedForWidgetUpdates")) response = { value: scenario === "empty" };
    else if (api.id.endsWith("requestAuthorization")) response = scenario === "unavailable" && !["calendar", "reminders", "photos"].includes(group)
      ? { error: `${group} is unavailable` } : { value: scenario === "empty" };
    else if (group === "health" && api.id.endsWith("authorizationStatus")) response = { value: scenario === "unavailable" ? "unavailable" : "notDisclosed" };
    else if (api.id.endsWith("authorizationStatus")) response = { value: scenario === "empty" ? (group === "location" ? "authorizedWhenInUse" : "authorized")
      : scenario === "unavailable" ? (group === "location" ? "disabled" : "unavailable") : "denied" };
    else if (scenario === "empty" && group === "health" && api.id === "$health.sleepSummary") response = {value:{...(isObject(responseFor(sampleFixtures(),api).value)?responseFor(sampleFixtures(),api).value as MockObject:{}),hasSamples:false,totalSleepSeconds:0,inBedSeconds:0,awakeSeconds:0,stages:{unspecified:0,core:0,deep:0,rem:0},sourceCount:0,conflictSeconds:0,truncated:false}};
    else if (scenario === "empty" && group === "health" && api.id === "$health.activitySummary") response = {value:{...(isObject(responseFor(sampleFixtures(),api).value)?responseFor(sampleFixtures(),api).value as MockObject:{}),hasSamples:false,move:{value:0,goal:null,unit:"kcal"},exercise:{value:0,goal:null,unit:"min"},stand:{value:0,goal:null,unit:"count"}}};
    else if (scenario === "empty" && group === "health" && api.id === "$health.workouts") response = {value:{...(isObject(responseFor(sampleFixtures(),api).value)?responseFor(sampleFixtures(),api).value as MockObject:{}),hasSamples:false,items:[],truncated:false}};
    else if (scenario === "empty" && group === "health") response = { value: { ...(isObject(api.value) ? api.value : {}), value: 0, hasSamples: false,
      ...(api.id.endsWith("heartRateLatest") ? { start: "", end: "" } : {}) } };
    else if (scenario === "empty" && ["calendar", "reminders", "photos"].includes(group)) response = { value: ["calendars", "lists"].includes(api.id.split(".")[1]!) ? []
      : { ...(isObject(api.value) ? api.value : {}), status: group === "photos" ? "ready" : "empty", items: [], truncated: false, ...(group === "photos" ? {fetchedAt:new Date().toISOString(),unavailableCount:0} : {}) } };
    else response = { error: scenario === "empty" ? "[no_data] No location fix is available"
      : scenario === "unavailable" ? `${group} is unavailable` : `${group} permission denied` };
    result = setResponse(result, api.id, response);
  }
  return result;
}

export type ServiceScenario = "connected" | "notConnected" | "notGranted" | "empty" | "publicOnly" | "expired" | "rateLimited" | "offline";
export function serviceScenario(text: string, scenario: ServiceScenario): string {
  const sample = mockAPIs.find(api => api.id === "$services.profile")!.value as MockObject;
  let result = setResponse(text, "$services.status", {value: ["notConnected", "notGranted"].includes(scenario) ? scenario : "connected"});
  const errors: Partial<Record<ServiceScenario,string>> = {expired:"[service_expired] Reconnect GitHub in the app.",rateLimited:"[service_rate_limit] GitHub is rate limited. Try later.",offline:"[service_unavailable] Service unavailable. Try again when online."};
  const value = scenario === "empty" ? {...sample,publicRepositories:0,privateRepositories:0,followers:0,following:0} : scenario === "publicOnly" ? {...sample,privateRepositories:null} : sample;
  return setResponse(result, "$services.profile", errors[scenario] ? {error:errors[scenario]!} : {value});
}

export type MusicScenario = "playing" | "paused" | "stopped" | "withheld" | "denied" | "unavailable";
export function musicScenario(text: string, scenario: MusicScenario): string {
  const sample = mockAPIs.find(api => api.id === "$music.current")!.value as MockObject;
  let result = setResponse(text, "$music.isAvailable", {value: scenario !== "unavailable"});
  result = setResponse(result, "$music.authorizationStatus", {value: scenario === "unavailable" ? "unavailable" : scenario === "denied" ? "denied" : "authorized"});
  const missing = scenario === "withheld" || scenario === "stopped";
  return setResponse(result, "$music.current", {value: {...sample, state: scenario === "withheld" ? "playing" : ["paused", "stopped"].includes(scenario) ? scenario : "playing", capturedAt: new Date().toISOString(),
    ...(missing ? {hasItem:false,title:null,artist:null,album:null,duration:null,position:null} : {})}});
}
