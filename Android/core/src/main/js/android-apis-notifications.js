// $notifications for Android: local notifications scheduled with inexact
// alarms. Policy is enforced in Kotlin (NotificationsModule).
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$notifications")) return;
  const { nativePromise, bridgeDictionary } = helpers;

  apis.$notifications = {
    status: () => nativePromise((resolve, reject) => bridge.callAsync("notifications.status", {}, resolve, reject)),
    pending: () => nativePromise((resolve, reject) => bridge.callAsync("notifications.pending", {}, resolve, reject)),
    schedule: (raw) => nativePromise((resolve, reject) => {
      let options = null;
      // Anything but a plain object reaches Kotlin as missing options and is rejected there.
      try { if (raw !== null && typeof raw === "object" && !Array.isArray(raw)) options = bridgeDictionary(raw, 0); } catch { options = null; }
      bridge.callAsync("notifications.schedule", { options }, resolve, reject);
    }),
    cancel: (raw) => nativePromise((resolve, reject) => {
      bridge.callAsync("notifications.cancel", { key: typeof raw === "string" ? raw : null }, resolve, reject);
    }),
  };
});
