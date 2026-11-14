package com.everettjf.scriptwidget.core.surfaces

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AutomationTest {
    private val token = "0123456789abcdef0123456789abcdef"

    private fun rejects(failure: AutomationFailure, block: () -> Unit) {
        try {
            block()
            fail("expected $failure")
        } catch (error: AutomationRejected) {
            assertEquals(failure, error.failure)
        }
    }

    @Test fun aRunRequestNeedsAPackageAnActionAndAToken() {
        val request = Automation.parse("run", mapOf("package" to "Counter", "action" to "increment", "token" to token))
        assertEquals("Counter", request.packageName)
        assertEquals("increment", request.action)
        assertNull(request.value)
        assertEquals(token, request.token)
        rejects(AutomationFailure.INVALID_REQUEST) { Automation.parse("run", mapOf("package" to "Counter", "token" to token)) }
        rejects(AutomationFailure.INVALID_REQUEST) { Automation.parse("run", mapOf("action" to "increment", "token" to token)) }
        rejects(AutomationFailure.INVALID_REQUEST) { Automation.parse("run", mapOf("package" to "Counter", "action" to "increment")) }
        rejects(AutomationFailure.INVALID_REQUEST) { Automation.parse("run", mapOf("package" to "Counter", "action" to "", "token" to token)) }
    }

    @Test fun aValueIsABooleanWrittenAsText() {
        fun value(text: String) = Automation.parse("run", mapOf("package" to "P", "action" to "a", "token" to token, "value" to text)).value
        assertEquals(true, value("true")); assertEquals(true, value("ON")); assertEquals(true, value("1"))
        assertEquals(false, value("false")); assertEquals(false, value("off")); assertEquals(false, value("0"))
        rejects(AutomationFailure.INVALID_REQUEST) { value("maybe") }
    }

    @Test fun aRefreshMayNameAPackageButNeverAnAction() {
        val all = Automation.parse("refresh", mapOf("token" to token, "action" to "increment", "value" to "true"))
        assertNull(all.packageName); assertNull(all.action); assertNull(all.value)
        assertEquals("Counter", Automation.parse("refresh", mapOf("token" to token, "package" to "Counter")).packageName)
        rejects(AutomationFailure.INVALID_REQUEST) { Automation.parse("refresh", emptyMap()) }
    }

    @Test fun overlongFieldsControlCharactersAndUnknownCommandsAreRefused() {
        rejects(AutomationFailure.INVALID_REQUEST) { Automation.parse("run", mapOf("package" to "x".repeat(129), "action" to "a", "token" to token)) }
        rejects(AutomationFailure.INVALID_REQUEST) { Automation.parse("run", mapOf("package" to "P\u0000", "action" to "a", "token" to token)) }
        rejects(AutomationFailure.INVALID_REQUEST) { Automation.parse("run", mapOf("package" to "P", "action" to "a\n", "token" to token)) }
        rejects(AutomationFailure.INVALID_REQUEST) { Automation.parse("eval", mapOf("package" to "P", "action" to "a", "token" to token)) }
    }

    @Test fun tokensAreRandomHexAndCompareExactly() {
        val first = Automation.newToken()
        val second = Automation.newToken()
        assertTrue(Automation.isValidToken(first))
        assertEquals(32, first.length)
        assertNotEquals(first, second)
        assertTrue(Automation.tokensMatch(first, first))
        assertFalse(Automation.tokensMatch(first, second))
        assertFalse(Automation.tokensMatch(first, first.dropLast(1)))
        assertFalse(Automation.tokensMatch(first, first.uppercase().takeIf { it != first } ?: "x"))
        assertFalse(Automation.tokensMatch(first, null))
        assertFalse(Automation.tokensMatch(first, ""))
    }

    @Test fun aMissingOrMalformedStoredTokenMatchesNothing() {
        assertFalse(Automation.tokensMatch(null, null))
        assertFalse(Automation.tokensMatch(null, ""))
        assertFalse(Automation.tokensMatch("", ""))
        assertFalse(Automation.tokensMatch("short", "short"))
        assertFalse(Automation.isValidToken("0123456789ABCDEF0123456789ABCDEF"))
        assertFalse(Automation.isValidToken("g123456789abcdef0123456789abcdef"))
    }

    @Test fun theLimiterAllowsThirtyRequestsAMinute() {
        val limiter = AutomationLimiter()
        for (index in 0 until 30) assertTrue("request $index", limiter.allow(1_000L + index))
        assertFalse(limiter.allow(1_100L))
        assertFalse(limiter.allow(60_999L))
        assertTrue(limiter.allow(61_000L))
        assertFalse(limiter.allow(61_000L))
    }

    @Test fun automationRunsOnlyDeclaredActions() {
        val surfaces = PackageSurfaces(listOf(DeclaredAction("increment", "Add one", null, "plus", "increment")), emptyList(), hasStoragePermission = true)
        val plan = ActionPlanner.plan(surfaces, "increment", ActionPlanner.SOURCE_AUTOMATION, null, null)
        assertEquals("increment", plan.actionID)
        assertNull(plan.callFunction)
        assertEquals("automation", plan.environments["action-source"])
        assertEquals("true", ActionPlanner.plan(surfaces, "increment", ActionPlanner.SOURCE_AUTOMATION, true, null).environments["action-value"])
        try {
            ActionPlanner.plan(surfaces, "anyFunction", ActionPlanner.SOURCE_AUTOMATION, null, null)
            fail("an undeclared action must be refused")
        } catch (error: ActionRejected) {
            assertEquals(ActionFailure.ACTION_NOT_FOUND, error.failure)
        }
    }
}
