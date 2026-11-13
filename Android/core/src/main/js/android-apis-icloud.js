// $icloud for Android: JSON documents kept as immutable revisions in the
// store the user connected in the app. The store lives in a sync folder the
// user chose, not in iCloud; the script-facing contract is the same.
// Policy is enforced in Kotlin (CloudJsonModule).
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$icloud")) return;
  const { nativePromise, bridgeDictionary } = helpers;

  // Anything but a plain object reaches Kotlin as a missing value and is rejected there.
  const plainObject = (raw) => {
    try { if (raw !== null && typeof raw === "object" && !Array.isArray(raw)) return bridgeDictionary(raw, 0); } catch { return null; }
    return null;
  };
  const text = (raw) => (typeof raw === "string" ? raw : null);
  const write = (operation) => (name, value, expectedRevision) => nativePromise((resolve, reject) => {
    bridge.callAsync(operation, { name: text(name), value: plainObject(value), expectedRevision: text(expectedRevision) }, resolve, reject);
  });

  apis.$icloud = {
    readJSON: (name) => nativePromise((resolve, reject) => bridge.callAsync("icloud.readJSON", { name: text(name) }, resolve, reject)),
    writeJSON: write("icloud.writeJSON"),
    resolveJSON: write("icloud.resolveJSON"),
    sync: () => nativePromise((resolve, reject) => bridge.callAsync("icloud.sync", {}, resolve, reject)),
    status: () => nativePromise((resolve, reject) => bridge.callAsync("icloud.status", {}, resolve, reject)),
  };
});
