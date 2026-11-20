import { scriptWidgetAPI } from "./scriptWidgetAPI.js";

// A native host may describe what only its system has by setting
// window.ScriptWidgetHostAPI before the editor loads:
//
//   { components: { list: { documentation, children, properties: { spacing: { type, documentation } } } },
//     colors: ["material.primary", ...] }
//
// The value is read as data only. Every field is checked and copied; anything
// in another shape is left out, and a host cannot replace a component or a
// general property the editor already knows. Without the global the editor
// offers exactly what scriptWidgetAPI.js lists.

const namePattern = /^[A-Za-z][A-Za-z0-9]{0,39}$/;
const colorPattern = /^[A-Za-z][A-Za-z0-9]{0,39}(?:\.[A-Za-z][A-Za-z0-9]{0,39})?$/;
const propertyTypes = new Set(["string", "number", "boolean", "color", "url", "enum", "number|string"]);
const maximumComponents = 32;
const maximumProperties = 32;
const maximumValues = 64;
const maximumColors = 256;
const maximumDocumentation = 600;

function isPlainObject(value) {
  if (value === null || typeof value !== "object") return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function documentation(value) {
  return typeof value === "string" ? value.slice(0, maximumDocumentation) : "";
}

function ownEntries(value, limit) {
  return isPlainObject(value) ? Object.entries(value).slice(0, limit) : [];
}

function readProperty(value) {
  if (!isPlainObject(value) || !propertyTypes.has(value.type)) return null;
  const property = { type: value.type };
  const text = documentation(value.documentation);
  if (text) property.documentation = text;
  if (value.required === true) property.required = true;
  if (value.type === "enum") {
    if (!Array.isArray(value.values)) return null;
    const values = value.values.slice(0, maximumValues).filter((item) => typeof item === "string" && /^[\w-]{1,40}$/.test(item));
    if (!values.length) return null;
    property.values = values;
  }
  return property;
}

function readComponent(value) {
  if (!isPlainObject(value)) return null;
  const properties = {};
  for (const [name, definition] of ownEntries(value.properties, maximumProperties)) {
    if (!namePattern.test(name)) continue;
    const property = readProperty(definition);
    if (property) properties[name] = property;
  }
  return { documentation: documentation(value.documentation), children: value.children === true, properties };
}

/** Returns the checked copy of a host description: `{ components, colors }`, both possibly empty. */
export function readHostAPI(value) {
  const result = { components: {}, colors: [] };
  if (!isPlainObject(value)) return result;
  const known = new Set(Object.keys(scriptWidgetAPI.components).map((name) => name.toLowerCase()));
  for (const [name, definition] of ownEntries(value.components, maximumComponents)) {
    if (!namePattern.test(name) || known.has(name.toLowerCase())) continue;
    const component = readComponent(definition);
    if (!component) continue;
    known.add(name.toLowerCase());
    result.components[name] = component;
  }
  if (Array.isArray(value.colors)) {
    const seen = new Set();
    for (const name of value.colors.slice(0, maximumColors)) {
      if (typeof name !== "string" || !colorPattern.test(name) || seen.has(name)) continue;
      seen.add(name);
      result.colors.push(name);
    }
  }
  return result;
}

const none = { api: scriptWidgetAPI, colors: [], extended: false };
let cachedSource;
let cached = none;

/**
 * The API metadata the editor works from: scriptWidgetAPI itself when the host
 * supplies nothing usable, otherwise a copy with the host's components added.
 */
export function editorAPI() {
  const source = globalThis.ScriptWidgetHostAPI;
  if (source === cachedSource) return cached;
  cachedSource = source;
  cached = none;
  if (source !== undefined) {
    let host = { components: {}, colors: [] };
    try { host = readHostAPI(source); } catch { /* a getter that throws: nothing is added */ }
    if (Object.keys(host.components).length || host.colors.length) {
      cached = {
        api: { ...scriptWidgetAPI, components: { ...scriptWidgetAPI.components, ...host.components } },
        colors: host.colors,
        extended: true,
      };
    }
  }
  return cached;
}
