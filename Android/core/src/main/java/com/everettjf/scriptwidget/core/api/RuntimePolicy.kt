package com.everettjf.scriptwidget.core.api

import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import org.json.JSONObject
import java.net.InetAddress

/**
 * Manifest and presentation rules that every native API checks before doing
 * work. JavaScript-side checks exist only for early, readable errors.
 */
object RuntimePolicy {
    fun manifest(request: ExecutionRequest): JSONObject? = request.prepared.manifest

    fun hasPermission(request: ExecutionRequest, permission: String): Boolean {
        val permissions = manifest(request)?.optJSONArray("permissions") ?: return false
        for (index in 0 until permissions.length()) if (permissions.optString(index) == permission) return true
        return false
    }

    /** Future timeline entries are rendered ahead of time and must not read live data or write. */
    fun isTimelineProjection(request: ExecutionRequest): Boolean =
        (request.environments["timeline-is-projection"] ?: request.prepared.timelineEnvironment["timeline-is-projection"]) == "true"

    fun isLiveActivity(request: ExecutionRequest): Boolean = request.environments["widget-size"] in setOf("live-activity", "dynamic-island")

    /** True while a declared action runs; writes to system data require it. */
    fun isAction(request: ExecutionRequest): Boolean = request.prepared.actionID != null

    /** Same textual rule as ScriptWidgetFetchPolicy.validationError. */
    fun blockedHostName(host: String): Boolean {
        val value = host.lowercase()
        val parts = value.split('.')
        return value == "localhost" || value == "::1" || value.endsWith(".local") ||
            value.startsWith("127.") || value.startsWith("10.") || value.startsWith("192.168.") ||
            (parts.size == 4 && parts[0] == "172" && (parts[1].toIntOrNull() ?: -1) in 16..31)
    }

    /** Rejects addresses that are not on the public Internet, whatever name resolved to them. */
    fun blockedAddress(address: InetAddress): Boolean {
        if (address.isLoopbackAddress || address.isAnyLocalAddress || address.isSiteLocalAddress || address.isLinkLocalAddress || address.isMulticastAddress) return true
        val bytes = address.address
        if (bytes.size == 16 && (bytes[0].toInt() and 0xFE) == 0xFC) return true // IPv6 unique local fc00::/7
        if (bytes.size == 4) {
            val first = bytes[0].toInt() and 0xFF
            val second = bytes[1].toInt() and 0xFF
            if (first == 0 || (first == 100 && second in 64..127) || (first == 169 && second == 254)) return true // this-network, CGNAT, link-local
        }
        return false
    }

    fun hostMatches(host: String, declarations: List<String>): Boolean {
        val value = host.lowercase()
        return declarations.any { declaration ->
            val domain = declaration.lowercase()
            if (domain.startsWith("*.")) { val suffix = domain.substring(2); value != suffix && value.endsWith(".$suffix") } else value == domain
        }
    }

    /** Package 2.0: `network` permission and a matching `networkDomains` entry. Legacy packages without a manifest are allowed. */
    fun packageAllowsHost(request: ExecutionRequest, host: String): Boolean {
        if (!request.prepared.hasManifest) return true
        val manifest = manifest(request) ?: return false
        if (!hasPermission(request, "network")) return false
        val domains = manifest.optJSONArray("networkDomains") ?: return false
        return hostMatches(host, List(domains.length()) { domains.optString(it) })
    }
}
