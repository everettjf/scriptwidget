package com.everettjf.scriptwidget.core.system

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import java.io.File
import java.nio.file.Files

const val OWNER = "11111111-1111-4111-8111-111111111111"
const val OTHER_OWNER = "22222222-2222-4222-8222-222222222222"
const val REQUEST_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const val REQUEST_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

/** 2026-11-12T12:00:00Z */
const val NOW = 1_794_484_800_000L

fun temporaryDirectory(): File = Files.createTempDirectory("scriptwidget-system").toFile().also { it.deleteOnExit() }

/** A call context with an adjustable query budget, defaulting to an installed Package 2.0 widget on Runtime 1.6. */
fun context(
    permissions: Set<String> = emptySet(), installation: String = OWNER, hasManifest: Boolean = true, domains: List<String> = emptyList(),
    runtime: String? = "1.6", action: Boolean = false, projection: Boolean = false, liveActivity: Boolean = false,
    queries: Int = CallContext.MAXIMUM_DATA_QUERIES, network: Int = CallContext.MAXIMUM_NETWORK_REQUESTS, active: () -> Boolean = { true },
): CallContext {
    var usedQueries = 0
    var usedNetwork = 0
    return CallContext(installation, hasManifest, permissions, domains, runtime, action, projection, liveActivity,
        dataQuery = { ++usedQueries <= queries }, networkRequest = { ++usedNetwork <= network }, active = active)
}

/** Asserts that [block] rejects with a message starting with `[code]`. */
fun assertRejects(code: String, block: () -> Unit) {
    try { block() } catch (error: SystemReject) {
        assertEquals("[$code]", "[" + SystemLog.code(error.message.orEmpty()) + "]")
        return
    }
    fail("Expected a [$code] rejection")
}

/** Asserts the exact rejection message. */
fun assertRejectsWith(message: String, block: () -> Unit) {
    try { block() } catch (error: SystemReject) { assertEquals(message, error.message); return }
    fail("Expected rejection: $message")
}

fun grantsIn(directory: File, vararg capabilities: String, installation: String = OWNER): SystemAccessGrants =
    SystemAccessGrants(PrivateFile(File(directory, "grants.json"), 128 * 1024)).also { grants -> capabilities.forEach { grants.set(installation, it, true) } }

fun promptsIn(directory: File): PermissionPrompts = PermissionPrompts(PrivateFile(File(directory, "prompts.json"), 4096))
