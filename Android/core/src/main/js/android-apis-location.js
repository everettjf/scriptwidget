// $location for Android. Policy is enforced in Kotlin (LocationModule); this
// file only shapes arguments and results.
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$location")) return;
  const { nativePromise, bridgeDictionary } = helpers;

  // Options that cannot be bridged are treated as absent, as the Apple bridge does.
  function options(raw) {
    if (raw === undefined || raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
    try { return bridgeDictionary(raw, 0); } catch { return null; }
  }
  const asynchronous = (operation) => (raw) => nativePromise((resolve, reject) => {
    bridge.callAsync(operation, { options: options(raw) }, resolve, reject);
  });

  apis.$location = {
    isAvailable() { return bridge.call("location.isAvailable") === true; },
    authorizationStatus() { return String(bridge.call("location.authorizationStatus") ?? "unknown"); },
    isAuthorizedForWidgetUpdates() { return bridge.call("location.isAuthorizedForWidgetUpdates") === true; },
    requestAuthorization: asynchronous("location.requestAuthorization"),
    current: asynchronous("location.current"),
  };
});
