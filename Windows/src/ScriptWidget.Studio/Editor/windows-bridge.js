// Windows side of the Studio editor bridge. The editor bundle talks to
// WKWebViewJavascriptBridge on Apple platforms; this provides the same two
// methods on top of WebView2 web messages. It is injected before any script
// of the page runs.
(function () {
  "use strict";
  var host = window.chrome && window.chrome.webview;
  if (!host || window.WKWebViewJavascriptBridge) return;
  var handlers = {};
  var callbacks = {};
  var sequence = 0;
  var send = function (message) { host.postMessage(JSON.stringify(message)); };
  window.webkit = window.webkit || {};
  // The bundle is served from an https origin here, as in the Android app.
  // It tells an embedding app from the public Web Studio site by this object
  // (see isWebStudio in Editor/editorfe/src/main.js); without it the editor
  // would ask to pair with a phone.
  window.ScriptWidgetAndroid = window.ScriptWidgetAndroid || { host: "windows" };
  window.WKWebViewJavascriptBridge = {
    registerHandler: function (name, handler) { handlers[name] = handler; },
    callHandler: function (name, data, callback) {
      var id = null;
      if (typeof callback === "function") { sequence += 1; id = "c" + sequence; callbacks[id] = callback; }
      send({ kind: "call", name: name, data: data === undefined ? null : data, id: id });
    },
    // Called by the host with the reply to a callHandler message.
    _respond: function (id, response) {
      var callback = callbacks[id];
      delete callbacks[id];
      if (callback) callback(response);
    },
    // Called by the host to run a handler the editor registered.
    _invoke: function (name, data, replyID) {
      var handler = handlers[name];
      if (!handler) { send({ kind: "reply", replyID: replyID, response: { result: "failed", message: "No handler for " + name } }); return; }
      handler(data, function (response) { send({ kind: "reply", replyID: replyID, response: response === undefined ? {} : response }); });
    },
  };
})();
