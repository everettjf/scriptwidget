// $photos for Android: thumbnails of the photos the user picked in the app.
// Policy is enforced in Kotlin (PhotosModule).
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$photos")) return;
  const { nativePromise, bridgeDictionary } = helpers;

  apis.$photos = {
    isAvailable() { return bridge.call("photos.isAvailable") === true; },
    authorizationStatus() { return String(bridge.call("photos.authorizationStatus") ?? "undeclared"); },
    requestAuthorization: () => nativePromise((resolve, reject) => bridge.callAsync("photos.requestAuthorization", {}, resolve, reject)),
    items: (raw) => nativePromise((resolve, reject) => {
      const payload = { options: null };
      if (raw !== undefined && raw !== null) {
        try {
          if (typeof raw !== "object" || Array.isArray(raw)) throw new Error("invalid");
          payload.options = bridgeDictionary(raw, 0);
        } catch { payload.invalid = true; }
      }
      bridge.callAsync("photos.items", payload, resolve, reject);
    }),
  };
});
