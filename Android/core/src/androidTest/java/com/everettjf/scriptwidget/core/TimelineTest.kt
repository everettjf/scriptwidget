package com.everettjf.scriptwidget.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.core.runtime.IntlBridge
import com.everettjf.scriptwidget.core.runtime.SharedScripts
import com.everettjf.scriptwidget.core.runtime.TimelinePlanner
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import java.time.Instant

@RunWith(AndroidJUnit4::class)
class TimelineTest {
    private val planner = TimelinePlanner(SharedScripts(InstrumentationRegistry.getInstrumentation().targetContext))
    private fun manifest(times: String, zone: String? = "America/Los_Angeles") =
        JSONObject("""{"timeline":{"dailyTimes":$times${if (zone != null) ",\"timeZone\":\"$zone\"" else ""}}}""")
    private fun at(text: String) = Instant.parse(text).toEpochMilli()

    @After fun reset() { IntlBridge.timeZoneOverride = null }

    @Test fun reportsTheCurrentSlotAndTheNextTransition() {
        // 2026-03-10 15:30 UTC is 08:30 in Los Angeles (daylight time): the 06:00 slot, next change at 12:00 local.
        val state = planner.state(manifest("""["06:00","12:00","18:00","22:00"]"""), at("2026-03-10T15:30:00Z"))!!
        assertEquals("0", state.environments["timeline-slot"])
        assertEquals("false", state.environments["timeline-is-projection"])
        assertEquals("America/Los_Angeles", state.environments["timeline-time-zone"])
        assertEquals(at("2026-03-10T19:00:00Z"), state.nextTransitionMilliseconds)
    }

    @Test fun beforeTheFirstTimeOfTheDayTheLastSlotStillApplies() {
        val state = planner.state(manifest("""["06:00","22:00"]"""), at("2026-03-10T10:00:00Z"))!! // 03:00 local
        assertEquals("1", state.environments["timeline-slot"])
        assertEquals(at("2026-03-10T13:00:00Z"), state.nextTransitionMilliseconds)
    }

    @Test fun usesTheDeviceZoneWhenNoneIsDeclared() {
        IntlBridge.timeZoneOverride = "Asia/Shanghai"
        val state = planner.state(manifest("""["09:00"]""", zone = null), at("2026-03-10T00:30:00Z"))!! // 08:30 in Shanghai
        assertEquals("Asia/Shanghai", state.environments["timeline-time-zone"])
        assertEquals(at("2026-03-10T01:00:00Z"), state.nextTransitionMilliseconds)
    }

    @Test fun packagesWithoutAValidScheduleHaveNoTimeline() {
        assertNull(planner.state(JSONObject("{}")))
        assertNull(planner.state(manifest("""["25:00"]""")))
        assertNull(planner.state(manifest("""["06:00"]""", zone = "Not/AZone")))
    }
}
