// $dataSource for Android: Data Source Plugin 1.0 requests.
//
// Kotlin (DataSourceModule) enforces every rule: the plugin must be declared
// in widget.json, the package needs the network permission, the destination
// must be HTTPS and inside both the plugin's hosts and the package's
// networkDomains, and requests share the execution's network budget. The
// checks below only produce the same errors earlier; package code can alter
// JavaScript built-ins, so nothing here is a security boundary.
//
// This file is evaluated before android-apis.js, whose fallback replaces
// $dataSource with an "unsupported" stub when the native module is absent.
__swRegisterAPIs(function (apis, helpers, bridge) {
  "use strict";
  const { config, nativePromise, nativeString, bridgeValue, timelineProjection, liveActivityPresentation } = helpers;
  const ArrayIsArray = Array.isArray;
  const plugins = ArrayIsArray(config.manifest?.plugins) ? config.manifest.plugins : [];
  const declared = (name) => {
    for (let index = 0; index < plugins.length; index += 1) if (plugins[index] === name) return true;
    return false;
  };

  apis.$dataSource = {
    request(pluginID, operationID, parameters) {
      const plugin = nativeString(pluginID), operation = nativeString(operationID);
      // Like JavaScriptCore's [String: Any]? conversion: only a dictionary carries values.
      const bridged = parameters === undefined || parameters === null ? null : bridgeValue(parameters, 0);
      const values = bridged !== null && typeof bridged === "object" && !ArrayIsArray(bridged) ? bridged : {};
      return nativePromise((resolve, reject) => {
        if (liveActivityPresentation) { reject("[live_activity_unavailable] Live Activity presentations cannot request service data; update their state from the app"); return; }
        if (timelineProjection) { reject("[timeline_read_only] Future entries cannot make live service requests"); return; }
        if (!declared(plugin)) { reject(`Plugin ${plugin} is not declared in widget.json`); return; }
        bridge.callAsync("datasource.request", { pluginID: plugin, operationID: operation, parameters: values }, resolve, reject);
      });
    },
  };
});
