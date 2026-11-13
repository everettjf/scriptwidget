package com.everettjf.scriptwidget.core.surfaces

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ActionPlannerTest {
    private val actions = listOf(
        DeclaredAction("refresh", "Refresh", null, "arrow.clockwise", "refreshWidget"),
        DeclaredAction("focus", "Focus", null, "timer", "setFocus"),
    )
    private val controls = listOf(
        DeclaredControl("refresh-tile", "button", "Refresh", null, "arrow.clockwise", null, "refresh", null),
        DeclaredControl("focus-tile", "toggle", "Focus", null, "timer", null, "Focus", "focus.enabled"),
        DeclaredControl("old", "button", "Old", null, "star", "runOld", null, null),
        DeclaredControl("old-toggle", "toggle", "Old", null, "star", "setOld", null, "old.on"),
    )
    private val surfaces = PackageSurfaces(actions, controls, hasStoragePermission = true)
    private val withoutStorage = PackageSurfaces(actions, controls, hasStoragePermission = false)

    private fun rejects(failure: ActionFailure, block: () -> Unit) {
        try {
            block()
            fail("expected $failure")
        } catch (error: ActionRejected) {
            assertEquals(failure, error.failure)
        }
    }

    @Test fun aShortcutRunsADeclaredActionWithTheDocumentedEnvironment() {
        val plan = ActionPlanner.plan(surfaces, "REFRESH", "shortcut", null, null)
        assertEquals("refresh", plan.actionID)
        assertNull(plan.callFunction)
        assertNull(plan.stateKey)
        assertEquals(mapOf("widget-size" to "action", "widget-param" to "", "action-source" to "shortcut", "action-id" to "refresh"), plan.environments)
    }

    @Test fun undeclaredActionsAndUnknownSourcesAreRejected() {
        rejects(ActionFailure.ACTION_NOT_FOUND) { ActionPlanner.plan(surfaces, "refreshWidget", "shortcut", null, null) }
        rejects(ActionFailure.ACTION_NOT_FOUND) { ActionPlanner.plan(surfaces, null, "widget", null, null) }
        rejects(ActionFailure.ACTION_NOT_FOUND) { ActionPlanner.plan(PackageSurfaces.EMPTY, "refresh", "widget", null, null) }
        rejects(ActionFailure.INVALID_REQUEST) { ActionPlanner.plan(surfaces, "refresh", "siri", null, null) }
        rejects(ActionFailure.INVALID_REQUEST) { ActionPlanner.plan(surfaces, "refresh", "widget", null, "refresh-tile") }
    }

    @Test fun aWidgetToggleStoresItsValueOnlyWithPermissionAndASafeKey() {
        val plan = ActionPlanner.plan(surfaces, "focus", "widget", true, null, "focus.enabled")
        assertEquals("focus.enabled", plan.stateKey)
        assertEquals(true, plan.stateValue)
        assertEquals("true", plan.environments["action-value"])
        assertEquals("true", plan.environments["control-value"])
        assertFalse(plan.environments.containsKey("control-id"))
        rejects(ActionFailure.STORAGE_DENIED) { ActionPlanner.plan(withoutStorage, "focus", "widget", true, null, "focus.enabled") }
        rejects(ActionFailure.INVALID_STATE_KEY) { ActionPlanner.plan(surfaces, "focus", "widget", true, null, "../other") }
        rejects(ActionFailure.INVALID_REQUEST) { ActionPlanner.plan(surfaces, "focus", "widget", null, null, "focus.enabled") }
        // A value without a key is passed to the action but not stored.
        val unsaved = ActionPlanner.plan(withoutStorage, "focus", "widget", false, null)
        assertNull(unsaved.stateKey)
        assertEquals("false", unsaved.environments["action-value"])
    }

    @Test fun aControlButtonRunsItsDeclaredAction() {
        val plan = ActionPlanner.plan(surfaces, null, "control", null, "refresh-tile")
        assertEquals("refresh", plan.actionID)
        assertEquals("refresh", plan.environments["action-id"])
        assertEquals("control", plan.environments["action-source"])
        assertEquals("refresh-tile", plan.environments["control-id"])
        assertFalse(plan.environments.containsKey("action-value"))
        assertEquals("refresh", ActionPlanner.plan(surfaces, "refresh", "control", null, "refresh-tile").actionID)
    }

    @Test fun aControlToggleStoresItsDeclaredKey() {
        val plan = ActionPlanner.plan(surfaces, null, "control", false, "focus-tile")
        assertEquals("focus", plan.actionID)
        assertEquals("focus.enabled", plan.stateKey)
        assertEquals(false, plan.stateValue)
        assertEquals("false", plan.environments["action-value"])
        assertEquals("false", plan.environments["control-value"])
        // The caller cannot redirect the write to another key.
        assertEquals("focus.enabled", ActionPlanner.plan(surfaces, null, "control", true, "focus-tile", "other.key").stateKey)
        rejects(ActionFailure.STORAGE_DENIED) { ActionPlanner.plan(withoutStorage, null, "control", true, "focus-tile") }
    }

    @Test fun controlRequestsMustMatchTheDeclaration() {
        rejects(ActionFailure.ACTION_NOT_FOUND) { ActionPlanner.plan(surfaces, null, "control", null, "missing") }
        rejects(ActionFailure.ACTION_NOT_FOUND) { ActionPlanner.plan(surfaces, null, "control", null, null) }
        rejects(ActionFailure.ACTION_NOT_FOUND) { ActionPlanner.plan(surfaces, "focus", "control", null, "refresh-tile") }
        rejects(ActionFailure.INVALID_REQUEST) { ActionPlanner.plan(surfaces, null, "control", true, "refresh-tile") }
        rejects(ActionFailure.INVALID_REQUEST) { ActionPlanner.plan(surfaces, null, "control", null, "focus-tile") }
        val dangling = PackageSurfaces(emptyList(), controls, true)
        rejects(ActionFailure.ACTION_NOT_FOUND) { ActionPlanner.plan(dangling, null, "control", null, "refresh-tile") }
    }

    @Test fun aLegacyControlCallsItsFunctionAsAnActionNamedAfterTheControl() {
        val plan = ActionPlanner.plan(surfaces, null, "control", null, "old")
        assertNull(plan.actionID)
        assertEquals("runOld", plan.callFunction)
        assertEquals("old", plan.environments["action-id"])
        assertEquals("old", plan.environments["control-id"])
        assertEquals("action", plan.environments["widget-size"])
        val toggle = ActionPlanner.plan(surfaces, "old-toggle", "control", true, "old-toggle")
        assertEquals("setOld", toggle.callFunction)
        assertEquals("old.on", toggle.stateKey)
        // The legacy function name is not an action other surfaces can select.
        rejects(ActionFailure.ACTION_NOT_FOUND) { ActionPlanner.plan(surfaces, "runOld", "shortcut", null, null) }
        rejects(ActionFailure.ACTION_NOT_FOUND) { ActionPlanner.plan(surfaces, "old", "shortcut", null, null) }
    }

    @Test fun storedToggleValuesFollowTheIosReading() {
        assertTrue(ActionPlanner.isOn("true"))
        assertTrue(ActionPlanner.isOn("1"))
        assertFalse(ActionPlanner.isOn("false"))
        assertFalse(ActionPlanner.isOn(""))
        assertFalse(ActionPlanner.isOn(null))
        assertFalse(ActionPlanner.isOn("TRUE"))
    }
}
