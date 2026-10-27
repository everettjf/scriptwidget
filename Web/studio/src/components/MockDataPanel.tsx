import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { addSampleMocks, isObject, mockAPIs, musicScenario, parseMocks, permissionScenario, responseFor, sampleFixtures, serviceScenario, setResponse, type MockObject, type MockValue } from "@/mockData.ts";

const groups = ["services", "music", "notifications", "alarms", "maps", "weather", "documents", "contacts", "home", "calendar", "reminders", "photos", "health", "location", "device", "system", "network", "storage", "icloud", "systemAccess", "dataSource", "json"];
const labels: Record<string, string> = { services: "Connected services", notifications: "Local notifications", alarms: "Alarms & timers", maps: "Maps & places", weather: "Weather forecast", documents: "Imported documents", contacts: "Selected contacts", home: "Home accessories", music: "Music playback", calendar: "Calendar", reminders: "Reminders", photos: "Photos", health: "Health", location: "Location", device: "Device", system: "System", network: "Network responses", storage: "Storage", icloud: "iCloud JSON", systemAccess: "System access grants", dataSource: "Data Source Plugins", json: "Full JSON" };

// Primitive leaves use normal form fields. Arrays and uncommon payloads can
// always be edited in the return JSON without losing unknown properties.
function ValueFields({ value, onChange, path = "result" }: { value: MockValue; onChange(value: MockValue): void; path?: string }) {
  if (isObject(value)) return <div className="grid gap-2">{Object.entries(value).map(([key, item]) => <ValueFields key={key} path={`${path}.${key}`} value={item} onChange={(next) => onChange({ ...value, [key]: next })} />)}</div>;
  if (Array.isArray(value) || value === null) return null;
  return <div className="grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)] items-center gap-2">
    <Label htmlFor={`mock-${path}`} className="break-all text-xs font-normal">{path.replace(/^result\.?/, "") || "Return value"}</Label>
    {typeof value === "boolean" ? <select id={`mock-${path}`} aria-label={path} className="h-8 min-w-0 rounded-md border bg-background px-2 text-xs" value={String(value)} onChange={(event) => onChange(event.target.value === "true")}><option value="true">true</option><option value="false">false</option></select>
      : <Input id={`mock-${path}`} aria-label={path} type={typeof value === "number" ? "number" : "text"} step="any" className="h-8 text-xs" value={value} onChange={(event) => {
        if (typeof value === "number") { if (event.target.value !== "" && Number.isFinite(event.target.valueAsNumber)) onChange(event.target.valueAsNumber); }
        else onChange(event.target.value);
      }} />}
  </div>;
}

export function MockDataPanel({ fixtures, onChange }: { fixtures: string; onChange(text: string): void }) {
  const [group, setGroup] = useState("health");
  const [selected, setSelected] = useState("$health.stepCountToday");
  const [draft, setDraft] = useState("");
  const [mode, setMode] = useState("value");
  const [error, setError] = useState("");
  const [calendarSelectionDraft, setCalendarSelectionDraft] = useState("null");
  let data: MockObject = {}, parseError = "";
  try { data = parseMocks(fixtures); } catch (reason) { parseError = (reason as Error).message; }
  const methods = mockAPIs.filter((api) => api.group === group);
  const api = mockAPIs.find((item) => item.id === selected)!;
  const response = responseFor(data, api);
  const writeResponse = api.operation === "write";
  const special = group === "network" ? "fetch" : group;
  const structured = ["network", "storage", "icloud", "systemAccess", "dataSource"].includes(group);
  const encoded = structured ? JSON.stringify(data[special] ?? (["storage", "icloud"].includes(group) ? {} : []), null, 2)
    : JSON.stringify("error" in response ? response.error : response.value, null, 2);
  useEffect(() => {
    try { setCalendarSelectionDraft(JSON.stringify(parseMocks(fixtures)[group === "reminders" ? "remindersSelection" : "calendarSelection"] ?? null, null, 2)); } catch { /* Preserve malformed Full JSON for repair. */ }
  }, [fixtures, group]);
  useEffect(() => { setDraft(encoded ?? "null"); setMode("error" in response ? "error" : "value"); setError(""); }, [encoded, selected, group, fixtures]); // eslint-disable-line react-hooks/exhaustive-deps
  const commit = (work: () => string) => { try { onChange(work()); setError(""); } catch (reason) { setError((reason as Error).message); } };
  const chooseGroup = (next: string) => { setGroup(next); const first = mockAPIs.find((item) => item.group === next); if (first) setSelected(first.id); };
  const apply = () => commit(() => {
    const value: MockValue = JSON.parse(draft);
    if (structured) {
      const next = { ...parseMocks(fixtures), [special]: value };
      const text = JSON.stringify(next, null, 2); parseMocks(text); return text;
    }
    if (mode === "error" && typeof value !== "string") throw new Error("An error response must be a JSON string.");
    return setResponse(fixtures, selected, { [mode]: value });
  });
  return <div className="flex flex-col gap-3" id="mock-data-panel">
    <p className="text-xs text-muted-foreground">Sample data for this preview. Changes stay in this browser project and are never exported. Scripts do not call real system services or the network here.</p>
    <div className="flex flex-wrap items-end gap-2">
      <div className="min-w-0 flex-1"><Label htmlFor="mock-group" className="text-xs">Data source</Label><select id="mock-group" className="mt-1 h-8 w-full rounded-md border bg-background px-2 text-xs" value={group} onChange={(event) => chooseGroup(event.target.value)}>{groups.map((item) => <option key={item} value={item}>{labels[item]}</option>)}</select></div>
      <Button variant="outline" size="sm" disabled={!!parseError} onClick={() => commit(() => addSampleMocks(fixtures))}>Add missing samples</Button>
    </div>
    {parseError && <p role="alert" className="text-xs text-destructive">{parseError} Fix the Full JSON below; your text has been preserved.</p>}
    {group === "json" || parseError ? <><Label htmlFor="fixtures" className="text-xs">Full mock JSON</Label><Textarea id="fixtures" spellCheck={false} aria-label="Preview fixtures JSON" className="min-h-64 font-mono text-xs" value={fixtures} onChange={(event) => onChange(event.target.value)} /></> : <>
      {!structured && <>
        <div><Label htmlFor="mock-api" className="text-xs">API</Label><select id="mock-api" className="mt-1 h-8 w-full rounded-md border bg-background px-2 font-mono text-xs" value={selected} onChange={(event) => setSelected(event.target.value)}>{methods.map((item) => <option key={item.id} value={item.id}>{item.id}()</option>)}</select></div>
        {(group === "health" || group === "location" || group === "calendar" || group === "reminders" || group === "photos") && <div className="flex flex-wrap gap-1">{(group === "health" ? ["granted", "empty", "unavailable"] as const : ["granted", "empty", "denied", "unavailable"] as const).map((item) => <Button key={item} variant="outline" size="xs" onClick={() => commit(() => permissionScenario(fixtures, group, item))}>{item === "granted" ? "Sample success" : item === "empty" ? (group === "health" ? "No shared data" : "No data") : item === "denied" ? "Permission denied" : "Unavailable"}</Button>)}</div>}
        <div className="flex items-center gap-2"><Label htmlFor="mock-mode" className="text-xs">Response</Label><select id="mock-mode" className="h-8 rounded-md border bg-background px-2 text-xs" value={mode} onChange={(event) => { setMode(event.target.value); setDraft(JSON.stringify(event.target.value === "error" ? "Simulated failure" : api.value, null, 2)); }}><option value="value">{writeResponse ? "Model-derived receipt" : "Return value"}</option><option value="error">Throw / reject error</option></select><Button size="xs" variant="ghost" className="ml-auto" onClick={() => commit(() => setResponse(fixtures, selected, responseFor(sampleFixtures(), api)))}>Reset this API</Button></div>
        {!writeResponse && mode === "value" && "value" in response && <ValueFields value={response.value!} onChange={(value) => commit(() => setResponse(fixtures, selected, { value }))} />}
      </>}
      {group === "music" && <>
        <p className="text-xs text-muted-foreground">Editable Music app samples. Native iOS widgets require music in widget.json and Music access in Settings. macOS cannot read the system Music player. Playback controls and other audio apps are unavailable; missing track details can still mean music is playing.</p>
        <div className="flex flex-wrap gap-1">{(["playing", "paused", "stopped", "withheld", "denied", "unavailable"] as const).map(scenario => <Button key={scenario} variant="outline" size="xs" onClick={() => commit(() => musicScenario(fixtures, scenario))}>{{playing:"Playing",paused:"Paused",stopped:"Stopped",withheld:"Track details withheld",denied:"Permission denied",unavailable:"Unavailable"}[scenario]}</Button>)}</div>
      </>}
      {group === "services" && <>
        <p className="text-xs text-muted-foreground">GitHub sample data only. Use $services.status("github") and $services.profile("github"). Native widgets need services access, network access to api.github.com, and approval in Service Accounts. This browser never authenticates; do not paste tokens here.</p>
        <div className="flex flex-wrap gap-1">{(["connected", "notConnected", "notGranted", "empty", "publicOnly", "expired", "rateLimited", "offline"] as const).map(scenario => <Button key={scenario} variant="outline" size="xs" onClick={() => commit(() => serviceScenario(fixtures, scenario))}>{{connected:"Sample success",notConnected:"Disconnected",notGranted:"No widget access",empty:"Zero counts",publicOnly:"Private count not shared",expired:"Token expired",rateLimited:"Rate limited",offline:"Offline"}[scenario]}</Button>)}</div>
      </>}
      {group === "photos" && <>
        <p className="text-xs text-muted-foreground">Declare photos in widget.json. Native access defaults to no selection. The browser uses sample images; it cannot read your system photo library. In Full JSON, photosSelection lists allowed sample IDs and photosSnapshotPrepared controls future-entry cache availability. Edit authorizationStatus to limited for limited system access.</p>
        <Button variant="outline" size="xs" onClick={() => commit(() => JSON.stringify({...parseMocks(fixtures),photosSelection:[]},null,2))}>Select no photos</Button>
        <Button variant="outline" size="xs" onClick={() => commit(() => JSON.stringify({...parseMocks(fixtures),photosSelection:["sample.photo"]},null,2))}>Select sample photo</Button>
      </>}
      {group === "location" && <>
        <Button variant="outline" size="xs" className="self-start" onClick={() => commit(() => permissionScenario(fixtures, "location", "widgetDenied"))}>Widget access off</Button>
        <p className="text-xs text-muted-foreground">Declare location in widget.json. App permission and widget permission are separate: edit isAuthorizedForWidgetUpdates to simulate widget access. Samples never grant real device access.</p>
      </>}
      {(group === "calendar" || group === "reminders") && <>
        <p className="text-xs text-muted-foreground">Declare {group} in widget.json. Native source selection limits what widgets can read; samples never grant real permission.</p>
        <Label htmlFor="mock-calendar-selection" className="text-xs">Allowed {group === "reminders" ? "reminder lists" : "calendar sources"} (JSON)</Label>
        <Textarea id="mock-calendar-selection" aria-label={group === "reminders" ? "Allowed reminder lists JSON" : "Allowed calendar sources JSON"} spellCheck={false} className="min-h-20 font-mono text-xs" value={calendarSelectionDraft} onChange={(event) => setCalendarSelectionDraft(event.target.value)} />
        <p className="text-xs text-muted-foreground">null allows all sources; [] selects none. Use IDs from the {group === "reminders" ? "lists" : "calendars"} response for a subset. Response overrides remain restricted to this selection.</p>
        <Button size="xs" variant="outline" className="self-start" onClick={() => commit(() => {
          const next = JSON.stringify({ ...parseMocks(fixtures), [group === "reminders" ? "remindersSelection" : "calendarSelection"]: JSON.parse(calendarSelectionDraft) }, null, 2);
          parseMocks(next); return next;
        })}>Apply source selection</Button>
      </>}
      {group === "icloud" && <p className="text-xs text-muted-foreground">Preview only. Set connected/available and documents. Each document has value, revision, state and conflicts. No Apple account or real iCloud files are accessed. New writes require a declared action; cloud upload completion is unknown.</p>}
      {group === "network" && <p className="text-xs text-muted-foreground">Match an exact URL and method. body is response text (JSON as a string); error simulates failure. Unmatched requests show a warning. Package network permissions still apply.</p>}
      {group === "storage" && <div className="flex items-center gap-2"><Label htmlFor="mock-storage-atomic" className="text-xs">Atomic updates</Label><select id="mock-storage-atomic" className="h-8 rounded-md border bg-background px-2 text-xs" value={data.storageAtomicAvailable === false ? "false" : "true"} onChange={(event) => commit(() => JSON.stringify({ ...parseMocks(fixtures), storageAtomicAvailable: event.target.value === "true" }, null, 2))}><option value="true">Available</option><option value="false">Unavailable / busy</option></select></div>}
      {group === "storage" && <p className="text-xs text-muted-foreground">Initial key/value pairs for each run. Reads and writes work within that run; the next preview starts from these values. Edit package files in the file tree to mock $file data.</p>}
      {group === "dataSource" && <p className="text-xs text-muted-foreground">Match pluginID and operationID. Each rule needs an HTTPS url and value or error. Declare the plugin, network permission and domain in widget.json. Parameters are not matched.</p>}
      {group === "dataSource" && <Button variant="outline" size="xs" className="self-start" onClick={() => setDraft(JSON.stringify([{ pluginID: "example.weather", operationID: "current", url: "https://api.example.com/weather", value: { temperature: 22 } }], null, 2))}>Show example rule</Button>}
      <Label htmlFor="mock-response-json" className="text-xs">{structured ? "Mock data JSON" : "Response JSON"}</Label>
      <Textarea id="mock-response-json" spellCheck={false} aria-label="Mock response JSON" className="min-h-32 font-mono text-xs" value={draft} readOnly={writeResponse && mode === "value" && !structured} onChange={(event) => setDraft(event.target.value)} />
      {writeResponse && <p className="text-xs text-muted-foreground">Write receipts come from the simulated items and request history. Edit $reminders.items to change the dataset, or choose an error response here.</p>}
      <Button size="sm" className="self-start" disabled={writeResponse && mode === "value" && !structured} onClick={apply}>Apply mock data</Button>
    </>}
    {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    <p className="text-xs text-muted-foreground">Files, JSX rendering and XML parsing run normally. Widget size, appearance and parameters use the preview controls. $runtime reports the real preview contract.</p>
  </div>;
}
