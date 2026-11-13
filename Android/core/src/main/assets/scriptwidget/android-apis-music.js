// $music for Android: a read-only snapshot of the active media session.
// Policy is enforced in Kotlin (MusicModule).
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$music")) return;
  const { nativePromise } = helpers;

  apis.$music = {
    isAvailable() { return bridge.call("music.isAvailable") === true; },
    authorizationStatus() { return String(bridge.call("music.authorizationStatus") ?? "undeclared"); },
    current: () => nativePromise((resolve, reject) => bridge.callAsync("music.current", {}, resolve, reject)),
  };
});
