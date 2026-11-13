// $health for Android: read-only Health Connect data. Policy, bounds and
// aggregation are enforced in Kotlin (HealthModule). Nothing is cached here.
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$health")) return;
  const { nativePromise, bridgeDictionary } = helpers;

  const plainObject = (raw) => raw !== null && typeof raw === "object" && !Array.isArray(raw);
  const reading = (operation) => () => nativePromise((resolve, reject) => bridge.callAsync(operation, {}, resolve, reject));
  // Options are optional. Anything that is not a plain, bridgeable object is
  // reported to Kotlin as invalid, so the rejection keeps its place in the policy order.
  const summary = (operation) => (raw) => nativePromise((resolve, reject) => {
    const payload = { options: null };
    if (raw !== undefined && raw !== null) {
      try {
        if (!plainObject(raw)) throw new Error("invalid");
        payload.options = bridgeDictionary(raw, 0);
      } catch { payload.invalid = true; }
    }
    bridge.callAsync(operation, payload, resolve, reject);
  });
  const history = (operation) => (raw) => nativePromise((resolve, reject) => {
    let options = {};
    // A value that is not a plain object reaches Kotlin as an unknown field and is rejected there.
    try { if (raw !== undefined && raw !== null) options = plainObject(raw) ? bridgeDictionary(raw, 0) : { invalid: true }; } catch { options = { invalid: true }; }
    bridge.callAsync(operation, { options }, resolve, reject);
  });

  apis.$health = {
    isAvailable() { return bridge.call("health.isAvailable") === true; },
    authorizationStatus() { return String(bridge.call("health.authorizationStatus") ?? "unavailable"); },
    requestAuthorization: reading("health.requestAuthorization"),
    stepCountToday: reading("health.stepCountToday"),
    activeEnergyToday: reading("health.activeEnergyToday"),
    heartRateLatest: reading("health.heartRateLatest"),
    sleepSummary: summary("health.sleepSummary"),
    activitySummary: summary("health.activitySummary"),
    workouts: summary("health.workouts"),
    dailyStatistics: history("health.dailyStatistics"),
  };
});
