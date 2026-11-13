// Native implementations of the runtime APIs for Android. The shared kernel
// builds preview simulations first; this file replaces the ones Android backs
// with real data. Policy is enforced again in Kotlin: package code can alter
// JavaScript built-ins, so nothing here is a security boundary.
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  const { nativePromise, nativeString, bridgeValue, bridgeDictionary, unbridge, storageJSON } = helpers;
  const JSONParse = JSON.parse;
  const JSONStringify = JSON.stringify;

  // MARK: - $storage (package-scoped, persisted by Kotlin)

  const text = (value) => nativeString(value);
  apis.$storage = {
    getString(key) {
      const entry = bridge.call("storage.get", { key: text(key) });
      return entry && entry.t === "s" ? entry.v : "";
    },
    setString(key, value) {
      return bridge.call("storage.set", { key: text(key), t: "s", v: text(value) }) === true;
    },
    getJSON(key) {
      const entry = bridge.call("storage.get", { key: text(key) });
      if (!entry || entry.t !== "j") return {};
      try { const value = JSONParse(entry.v); return value !== null && typeof value === "object" && !Array.isArray(value) ? value : {}; } catch { return {}; }
    },
    setJSON(key, value) {
      const json = storageJSON(value);
      if (json === null) return false;
      return bridge.call("storage.set", { key: text(key), t: "j", v: json.encoded }) === true;
    },
    compareAndSetString(key, expected, value) {
      return bridge.call("storage.cas", { key: text(key), t: "s", expected: text(expected), v: text(value) }) === true;
    },
    compareAndSetJSON(key, expected, value) {
      const before = storageJSON(expected), next = storageJSON(value);
      if (before === null || next === null) return false;
      return bridge.call("storage.cas", { key: text(key), t: "j", expected: before.encoded, v: next.encoded }) === true;
    },
    remove(key) { return bridge.call("storage.remove", { key: text(key) }) === true; },
    keys() { return bridge.call("storage.keys") ?? []; },
    clear() { return bridge.call("storage.clear") === true; },
  };

  // MARK: - fetch and $http

  function request(method, url, params, metadata) {
    const urlString = text(url);
    const bridged = params === undefined || params === null ? null : bridgeValue(params, 0);
    return nativePromise((resolve, reject) => {
      const job = { method, url: urlString, metadata: metadata === true };
      if (bridged && typeof bridged === "object") {
        if (bridged.headers && typeof bridged.headers === "object") {
          job.headers = {};
          for (const name of Object.keys(bridged.headers)) if (typeof bridged.headers[name] === "string") job.headers[name] = bridged.headers[name];
        }
        if (typeof bridged.body === "string") job.body = bridged.body;
        else if (bridged.body && typeof bridged.body === "object") { job.body = JSONStringify(bridged.body); job.jsonBody = true; }
        if (typeof bridged.timeoutInterval === "number") job.timeout = bridged.timeoutInterval;
        if (bridged.responseType === "base64") job.base64 = true;
      }
      bridge.callAsync("http.request", job, resolve, reject);
    });
  }
  apis.fetch = (url, params) => request("GET", url, params, false);
  apis.$http = {
    get: (url, params) => request("GET", url, params, false),
    getResponse: (url, params) => request("GET", url, params, true),
    post: (url, params) => request("POST", url, params, false),
    put: (url, params) => request("PUT", url, params, false),
    patch: (url, params) => request("PATCH", url, params, false),
    delete: (url, params) => request("DELETE", url, params, false),
  };
});
