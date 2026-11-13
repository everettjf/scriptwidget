// $maps for Android: the platform geocoder for supplied text and coordinates.
// Policy is enforced in Kotlin (MapsModule). snapshot has no Android
// equivalent in this release and rejects there.
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$maps")) return;
  const { nativePromise, bridgeDictionary } = helpers;

  const withOptions = (operation) => (raw) => nativePromise((resolve, reject) => {
    // Anything but a plain object reaches Kotlin as an unknown field and is rejected there.
    let options = { invalid: true };
    try { if (raw !== null && typeof raw === "object" && !Array.isArray(raw)) options = bridgeDictionary(raw, 0); } catch { options = { invalid: true }; }
    bridge.callAsync(operation, { options }, resolve, reject);
  });

  apis.$maps = {
    search: withOptions("maps.search"),
    geocode: (raw) => nativePromise((resolve, reject) => {
      bridge.callAsync("maps.geocode", { address: typeof raw === "string" ? raw : null }, resolve, reject);
    }),
    reverseGeocode: withOptions("maps.reverseGeocode"),
    snapshot: () => nativePromise((resolve, reject) => bridge.callAsync("maps.snapshot", {}, resolve, reject)),
  };
});
