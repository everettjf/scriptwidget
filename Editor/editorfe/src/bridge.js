import { StudioMessage, studioEnvelope } from "./studioProtocol.js";

export function connectNativeBridge(onConnected) {
  if (window.WKWebViewJavascriptBridge) {
    onConnected(window.WKWebViewJavascriptBridge);
    return;
  }

  if (window.WKWVJBCallbacks) {
    window.WKWVJBCallbacks.push(onConnected);
    return;
  }

  if (window.webkit?.messageHandlers?.iOS_Native_InjectJavascript) {
    window.WKWVJBCallbacks = [onConnected];
    window.webkit.messageHandlers.iOS_Native_InjectJavascript.postMessage(null);
  }
}

export function callNative(bridge, type, payload = {}, documentID = null, callback = () => {}) {
  if (!bridge) {
    callback({ result: "unavailable" });
    return;
  }
  bridge.callHandler(type, studioEnvelope(type, payload, documentID), callback);
}

export function announceReady(bridge) {
  const payload = { capabilities: ["jsx", "format", "search", "completion", "diagnostics"] };
  callNative(bridge, StudioMessage.ready, payload);
}
