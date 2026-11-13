// Android side of the Studio editor bridge. The editor bundle talks to
// WKWebViewJavascriptBridge on Apple platforms; this provides the same two
// methods on top of the Android JavaScript interface.
(function () {
  "use strict";
  var native = window.ScriptWidgetAndroid;
  if (!native || window.WKWebViewJavascriptBridge) return;
  var handlers = {};
  var callbacks = {};
  var sequence = 0;
  window.webkit = window.webkit || {};
  window.WKWebViewJavascriptBridge = {
    registerHandler: function (name, handler) { handlers[name] = handler; },
    callHandler: function (name, data, callback) {
      var id = null;
      if (typeof callback === "function") { sequence += 1; id = "c" + sequence; callbacks[id] = callback; }
      native.postMessage(JSON.stringify({ name: name, data: data === undefined ? null : data, id: id }));
    },
    // Called by Kotlin with the reply to a callHandler message.
    _respond: function (id, response) {
      var callback = callbacks[id];
      delete callbacks[id];
      if (callback) callback(response);
    },
    // Called by Kotlin to run a handler the editor registered.
    _invoke: function (name, data, replyID) {
      var handler = handlers[name];
      if (!handler) { native.reply(replyID, JSON.stringify({ result: "failed", message: "No handler for " + name })); return; }
      handler(data, function (response) { native.reply(replyID, JSON.stringify(response === undefined ? {} : response)); });
    },
  };
})();
