// Android side of the Studio editor bridge. The editor bundle talks to
// WKWebViewJavascriptBridge on Apple platforms; this provides the same two
// methods on top of the Android JavaScript interface.
(function () {
  "use strict";
  var native = window.ScriptWidgetAndroid;
  if (!native || window.WKWebViewJavascriptBridge) return;
  // What only Android has, for the editor's completion, hover and attribute
  // check (Editor/editorfe/src/hostAPI.js reads this as data). The roles are
  // ThemeColors.roleNames and the attributes of <list> are those of the
  // "tag@android list" line in AiJsxSurfaceData; StudioHostApiTest fails when
  // either list here differs from the Kotlin one.
  var materialRoles = [
    "primary", "onPrimary", "primaryContainer", "onPrimaryContainer",
    "secondary", "onSecondary", "secondaryContainer", "onSecondaryContainer",
    "tertiary", "onTertiary", "tertiaryContainer", "onTertiaryContainer",
    "background", "onBackground", "surface", "onSurface", "surfaceVariant", "onSurfaceVariant",
    "surfaceContainerLowest", "surfaceContainerLow", "surfaceContainer", "surfaceContainerHigh", "surfaceContainerHighest",
    "outline", "outlineVariant"
  ];
  var listAttributes = {
    "spacing": { type: "number", documentation: "Gap between rows. Default 0." }
  };
  window.ScriptWidgetHostAPI = {
    components: {
      list: {
        documentation: "Android only. A vertical stack that scrolls inside the widget; its children are the rows, at most 100. On iPhone the tag is unknown, so check $system.platform() first.",
        children: true,
        properties: listAttributes
      }
    },
    colors: materialRoles.map(function (role) { return "material." + role; })
  };
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
