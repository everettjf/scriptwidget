package com.everettjf.scriptwidget.ui

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * The CodeMirror-based Studio editor (the same bundle the Apple apps embed)
 * in a WebView. The page is served only from app assets under a private
 * origin; it cannot navigate elsewhere or read files.
 */
@SuppressLint("SetJavaScriptEnabled")
class StudioEditor(context: Context, private val onSave: (String) -> Boolean, private val onReady: () -> Unit = {}) {
    val webView = WebView(context)
    private val main = Handler(Looper.getMainLooper())
    private val replies = ConcurrentHashMap<String, (JSONObject) -> Unit>()
    private var documentID = ""
    private var sessionID = ""
    private var pendingDocument: Pair<String, String>? = null
    @Volatile var isReady = false
        private set

    init {
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.settings.allowFileAccess = false
        webView.settings.allowContentAccess = false
        webView.addJavascriptInterface(Bridge(), "ScriptWidgetAndroid")
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = request.url.host != HOST
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                if (request.url.host != HOST) return WebResourceResponse("text/plain", "utf-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0)))
                return serve(view.context, request.url)
            }
        }
        webView.loadUrl("https://$HOST/index.html")
    }

    private fun serve(context: Context, url: Uri): WebResourceResponse {
        val path = url.path.orEmpty().trimStart('/').ifEmpty { "index.html" }
        val missing = WebResourceResponse("text/plain", "utf-8", 404, "Not Found", emptyMap(), ByteArrayInputStream(ByteArray(0)))
        if (path.contains("..")) return missing
        return try {
            val bytes = if (path == "android-bridge.js") context.assets.open("studio/android-bridge.js").use { it.readBytes() }
            else context.assets.open("StudioEditor.bundle/$path").use { it.readBytes() }
            val body = if (path == "index.html") {
                // The bridge must exist before the editor's module script runs.
                bytes.toString(Charsets.UTF_8).replaceFirst("<head>", "<head><script src=\"./android-bridge.js\"></script>").toByteArray()
            } else bytes
            val type = when (path.substringAfterLast('.')) {
                "html" -> "text/html"; "js", "mjs" -> "text/javascript"; "css" -> "text/css"; "json" -> "application/json"
                "svg" -> "image/svg+xml"; "woff2" -> "font/woff2"; "png" -> "image/png"; else -> "application/octet-stream"
            }
            WebResourceResponse(type, "utf-8", ByteArrayInputStream(body))
        } catch (_: Exception) { missing }
    }

    /** Shows [content] as the document being edited. */
    fun open(id: String, content: String) {
        documentID = id
        sessionID = UUID.randomUUID().toString()
        if (!isReady) { pendingDocument = id to content; return }
        invoke("document.open", JSONObject().put("content", content).put("version", 0).put("readOnly", false).put("resources", org.json.JSONArray())) {}
    }

    /** Reads the current text from the editor. */
    fun content(callback: (String?) -> Unit) {
        if (!isReady) { callback(null); return }
        invoke("editor.getState", JSONObject()) { response -> callback(if (response.optString("result") == "ok") response.optString("content") else null) }
    }

    fun format() { if (isReady) invoke("editor.format", JSONObject()) {} }

    fun setTheme(dark: Boolean) { if (isReady) invoke("editor.setTheme", JSONObject().put("theme", if (dark) "dark" else "light")) {} }

    fun publishDiagnostics(message: String?) {
        if (!isReady) return
        val items = org.json.JSONArray()
        if (message != null) items.put(JSONObject().put("message", message).put("severity", "error"))
        invoke("diagnostics.publish", JSONObject().put("items", items)) {}
    }

    fun destroy() { webView.removeJavascriptInterface("ScriptWidgetAndroid"); webView.destroy() }

    private fun invoke(name: String, payload: JSONObject, reply: (JSONObject) -> Unit) {
        val replyID = UUID.randomUUID().toString()
        replies[replyID] = reply
        val envelope = JSONObject().put("protocolVersion", 1).put("type", name).put("documentID", documentID).put("sessionID", sessionID).put("payload", payload)
        main.post { webView.evaluateJavascript("window.WKWebViewJavascriptBridge._invoke(${JSONObject.quote(name)}, $envelope, ${JSONObject.quote(replyID)});", null) }
    }

    private fun respond(id: String?, response: JSONObject) {
        if (id == null) return
        main.post { webView.evaluateJavascript("window.WKWebViewJavascriptBridge._respond(${JSONObject.quote(id)}, $response);", null) }
    }

    private inner class Bridge {
        @JavascriptInterface
        fun postMessage(text: String) {
            val message = runCatching { JSONObject(text) }.getOrNull() ?: return
            val id = if (message.isNull("id")) null else message.optString("id")
            val data = message.optJSONObject("data") ?: JSONObject()
            when (message.optString("name")) {
                "studio.ready" -> main.post {
                    isReady = true
                    pendingDocument?.let { (pendingID, content) -> pendingDocument = null; open(pendingID, content) }
                    onReady()
                    respond(id, JSONObject().put("result", "ok"))
                }
                "document.save" -> {
                    val current = data.optString("documentID") == documentID && (data.isNull("sessionID") || data.optString("sessionID") == sessionID)
                    val content = data.optJSONObject("payload")?.optString("content")
                    main.post {
                        val saved = current && content != null && onSave(content)
                        respond(id, JSONObject().put("result", if (saved) "ok" else "failed"))
                    }
                }
                "document.resources" -> respond(id, JSONObject().put("result", "ok").put("documentID", documentID).put("resources", org.json.JSONArray()))
                else -> respond(id, JSONObject().put("result", "ok"))
            }
        }

        @JavascriptInterface
        fun reply(replyID: String, text: String) {
            val callback = replies.remove(replyID) ?: return
            val response = runCatching { JSONObject(text) }.getOrElse { JSONObject().put("result", "failed") }
            main.post { callback(response) }
        }
    }

    private companion object { const val HOST = "studio.scriptwidget.invalid" }
}
