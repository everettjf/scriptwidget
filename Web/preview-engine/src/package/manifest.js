// Package 2.0 manifest handling, mirroring ScriptWidgetPackage.readManifest
// (strict keys + Codable decoding) and WidgetPackageManifestValidator.
import { validTimelineSchedule } from "../timeline.js";
import { runtimeContract } from "../contract.js";
import { normalizePackagePath } from "../packageFiles.js";

export const runtimeAPIVersion = "1.0";
export const families = ["systemSmall", "systemMedium", "systemLarge", "systemExtraLarge", "systemExtraLargePortrait", "accessoryCircular", "accessoryRectangular", "accessoryInline"];
export const permissions = ["network", "location", "health", "calendar", "reminders", "remindersWrite", "photos", "services", "music", "storage", "icloud", "notifications", "calendarWrite", "maps", "weather", "alarms", "documents", "contacts", "home", "files"];
const manifestKeys = new Set(["formatVersion", "id", "name", "version", "runtimeVersion", "minimumRuntimeVersion", "timeline", "entry", "supportedFamilies", "permissions", "networkDomains", "plugins", "actions", "controls", "pushUpdates", "description", "category", "tags", "icon", "preview", "author", "license"]);
const actionKeys = new Set(["id", "title", "description", "systemImage", "function"]);
const controlKeys = new Set(["id", "type", "title", "subtitle", "systemImage", "action", "actionID", "stateKey"]);

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const isInteger = (value) => typeof value === "number" && Number.isInteger(value);
const subset = (object, allowed) => Object.keys(object).every((key) => allowed.has(key));

/// Decodes widget.json text. Returns {manifest} or {error}; a present but
/// malformed manifest must fail closed.
export function decodeManifest(text) {
  let object;
  try { object = JSON.parse(text); } catch { return { error: "widget.json is not valid JSON." }; }
  if (!isObject(object)) return { error: "widget.json must contain a JSON object." };
  const unknown = Object.keys(object).filter((key) => !manifestKeys.has(key));
  if (unknown.length) return { error: `widget.json has unknown fields: ${unknown.join(", ")}.` };
  if (isObject(object.author) && !subset(object.author, new Set(["name", "url"]))) return { error: "author has unknown fields." };
  if (Array.isArray(object.controls) && !object.controls.every((item) => isObject(item) && subset(item, controlKeys))) return { error: "controls have unknown fields." };
  if (Array.isArray(object.actions) && !object.actions.every((item) => isObject(item) && subset(item, actionKeys))) return { error: "actions have unknown fields." };
  if (isObject(object.pushUpdates) && !subset(object.pushUpdates, new Set(["registrationURL", "channel"]))) return { error: "pushUpdates has unknown fields." };

  if (object.timeline !== undefined && object.timeline !== null) {
    const value = object.timeline;
    if (!isObject(value) || !subset(value, new Set(["dailyTimes", "timeZone"])) || !Array.isArray(value.dailyTimes) || !value.dailyTimes.every((time) => typeof time === "string") ||
        (value.timeZone !== undefined && value.timeZone !== null && typeof value.timeZone !== "string")) return { error: "timeline is malformed." };
  }
  // Codable: required keys with exact types; enum arrays reject unknown values.
  const stringFields = ["id", "name", "version", "runtimeVersion", "entry"];
  if (!isInteger(object.formatVersion)) return { error: "formatVersion must be an integer." };
  for (const field of stringFields) if (typeof object[field] !== "string") return { error: `${field} must be a string.` };
  const stringArray = (value) => Array.isArray(value) && value.every((item) => typeof item === "string");
  if (!stringArray(object.supportedFamilies) || !object.supportedFamilies.every((item) => families.includes(item))) return { error: "supportedFamilies contains an unknown family." };
  if (!stringArray(object.permissions) || !object.permissions.every((item) => permissions.includes(item))) return { error: "permissions contains an unknown permission." };
  if (!stringArray(object.networkDomains)) return { error: "networkDomains must be an array of strings." };
  for (const field of ["description", "category", "icon", "preview", "license", "minimumRuntimeVersion"]) if (field in object && object[field] !== null && typeof object[field] !== "string") return { error: `${field} must be a string.` };
  for (const field of ["plugins", "tags"]) if (field in object && object[field] !== null && !stringArray(object[field])) return { error: `${field} must be an array of strings.` };
  if ("actions" in object && object.actions !== null) {
    if (!Array.isArray(object.actions) || !object.actions.every((item) => ["id", "title", "systemImage", "function"].every((key) => typeof item[key] === "string") && (item.description === undefined || item.description === null || typeof item.description === "string"))) return { error: "actions are malformed." };
  }
  if ("controls" in object && object.controls !== null) {
    const valid = Array.isArray(object.controls) && object.controls.every((item) => ["id", "title", "systemImage"].every((key) => typeof item[key] === "string")
      && (item.type === "button" || item.type === "toggle")
      && ["subtitle", "action", "actionID", "stateKey"].every((key) => item[key] === undefined || item[key] === null || typeof item[key] === "string"));
    if (!valid) return { error: "controls are malformed." };
  }
  if ("pushUpdates" in object && object.pushUpdates !== null && !(isObject(object.pushUpdates) && typeof object.pushUpdates.registrationURL === "string" && typeof object.pushUpdates.channel === "string")) return { error: "pushUpdates is malformed." };
  if ("author" in object && object.author !== null && !(isObject(object.author) && typeof object.author.name === "string" && (object.author.url === undefined || object.author.url === null || typeof object.author.url === "string"))) return { error: "author is malformed." };
  return { manifest: object };
}

const randomUUID = () => (globalThis.crypto?.randomUUID ? globalThis.crypto.randomUUID() : "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => ((Math.random() * 16) | (c === "x" ? 0 : 8)).toString(16)));

/// WidgetPackageManifest.newProject.
export function newManifest(name, metadata = {}) {
  const manifest = {
    formatVersion: 2, id: `local.${randomUUID().toLowerCase()}`, name, version: "1.0.0", runtimeVersion: runtimeAPIVersion, entry: "main.jsx",
    supportedFamilies: ["systemSmall", "systemMedium", "systemLarge"], permissions: [], networkDomains: [], plugins: [], actions: [], controls: [],
  };
  for (const key of ["description", "category", "tags", "icon", "preview"]) if (metadata[key] !== undefined) manifest[key] = metadata[key];
  return manifest;
}

/// WidgetPackageManifest.legacy: for packages with main.jsx and no widget.json.
export function legacyManifest(name, metadata = {}) {
  const manifest = newManifest(name, metadata);
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  manifest.id = `legacy.${slug || "widget"}`;
  return manifest;
}

function isPublicHost(host) {
  const value = host.toLowerCase();
  if (value === "localhost" || value === "::1" || value.endsWith(".local") || value.startsWith("127.") || value.startsWith("10.") || value.startsWith("192.168.")) return false;
  const parts = value.split(".");
  return !(parts.length === 4 && parts[0] === "172" && Number(parts[1]) >= 16 && Number(parts[1]) <= 31);
}

function matchesDeclaredHost(host, declarations) {
  const value = host.toLowerCase();
  return declarations.some((declaration) => (declaration.startsWith("*.") ? value !== declaration.slice(2) && value.endsWith(`.${declaration.slice(2)}`) : value === declaration));
}

const pattern = (regex) => (value) => typeof value === "string" && regex.test(value);
const validId = pattern(/^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$/);
const validShortId = pattern(/^[A-Za-z0-9][A-Za-z0-9.-]{0,63}$/);
const validSymbol = pattern(/^[A-Za-z0-9][A-Za-z0-9.-]{0,79}$/);
const validFunction = pattern(/^[A-Za-z_$][A-Za-z0-9_$]{0,63}$/);
const validStateKey = pattern(/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/);
const swiftLength = (text) => [...text].length;

export function validPackageName(name) {
  if (typeof name !== "string" || name.trim() === "" || name.startsWith(".")) return false;
  if (name.normalize("NFC").toLowerCase() === "__build" || /[/\\]/u.test(name) || /^[A-Za-z]:/u.test(name)) return false;
  if (/[\p{Cc}\p{Cf}]/u.test(name.replace(/[\u200c\u200d]/gu, ""))) return false;
  const count = typeof Intl.Segmenter === "function"
    ? [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(name)].length
    : [...name.normalize("NFC")].length;
  return count <= 80 && new TextEncoder().encode(name).byteLength <= 240;
}


export function supportsMinimumRuntime(minimum, current = runtimeContract.nativeAPIVersion) {
  const parse = (text) => typeof text === "string" && /^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$/.test(text) ? text.split(".").map(Number) : null;
  const required = parse(minimum), supported = parse(current);
  return required !== null && supported !== null && required[0] === supported[0] && required[1] <= supported[1];
}

/// WidgetPackageManifestValidator.validate. `paths` lists package files.
export function validateManifest(manifest, paths, { checkEntryExists = true } = {}) {
  const issues = [];
  const error = (code, message) => issues.push({ severity: "error", code, message });
  const warning = (code, message) => issues.push({ severity: "warning", code, message });
  const files = new Set(paths);
  if (paths.some((path) => path.toLowerCase() === "widget.json" && path !== "widget.json")) error("invalid_manifest_case", "Use the exact file name widget.json.");

  if (manifest.formatVersion !== 2) error("unsupported_format", `Package format ${manifest.formatVersion} is not supported.`);
  if (!validId(manifest.id)) error("invalid_id", "id must contain 3–128 letters, numbers, dots, or hyphens.");
  if (!validPackageName(manifest.name)) error("invalid_name", "name must be a nonreserved package name, at most 80 characters/240 UTF-8 bytes, without path separators or control characters.");
  if (!/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(manifest.version)) error("invalid_version", "version must use semantic versioning, for example 1.0.0.");
  if (manifest.runtimeVersion !== runtimeAPIVersion) error("unsupported_runtime", `Runtime ${manifest.runtimeVersion} is incompatible with ${runtimeAPIVersion}.`);
  if (manifest.minimumRuntimeVersion != null) {
    if (!/^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$/.test(manifest.minimumRuntimeVersion)) error("invalid_minimum_runtime", "minimumRuntimeVersion must be a canonical major.minor API version.");
    else if (!supportsMinimumRuntime(manifest.minimumRuntimeVersion)) error("unsupported_minimum_runtime", "This package requires a newer or incompatible ScriptWidget Runtime. Update the app before running it.");
  }
  if (manifest.timeline != null && !validTimelineSchedule(manifest.timeline)) error("invalid_timeline", "timeline requires sorted dailyTimes and a valid timeZone.");
  if (manifest.entry.startsWith("/") || manifest.entry.includes("\\")) error("invalid_entry", "entry must be a package-relative POSIX path.");
  else {
    const entry = normalizePackagePath(manifest.entry);
    if (entry === null) error("invalid_entry", "entry escapes the package directory.");
    else if (!/\.(js|jsx)$/i.test(entry)) error("invalid_entry_type", "entry must be a .js or .jsx file.");
    else if (checkEntryExists && !files.has(entry)) error("missing_entry", `Entry file ${manifest.entry} does not exist.`);
  }
  if (manifest.supportedFamilies.length === 0) error("missing_families", "At least one supported widget family is required.");
  if (new Set(manifest.supportedFamilies).size !== manifest.supportedFamilies.length) error("duplicate_families", "supportedFamilies must not contain duplicates.");
  if (new Set(manifest.permissions).size !== manifest.permissions.length) error("duplicate_permissions", "permissions must not contain duplicates.");
  if (manifest.permissions.some(p => ["notifications","calendarWrite","maps","weather","alarms","documents","contacts","home"].includes(p)) && !supportsMinimumRuntime("1.6", manifest.minimumRuntimeVersion ?? "0.0")) error("system_runtime", "System capabilities require minimumRuntimeVersion 1.6 or later.");
  if (manifest.permissions.includes("calendarWrite") && !manifest.permissions.includes("calendar")) error("calendar_write_permission", "calendarWrite also requires calendar.");
  if (manifest.permissions.includes("icloud") && (!/^1\.[0-9]+$/.test(manifest.minimumRuntimeVersion ?? "") || Number(manifest.minimumRuntimeVersion.split(".")[1]) < 5)) error("icloud_runtime", "iCloud JSON requires minimumRuntimeVersion 1.5 or later.");
  const network = manifest.permissions.includes("network");
  if (manifest.networkDomains.length && !network) error("undeclared_network", "networkDomains requires the network permission.");
  if (network && manifest.networkDomains.length === 0) error("missing_network_domains", "Network access must declare at least one host.");
  const plugins = manifest.plugins ?? null;
  if (plugins) {
    if (new Set(plugins.map((plugin) => plugin.toLowerCase())).size !== plugins.length) error("duplicate_plugins", "plugins must contain unique identifiers.");
    for (const plugin of plugins) if (!validId(plugin)) error("invalid_plugin", `Invalid plugin identifier: ${plugin}.`);
    if (plugins.length && !network) error("plugin_network", "Data source plugins require the network permission.");
  }
  const actions = manifest.actions ?? [];
  if (actions.length > 16) error("too_many_actions", "A package may declare at most 16 actions.");
  if (new Set(actions.map((action) => action.id.toLowerCase())).size !== actions.length) error("duplicate_actions", "Action identifiers must be unique.");
  for (const action of actions) {
    if (!validShortId(action.id)) error("invalid_action_id", `Invalid action identifier: ${action.id}.`);
    if (action.title.trim() === "" || swiftLength(action.title) > 40) error("invalid_action_title", "Action titles must contain 1–40 characters.");
    if (typeof action.description === "string" && swiftLength(action.description) > 160) error("invalid_action_description", "Action descriptions may contain at most 160 characters.");
    if (!validSymbol(action.systemImage)) error("invalid_action_image", "Action systemImage must be an SF Symbols name.");
    if (!validFunction(action.function)) error("invalid_action_function", "Action function must be a JavaScript function identifier.");
  }
  if (manifest.controls) {
    const controls = manifest.controls;
    if (controls.length > 8) error("too_many_controls", "A package may declare at most 8 controls.");
    if (new Set(controls.map((control) => control.id.toLowerCase())).size !== controls.length) error("duplicate_controls", "Control identifiers must be unique.");
    for (const control of controls) {
      if (!validShortId(control.id)) error("invalid_control_id", `Invalid control identifier: ${control.id}.`);
      if (control.title.trim() === "" || swiftLength(control.title) > 40) error("invalid_control_title", "Control titles must contain 1–40 characters.");
      if (!validSymbol(control.systemImage)) error("invalid_control_image", "Control systemImage must be an SF Symbols name.");
      const hasAction = typeof control.action === "string"; const hasActionID = typeof control.actionID === "string";
      if (hasAction && hasActionID) error("ambiguous_control_action", "Controls must declare either action or actionID, not both.");
      else if (hasAction) { if (!validFunction(control.action)) error("invalid_control_action", "Control action must be a JavaScript function identifier."); }
      else if (hasActionID) { if (!actions.some((action) => action.id.toLowerCase() === control.actionID.toLowerCase())) error("missing_control_action", `Control ${control.id} references unknown action ${control.actionID}.`); }
      else error("missing_control_action", "Controls must declare actionID or the legacy action field.");
      if (control.type === "toggle") {
        if (!validStateKey(control.stateKey)) { error("invalid_control_state", "Toggle controls require a valid stateKey."); continue; }
        if (!manifest.permissions.includes("storage")) error("control_storage", "Toggle controls require the storage permission.");
      } else if (typeof control.stateKey === "string") error("button_control_state", "Button controls must not declare stateKey.");
    }
  }
  if (manifest.pushUpdates) {
    if (!network) error("push_network", "pushUpdates requires the network permission.");
    let ok = false;
    try {
      const url = new URL(manifest.pushUpdates.registrationURL);
      ok = url.protocol === "https:" && url.hostname !== "" && isPublicHost(url.hostname) && matchesDeclaredHost(url.hostname, manifest.networkDomains);
    } catch { ok = false; }
    if (!ok) error("invalid_push_url", "pushUpdates.registrationURL must be a public HTTPS URL on a declared network domain.");
    if (!validStateKey(manifest.pushUpdates.channel)) error("invalid_push_channel", "pushUpdates.channel must be a stable 1–128 character identifier.");
  }
  for (const domain of manifest.networkDomains) {
    const normalized = domain.toLowerCase();
    if (domain !== normalized || normalized.includes("://") || normalized.includes("/") || normalized.includes(":") || normalized.startsWith(".") || normalized.endsWith(".")
      || !/^[a-z0-9*.-]+$/.test(normalized) || (normalized.includes("*") && !normalized.startsWith("*."))) error("invalid_network_domain", `Invalid network host declaration: ${domain}.`);
  }
  if (manifest.tags) {
    if (manifest.tags.length > 20) error("too_many_tags", "A package may declare at most 20 tags.");
    if (new Set(manifest.tags.map((tag) => tag.toLowerCase())).size !== manifest.tags.length) warning("duplicate_tags", "Duplicate tags should be removed.");
  }
  if (manifest.author?.url) {
    let https = false;
    try { https = new URL(manifest.author.url).protocol === "https:"; } catch { https = false; }
    if (!https) error("invalid_author_url", "author.url must use HTTPS.");
  }
  if (typeof manifest.preview === "string" && normalizePackagePath(manifest.preview) === null) error("invalid_preview", "preview escapes the package directory.");
  return { issues, valid: !issues.some((issue) => issue.severity === "error") };
}
