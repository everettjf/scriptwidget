package com.everettjf.scriptwidget.core.surfaces

import com.everettjf.scriptwidget.core.PlatformSupport
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SurfaceManifestTest {
    private val refresh = """{"id":"refresh","title":"Refresh Dashboard","systemImage":"arrow.clockwise","function":"refreshWidget"}"""
    private val focus = """{"id":"focus","title":"Set Focus","systemImage":"timer","function":"setFocus"}"""

    private fun manifest(actions: String? = "[$refresh,$focus]", controls: String? = null, permissions: String = """["storage"]"""): JSONObject {
        val json = JSONObject("""{"formatVersion":2,"id":"com.example.test","name":"Test","permissions":$permissions}""")
        if (actions != null) json.put("actions", org.json.JSONArray(actions))
        if (controls != null) json.put("controls", org.json.JSONArray(controls))
        return json
    }

    private fun rejects(code: String, manifest: JSONObject) {
        try {
            SurfaceManifest.parse(manifest)
            fail("expected $code")
        } catch (error: SurfaceManifestException) {
            assertEquals(code, error.code)
        }
    }

    @Test fun readsTheDocumentedExample() {
        val controls = """[
            {"id":"refresh","type":"button","title":"Refresh","systemImage":"arrow.clockwise","actionID":"refresh"},
            {"id":"focus","type":"toggle","title":"Focus","subtitle":"Deep work","systemImage":"timer","actionID":"focus","stateKey":"focus.enabled"}]"""
        val surfaces = SurfaceManifest.parse(manifest(controls = controls))
        assertEquals(listOf("refresh", "focus"), surfaces.actions.map { it.id })
        assertEquals("refreshWidget", surfaces.action("REFRESH")?.function)
        assertTrue(surfaces.hasStoragePermission)
        val toggle = surfaces.control("focus")!!
        assertTrue(toggle.isToggle)
        assertEquals("focus.enabled", toggle.stateKey)
        assertEquals("Deep work", toggle.subtitle)
        assertEquals("focus", toggle.actionID)
        assertNull(toggle.function)
        assertFalse(surfaces.control("refresh")!!.isToggle)
        assertNull(surfaces.action("missing"))
        assertNull(surfaces.action(null))
    }

    @Test fun aPackageWithoutAManifestOrSurfacesDeclaresNothing() {
        assertTrue(SurfaceManifest.parse(null).actions.isEmpty())
        val empty = SurfaceManifest.parse(manifest(actions = null, permissions = "[]"))
        assertTrue(empty.actions.isEmpty() && empty.controls.isEmpty())
        assertFalse(empty.hasStoragePermission)
        assertTrue(SurfaceManifest.parse(manifest(actions = null).put("actions", JSONObject.NULL)).actions.isEmpty())
    }

    @Test fun actionLimitsAreEnforced() {
        val sixteen = (1..16).joinToString(",") { """{"id":"a$it","title":"A","systemImage":"star","function":"run"}""" }
        assertEquals(16, SurfaceManifest.parse(manifest("[$sixteen]")).actions.size)
        rejects("too_many_actions", manifest("""[$sixteen,{"id":"a17","title":"A","systemImage":"star","function":"run"}]"""))
        rejects("duplicate_actions", manifest("""[$refresh,{"id":"Refresh","title":"A","systemImage":"star","function":"run"}]"""))
        rejects("invalid_action_id", manifest("""[{"id":"-bad","title":"A","systemImage":"star","function":"run"}]"""))
        rejects("invalid_action_id", manifest("""[{"id":"${"a".repeat(65)}","title":"A","systemImage":"star","function":"run"}]"""))
        rejects("invalid_action_title", manifest("""[{"id":"a","title":"   ","systemImage":"star","function":"run"}]"""))
        rejects("invalid_action_title", manifest("""[{"id":"a","title":"${"t".repeat(41)}","systemImage":"star","function":"run"}]"""))
        rejects("invalid_action_description", manifest("""[{"id":"a","title":"A","description":"${"d".repeat(161)}","systemImage":"star","function":"run"}]"""))
        rejects("invalid_action_image", manifest("""[{"id":"a","title":"A","systemImage":"star fill","function":"run"}]"""))
        rejects("invalid_action_function", manifest("""[{"id":"a","title":"A","systemImage":"star","function":"run()"}]"""))
        rejects("invalid_action_function", manifest("""[{"id":"a","title":"A","systemImage":"star","function":"a.b"}]"""))
    }

    @Test fun titlesAreCountedInUserPerceivedCharacters() {
        // Forty family emoji are 40 characters although they are 440 UTF-16 units.
        val family = "👨‍👩‍👧‍👦"
        assertEquals(1, SurfaceManifest.characters(family))
        val action = JSONObject().put("id", "a").put("title", family.repeat(40)).put("systemImage", "star").put("function", "run")
        assertEquals(1, SurfaceManifest.parse(manifest(actions = null).put("actions", org.json.JSONArray().put(action))).actions.size)
        action.put("title", family.repeat(41))
        rejects("invalid_action_title", manifest(actions = null).put("actions", org.json.JSONArray().put(action)))
    }

    @Test fun malformedShapesFailClosed() {
        rejects("malformed_actions", manifest(actions = null).put("actions", "refresh"))
        rejects("malformed_actions", manifest("""["refresh"]"""))
        rejects("malformed_actions", manifest("""[{"id":"a","title":"A","systemImage":"star"}]"""))
        rejects("malformed_actions", manifest("""[{"id":7,"title":"A","systemImage":"star","function":"run"}]"""))
        rejects("unknown_actions_fields", manifest("""[{"id":"a","title":"A","systemImage":"star","function":"run","shell":"rm"}]"""))
        rejects("malformed_controls", manifest(controls = """[{"id":"c","type":"slider","title":"C","systemImage":"star","actionID":"refresh"}]"""))
        rejects("malformed_controls", manifest(controls = """[{"id":"c","type":"button","title":"C","systemImage":"star","actionID":3}]"""))
        rejects("unknown_controls_fields", manifest(controls = """[{"id":"c","type":"button","title":"C","systemImage":"star","actionID":"refresh","url":"x"}]"""))
    }

    @Test fun controlRulesAreEnforced() {
        val eight = (1..8).joinToString(",") { """{"id":"c$it","type":"button","title":"C","systemImage":"star","actionID":"refresh"}""" }
        assertEquals(8, SurfaceManifest.parse(manifest(controls = "[$eight]")).controls.size)
        rejects("too_many_controls", manifest(controls = """[$eight,{"id":"c9","type":"button","title":"C","systemImage":"star","actionID":"refresh"}]"""))
        rejects("duplicate_controls", manifest(controls = """[{"id":"c","type":"button","title":"C","systemImage":"star","actionID":"refresh"},{"id":"C","type":"button","title":"C","systemImage":"star","actionID":"refresh"}]"""))
        rejects("missing_control_action", manifest(controls = """[{"id":"c","type":"button","title":"C","systemImage":"star","actionID":"gone"}]"""))
        rejects("missing_control_action", manifest(controls = """[{"id":"c","type":"button","title":"C","systemImage":"star"}]"""))
        rejects("ambiguous_control_action", manifest(controls = """[{"id":"c","type":"button","title":"C","systemImage":"star","actionID":"refresh","action":"run"}]"""))
        rejects("invalid_control_action", manifest(controls = """[{"id":"c","type":"button","title":"C","systemImage":"star","action":"run now"}]"""))
        rejects("invalid_control_title", manifest(controls = """[{"id":"c","type":"button","title":"","systemImage":"star","actionID":"refresh"}]"""))
        rejects("invalid_control_subtitle", manifest(controls = """[{"id":"c","type":"button","title":"C","subtitle":"${"s".repeat(81)}","systemImage":"star","actionID":"refresh"}]"""))
        rejects("invalid_control_image", manifest(controls = """[{"id":"c","type":"button","title":"C","systemImage":"","actionID":"refresh"}]"""))
        rejects("button_control_state", manifest(controls = """[{"id":"c","type":"button","title":"C","systemImage":"star","actionID":"refresh","stateKey":"k"}]"""))
    }

    @Test fun togglesNeedAStateKeyAndTheStoragePermission() {
        val toggle = """[{"id":"c","type":"toggle","title":"C","systemImage":"star","actionID":"focus","stateKey":"focus.enabled"}]"""
        assertEquals(1, SurfaceManifest.parse(manifest(controls = toggle)).controls.size)
        rejects("control_storage", manifest(controls = toggle, permissions = """["network"]"""))
        rejects("invalid_control_state", manifest(controls = """[{"id":"c","type":"toggle","title":"C","systemImage":"star","actionID":"focus"}]"""))
        rejects("invalid_control_state", manifest(controls = """[{"id":"c","type":"toggle","title":"C","systemImage":"star","actionID":"focus","stateKey":"../escape"}]"""))
        assertTrue(SurfaceManifest.isValidStateKey("focus.enabled_1-a"))
        assertFalse(SurfaceManifest.isValidStateKey(".hidden"))
        assertFalse(SurfaceManifest.isValidStateKey("a".repeat(129)))
        assertFalse(SurfaceManifest.isValidStateKey(null))
    }

    @Test fun legacyControlFunctionsRemainReadable() {
        val surfaces = SurfaceManifest.parse(manifest(actions = null, controls = """[{"id":"old","type":"button","title":"Old","systemImage":"star","action":"runOld"}]"""))
        assertEquals("runOld", surfaces.control("old")?.function)
        assertNull(surfaces.control("old")?.actionID)
    }

    @Test fun controlsAreNoLongerReportedAsUnsupported() {
        val controls = """[{"id":"c","type":"button","title":"C","systemImage":"star","actionID":"refresh"}]"""
        assertTrue(PlatformSupport.unsupported(manifest(controls = controls), null).isEmpty())
        assertEquals(1, PlatformSupport.unsupported(manifest().put("pushUpdates", JSONObject().put("channel", "a")), null).size)
    }
}
