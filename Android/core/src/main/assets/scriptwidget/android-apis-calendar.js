// $calendar for Android: reads, plus create/update for events the widget
// created. Policy is enforced in Kotlin (CalendarModule).
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$calendar")) return;
  const { nativePromise, bridgeDictionary } = helpers;

  const plainObject = (raw) => raw !== null && typeof raw === "object" && !Array.isArray(raw);
  const read = (operation) => (raw) => nativePromise((resolve, reject) => {
    const payload = { options: null };
    if (raw !== undefined && raw !== null) {
      try {
        if (!plainObject(raw)) throw new Error("Unknown calendar query option");
        payload.options = bridgeDictionary(raw, 0);
      } catch (error) { payload.invalid = `[invalid_options] ${String(error?.message ?? "Invalid calendar query")}`.slice(0, 200); }
    }
    bridge.callAsync(operation, payload, resolve, reject);
  });
  const write = (operation) => (raw) => nativePromise((resolve, reject) => {
    let options = {};
    // A value that is not a plain object reaches Kotlin as an unknown field and is rejected there.
    try { options = plainObject(raw) ? bridgeDictionary(raw, 0) : { invalid: true }; } catch { options = { invalid: true }; }
    bridge.callAsync(operation, { options }, resolve, reject);
  });

  apis.$calendar = {
    isAvailable() { return bridge.call("calendar.isAvailable") === true; },
    authorizationStatus() { return String(bridge.call("calendar.authorizationStatus") ?? "undeclared"); },
    requestAuthorization: () => nativePromise((resolve, reject) => bridge.callAsync("calendar.requestAuthorization", {}, resolve, reject)),
    calendars: () => nativePromise((resolve, reject) => bridge.callAsync("calendar.calendars", {}, resolve, reject)),
    events: read("calendar.events"),
    create: write("calendar.create"),
    update: write("calendar.update"),
  };
});
