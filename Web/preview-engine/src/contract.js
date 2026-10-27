// Mirrors ScriptWidgetRuntimeContract, ScriptWidgetCompiler, and
// ScriptWidgetError in Shared/ScriptWidgetRuntime. test/contract.test.js reads
// the Swift sources and fails when these values drift.

export const runtimeContract = Object.freeze({
  // Native 1.3 uses cooperative checks and disallows dynamic code. The web
  // host keeps its disposable Worker; both expose Calendar, with distinct caches.
  nativeAPIVersion: "1.6",
  nativeCompilerFingerprint: "scriptwidget-babel-v3",
  apiVersion: "1.2",
  compilerFingerprint: "scriptwidget-babel-v2",
  maximumSourceBytes: 512 * 1024,
  maximumTranspiledBytes: 2 * 1024 * 1024,
  executionTimeoutMilliseconds: 5000,
  maximumElementNodes: 1000,
  maximumMaterialBackgrounds: 4,
  maximumElementDepth: 64,
  maximumPropsPerElement: 128,
  maximumDataQueries: 8,
  globalAPIs: Object.freeze(["$alarms", "$calendar", "$component", "$console", "$contacts", "$device", "$documents", "$dynamic_island", "$element", "$error", "$fetch", "$file", "$getenv", "$health", "$home", "$http", "$icloud", "$import", "$location", "$maps", "$music", "$notifications", "$photos", "$reminders", "$render", "$runtime", "$services", "$storage", "$system", "$weather", "$xml", "console", "fetch"]),
});

/// Bumped whenever the web host changes observable execution semantics.
export const engineVersion = "0.19.0";

export const errorCategories = Object.freeze({
  undefinedRender: Object.freeze({ category: "Render", recovery: "Call $render(...) once from the main script." }),
  internalError: Object.freeze({ category: "Internal", recovery: "Retry. If this persists, export the package and report the diagnostic." }),
  transformError: Object.freeze({ category: "Syntax", recovery: "Check the highlighted JSX syntax and property values." }),
  scriptError: Object.freeze({ category: "Runtime", recovery: "Use the reported line and stack trace to inspect the script." }),
  scriptException: Object.freeze({ category: "Runtime", recovery: "Use the reported line and stack trace to inspect the script." }),
  resourceLimit: Object.freeze({ category: "Resource Limit", recovery: "Reduce source size, imported work, network data, or execution time." }),
});

export function makeError(kind, message) {
  const info = errorCategories[kind] ?? errorCategories.internalError;
  return { kind, message, category: info.category, recovery: info.recovery,
    diagnostic: `[${info.category}] ${message}\n${info.recovery}` };
}

/// ScriptWidgetCompiler.wrappedSource, byte for byte.
export function wrappedSource(source, callFunction = "") {
  let result = "async function $main() { try {";
  result += source;
  if (callFunction !== "") result += `await ${callFunction}();`;
  result += "} catch(e){ console.error(e); $error(`${e}`) } }";
  return result;
}

export function utf8ByteLength(value) {
  let bytes = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length &&
      (value.charCodeAt(index + 1) & 0xfc00) === 0xdc00) { bytes += 4; index += 1; }
    else bytes += 3;
  }
  return bytes;
}

export function validateByteCount(value, maximum, label) {
  return utf8ByteLength(value) <= maximum
    ? null
    : makeError("resourceLimit", `${label} exceeds the ${maximum}-byte runtime memory budget`);
}

/// ScriptWidgetCompiledArtifactStore.inferredLibraries.
export function inferredLibraries(source) {
  return source.includes("moment(") || source.includes("moment.") ? ["moment"] : [];
}
