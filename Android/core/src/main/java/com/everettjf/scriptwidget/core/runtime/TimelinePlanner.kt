package com.everettjf.scriptwidget.core.runtime

import com.everettjf.scriptwidget.core.js.JsHost
import com.everettjf.scriptwidget.core.js.JsThread
import com.everettjf.scriptwidget.core.js.QuickJs
import org.json.JSONObject

/** The current timeline entry of a package and when the next one starts. */
class TimelineState(val environments: Map<String, String>, val nextTransitionMilliseconds: Long?) {
    fun nextTimelineTransitionOrNull(): Long? = nextTransitionMilliseconds
}

/**
 * Evaluates a package's `timeline.dailyTimes` schedule with the planner
 * shared with iOS and the web preview (Web/preview-engine/src/timeline.js),
 * so slots, time zones and daylight-saving rules agree on every platform.
 *
 * iOS hands WidgetKit pre-rendered future entries. Android wakes at the next
 * transition and runs the script again as the current entry instead.
 */
class TimelinePlanner(private val scripts: SharedScripts) {
    /** Returns null when the manifest declares no schedule or the schedule is invalid. */
    fun state(manifest: JSONObject?, nowMilliseconds: Long = System.currentTimeMillis()): TimelineState? {
        val schedule = manifest?.optJSONObject("timeline") ?: return null
        // A plan stays correct until its next transition, so widgets that refresh often reuse it.
        val key = schedule.toString() + "|" + IntlBridge.defaultTimeZone()
        synchronized(cache) {
            cache[key]?.takeIf { nowMilliseconds >= it.from && nowMilliseconds < it.until }?.let { return it.state }
        }
        val state = evaluate(schedule, nowMilliseconds) ?: return null
        val until = minOf(state.nextTransitionMilliseconds ?: Long.MAX_VALUE, nowMilliseconds + 3_600_000)
        synchronized(cache) {
            if (cache.size >= 32) cache.clear()
            cache[key] = Cached(state, nowMilliseconds, until)
        }
        return state
    }

    private class Cached(val state: TimelineState, val from: Long, val until: Long)
    private val cache = HashMap<String, Cached>()

    private fun evaluate(schedule: JSONObject, nowMilliseconds: Long): TimelineState? {
        val plan = runCatching {
            JsThread.run("scriptwidget-timeline") {
                // A small context: the planner needs Intl and the prepare bundle, not Babel.
                QuickJs(JsHost { operation, payload -> IntlBridge.call(operation, payload) }, memoryLimitBytes = 32L * 1024 * 1024).use { engine ->
                    engine.setDeadline(6000)
                    engine.evaluate(scripts.text("android-host.js"), "android-host.js")
                    engine.evaluate("globalThis.TextEncoder = class { encode(text) { return new Uint8Array(unescape(encodeURIComponent(String(text))).split('').map(function (c) { return c.charCodeAt(0); })); } };", "prelude.js")
                    engine.evaluate(scripts.text("prepare.js"), "prepare.js")
                    engine.evaluate(
                        "globalThis.__swPlan = function (schedule, now, zone) { var time = Number(now);" +
                            " return JSON.stringify(__swPrepareBundle.buildTimelinePlan(JSON.parse(schedule), new Date(time), new Date(time + 3600000), zone)); };",
                        "timeline-driver.js",
                    )
                    JSONObject(engine.call("__swPlan", schedule.toString(), nowMilliseconds.toString(), IntlBridge.defaultTimeZone())!!)
                }
            }
        }.onFailure { android.util.Log.w("ScriptWidget", "Timeline schedule could not be evaluated: ${it.message?.take(300)}") }.getOrNull() ?: return null
        val entries = plan.optJSONArray("entries") ?: return null
        val current = entries.optJSONObject(0)?.optJSONObject("environments") ?: return null
        val environments = HashMap<String, String>()
        current.keys().forEach { environments[it] = current.optString(it) }
        val next = entries.optJSONObject(1)?.optString("date")?.takeIf { it.isNotEmpty() }?.let { runCatching { java.time.Instant.parse(it).toEpochMilli() }.getOrNull() }
        return TimelineState(environments, next)
    }
}
