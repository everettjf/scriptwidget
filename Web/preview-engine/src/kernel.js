// The execution kernel runs *inside* the isolated realm that executes user
// code (a Node vm context in tests and the CLI, a sandboxed Worker in the
// browser). It must stay self-contained: its source text is evaluated in that
// realm, so it may not reference module-scope bindings.
//
// The kernel mirrors ScriptWidgetRuntime.internalExecuteJavaScriptForWidget,
// resolveWidgetElementTree, ScriptWidgetRuntimeContract.validateElementTree,
// and the JavaScriptCore <-> Foundation bridge conversions that native
// ScriptWidgetRuntimeElement properties go through. Values that leave the
// realm are strings only.
//
// host: {
//   evaluateScript(code)   classic-script evaluation in this realm (shared
//                          global lexical scope, like JSContext.evaluateScript)
//   compiledImport(path)   JSON string {ok, code} | {ok:false, kind, message},
//                          or null when the package file does not exist
//   readFile(path)         package-relative text or null
//   supportScript(name)    "util.js" / "moment.min.js" source or null
//   log(level, message)
//   parseXML(source)       JSON string matching ScriptWidgetXMLParser.parse
//   defer(callback)        run callback in a later macrotask
//   timeout(ms, callback)  run callback once the execution budget is spent
//   finish(resultJSON)     receives {tree, error, logs, diagnostics}
// }
export function scriptWidgetKernel(global, host, configJSON) {
  "use strict";
  const config = JSON.parse(configJSON);
  const contract = config.contract;
  const ObjectKeys = Object.keys;
  const ArrayIsArray = Array.isArray;
  const DateCtor = Date;
  const datePrototypeGetTime = Date.prototype.getTime;
  const StringCtor = String;
  const stringLowerCase = Function.prototype.call.bind(String.prototype.toLowerCase);
  const JSONStringify = JSON.stringify;
  const logs = [];
  const diagnostics = [];

  function utf8ByteLength(text) {
    let count = 0;
    for (const character of text) { const cp = character.codePointAt(0); count += cp <= 0x7f ? 1 : cp <= 0x7ff ? 2 : cp <= 0xffff ? 3 : 4; }
    return count;
  }

  function diagnostic(severity, code, message) {
    if (diagnostics.length < 200) diagnostics.push({ severity, code, message: StringCtor(message) });
  }

  function describeException(error) {
    let message;
    try { message = StringCtor(error); } catch { message = "unknown error"; }
    if (error !== null && typeof error === "object") {
      const field = (name) => {
        try {
          const value = error[name];
          if (value === undefined || value === null) return null;
          const text = StringCtor(value);
          return text === "" ? null : text;
        } catch { return null; }
      };
      const line = field("line");
      if (line !== null) {
        const column = field("column");
        message += column !== null ? ` (line ${line}, column ${column})` : ` (line ${line})`;
      }
      const stack = field("stack");
      if (stack !== null) message += "\n" + stack;
    }
    return message;
  }

  // MARK: - Elements and the JavaScriptCore bridge

  const elements = new WeakSet();

  class ScriptWidgetRuntimeElement {
    constructor(tag, props, children) {
      this.tag = tag;
      this.props = props;
      this.children = children;
      elements.add(this);
    }
  }
  const isElement = (value) => value !== null && typeof value === "object" && elements.has(value);

  // JavaScriptCore converts arguments typed [AnyHashable: Any]? / [Any]? with
  // the rules measured in docs/browser-preview-engine.md: undefined object
  // members are dropped, undefined/null array members become NSNull, all
  // numbers become doubles, booleans stay booleans, Dates become NSDate,
  // functions and non-plain objects become dictionaries of their own
  // enumerable properties, and exported native objects keep their identity.
  function bridgeValue(value, depth) {
    if (depth > 64) throw new TypeError("Value nesting is too deep to cross the native bridge");
    if (value === undefined || value === null) return null;
    const type = typeof value;
    if (type === "string" || type === "number" || type === "boolean") return value;
    if (type === "bigint" || type === "symbol") return {};
    if (isElement(value)) return value;
    if (value instanceof DateCtor) return new DateCtor(datePrototypeGetTime.call(value));
    if (ArrayIsArray(value)) {
      const result = [];
      for (let index = 0; index < value.length; index += 1) result.push(bridgeValue(value[index], depth + 1));
      return result;
    }
    return bridgeDictionary(value, depth);
  }

  function bridgeDictionary(value, depth) {
    const result = {};
    for (const key of ObjectKeys(value)) {
      const member = value[key];
      if (member === undefined) continue;
      result[key] = bridgeValue(member, depth + 1);
    }
    return result;
  }

  function createElement(tag, props, children) {
    let bridgedProps = null;
    if (props !== undefined && props !== null) {
      if (typeof props !== "object" && typeof props !== "function") {
        throw new TypeError("Cannot convert primitive to NSDictionary");
      }
      bridgedProps = bridgeDictionary(props, 0);
    }
    let bridgedChildren = null;
    if (children !== undefined && children !== null) {
      bridgedChildren = ArrayIsArray(children) ? bridgeValue(children, 0) : [];
    }
    return new ScriptWidgetRuntimeElement(tag, bridgedProps, bridgedChildren);
  }

  // Foundation -> JavaScript copy used when a Swift dictionary is passed back
  // into a function component.
  function unbridge(value) {
    if (value === null || typeof value !== "object" || isElement(value)) return value;
    if (value instanceof DateCtor) return new DateCtor(datePrototypeGetTime.call(value));
    if (ArrayIsArray(value)) return value.map(unbridge);
    const result = {};
    for (const key of ObjectKeys(value)) result[key] = unbridge(value[key]);
    return result;
  }

  function childrenAsElements(children) {
    const result = [];
    const visit = (items) => {
      for (const child of items) {
        if (isElement(child)) result.push(child);
        else if (ArrayIsArray(child)) visit(child);
      }
    };
    if (children) visit(children);
    return result;
  }

  // MARK: - Execution state (one run per realm)

  let signalled = false;
  let signalWaiter = null;
  let resultElement = null;
  let rootResolutionError = null;
  let exceptionInfo = null;
  let snapshot = null;

  function signal() {
    if (signalled) return;
    signalled = true;
    // The native host waits on a counting semaphore. Capture the first
    // completion deterministically instead of racing later writes.
    snapshot = { resultElement, rootResolutionError, exceptionInfo };
    if (signalWaiter) signalWaiter();
  }

  function fail(kind, message) { return { ok: false, kind, message }; }

  function resolveWidgetElementTree(root) {
    const activePath = new Set();
    const maximumDepth = contract.maximumElementDepth;

    function singleFragmentElement(values) {
      const flattened = [];
      const append = (value) => { if (ArrayIsArray(value)) value.forEach(append); else flattened.push(value); };
      values.forEach(append);
      if (flattened.length !== 1) return null;
      return isElement(flattened[0]) ? flattened[0] : null;
    }

    function resolve(element, depth, unwrapFragment) {
      if (depth > maximumDepth) {
        return fail("resourceLimit", `Element tree exceeds the maximum depth of ${maximumDepth}`);
      }
      let current = element;
      const inserted = [];
      try {
        for (let step = 0; step < maximumDepth; step += 1) {
          if (activePath.has(current)) return fail("resourceLimit", "Element tree contains a component cycle");
          activePath.add(current);
          inserted.push(current);
          if (typeof current.tag === "string" || typeof current.tag !== "function") break;

          const argument = unbridge(current.props ?? {});
          argument.children = unbridge(current.children ?? []);
          let resolved;
          try {
            resolved = current.tag.call(undefined, argument);
          } catch (error) {
            exceptionInfo = describeException(error);
            signal();
            return fail("scriptError", "Custom component must return a ScriptWidget element");
          }
          if (!isElement(resolved)) return fail("scriptError", "Custom component must return a ScriptWidget element");
          current = resolved;
        }
        if (typeof current.tag !== "string") {
          return fail("resourceLimit", "Component resolution exceeds the maximum depth");
        }
        if (unwrapFragment && current.tag === "Fragment") {
          const child = singleFragmentElement(current.children ?? []);
          if (child) return resolve(child, depth, true);
        }

        const resolveChild = (child) => {
          if (isElement(child)) {
            const result = resolve(child, depth + 1, false);
            return result.ok ? { ok: true, value: result.element } : result;
          }
          if (ArrayIsArray(child)) {
            const values = [];
            for (const nested of child) {
              const result = resolveChild(nested);
              if (!result.ok) return result;
              values.push(result.value);
            }
            return { ok: true, value: values };
          }
          return { ok: true, value: child };
        };

        const resolvedChildren = [];
        for (const child of current.children ?? []) {
          const result = resolveChild(child);
          if (!result.ok) return result;
          resolvedChildren.push(result.value);
        }
        current.children = resolvedChildren;
        return { ok: true, element: current };
      } finally {
        for (const item of inserted) activePath.delete(item);
      }
    }

    return resolve(root, 1, true);
  }

  function validateElementTree(root) {
    let count = 0;
    let materials = 0;
    const activePath = new Set();
    function visit(element, depth) {
      if (depth > contract.maximumElementDepth) {
        return fail("resourceLimit", `Element tree exceeds the maximum depth of ${contract.maximumElementDepth}`);
      }
      count += 1;
      const material = element.props?.backgroundMaterial;
      if (stringLowerCase(StringCtor(element.tag)) !== "spacer" && (material === "ultraThin" || material === "thin" || material === "regular" || material === "thick" || material === "ultraThick")) {
        materials += 1;
        if (materials > contract.maximumMaterialBackgrounds) return fail("resourceLimit", `Element tree exceeds the ${contract.maximumMaterialBackgrounds}-material background limit`);
      }
      if (count > contract.maximumElementNodes) {
        return fail("resourceLimit", `Element tree exceeds the ${contract.maximumElementNodes}-node limit`);
      }
      if (ObjectKeys(element.props ?? {}).length > contract.maximumPropsPerElement) {
        return fail("resourceLimit", `Element has more than ${contract.maximumPropsPerElement} properties`);
      }
      if (activePath.has(element)) return fail("resourceLimit", "Element tree contains a cycle");
      activePath.add(element);
      try {
        for (const child of childrenAsElements(element.children)) {
          const error = visit(child, depth + 1);
          if (error) return error;
        }
      } finally { activePath.delete(element); }
      return null;
    }
    return visit(root, 1);
  }

  // MARK: - Canonical tree JSON (shared with BrowserPreviewParityTests.swift)

  function encodeNumber(value) {
    if (value !== value) return '{"$number":"NaN"}';
    if (value === Infinity) return '{"$number":"Infinity"}';
    if (value === -Infinity) return '{"$number":"-Infinity"}';
    if (value === 0 && 1 / value < 0) return '{"$number":"-0"}';
    return StringCtor(value);
  }

  const sortKeys = (keys) => keys.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

  function encodeValue(value) {
    if (value === null) return "null";
    if (typeof value === "string") return JSONStringify(value);
    if (typeof value === "number") return encodeNumber(value);
    if (typeof value === "boolean") return value ? "true" : "false";
    if (isElement(value)) return encodeElement(value);
    if (value instanceof DateCtor) return `{"$date":${encodeNumber(datePrototypeGetTime.call(value))}}`;
    if (ArrayIsArray(value)) return "[" + value.map(encodeValue).join(",") + "]";
    return '{"$dict":' + encodeDictionary(value) + "}";
  }

  function encodeDictionary(value) {
    return "{" + sortKeys(ObjectKeys(value)).map((key) => JSONStringify(key) + ":" + encodeValue(value[key])).join(",") + "}";
  }

  function encodeElement(element) {
    const tag = typeof element.tag === "string" ? JSONStringify(element.tag) : '{"$function":true}';
    const props = element.props === null ? "null" : encodeDictionary(element.props);
    const children = element.children === null ? "null" : "[" + element.children.map(encodeValue).join(",") + "]";
    return `{"$element":${tag},"props":${props},"children":${children}}`;
  }

  // MARK: - Host APIs

  function nativeString(value) {
    // JSExport String parameters use JavaScript ToString.
    try { return StringCtor(value); } catch { return ""; }
  }

  // ScriptWidgetRuntimePromise exposes only then(resolve, reject), returns
  // undefined, and starts work when then() is called.
  function nativePromise(start) {
    const promise = {};
    Object.defineProperty(promise, "then", {
      enumerable: false,
      value: function then(resolve, reject) {
        const safeResolve = typeof resolve === "function" ? resolve : () => {};
        const safeReject = typeof reject === "function" ? reject : () => {};
        start((value) => host.defer(() => safeResolve(value)), (reason) => host.defer(() => safeReject(reason)));
        return undefined;
      },
    });
    return promise;
  }

  const actionMode = typeof config.actionID === "string" && config.manifest?.actions?.some((item) => item.id === config.actionID) === true;
  const environments = config.environments ?? {};
  const timelineProjection = environments["timeline-is-projection"] === "true";
  const liveActivityPresentation = config.liveActivityPresentation === true || ["live-activity","dynamic-island"].includes(environments["widget-size"]);
  const fixtures = config.fixtures ?? {};
  let networkRequests = 0;

  function fetchPolicyError(url) {
    if (liveActivityPresentation) return ["[live_activity_unavailable] Live Activity presentations cannot request network data; update their state from the app", null];
    if (timelineProjection) return ["[timeline_read_only] Future entries cannot make live network requests", null];
    const match = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)/.exec(url);
    if (!match) return ["Only HTTP and HTTPS URLs are allowed", null];
    const scheme = match[1].toLowerCase();
    if (scheme !== "http" && scheme !== "https") return ["Only HTTP and HTTPS URLs are allowed", null];
    let host = match[2].replace(/^[^@]*@/, "").toLowerCase();
    if (host.startsWith("[")) host = host.slice(1, host.indexOf("]"));
    else host = host.replace(/:\d*$/, "");
    if (host === "") return ["URL host is required", null];
    const parts = host.split(".");
    const blocked = host === "localhost" || host === "::1" || host.endsWith(".local") ||
      host.startsWith("127.") || host.startsWith("10.") || host.startsWith("192.168.") ||
      (parts.length === 4 && parts[0] === "172" && Number(parts[1]) >= 16 && Number(parts[1]) <= 31);
    return blocked ? ["Local and private network hosts are not allowed", host] : [null, host];
  }

  function hostMatches(host, declarations) {
    return declarations.some((declaration) => {
      const domain = declaration.toLowerCase();
      if (domain.startsWith("*.")) {
        const suffix = domain.slice(2);
        return host !== suffix && host.endsWith("." + suffix);
      }
      return host === domain;
    });
  }

  function packageAllows(host) {
    if (!config.hasManifest) return true;
    const manifest = config.manifest;
    if (!manifest) return false;
    return (manifest.permissions ?? []).includes("network") && hostMatches(host, manifest.networkDomains ?? []);
  }

  function internalFetch(method, url, params, metadata = false) {
    const urlString = nativeString(url);
    const bridgedParams = params === undefined || params === null ? null : bridgeValue(params, 0);
    return nativePromise((resolve, reject) => {
      const [policyError, host] = fetchPolicyError(urlString);
      if (policyError) { reject(policyError); return; }
      if (!packageAllows(host)) { reject("Network host is not declared in widget.json"); return; }
      networkRequests += 1;
      if (networkRequests > 16) { reject("Network request budget exceeded"); return; }
      const fixture = (fixtures.fetch ?? []).find((item) =>
        item.url === urlString && (item.method ?? "GET").toUpperCase() === method);
      if (!fixture) {
        diagnostic("warning", "fixture.fetch.missing", `No fetch fixture for ${method} ${urlString}; the web preview does not use the network.`);
        reject(`${urlString} is empty`);
        return;
      }
      if (fixture.error) { reject(nativeString(fixture.error)); return; }
      const body = nativeString(fixture.body ?? "");
      const encodedBody = bridgedParams?.responseType === "base64" ? nativeString(fixture.base64 ?? body) : body;
      if (utf8ByteLength(body) > 2097152) { reject("Response exceeds the 2097152-byte limit"); return; }
      if (metadata) {
        const headers = {};
        const allowed = ["content-type", "cache-control", "expires", "last-modified", "date", "retry-after"];
        for (const [key,value] of Object.entries(fixture.headers ?? {})) {
          const name = key.toLowerCase();
          if (allowed.includes(name) && typeof value === "string" && utf8ByteLength(value) <= 2048) headers[name] = value;
        }
        resolve({status:fixture.status ?? 200,body:encodedBody,headers});
      } else resolve(encodedBody);
    });
  }

  function unavailablePromise(api) {
    return () => nativePromise((resolve, reject) => {
      const fixture = fixtures[api];
      if (fixture !== undefined) { resolve(bridgeValue(fixture, 0)); return; }
      diagnostic("warning", `fixture.${api}.missing`, `${api} needs a fixture in the web preview.`);
      reject(`${api} is not available in the web preview`);
    });
  }

  const storage = new Map(Object.entries(config.storage ?? fixtures.storage ?? {}));
  // iCloud is always an isolated preview model. No network, account or native
  // connection is acquired by a fixture or a package-supplied store ID.
  const cloudFixture = fixtures.icloud ?? {};
  const cloudDocuments = new Map(Object.entries(cloudFixture.documents ?? {}));
  let cloudRevision = 0;
  function cloudJSON(method, name, value, expected) {
    return nativePromise((resolve, reject) => {
      const fail = (reason) => reject(`[icloud:${reason}] Preview operation rejected; existing data is preserved.`);
      if (!config.hasManifest || !config.manifest?.permissions?.includes("icloud")) { reject("[permission_denied] Declare icloud in widget.json"); return; }
      if (timelineProjection || liveActivityPresentation || (["write", "resolve", "sync"].includes(method) && !actionMode)) { fail("read_only"); return; }
      if (++dataQueries > contract.maximumDataQueries) { reject("[query_limit] Too many system data queries"); return; }
      if (cloudFixture.connected !== true) { fail("notConnected"); return; }
      if (method === "status") { resolve({ state: cloudFixture.available === false ? "unavailable" : "connected", store: "preview-only", uploaded: null, uploadState: "unknown", conflictPolicy: "preserveAllVersions" }); return; }
      if (method === "sync") { if (cloudFixture.available === false) fail("unavailable"); else resolve({ state: "pending", materializedRevisions: cloudDocuments.size, downloadedRevisions: 0, uploaded: null }); return; }
      if (typeof name !== "string" || !/^[a-z][a-z0-9_-]{0,58}\.json$/.test(name)) { fail("invalidName"); return; }
      const previous = cloudDocuments.get(name) ?? { value: null, revision: "", state: "cached", conflicts: [] };
      if (method === "read") { resolve(bridgeValue(previous, 0)); return; }
      if (expected !== previous.revision) { fail("staleRevision"); return; }
      if (method !== "resolve" && previous.state === "conflict") { fail("conflict"); return; }
      const valid = (item, depth = 0) => depth <= 32 && (item === null || typeof item === "string" || typeof item === "boolean" || (typeof item === "number" && Number.isFinite(item)) || (typeof item === "object" && Object.values(item).every(child => valid(child, depth + 1))));
      if (!value || typeof value !== "object" || ArrayIsArray(value) || !valid(value)) { fail("invalidData"); return; }
      const encoded = JSONStringify(value);
      if (utf8ByteLength(encoded) > 64 * 1024) { fail("limitExceeded"); return; }
      cloudRevision += 1;
      if (cloudRevision > 256) { fail("limitExceeded"); return; }
      const current = { value: JSON.parse(encoded), revision: `preview-${cloudRevision}`, state: "pending", conflicts: [] };
      cloudDocuments.set(name, current); resolve(bridgeValue(current, 0));
    });
  }

  const validStorageKey = (key) => key !== "" && utf8ByteLength(key) <= 256;
  function storageJSON(value) {
    if (value === null || typeof value !== "object") return null;
    try {
      const dictionary = bridgeDictionary(value, 0);
      const normalize = (item) => {
        if (item === null || typeof item === "string" || typeof item === "boolean") return item;
        if (typeof item === "number") { if (!Number.isFinite(item)) throw new Error("Nonfinite JSON"); return item; }
        if (item instanceof DateCtor || isElement(item)) throw new Error("Unsupported JSON value");
        if (ArrayIsArray(item)) return item.map(normalize);
        return Object.fromEntries(ObjectKeys(item).sort().map((key) => [key, normalize(item[key])]));
      };
      const encoded = JSONStringify(normalize(dictionary));
      return utf8ByteLength(encoded) <= 256 * 1024 ? { encoded, value: dictionary } : null;
    } catch { return null; }
  }
  const device = config.device ?? fixtures.device ?? {};
  const system = config.system ?? fixtures.system ?? {};
  const constant = (value) => () => unbridge(bridgeValue(value, 0));

  function readJSON(text) {
    if (text === null || text === undefined) return {};
    try {
      const value = JSON.parse(text);
      return value !== null && typeof value === "object" && !ArrayIsArray(value) ? value : null;
    } catch { return {}; }
  }

  const apis = {
    fetch: (url, params) => internalFetch("GET", url, params),
    $console: {
      log(message) { logs.push({ level: "log", message: nativeString(message) }); host.log("log", nativeString(message)); },
      error(message) { logs.push({ level: "error", message: nativeString(message) }); host.log("error", nativeString(message)); },
    },
    $element: { createElement },
    $device: {
      screen: constant(device.screen ?? { width: 390, height: 844, scale: 3 }),
      language: constant(device.language ?? "en"),
      model: constant(device.model ?? "iPhone"),
      name: constant(device.name ?? "iPhone"),
      battery: constant(device.battery ?? { level: 0.8, state: "unplugged" }),
      systemVersion: constant(device.systemVersion ?? "26.0"),
      isdarkmode: () => config.preview?.appearance === "dark",
      totalDiskSpace: constant(device.totalDiskSpace ?? 128000000000),
      freeDiskSpace: constant(device.freeDiskSpace ?? 64000000000),
    },
    $http: {
      get: (url, params) => internalFetch("GET", url, params),
      getResponse: (url, params) => internalFetch("GET", url, params, true),
      post: (url, params) => internalFetch("POST", url, params),
      put: (url, params) => internalFetch("PUT", url, params),
      patch: (url, params) => internalFetch("PATCH", url, params),
      delete: (url, params) => internalFetch("DELETE", url, params),
    },
    $file: {
      exists(path) {
        const name = nativeString(path), parts = name.split("/");
        if (/^[A-Za-z]:/.test(name) || parts.length > 16 || parts.some((part) => !part || part === "." || part === ".." || part.includes("\\") || utf8ByteLength(part) > 255 || [...part].some((character) => /[\p{Cc}\p{Cf}]/u.test(character) && character !== "\u200c" && character !== "\u200d"))) return false;
        return host.fileExists?.(name) === true;
      },
      read(path) { const text = host.readFile(nativeString(path)); return text ?? ""; },
      readJSON(path) { return readJSON(host.readFile(nativeString(path))); },
    },
    $system: {
      appInfo: constant(system.appInfo ?? { name: "ScriptWidget", bundleId: "com.everettjf.scriptwidget", version: "", build: "" }),
      locale: constant(system.locale ?? "en_US"),
      preferredLanguages: constant(system.preferredLanguages ?? ["en-US"]),
      timeZone: constant(system.timeZone ?? { identifier: "UTC", abbreviation: "GMT", offsetSeconds: 0 }),
      is24HourClock: constant(system.is24HourClock ?? false),
      calendarInfo: constant(system.calendarInfo ?? { identifier: "gregorian", firstWeekday: 1, minimumDaysInFirstWeek: 1 }),
      systemUptime: constant(system.systemUptime ?? 3600),
      memory: constant(system.memory ?? { physical: 8589934592 }),
      thermalState: constant(system.thermalState ?? "nominal"),
      lowPowerMode: constant(system.lowPowerMode ?? false),
      brightness: constant(system.brightness ?? 0.5),
      reduceMotionEnabled: constant(system.reduceMotionEnabled ?? false),
      platform: constant(system.platform ?? "ios"),
      hostName: constant(system.hostName ?? "iPhone"),
      processName: constant(system.processName ?? "ScriptWidgetWidget"),
      osVersionString: constant(system.osVersionString ?? "Version 26.0"),
      processorCount: constant(system.processorCount ?? 6),
      activeProcessorCount: constant(system.activeProcessorCount ?? 6),
    },
    $reminders: {
      isAvailable: () => false,
      authorizationStatus: () => "unavailable",
      requestAuthorization: unavailablePromise("reminders.authorization"),
      lists: unavailablePromise("reminders.lists"),
      items: unavailablePromise("reminders.items"),
    },
    $calendar: {
      isAvailable: () => false,
      authorizationStatus: () => "unavailable",
      requestAuthorization: unavailablePromise("calendar.authorization"),
      calendars: unavailablePromise("calendar.calendars"),
      events: unavailablePromise("calendar.events"),
    },
    $services: {},
    $music: {
      isAvailable: () => false, authorizationStatus: () => "unavailable",
      current: unavailablePromise("music.current"),
    },
    $photos: {
      isAvailable: () => false, authorizationStatus: () => "unavailable",
      requestAuthorization: unavailablePromise("photos.authorization"), items: unavailablePromise("photos.items"),
    },
    $health: {
      authorizationStatus: () => fixtures.health !== undefined ? "notDisclosed" : "unavailable",
      isAvailable: () => fixtures.health !== undefined,
      requestAuthorization: unavailablePromise("health"),
      stepCountToday: unavailablePromise("health.stepCountToday"),
      activeEnergyToday: unavailablePromise("health.activeEnergyToday"),
      heartRateLatest: unavailablePromise("health.heartRateLatest"),
      sleepSummary: unavailablePromise("health.sleepSummary"),
      activitySummary: unavailablePromise("health.activitySummary"),
      workouts: unavailablePromise("health.workouts"),
    },
    $location: {
      isAuthorizedForWidgetUpdates: () => fixtures.location !== undefined,
      isAvailable: () => fixtures.location !== undefined,
      authorizationStatus: () => (fixtures.location !== undefined ? "authorizedWhenInUse" : "notDetermined"),
      requestAuthorization: unavailablePromise("location.authorization"),
      current: unavailablePromise("location"),
    },
    $icloud: {
      readJSON: (name) => cloudJSON("read", name),
      writeJSON: (name, value, expectedRevision) => cloudJSON("write", name, value, expectedRevision),
      resolveJSON: (name, value, expectedRevision) => cloudJSON("resolve", name, value, expectedRevision),
      sync: () => cloudJSON("sync"),
      status: () => cloudJSON("status"),
    },
    $storage: {
      getString(key) { const name = nativeString(key); const value = validStorageKey(name) ? storage.get(name) : undefined; return typeof value === "string" ? value : ""; },
      setString(key, value) {
        if (timelineProjection) return false;
        const name = nativeString(key); const text = nativeString(value);
        if (!validStorageKey(name) || utf8ByteLength(text) > 256 * 1024) return false;
        storage.set(name, text); return true;
      },
      getJSON(key) {
        const name = nativeString(key); const value = validStorageKey(name) ? storage.get(name) : undefined;
        return value && typeof value === "object" && !ArrayIsArray(value) ? unbridge(value) : {};
      },
      setJSON(key, value) {
        if (timelineProjection) return false;
        const name = nativeString(key), json = storageJSON(value);
        if (!validStorageKey(name) || json === null) return false;
        storage.set(name, json.value); return true;
      },
      compareAndSetString(key, expected, value) {
        if (timelineProjection || fixtures.storageAtomicAvailable === false) return false;
        const name = nativeString(key), before = nativeString(expected), next = nativeString(value);
        if (!validStorageKey(name) || utf8ByteLength(before) > 256 * 1024 || utf8ByteLength(next) > 256 * 1024) return false;
        if ((storage.has(name) && typeof storage.get(name) !== "string") || (storage.get(name) ?? "") !== before) return false;
        storage.set(name, next); return true;
      },
      compareAndSetJSON(key, expected, value) {
        if (timelineProjection || fixtures.storageAtomicAvailable === false) return false;
        const name = nativeString(key), before = storageJSON(expected), next = storageJSON(value);
        if (!validStorageKey(name) || before === null || next === null) return false;
        if (storage.has(name)) {
          const current = storage.get(name);
          if (!current || typeof current !== "object" || ArrayIsArray(current) || storageJSON(current)?.encoded !== before.encoded) return false;
        } else if (before.encoded !== "{}") return false;
        storage.set(name, next.value); return true;
      },
      remove(key) { if (timelineProjection) return false; const name = nativeString(key); if (!validStorageKey(name)) return false; storage.delete(name); return true; },
      keys() { return [...storage.keys()].sort(); },
      clear() { if (timelineProjection) return false; storage.clear(); return true; },
    },
    $runtime: {
      apiVersion: contract.apiVersion,
      limits: {
        sourceBytes: contract.maximumSourceBytes,
        transpiledBytes: contract.maximumTranspiledBytes,
        executionMilliseconds: contract.executionTimeoutMilliseconds,
        elementNodes: contract.maximumElementNodes,
        elementDepth: contract.maximumElementDepth,
        propsPerElement: contract.maximumPropsPerElement,
        systemDataQueries: contract.maximumDataQueries,
      },
    },
    $dataSource: {
      request: (pluginID, operationID) => nativePromise((resolve, reject) => {
        if (liveActivityPresentation) { reject("[live_activity_unavailable] Live Activity presentations cannot request service data; update their state from the app"); return; }
        if (timelineProjection) { reject("[timeline_read_only] Future entries cannot make live service requests"); return; }
        const plugin = nativeString(pluginID), operation = nativeString(operationID);
        const fixture = (fixtures.dataSource ?? []).find((item) => item.pluginID === plugin && item.operationID === operation);
        if (!fixture) {
          diagnostic("warning", "fixture.dataSource.missing", `No Data Source mock for ${plugin} / ${operation}.`);
          reject("Data Source Plugins need a matching mock in the web preview");
          return;
        }
        // A mock must not hide missing package permissions or a disallowed host.
        if (!config.manifest?.plugins?.includes(plugin)) { reject(`Plugin ${plugin} is not declared in widget.json`); return; }
        const [policyError, host] = fetchPolicyError(nativeString(fixture.url ?? ""));
        if (policyError || !nativeString(fixture.url).startsWith("https://")) { reject(policyError ?? "Data Source mocks require HTTPS"); return; }
        if (!packageAllows(host)) { reject("Network host is not declared in widget.json"); return; }
        if (++networkRequests > 16) { reject("Network request budget exceeded"); return; }
        if (fixture.error !== undefined) { reject(nativeString(fixture.error)); return; }
        resolve(bridgeValue(fixture.value, 0));
      }),
    },
    $xml_parse: (source) => host.parseXML(nativeString(source)),
    $getenv: (key) => {
      const value = environments[nativeString(key)];
      return typeof value === "string" ? value : "";
    },
    $render(root) {
      if (actionMode) return;
      if (isElement(root)) {
        const result = resolveWidgetElementTree(root);
        if (result.ok) resultElement = result.element;
        else rootResolutionError = { kind: result.kind, message: result.message };
      }
      signal();
    },
    $dynamic_island() { if (!actionMode) signal(); },
    $component() {},
    $error(message) { exceptionInfo = nativeString(message); signal(); },
    $import(relativePath) {
      const path = nativeString(relativePath);
      const compiled = host.compiledImport(path);
      if (compiled === null || compiled === undefined) {
        diagnostic("error", "import.missing", `$import("${path}") did not find a package file; the native runtime returns false silently.`);
        return false;
      }
      const transformed = JSON.parse(compiled);
      if (!transformed.ok) {
        diagnostic("error", "import.transform", `$import("${path}") failed to compile: ${transformed.message}`);
        return false;
      }
      try {
        host.evaluateScript(transformed.code);
      } catch (error) {
        exceptionInfo = describeException(error);
        signal();
      }
      return true;
    },
  };
  // Explicit per-method mocks override data APIs only. Rendering, package files,
  // imports, runtime contracts and network policy continue to execute normally.
  // Fresh bridged values prevent a script from modifying later mock responses.
  const apiMocks = fixtures.api ?? {};
  for (const namespace of ["$device", "$system", "$health", "$location", "$calendar", "$reminders", "$photos", "$music"]) {
    for (const method of ObjectKeys(apis[namespace])) {
      const mock = apiMocks[`${namespace}.${method}`];
      if (!mock || typeof mock !== "object" || ArrayIsArray(mock)) continue;
      const hasError = Object.prototype.hasOwnProperty.call(mock, "error");
      if (!hasError && !Object.prototype.hasOwnProperty.call(mock, "value")) continue;
      const asynchronous = (["$calendar", "$reminders", "$photos", "$music"].includes(namespace) && !["isAvailable", "authorizationStatus"].includes(method)) || (namespace === "$health" && !["isAvailable", "authorizationStatus"].includes(method)) ||
        (namespace === "$location" && (method === "current" || method === "requestAuthorization"));
      apis[namespace][method] = asynchronous
        ? () => nativePromise((resolve, reject) => hasError ? reject(nativeString(mock.error)) : resolve(bridgeValue(mock.value, 0)))
        : () => { if (hasError) throw new Error(nativeString(mock.error)); return unbridge(bridgeValue(mock.value, 0)); };
    }
  }
  // Apply policy after fixture replacement: mocks cannot grant package access.
  let dataQueries = 0;
  const musicDeclared = () => config.hasManifest && config.manifest?.permissions?.includes("music") === true;
  const musicAvailable = apis.$music.isAvailable, musicStatus = apis.$music.authorizationStatus;
  apis.$music.isAvailable = () => musicDeclared() && musicAvailable() === true;
  apis.$music.authorizationStatus = () => {
    if (!musicDeclared()) return "undeclared";
    const value = musicStatus();
    if (!["authorized", "denied", "restricted", "notDetermined", "unavailable"].includes(value)) throw new Error("[mock_invalid] Invalid Music authorization status");
    return value;
  };
  apis.$music.current = () => nativePromise((resolve, reject) => {
    try {
      if (!musicDeclared()) throw new Error("[music_permission] Declare music in widget.json");
      if (timelineProjection || liveActivityPresentation) throw new Error("[timeline_read_only] Prepare Music display data in the current entry");
      if (++dataQueries > contract.maximumDataQueries) throw new Error("[query_limit] Too many system data queries");
      if (!apis.$music.isAvailable()) throw new Error("[music_unavailable] Current Music app playback is unavailable on this platform");
      if (apis.$music.authorizationStatus() !== "authorized") throw new Error("[music_permission] Allow Music access in native Settings");
      const mock = apiMocks["$music.current"];
      if (mock?.error !== undefined) throw new Error(nativeString(mock.error));
      const value = mock?.value, keys = ["provider", "state", "hasItem", "title", "artist", "album", "duration", "position", "capturedAt"];
      const text = input => input === null || (typeof input === "string" && utf8ByteLength(input) <= 512 && !/\p{Cc}/u.test(input));
      const seconds = (input, minimum) => input === null || (typeof input === "number" && Number.isFinite(input) && input >= minimum && input <= 604800);
      if (!value || typeof value !== "object" || ArrayIsArray(value) || ObjectKeys(value).length !== keys.length || ObjectKeys(value).some(key => !keys.includes(key)) ||
          value.provider !== "appleMusic" || !["playing", "paused", "stopped", "interrupted", "seeking", "unknown"].includes(value.state) || typeof value.hasItem !== "boolean" ||
          !["title", "artist", "album"].every(key => text(value[key])) || !seconds(value.duration, Number.MIN_VALUE) || !seconds(value.position, 0) ||
          (!value.hasItem && ["title", "artist", "album", "duration"].some(key => value[key] !== null)) ||
          typeof value.capturedAt !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(value.capturedAt) || !Number.isFinite(datePrototypeGetTime.call(new DateCtor(value.capturedAt)))) throw new Error("[music_snapshot] Invalid Music playback snapshot");
      resolve(bridgeValue(value, 0));
    } catch (error) { reject(nativeString(error)); }
  });
  const serviceProfileKeys = ["service", "subject", "username", "displayName", "publicRepositories", "privateRepositories", "followers", "following"];
  const serviceError = (code, text) => `[service_${code}] ${text}`;
  const serviceStatus = () => {
    const mock = apiMocks["$services.status"];
    if (mock?.error !== undefined) throw new Error(nativeString(mock.error));
    const value = mock?.value ?? "notConnected";
    if (!["connected", "notConnected", "notGranted", "unavailable"].includes(value)) throw new Error("[mock_invalid] Invalid service status");
    return value;
  };
  for (const method of ["status", "profile"]) {
    apis.$services[method] = (rawService) => nativePromise((resolve, reject) => {
      try {
        if (!config.hasManifest || !config.manifest?.permissions?.includes("services")) throw new Error(serviceError("permission", "Install this widget and declare services in widget.json"));
        const service = nativeString(rawService);
        if (service !== "github") throw new Error(serviceError("operation", "This service operation is unsupported"));
        if (timelineProjection || liveActivityPresentation) throw new Error("[timeline_read_only] Read services in the current entry, then reuse a display snapshot");
        if (++dataQueries > contract.maximumDataQueries) throw new Error("[query_limit] Too many system data queries");
        const status = serviceStatus();
        if (method === "status") { resolve(status); return; }
        if (status === "notConnected") throw new Error(serviceError("not_connected", "Connect GitHub in the app"));
        if (status === "notGranted") throw new Error(serviceError("permission", "Allow this widget in native Service Accounts"));
        if (status === "unavailable") throw new Error(serviceError("unavailable", "The service is currently unavailable"));
        if (!packageAllows("api.github.com")) throw new Error(serviceError("permission", "Declare network and api.github.com in widget.json"));
        if (++networkRequests > 16) throw new Error("[network_limit] Network request budget exceeded");
        const mock = apiMocks["$services.profile"];
        if (mock?.error !== undefined) throw new Error(nativeString(mock.error));
        const value = mock?.value;
        const text = (input, max) => typeof input === "string" && utf8ByteLength(input) <= max && !/[\p{Cc}\p{Cf}\p{Cs}]/u.test(input);
        const count = (input, required = false) => (!required && input === null) || (Number.isSafeInteger(input) && input >= 0);
        if (!value || typeof value !== "object" || ArrayIsArray(value) || ObjectKeys(value).length !== serviceProfileKeys.length || ObjectKeys(value).some(key => !serviceProfileKeys.includes(key)) ||
            value.service !== "github" || typeof value.subject !== "string" || !/^[1-9][0-9]{0,15}$/.test(value.subject) || !Number.isSafeInteger(Number(value.subject)) ||
            !text(value.username,39) || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,38}$/.test(value.username) || !(value.displayName === null || text(value.displayName,256)) ||
            !count(value.publicRepositories,true) || !["privateRepositories","followers","following"].every(key=>count(value[key]))) throw new Error("[mock_invalid] Invalid service profile fields");
        resolve(bridgeValue(value, 0));
      } catch (error) { reject(nativeString(error)); }
    });
  }
  const healthStatus = apis.$health.authorizationStatus;
  apis.$health.authorizationStatus = () => config.hasManifest && !config.manifest?.permissions?.includes("health") ? "undeclared" : healthStatus();
  const healthNow = () => datePrototypeGetTime.call(new DateCtor());
  const healthZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const healthISO = Date.prototype.toISOString;
  const healthInstant = (raw) => {
    if (typeof raw !== "string" || !/^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/.test(raw) || !healthDay(raw.slice(0,10))) throw new Error("[invalid_options] Invalid Health date");
    const date = new DateCtor(raw), time = datePrototypeGetTime.call(date);
    if (!Number.isFinite(time)) throw new Error("[invalid_options] Invalid Health date"); return time;
  };
  const healthDay = (raw) => {
    if (typeof raw !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(raw)) return false;
    const [year,month,day]=raw.split("-").map(Number), date=new DateCtor(0);
    if(year<1)return false;date.setUTCFullYear(year,month-1,day);date.setUTCHours(0,0,0,0);
    return healthISO.call(date).slice(0,10)===raw;
  };
  const healthLocalDay = (time) => {const d=new DateCtor(time);return `${StringCtor(d.getFullYear()).padStart(4,"0")}-${StringCtor(d.getMonth()+1).padStart(2,"0")}-${StringCtor(d.getDate()).padStart(2,"0")}`;};
  for (const method of ["requestAuthorization", "stepCountToday", "activeEnergyToday", "heartRateLatest"]) {
    const call = apis.$health[method];
    apis.$health[method] = (...args) => nativePromise((resolve,reject) => {
      if(config.hasManifest && !config.manifest?.permissions?.includes("health")){reject("[permission_denied] Declare health in widget.json");return;}
      if(timelineProjection || liveActivityPresentation){reject("[timeline_read_only] Health presentations cannot query live readings");return;}
      if(++dataQueries>contract.maximumDataQueries){reject("[query_limit] Too many system data queries");return;}
      if(!apis.$health.isAvailable()){reject("[unavailable] Health data is unavailable");return;}
      call(...args).then(resolve,reject);
    });
  }
  for(const method of ["sleepSummary","activitySummary","workouts"]) {
    apis.$health[method] = (options) => nativePromise((resolve,reject)=>{
      try {
        if(!config.manifest?.permissions?.includes("health")){reject("[permission_denied] Declare health in widget.json");return;}
        if(timelineProjection || liveActivityPresentation){reject("[timeline_read_only] Read Health in the current entry");return;}
        const input=bridgeDictionary(options??{},0), fields=method==="activitySummary"?["date"]:method==="workouts"?["start","end","limit"]:["start","end"];
        if(ObjectKeys(input).some(key=>!fields.includes(key)))throw new Error("[invalid_options] Unknown Health query option");
        const now=healthNow();let start,end,date,limit=5;
        if(method==="activitySummary") {
          date=input.date===undefined?healthLocalDay(now):input.date;
          if(!healthDay(date)||date>healthLocalDay(now))throw new Error("[invalid_options] Invalid Health activity day");
        } else {
          end=input.end===undefined?now:healthInstant(input.end);start=input.start===undefined?end-(method==="sleepSummary"?86400000:7*86400000):healthInstant(input.start);
          if(end<=start||end>now+1000||end-start>(method==="sleepSummary"?7:31)*86400000)throw new Error("[invalid_options] Invalid Health query range");
          if(input.limit!==undefined){limit=input.limit;if(typeof limit!=="number"||!Number.isInteger(limit)||limit<1||limit>50)throw new Error("[invalid_options] Invalid workout limit");}
        }
        if(++dataQueries>contract.maximumDataQueries){reject("[query_limit] Too many system data queries");return;}
        if(!apis.$health.isAvailable()){reject("[unavailable] Health data is unavailable");return;}
        const mock=apiMocks[`$health.${method}`];if(mock?.error!==undefined){reject(StringCtor(mock.error));return;}
        const value=unbridge(bridgeValue(mock?.value,0));
        const invalid=()=>{throw new Error("[mock_invalid] Invalid Health summary sample");};
        const finite=(x,max=1e9)=>typeof x==="number"&&Number.isFinite(x)&&x>=0&&x<=max;
        if(!value||typeof value!=="object"||ArrayIsArray(value)||typeof value.hasSamples!=="boolean")invalid();
        if(method==="sleepSummary") {
          const span=(end-start)/1000, stages=value.stages;
          if(!stages||ObjectKeys(stages).sort().join(",")!=="core,deep,rem,unspecified"||Object.values(stages).some(x=>!finite(x,span))||![value.totalSleepSeconds,value.inBedSeconds,value.awakeSeconds,value.conflictSeconds].every(x=>finite(x,span))||Math.abs(Object.values(stages).reduce((a,b)=>a+b,0)-value.totalSleepSeconds)>0.01||value.totalSleepSeconds+value.awakeSeconds>span+0.01||!Number.isInteger(value.sourceCount)||value.sourceCount<0||value.sourceCount>256||typeof value.truncated!=="boolean"||value.aggregation!=="union-awake-rem-deep-core-unspecified")invalid();
          if(!value.hasSamples&&(value.totalSleepSeconds||value.inBedSeconds||value.awakeSeconds||value.sourceCount||value.conflictSeconds))invalid();
        } else if(method==="activitySummary") {
          if(!["activeEnergy","moveTime"].includes(value.moveMode))invalid();
          for(const [key,unit] of [["move",value.moveMode==="moveTime"?"min":"kcal"],["exercise","min"],["stand","count"]]) {
            const item=value[key];if(!item||item.unit!==unit||!finite(item.value)||(item.goal!==null&&!finite(item.goal))||(!value.hasSamples&&(item.value!==0||item.goal!==null)))invalid();
          }
          value.date=date;
        } else {
          if(!ArrayIsArray(value.items)||value.items.length>50||typeof value.truncated!=="boolean"||new Set(value.items.map(row=>row.id)).size!==value.items.length)invalid();
          const activities=["walking","running","cycling","swimming","hiking","yoga","strength","rowing","elliptical","pilates","dance","other"];
          for(const row of value.items) {
            const a=healthInstant(row.start),b=healthInstant(row.end);
            if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(row.id)||!activities.includes(row.activity)||b<=a||!finite(row.duration,(b-a)/1000+0.01)||[row.energyKcal,row.distanceMeters].some(x=>x!==null&&!finite(x)))invalid();
          }
          value.items=value.items.filter(row=>healthInstant(row.start)>=start&&healthInstant(row.end)<=end).sort((a,b)=>healthInstant(b.start)-healthInstant(a.start)||a.id.localeCompare(b.id));
          value.truncated=value.truncated||value.items.length>limit;value.items=value.items.slice(0,limit);value.hasSamples=value.items.length>0;
        }
        if(method!=="activitySummary"){value.start=healthISO.call(new DateCtor(start));value.end=healthISO.call(new DateCtor(end));}
        value.timeZone=healthZone;resolve(value);
      } catch(error){reject(StringCtor(error.message??error));}
    });
  }

  const photosDeclared = () => config.manifest?.permissions?.includes("photos") === true;
  const photoStatusMock = apis.$photos.authorizationStatus, photoAvailableMock = apis.$photos.isAvailable;
  apis.$photos.authorizationStatus = () => photosDeclared() ? photoStatusMock() : "undeclared";
  apis.$photos.isAvailable = () => photosDeclared() && photoAvailableMock();
  const photoSelection = fixtures.photosSelection ?? [];
  const validPhotoID = (id) => typeof id === "string" && id.length > 0 && utf8ByteLength(id) <= 1024 && !/[\x00-\x1f\x7f]/.test(id);
  const photoScopeValid = ArrayIsArray(photoSelection) && photoSelection.length <= 64 && photoSelection.every(validPhotoID) && new Set(photoSelection).size === photoSelection.length;
  const photoAllowed = new Set(photoScopeValid ? photoSelection : []);
  for (const method of ["requestAuthorization", "items"]) {
    apis.$photos[method] = (options) => nativePromise((resolve, reject) => {
      if (!photosDeclared()) { reject("[permission_denied] Declare photos in widget.json"); return; }
      if ((method !== "requestAuthorization" || (!timelineProjection && !liveActivityPresentation)) && ++dataQueries > contract.maximumDataQueries) { reject("[query_limit] Too many system data queries"); return; }
      if (!apis.$photos.isAvailable()) { reject("[unavailable] Photos are unavailable"); return; }
      const authorized = ["authorized", "limited"].includes(apis.$photos.authorizationStatus());
      if (method === "requestAuthorization") {
        const mock = apiMocks["$photos.requestAuthorization"];
        if (mock?.error !== undefined) reject(StringCtor(mock.error)); else resolve(authorized && mock?.value === true);
        return;
      }
      if (!authorized || !photoScopeValid || photoAllowed.size === 0) { reject("[permission_denied] Allow Photos and choose photos or albums in Settings"); return; }
      const input = bridgeDictionary(options ?? {}, 0);
      const number = (key, fallback, min, max, integer) => {
        const value = Object.prototype.hasOwnProperty.call(input, key) ? input[key] : fallback;
        if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value))) throw new Error("[invalid_options] Invalid photo query");
        return value;
      };
      try {
        if (ObjectKeys(input).some((key) => !["limit", "offset", "maxAgeSeconds"].includes(key))) throw new Error("[invalid_options] Unknown photo option");
        const limit = number("limit", 4, 1, 4, true), offset = number("offset", 0, 0, 63, true), maxAge = number("maxAgeSeconds", 3600, 0, 86400, false);
        const mock = apiMocks["$photos.items"];
        if (mock?.error !== undefined) { reject(StringCtor(mock.error)); return; }
        const result = unbridge(bridgeValue(mock?.value, 0));
        if (!result || !ArrayIsArray(result.items) || result.items.length > 64 || new Set(result.items.map((row) => row.id)).size !== result.items.length || result.items.some((row) => !validPhotoID(row.id) || typeof row.image !== "string" || !/^data:image\/jpeg;base64,[A-Za-z0-9+/]+={0,2}$/.test(row.image) || utf8ByteLength(row.image) > 174787 || !Number.isInteger(row.width) || row.width < 1 || !Number.isInteger(row.height) || row.height < 1) || !Number.isInteger(result.unavailableCount) || result.unavailableCount < 0 || result.unavailableCount > 64) throw new Error("[mock_invalid] Invalid photo snapshot");
        const age = (DateCtor.now() - DateCtor.parse(result.fetchedAt)) / 1000;
        if (!Number.isFinite(age) || age < 0 || age > 86400 || ((timelineProjection || liveActivityPresentation) && fixtures.photosSnapshotPrepared !== true)) { reject("[cache_miss] Prepare a matching photo snapshot in the app"); return; }
        result.items = result.items.filter((row) => photoAllowed.has(row.id)).slice(offset, offset + limit);
        if (timelineProjection || liveActivityPresentation) { result.source = "cache"; result.stale = age > maxAge; }
        resolve(result);
      } catch (error) { reject(StringCtor(error.message ?? error)); }
    });
  }

  const locationDeclared = () => !config.manifest || config.manifest.permissions?.includes("location") === true;
  const locationStatus = apis.$location.authorizationStatus;
  const locationWidgetAuthorization = apis.$location.isAuthorizedForWidgetUpdates;
  apis.$location.authorizationStatus = () => locationDeclared() ? locationStatus() : "undeclared";
  apis.$location.isAuthorizedForWidgetUpdates = () => locationDeclared() && apis.$location.isAvailable() === true &&
    ["authorizedAlways", "authorizedWhenInUse"].includes(apis.$location.authorizationStatus()) && locationWidgetAuthorization() === true;
  for (const method of ["requestAuthorization", "current"]) {
    const implementation = apis.$location[method];
    apis.$location[method] = (options) => nativePromise((resolve, reject) => {
      if (liveActivityPresentation) { reject("[live_activity_unavailable] Live Activity presentations cannot request location updates; update their state from the app"); return; }
      if (!locationDeclared()) { reject("[permission_denied] Declare location in widget.json"); return; }
      if (++dataQueries > contract.maximumDataQueries) { reject("[query_limit] System data query limit exceeded"); return; }
      if (method === "current") {
        if (!apis.$location.isAvailable()) { reject("[unavailable] Location services are disabled on this device"); return; }
        if (!["authorizedAlways", "authorizedWhenInUse"].includes(apis.$location.authorizationStatus())) { reject("[permission_denied] Location permission denied"); return; }
        if (!apis.$location.isAuthorizedForWidgetUpdates()) { reject("[widget_not_authorized] Allow location for widgets in Settings"); return; }
      }
      implementation(options).then(resolve, reject);
    });
  }
  const rawCalendarSelection = fixtures.calendarSelection;
  const calendarSelectionValid = rawCalendarSelection == null || (ArrayIsArray(rawCalendarSelection) && rawCalendarSelection.length <= 64 && new Set(rawCalendarSelection).size === rawCalendarSelection.length && rawCalendarSelection.every((id) => typeof id === "string" && id.length > 0 && utf8ByteLength(id) <= 256));
  const selectedCalendars = rawCalendarSelection == null ? null : calendarSelectionValid ? new Set(rawCalendarSelection) : new Set();
  const calendarDeclared = () => config.manifest?.permissions?.includes("calendar") === true;
  const calendarStatus = apis.$calendar.authorizationStatus;
  apis.$calendar.authorizationStatus = () => calendarDeclared() ? calendarStatus() : "undeclared";
  for (const method of ["requestAuthorization", "calendars", "events"]) {
    const implementation = apis.$calendar[method];
    apis.$calendar[method] = (options) => nativePromise((resolve, reject) => {
      if (!calendarDeclared()) { reject("[permission_denied] Declare calendar in widget.json"); return; }
      let calendarQuery = {};
      if (method === "events") {
        try {
          const query = options == null ? {} : bridgeDictionary(options, 0);
          calendarQuery = query;
          if (ObjectKeys(query).some((key) => !["start", "end", "limit", "calendarIDs", "maxAgeSeconds"].includes(key))) throw new Error("Unknown calendar query option");
          const parseDate = (value) => {
            if (typeof value !== "string" || value.length > 64 || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(value) || !Number.isFinite(new DateCtor(value).getTime())) throw new Error("Invalid calendar date");
            return new DateCtor(value);
          };
          const start = query.start === undefined ? new DateCtor(new DateCtor().setHours(0, 0, 0, 0)) : parseDate(query.start);
          const end = query.end === undefined ? new DateCtor(new DateCtor(start).setDate(start.getDate() + 1)) : parseDate(query.end);
          if (!(end > start) || end - start > 31 * 86400000) throw new Error("Calendar range must be positive and at most 31 days");
          if (query.limit !== undefined && (!Number.isInteger(query.limit) || query.limit < 1 || query.limit > 50)) throw new Error("Invalid limit");
          if (query.maxAgeSeconds !== undefined && (typeof query.maxAgeSeconds !== "number" || !Number.isFinite(query.maxAgeSeconds) || query.maxAgeSeconds < 0 || query.maxAgeSeconds > 86400)) throw new Error("Invalid maxAgeSeconds");
          const ids = query.calendarIDs;
          if (ids !== undefined && (!ArrayIsArray(ids) || ids.length < 1 || ids.length > 16 || new Set(ids).size !== ids.length || ids.some((id) => typeof id !== "string" || !id || utf8ByteLength(id) > 256))) throw new Error("Invalid calendarIDs");
        } catch (error) { reject(`[invalid_options] ${StringCtor(error.message)}`); return; }
      }
      if (method !== "requestAuthorization" && ++dataQueries > contract.maximumDataQueries) { reject("[query_limit] Too many system data queries"); return; }
      if (method !== "requestAuthorization" && !apis.$calendar.isAvailable()) { reject("[unavailable] Calendar is unavailable"); return; }
      if (method !== "requestAuthorization" && apis.$calendar.authorizationStatus() !== "authorized") { reject("[permission_denied] Allow calendar access in ScriptWidget"); return; }
      if (method !== "requestAuthorization") {
        if (!calendarSelectionValid) { reject("[permission_denied] Calendar source settings are unavailable"); return; }
        if (method === "events" && selectedCalendars?.size === 0) { reject("[permission_denied] No Calendar sources are selected in ScriptWidget Settings"); return; }
        const available = apiMocks["$calendar.calendars"]?.value;
        if (method === "events" && selectedCalendars !== null && ArrayIsArray(available) && !available.some((item) => selectedCalendars.has(item?.id))) {
          reject("[invalid_options] A requested Calendar source is unavailable or outside your selection"); return;
        }
        if (method === "events" && calendarQuery.calendarIDs?.some((id) => (selectedCalendars !== null && !selectedCalendars.has(id)) || (ArrayIsArray(available) && !available.some((item) => item?.id === id)))) {
          reject("[invalid_options] A requested Calendar source is unavailable or outside your selection"); return;
        }
      }
      if (timelineProjection) {
        if (method === "requestAuthorization") { resolve(apis.$calendar.authorizationStatus() === "authorized"); return; }
        const snapshot = apiMocks["$calendar.events"]?.value;
        if (method === "calendars" || snapshot?.source !== "cache") { reject("[timeline_read_only] No matching Calendar snapshot is available"); return; }
      }
      implementation(options).then((value) => {
        if (method === "requestAuthorization") { resolve(value); return; }
        const available = apiMocks["$calendar.calendars"]?.value;
        const allowed = (id) => typeof id === "string" && (selectedCalendars === null || selectedCalendars.has(id)) && (!ArrayIsArray(available) || available.some((item) => item?.id === id));
        if (method === "calendars") {
          if (!ArrayIsArray(value)) { reject("[mock_invalid] Calendar sources must be an array"); return; }
          resolve(value.filter((item) => allowed(item?.id)).slice(0,64)); return;
        }
        if (!value || !ArrayIsArray(value.items)) { reject("[mock_invalid] Calendar events need an items array"); return; }
        const items = value.items.filter((item) => allowed(item?.calendarID) && (!calendarQuery.calendarIDs || calendarQuery.calendarIDs.includes(item.calendarID)));
        const limit = calendarQuery.limit ?? 10;
        resolve({ ...value, items: items.slice(0, limit), status: items.length ? "ready" : "empty", truncated: value.truncated === true || items.length > limit });
      }, reject);
    });
  }
  const reminderStateInput = fixtures.remindersState;
  const reminderRows = JSON.parse(JSONStringify(reminderStateInput?.items ?? apiMocks["$reminders.items"]?.value?.items ?? []));
  const reminderReceipts = JSON.parse(JSONStringify(reminderStateInput?.receipts ?? []));
  let remindersChanged = reminderStateInput !== undefined;
  function reminderDate(text) {
    if (typeof text !== "string" || text.length > 64) return false;
    if (/^\d{4}-\d{2}-\d{2}$/.test(text)) {
      const [y, m, d] = text.split("-").map(Number), value = new DateCtor(0);
      value.setFullYear(y, m - 1, d); value.setHours(0, 0, 0, 0);
      return y >= 1 && value.getFullYear() === y && value.getMonth() === m - 1 && value.getDate() === d;
    }
    return /^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(text) && reminderDate(text.slice(0, 10)) && Number.isFinite(new DateCtor(text).getTime());
  }
  function reminderHash(text) {
    const bytes = [];
    for (const c of text) { const n = c.codePointAt(0); if (n < 128) bytes.push(n); else if (n < 2048) bytes.push(192 | n >> 6, 128 | n & 63); else if (n < 65536) bytes.push(224 | n >> 12, 128 | n >> 6 & 63, 128 | n & 63); else bytes.push(240 | n >> 18, 128 | n >> 12 & 63, 128 | n >> 6 & 63, 128 | n & 63); }
    const bits = bytes.length * 8; bytes.push(128); while (bytes.length % 64 !== 56) bytes.push(0);
    bytes.push(0, 0, 0, 0, bits >>> 24, bits >>> 16 & 255, bits >>> 8 & 255, bits & 255);
    const k = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
    const h = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19], rotate = (n, b) => n >>> b | n << 32 - b;
    for (let offset = 0; offset < bytes.length; offset += 64) {
      const w = new Array(64); for (let i = 0; i < 16; i++) w[i] = bytes[offset + i * 4] << 24 | bytes[offset + i * 4 + 1] << 16 | bytes[offset + i * 4 + 2] << 8 | bytes[offset + i * 4 + 3];
      for (let i = 16; i < 64; i++) { const x = w[i - 15], y = w[i - 2]; w[i] = (w[i - 16] + (rotate(x, 7) ^ rotate(x, 18) ^ x >>> 3) + w[i - 7] + (rotate(y, 17) ^ rotate(y, 19) ^ y >>> 10)) | 0; }
      let [a,b,c,d,e,f,g,j] = h;
      for (let i = 0; i < 64; i++) { const t = (j + (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) + (e & f ^ ~e & g) + k[i] + w[i]) | 0, u = ((rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) + (a & b ^ a & c ^ b & c)) | 0; j=g;g=f;f=e;e=(d+t)|0;d=c;c=b;b=a;a=(t+u)|0; }
      [a,b,c,d,e,f,g,j].forEach((v, i) => { h[i] = h[i] + v | 0; });
    }
    return h.map((n) => (n >>> 0).toString(16).padStart(8, "0")).join("");
  }
  const rawReminderSelection = fixtures.remindersSelection;
  const reminderSelectionValid = rawReminderSelection == null || (ArrayIsArray(rawReminderSelection) && rawReminderSelection.length <= 64 && new Set(rawReminderSelection).size === rawReminderSelection.length && rawReminderSelection.every((id) => typeof id === "string" && id.length > 0 && utf8ByteLength(id) <= 256));
  const selectedLists = rawReminderSelection == null ? null : reminderSelectionValid ? new Set(rawReminderSelection) : new Set();
  const remindersDeclared = () => config.manifest?.permissions?.includes("reminders") === true;
  const remindersStatus = apis.$reminders.authorizationStatus;
  apis.$reminders.authorizationStatus = () => remindersDeclared() ? remindersStatus() : "undeclared";
  for (const method of ["requestAuthorization", "lists", "items"]) {
    const implementation = apis.$reminders[method];
    apis.$reminders[method] = (options) => nativePromise((resolve, reject) => {
      if (!remindersDeclared()) { reject("[permission_denied] Declare reminders in widget.json"); return; }
      let reminderQuery = {};
      if (method === "items") {
        try {
          const query = options == null ? {} : bridgeDictionary(options, 0);
          reminderQuery = query;
          if (ObjectKeys(query).some((key) => !["start", "end", "limit", "listIDs", "maxAgeSeconds", "completed"].includes(key))) throw new Error("Unknown reminder query option");
          const parseDate = (value) => {
            if (typeof value !== "string" || value.length > 64 || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(value) || !Number.isFinite(new DateCtor(value).getTime())) throw new Error("Invalid reminder date");
            return new DateCtor(value);
          };
          const start = query.start === undefined ? new DateCtor(new DateCtor().setHours(0, 0, 0, 0)) : parseDate(query.start);
          const end = query.end === undefined ? new DateCtor(new DateCtor(start).setDate(start.getDate() + 1)) : parseDate(query.end);
          if (!(end > start) || end - start > 31 * 86400000) throw new Error("Reminder range must be positive and at most 31 days");
          if (query.limit !== undefined && (!Number.isInteger(query.limit) || query.limit < 1 || query.limit > 50)) throw new Error("Invalid limit");
          if (query.maxAgeSeconds !== undefined && (typeof query.maxAgeSeconds !== "number" || !Number.isFinite(query.maxAgeSeconds) || query.maxAgeSeconds < 0 || query.maxAgeSeconds > 86400)) throw new Error("Invalid maxAgeSeconds");
          if (query.completed !== undefined && typeof query.completed !== "boolean") throw new Error("completed must be a Boolean");
          reminderQuery = { ...query, start: start.toISOString(), end: end.toISOString() };
          const ids = query.listIDs;
          if (ids !== undefined && (!ArrayIsArray(ids) || ids.length < 1 || ids.length > 16 || new Set(ids).size !== ids.length || ids.some((id) => typeof id !== "string" || !id || utf8ByteLength(id) > 256))) throw new Error("Invalid listIDs");
        } catch (error) { reject(`[invalid_options] ${StringCtor(error.message)}`); return; }
      }
      if (method !== "requestAuthorization" && ++dataQueries > contract.maximumDataQueries) { reject("[query_limit] Too many system data queries"); return; }
      if (method !== "requestAuthorization" && !apis.$reminders.isAvailable()) { reject("[unavailable] Reminder is unavailable"); return; }
      if (method !== "requestAuthorization" && apis.$reminders.authorizationStatus() !== "authorized") { reject("[permission_denied] Allow reminders access in ScriptWidget"); return; }
      if (method !== "requestAuthorization") {
        if (!reminderSelectionValid) { reject("[permission_denied] Reminder source settings are unavailable"); return; }
        if (method === "items" && selectedLists?.size === 0) { reject("[permission_denied] No Reminder lists are selected in ScriptWidget Settings"); return; }
        const available = apiMocks["$reminders.lists"]?.value;
        if (method === "items" && selectedLists !== null && ArrayIsArray(available) && !available.some((item) => selectedLists.has(item?.id))) {
          reject("[invalid_options] A requested Reminder source is unavailable or outside your selection"); return;
        }
        if (method === "items" && reminderQuery.listIDs?.some((id) => (selectedLists !== null && !selectedLists.has(id)) || (ArrayIsArray(available) && !available.some((item) => item?.id === id)))) {
          reject("[invalid_options] A requested Reminder source is unavailable or outside your selection"); return;
        }
      }
      if (timelineProjection || liveActivityPresentation) {
        if (method === "requestAuthorization") { resolve(apis.$reminders.authorizationStatus() === "authorized"); return; }
        const snapshot = apiMocks["$reminders.items"]?.value;
        if (method === "lists" || snapshot?.source !== "cache") { reject("[timeline_read_only] No matching Reminder snapshot is available"); return; }
      }
      implementation(options).then((value) => {
        if (method === "requestAuthorization") { resolve(value); return; }
        const available = apiMocks["$reminders.lists"]?.value;
        const allowed = (id) => typeof id === "string" && (selectedLists === null || selectedLists.has(id)) && (!ArrayIsArray(available) || available.some((item) => item?.id === id));
        if (method === "lists") {
          if (!ArrayIsArray(value)) { reject("[mock_invalid] Reminder sources must be an array"); return; }
          resolve(value.filter((item) => allowed(item?.id)).slice(0,64)); return;
        }
        if (remindersChanged && value && ArrayIsArray(value.items)) value = { ...value, items: unbridge(reminderRows) };
        if (!value || !ArrayIsArray(value.items)) { reject("[mock_invalid] Reminder events need an items array"); return; }
        const inWindow = (item) => {
          if (item?.completed !== (reminderQuery.completed ?? false)) return false;
          const start = new DateCtor(reminderQuery.start).getTime(), end = new DateCtor(reminderQuery.end).getTime();
          const date = item.completed ? item.completedAt : item.due;
          if (typeof date !== "string") return false;
          if (!item.completed && item.hasTime === false && /^\d{4}-\d{2}-\d{2}$/.test(date)) {
            const [year, month, day] = date.split("-").map(Number);
            const midnight = new DateCtor(year, month - 1, day);
            if (midnight.getFullYear() !== year || midnight.getMonth() !== month - 1 || midnight.getDate() !== day) return false;
            const next = new DateCtor(midnight); next.setDate(next.getDate() + 1);
            return midnight.getTime() < end && next.getTime() > start;
          }
          if (!/^\d{4}-\d{2}-\d{2}T/.test(date)) return false;
          const time = new DateCtor(date).getTime();
          return Number.isFinite(time) && time >= start && time < end;
        };
        const items = value.items.filter((item) => allowed(item?.listID) && (!reminderQuery.listIDs || reminderQuery.listIDs.includes(item.listID)) && inWindow(item));
        const limit = reminderQuery.limit ?? 10;
        resolve({ ...value, items: items.slice(0, limit), status: items.length ? "ready" : "empty", truncated: value.truncated === true || items.length > limit });
      }, reject);
    });
  }
  for (const method of ["create", "update", "setCompleted"]) {
    apis.$reminders[method] = (options) => nativePromise((resolve, reject) => {
      const invalid = (message) => { throw new Error(`[invalid_options] ${message}`); };
      try {
        if (!remindersDeclared() || !config.manifest?.permissions?.includes("remindersWrite") || !actionMode || timelineProjection || liveActivityPresentation) {
          reject("[permission_denied] Declare reminders and remindersWrite and invoke a declared action"); return;
        }
        const input = bridgeDictionary(options ?? {}, 0), fields = method === "create" ? ["requestID", "listID", "title", "due", "priority"] : method === "update" ? ["requestID", "listID", "id", "title", "due", "priority"] : ["requestID", "listID", "id", "completed"];
        if (ObjectKeys(input).some((key) => !fields.includes(key))) invalid("Unknown mutation option");
        if (typeof input.requestID !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(input.requestID)) invalid("A canonical request UUID is required");
        const validList = (id) => typeof id === "string" && id.length > 0 && utf8ByteLength(id) <= 256;
        const validID = (id) => typeof id === "string" && id.length > 0 && utf8ByteLength(id) <= 2048 && !/[\p{Cc}\p{Cf}]/u.test(id);
        if (!validList(input.listID) || (method !== "create" && !validID(input.id))) invalid("One listID and an existing reminder ID are required");
        if (method === "create" && input.title === undefined) invalid("A title is required");
        if (input.title !== undefined && (typeof input.title !== "string" || !input.title.trim() || utf8ByteLength(input.title) > 1024 || /[\p{Cc}\p{Cf}]/u.test(input.title))) invalid("Invalid title");
        if (input.due !== undefined && input.due !== null && !reminderDate(input.due)) invalid("Invalid due date");
        if (input.priority !== undefined && (!Number.isInteger(input.priority) || input.priority < 0 || input.priority > 9)) invalid("Invalid priority");
        if (method === "setCompleted" && typeof input.completed !== "boolean") invalid("completed must be Boolean");
        if (method === "update" && !["title", "due", "priority"].some((field) => input[field] !== undefined)) invalid("An update requires changed fields");
        if (++dataQueries > contract.maximumDataQueries) { reject("[query_limit] Too many system data operations"); return; }
        if (!apis.$reminders.isAvailable()) { reject("[unavailable] Reminder is unavailable"); return; }
        if (apis.$reminders.authorizationStatus() !== "authorized" || !reminderSelectionValid || (selectedLists !== null && !selectedLists.has(input.listID))) { reject("[permission_denied] Allow reminders access and select the list"); return; }
        const available = apiMocks["$reminders.lists"]?.value;
        if (!ArrayIsArray(available) || !available.some((item) => item?.id === input.listID)) invalid("The selected list is unavailable");
        const mock = apiMocks[`$reminders.${method}`];
        if (mock && Object.prototype.hasOwnProperty.call(mock, "error")) { reject(StringCtor(mock.error)); return; }
        const now = new DateCtor().getTime() / 1000;
        if ((reminderStateInput !== undefined && reminderStateInput?.formatVersion !== 1) || !ArrayIsArray(reminderReceipts) || reminderReceipts.length > 128 || utf8ByteLength(JSONStringify(reminderReceipts)) > 65536 || reminderReceipts.some((entry) => !entry || ObjectKeys(entry).some((key) => !["requestID", "fingerprint", "listID", "createdAt", "state", "id"].includes(key)) || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(entry.requestID) || !/^[0-9a-f]{64}$/.test(entry.fingerprint) || !validList(entry.listID) || typeof entry.createdAt !== "number" || !Number.isFinite(entry.createdAt) || entry.createdAt < 0 || !["prepared", "completed"].includes(entry.state) || (entry.state === "prepared" ? entry.id !== undefined : !validID(entry.id))) || new Set(reminderReceipts.map((entry) => entry.requestID)).size !== reminderReceipts.length) { reject("[write_history_invalid] Reminder write history could not be validated"); return; }
        if (!ArrayIsArray(reminderRows) || reminderRows.length > 1000 || new Set(reminderRows.map((row) => row?.id)).size !== reminderRows.length || reminderRows.some((row) => !row || !validID(row.id) || !validList(row.listID) || typeof row.title !== "string" || utf8ByteLength(row.title) > 1024 || typeof row.completed !== "boolean" || !Number.isInteger(row.priority) || row.priority < 0 || row.priority > 9)) { reject("[mock_invalid] Reminder state needs valid unique items"); return; }
        const identity = { kind: method, listID: input.listID };
        for (const key of ["id", "title", "due", "priority", "completed"]) if (input[key] !== undefined) identity[key] = input[key];
        if (method === "create" && identity.priority === undefined) identity.priority = 0;
        const fingerprint = reminderHash(JSONStringify(Object.fromEntries(ObjectKeys(identity).sort().map((key) => [key, identity[key]]))));
        for (let i = reminderReceipts.length - 1; i >= 0; i--) if (reminderReceipts[i].state === "completed" && now - reminderReceipts[i].createdAt > 7 * 86400) reminderReceipts.splice(i, 1);
        const previous = reminderReceipts.find((receipt) => receipt.requestID === input.requestID);
        if (previous) {
          if (previous.fingerprint !== fingerprint || previous.listID !== input.listID) { reject("[request_conflict] This requestID belongs to a different operation"); return; }
          if (previous.state !== "completed") { reject("[outcome_unknown] Inspect Reminders before creating another request"); return; }
          resolve({ id: previous.id, listID: previous.listID, status: "applied", replayed: true }); return;
        }
        if (reminderReceipts.length >= 128) { reject("[write_history_full] Reminder write history has reached its bound"); return; }
        let row;
        if (method === "create") {
          if (reminderRows.length >= 1000) { reject("[mock_limit] Reminder preview state is limited to 1000 items"); return; }
          row = { id: `mock.reminder.${input.requestID}`, listID: input.listID, title: input.title, due: input.due ?? null, hasTime: typeof input.due === "string" && input.due.includes("T"), priority: input.priority ?? 0, completed: false, completedAt: null };
        } else {
          const prior = reminderRows.find((item) => item.id === input.id && item.listID === input.listID);
          if (!prior) invalid("The reminder is unavailable in the selected list");
          row = { ...prior };
          if (input.title !== undefined) row.title = input.title;
          if (input.priority !== undefined) row.priority = input.priority;
          if (input.due !== undefined) { row.due = input.due; row.hasTime = typeof input.due === "string" && input.due.includes("T"); }
          if (input.completed !== undefined) { row.completed = input.completed; row.completedAt = input.completed ? new DateCtor().toISOString() : null; }
        }
        const receipt = { requestID: input.requestID, fingerprint, listID: input.listID, createdAt: now, state: fixtures.remindersCommitUncertain === true ? "prepared" : "completed", ...(fixtures.remindersCommitUncertain === true ? {} : { id: row.id }) };
        if (utf8ByteLength(JSONStringify([...reminderReceipts, { ...receipt, state: "completed", id: "x".repeat(2048) }])) > 65536) { reject("[write_history_full] Reminder write history has reached its bound"); return; }
        if (method === "create") reminderRows.push(row); else reminderRows[reminderRows.findIndex((item) => item.id === row.id)] = row;
        reminderReceipts.push(receipt); remindersChanged = true;
        if (receipt.state === "prepared") { reject("[outcome_unknown] The write may have been applied. Inspect the mock state before retrying."); return; }
        resolve({ id: row.id, listID: row.listID, status: "applied", replayed: false });
      } catch (error) { reject(StringCtor(error.message ?? error)); }
    });
  }
  apis.$fetch = apis.fetch;
  apis.console = apis.$console;
  apis.Promise = global.Promise;

  for (const name of ObjectKeys(apis)) {
    Object.defineProperty(global, name, { value: apis[name], writable: true, configurable: true, enumerable: false });
  }

  function evaluate(code) {
    try {
      host.evaluateScript(code);
      return true;
    } catch (error) {
      exceptionInfo = describeException(error);
      signal();
      return false;
    }
  }

  function finish(state, extra) {
    let error = null;
    let tree = null;
    if (extra.error) error = extra.error;
    else if (state.exceptionInfo !== null) error = { kind: "scriptException", message: state.exceptionInfo };
    else if (state.rootResolutionError) error = state.rootResolutionError;
    else if (!state.resultElement) error = { kind: "scriptError", message: "Transform result is not Element : nil" };
    else {
      const validation = validateElementTree(state.resultElement);
      if (validation) error = { kind: validation.kind, message: validation.message };
      else tree = encodeElement(state.resultElement);
    }
    return JSONStringify({ tree, error, logs, diagnostics, ...(actionMode ? { mockState: { storage: Object.fromEntries(storage), remindersState: { formatVersion: 1, items: reminderRows, receipts: reminderReceipts } } } : {}) });
  }

  return {
    run(javaScript, timeoutMilliseconds) {
      let done = false;
      const complete = (extra) => {
        if (done) return;
        done = true;
        host.finish(finish(snapshot ?? { resultElement, rootResolutionError, exceptionInfo }, extra));
      };

      const supportJS = host.supportScript("util.js");
      if (supportJS === null) { complete({ error: { kind: "internalError", message: "scriptwidget not found" } }); return; }
      evaluate(supportJS);

      if (javaScript.includes("moment(") || javaScript.includes("moment.")) {
        const momentJS = host.supportScript("moment.min.js");
        if (momentJS !== null) evaluate(momentJS);
      }
      evaluate(javaScript);

      const main = global.$main;
      if (main === undefined) { complete({ error: { kind: "undefinedRender", message: "$main() is not defined" } }); return; }
      if (/\bPromise\s*(\.|\()/.test(javaScript) || /new\s+Promise\b/.test(javaScript)) {
        diagnostic("warning", "compat.promise", "The native runtime replaces the global Promise with a then-only shim; new Promise, Promise.all, .catch, and .finally may fail on iPhone.");
      }

      signalWaiter = () => host.defer(() => complete({}));
      try {
        const returned = main.call(undefined);
        if (actionMode) {
          returned.then(() => {
            resultElement = new ScriptWidgetRuntimeElement("text", null, ["Action completed"]);
            signal();
          }, (error) => { exceptionInfo = describeException(error); signal(); });
        }
      } catch (error) {
        exceptionInfo = describeException(error);
        signal();
      }
      if (!actionMode && !javaScript.includes("$render")) {
        resultElement = new ScriptWidgetRuntimeElement("text", null, ["#UI Not Found#"]);
        signal();
      }
      if (signalled) { signalWaiter(); return; }
      host.timeout(timeoutMilliseconds, () => complete({
        error: { kind: "resourceLimit", message: "Script exceeded the 5-second execution limit" },
      }));
    },
  };
}
