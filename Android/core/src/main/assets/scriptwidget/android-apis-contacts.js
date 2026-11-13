// $contacts for Android: the contacts the user picked in the app.
// Policy is enforced in Kotlin (ContactsModule).
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  if (!(bridge.job.supportedAPIs ?? []).includes("$contacts")) return;
  const { nativePromise } = helpers;

  apis.$contacts = {
    selected: () => nativePromise((resolve, reject) => bridge.callAsync("contacts.selected", {}, resolve, reject)),
  };
});
