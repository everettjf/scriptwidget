// $alarms for Android: the app's own alarm and timer records, presented as
// notifications when they fire. Policy is enforced in Kotlin (AlarmsModule).
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$alarms")) return;
  const { nativePromise, bridgeDictionary } = helpers;

  const control = (operation) => (raw) => nativePromise((resolve, reject) => {
    bridge.callAsync(operation, { key: typeof raw === "string" ? raw : null }, resolve, reject);
  });

  apis.$alarms = {
    status: () => nativePromise((resolve, reject) => bridge.callAsync("alarms.status", {}, resolve, reject)),
    pending: () => nativePromise((resolve, reject) => bridge.callAsync("alarms.pending", {}, resolve, reject)),
    schedule: (raw) => nativePromise((resolve, reject) => {
      let options = null;
      // Anything but a plain object reaches Kotlin as missing options and is rejected there.
      try { if (raw !== null && typeof raw === "object" && !Array.isArray(raw)) options = bridgeDictionary(raw, 0); } catch { options = null; }
      bridge.callAsync("alarms.schedule", { options }, resolve, reject);
    }),
    cancel: control("alarms.cancel"),
    stop: control("alarms.stop"),
    pause: control("alarms.pause"),
    resume: control("alarms.resume"),
  };
});
