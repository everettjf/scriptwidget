// $weather for Android: MET Norway forecast for supplied coordinates.
// Policy is enforced in Kotlin (WeatherModule).
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$weather")) return;
  const { nativePromise, bridgeDictionary } = helpers;

  apis.$weather = {
    forecast: (raw) => nativePromise((resolve, reject) => {
      // Anything but a plain object reaches Kotlin as an unknown field and is rejected there.
      let options = { invalid: true };
      try { if (raw !== null && typeof raw === "object" && !Array.isArray(raw)) options = bridgeDictionary(raw, 0); } catch { options = { invalid: true }; }
      bridge.callAsync("weather.forecast", { options }, resolve, reject);
    }),
  };
});
