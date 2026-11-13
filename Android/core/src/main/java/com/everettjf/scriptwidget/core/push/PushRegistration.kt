package com.everettjf.scriptwidget.core.push

import com.everettjf.scriptwidget.core.api.RuntimePolicy
import org.json.JSONObject
import java.net.URI

/** One package's push registration: where to send the device token and for which channel. */
class PushTarget(val packageID: String, val channel: String, val url: URI, val networkDomains: List<String>)

/**
 * Rules for Package 2.0 `pushUpdates`, the Android counterpart of
 * `ScriptWidgetPushRegistration` on iOS. A package gets push-triggered
 * refresh only when its manifest declares the registration URL's host:
 * the token is posted over HTTPS to a public host inside the package's
 * network allowlist, and nowhere else.
 */
object PushRegistration {
    const val MAXIMUM_BODY_BYTES = 8 * 1024

    /** The registration target of a manifest, or null when it declares none or the declaration is not allowed. */
    fun target(manifest: JSONObject?): PushTarget? {
        val push = manifest?.optJSONObject("pushUpdates") ?: return null
        val packageID = manifest.optString("id")
        val channel = push.optString("channel")
        val url = runCatching { URI(push.optString("registrationURL")) }.getOrNull() ?: return null
        if (packageID.isEmpty() || channel.isEmpty() || !allowedURL(url)) return null
        val permissions = manifest.optJSONArray("permissions")?.let { array -> List(array.length()) { array.optString(it) } }.orEmpty()
        val domains = manifest.optJSONArray("networkDomains")?.let { array -> List(array.length()) { array.optString(it) } }.orEmpty()
        if ("network" !in permissions || !RuntimePolicy.hostMatches(url.host, domains)) return null
        return PushTarget(packageID, channel, url, domains)
    }

    /** HTTPS, a public host name, no credentials. */
    fun allowedURL(url: URI): Boolean {
        val host = url.host ?: return false
        return url.scheme?.lowercase() == "https" && url.userInfo == null && host.isNotEmpty() && !RuntimePolicy.blockedHostName(host)
    }

    /** A redirect may only go to another HTTPS host the package declares. */
    fun allowedRedirect(target: PushTarget, redirected: URI): Boolean =
        allowedURL(redirected) && RuntimePolicy.hostMatches(redirected.host, target.networkDomains)

    /**
     * The JSON body posted to the registration URL. `token`, `packageID` and
     * `channel` match iOS; `platform` tells the server which push service the
     * token belongs to (iOS sends a WidgetKit token and no platform field).
     * Returns null when the body would exceed the size limit.
     */
    fun body(target: PushTarget, token: String): ByteArray? {
        val bytes = JSONObject().put("token", token).put("packageID", target.packageID).put("channel", target.channel).put("platform", "android")
            .toString().toByteArray()
        return bytes.takeIf { it.size <= MAXIMUM_BODY_BYTES }
    }

    /** True when a received push names this manifest's package and channel. */
    fun matches(manifest: JSONObject?, packageID: String?, channel: String?): Boolean {
        val target = target(manifest) ?: return false
        return target.packageID == packageID && target.channel == channel
    }
}
