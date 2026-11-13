// $documents for Android: JSON and CSV files the user imported in the app.
// Content is parsed in Kotlin (DocumentsModule) and never executed.
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$documents")) return;
  const { nativePromise } = helpers;

  const read = (operation) => (raw) => nativePromise((resolve, reject) => {
    bridge.callAsync(operation, { id: typeof raw === "string" ? raw : null }, resolve, reject);
  });

  apis.$documents = {
    list: () => nativePromise((resolve, reject) => bridge.callAsync("documents.list", {}, resolve, reject)),
    readJSON: read("documents.readJSON"),
    readCSV: read("documents.readCSV"),
  };
});
