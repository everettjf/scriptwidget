// $services for Android: GitHub only. The token never enters JavaScript;
// policy is enforced in Kotlin (ServicesModule).
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$services")) return;
  const { nativePromise, nativeString } = helpers;

  const query = (operation) => (rawService) => nativePromise((resolve, reject) => {
    let service = "";
    try { service = nativeString(rawService); } catch { service = ""; }
    bridge.callAsync(operation, { service }, resolve, reject);
  });
  apis.$services = { status: query("services.status"), profile: query("services.profile") };
});
