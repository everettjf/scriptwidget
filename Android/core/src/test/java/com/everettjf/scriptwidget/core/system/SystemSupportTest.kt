package com.everettjf.scriptwidget.core.system

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class SystemSupportTest {
    @Test fun isoDatesNeedATimeZoneAndRealFields() {
        assertEquals(NOW, IsoDates.parse("2026-11-12T12:00:00Z"))
        assertEquals(NOW, IsoDates.parse("2026-11-12T04:00:00.000-08:00"))
        assertNull(IsoDates.parse("2026-11-12T12:00:00"))
        assertNull(IsoDates.parse("2026-11-12"))
        assertNull(IsoDates.parse("2026-02-30T12:00:00Z"))
        assertNull(IsoDates.parse("2026-11-12T25:00:00Z"))
        assertEquals("2026-11-12T12:00:00Z", IsoDates.format(NOW + 999))
        assertEquals("2026-11-12T12:00:00.250Z", IsoDates.formatFractional(NOW + 250))
    }

    @Test fun optionTextRejectsBlankControlAndOversizedValues() {
        assertEquals("Focus", SystemOptions.text("Focus"))
        assertRejects("invalid_options") { SystemOptions.text("   ") }
        assertRejects("invalid_options") { SystemOptions.text("a\u0007b") }
        assertRejects("invalid_options") { SystemOptions.text("a​b") }
        assertRejects("invalid_options") { SystemOptions.text("é".repeat(129), 256) }
        assertRejects("invalid_options") { SystemOptions.text(12) }
        assertEquals("é".repeat(128), SystemOptions.text("é".repeat(128), 256))
    }

    @Test fun optionNumbersRejectBooleansAndFractions() {
        assertEquals(7, SystemOptions.integer(7, 0..23))
        assertRejects("invalid_options") { SystemOptions.integer(7.5, 0..23) }
        assertRejects("invalid_options") { SystemOptions.integer(true, 0..23) }
        assertRejects("invalid_options") { SystemOptions.integer(24, 0..23) }
        assertRejects("invalid_options") { SystemOptions.number(Double.NaN, 0.0..1.0) }
        assertRejects("invalid_options") { SystemOptions.boolean(1) }
    }

    @Test fun optionFieldsAreClosedAndBounded() {
        SystemOptions.fields(JSONObject().put("key", "a"), setOf("key"))
        assertRejects("invalid_options") { SystemOptions.fields(JSONObject().put("other", 1), setOf("key")) }
        assertRejects("invalid_options") { SystemOptions.fields(JSONObject().put("key", "x".repeat(17000)), setOf("key")) }
        assertTrue(SystemOptions.validKey("reading_1-a"))
        assertFalse(SystemOptions.validKey("a b"))
        assertFalse(SystemOptions.validKey("x".repeat(65)))
        assertFalse(SystemOptions.validRequestID(REQUEST_A.uppercase()))
    }

    @Test fun fingerprintIgnoresKeyOrderButNotValues() {
        val first = Canonical.fingerprint("create", JSONObject().put("a", 1).put("b", "x"))
        val reordered = Canonical.fingerprint("create", JSONObject().put("b", "x").put("a", 1))
        assertEquals(first, reordered)
        assertNotEquals(first, Canonical.fingerprint("create", JSONObject().put("a", 2).put("b", "x")))
        assertNotEquals(first, Canonical.fingerprint("update", JSONObject().put("a", 1).put("b", "x")))
        assertTrue(Regex("^[0-9a-f]{64}$").matches(first))
    }

    @Test fun runtimeRequirementComparesMajorAndMinor() {
        assertTrue(SystemGate.supportsRuntime("1.6", "1.6"))
        assertTrue(SystemGate.supportsRuntime("1.6", "1.10"))
        assertTrue(SystemGate.supportsRuntime("1.6", "2.0"))
        assertFalse(SystemGate.supportsRuntime("1.6", "1.5"))
        assertFalse(SystemGate.supportsRuntime("1.6", null))
        assertFalse(SystemGate.supportsRuntime("1.6", "latest"))
    }

    @Test fun gateOrderIsPermissionThenReadOnlyThenGrantThenBudget() {
        val directory = temporaryDirectory()
        val granted = grantsIn(directory, "notifications")
        val none = SystemAccessGrants(PrivateFile(File(directory, "empty.json"), 1024))
        // 1. Package permission, installed owner, manifest and runtime version.
        assertRejects("permission_denied") { SystemGate.check(context(emptySet(), action = true), "notifications", true, granted) }
        assertRejects("permission_denied") { SystemGate.check(context(setOf("notifications"), installation = "My Widget", action = true), "notifications", true, granted) }
        assertRejects("permission_denied") { SystemGate.check(context(setOf("notifications"), hasManifest = false, action = true), "notifications", true, granted) }
        assertRejects("permission_denied") { SystemGate.check(context(setOf("notifications"), runtime = "1.5", action = true), "notifications", true, granted) }
        // 2. Read-only presentations and writes outside an action, before the grant is even looked at.
        assertRejects("read_only") { SystemGate.check(context(setOf("notifications")), "notifications", true, none) }
        assertRejects("read_only") { SystemGate.check(context(setOf("notifications"), action = true, projection = true), "notifications", false, none) }
        assertRejects("read_only") { SystemGate.check(context(setOf("notifications"), liveActivity = true), "notifications", false, none) }
        // 3. Native grant.
        assertRejects("permission_denied") { SystemGate.check(context(setOf("notifications"), action = true), "notifications", true, none) }
        // 4. Query budget, only after everything else passed.
        assertRejects("query_limit") { SystemGate.check(context(setOf("notifications"), action = true, queries = 0), "notifications", true, granted) }
        assertRejects("permission_denied") { SystemGate.check(context(setOf("notifications"), action = true, queries = 0), "notifications", true, none) }
        SystemGate.check(context(setOf("notifications"), action = true), "notifications", true, granted)
        SystemGate.check(context(setOf("notifications")), "notifications", false, granted)
    }

    @Test fun eightDataQueriesPerExecution() {
        val shared = context(setOf("notifications"))
        val grants = grantsIn(temporaryDirectory(), "notifications")
        repeat(8) { SystemGate.check(shared, "notifications", false, grants) }
        assertRejects("query_limit") { SystemGate.check(shared, "notifications", false, grants) }
        assertEquals("[query_limit] System operation could not complete. Existing user data is preserved.", SystemServiceError.QUERY_LIMIT.message)
    }

    @Test fun grantsAreBoundToTheInstallationAndFailClosed() {
        val directory = temporaryDirectory()
        val file = PrivateFile(File(directory, "grants.json"), 128 * 1024)
        val grants = SystemAccessGrants(file)
        assertFalse(grants.granted(OWNER, "notifications"))
        assertTrue(grants.set(OWNER, "notifications", true))
        assertTrue(grants.granted(OWNER, "notifications"))
        assertFalse(grants.granted(OTHER_OWNER, "notifications"))
        assertFalse(grants.granted(OWNER, "calendarWrite"))
        assertFalse(grants.set(OWNER, "contacts", true))
        assertFalse(grants.set("not-an-installation", "notifications", true))
        assertTrue(grants.set(OWNER, "notifications", false))
        assertFalse(grants.granted(OWNER, "notifications"))
        file.write("{\"formatVersion\":1,\"grants\":{\"$OWNER\":[\"everything\"]}}")
        assertRejects("unavailable") { grants.granted(OWNER, "notifications") }
        file.write("not json")
        assertRejects("unavailable") { grants.granted(OWNER, "notifications") }
        assertEquals(emptySet<String>(), grants.capabilities(OWNER))
    }

    private fun ledger(directory: File, clock: () -> Long = { NOW }) = MutationLedger(PrivateFile(File(directory, "receipts.json"), MutationLedger.MAXIMUM_BYTES)) { clock() }
    private val fingerprintA = "a".repeat(64)
    private val fingerprintB = "b".repeat(64)

    @Test fun ledgerReplaysACompletedRequestWithoutWritingAgain() {
        val ledger = ledger(temporaryDirectory())
        var writes = 0
        val first = ledger.perform(REQUEST_A, fingerprintA, "cal", {}) { commit -> commit(); writes += 1; "event-1" }
        val second = ledger.perform(REQUEST_A, fingerprintA, "cal", {}) { commit -> commit(); writes += 1; "event-2" }
        assertEquals("event-1", first.id); assertFalse(first.replayed)
        assertEquals("event-1", second.id); assertTrue(second.replayed)
        assertEquals(1, writes)
    }

    @Test fun ledgerRejectsAReusedRequestWithOtherArguments() {
        val ledger = ledger(temporaryDirectory())
        ledger.perform(REQUEST_A, fingerprintA, "cal", {}) { commit -> commit(); "event-1" }
        val conflict = runCatching { ledger.perform(REQUEST_A, fingerprintB, "cal", {}) { commit -> commit(); "event-2" } }.exceptionOrNull() as MutationLedger.LedgerException
        assertEquals(MutationLedger.Failure.CONFLICT, conflict.failure)
        val otherList = runCatching { ledger.perform(REQUEST_A, fingerprintA, "other", {}) { commit -> commit(); "event-2" } }.exceptionOrNull() as MutationLedger.LedgerException
        assertEquals(MutationLedger.Failure.CONFLICT, otherList.failure)
        assertEquals(SystemServiceError.REQUEST_CONFLICT, MutationLedger.error(MutationLedger.Failure.CONFLICT))
    }

    @Test fun ledgerKeepsAPreparedReceiptWhenTheWriteFailsAfterCommit() {
        val ledger = ledger(temporaryDirectory())
        val failed = runCatching { ledger.perform(REQUEST_A, fingerprintA, "cal", {}) { commit -> commit(); throw IllegalStateException("provider died") } }.exceptionOrNull() as MutationLedger.LedgerException
        assertEquals(MutationLedger.Failure.UNCERTAIN, failed.failure)
        var writes = 0
        val retry = runCatching { ledger.perform(REQUEST_A, fingerprintA, "cal", {}) { commit -> commit(); writes += 1; "event-1" } }.exceptionOrNull() as MutationLedger.LedgerException
        assertEquals(MutationLedger.Failure.UNCERTAIN, retry.failure)
        assertEquals(0, writes)
        assertEquals(SystemServiceError.OUTCOME_UNKNOWN, MutationLedger.error(MutationLedger.Failure.UNCERTAIN))
    }

    @Test fun ledgerLeavesNoReceiptWhenValidationFailsBeforeCommit() {
        val ledger = ledger(temporaryDirectory())
        var allowed = false
        assertRejects("permission_denied") { ledger.perform(REQUEST_A, fingerprintA, "cal", { if (!allowed) throw SystemServiceError.PERMISSION_DENIED.reject() }) { commit -> commit(); "event-1" } }
        allowed = true
        val receipt = ledger.perform(REQUEST_A, fingerprintA, "cal", { }) { commit -> commit(); "event-1" }
        assertFalse(receipt.replayed)
    }

    @Test fun ledgerExpiresCompletedReceiptsAfterSevenDaysAndIsBounded() {
        val directory = temporaryDirectory()
        var now = NOW
        val ledger = ledger(directory) { now }
        ledger.perform(REQUEST_A, fingerprintA, "cal", {}) { commit -> commit(); "event-1" }
        now += 7 * 86_400_000L + 1000
        val again = ledger.perform(REQUEST_A, fingerprintA, "cal", {}) { commit -> commit(); "event-2" }
        assertFalse(again.replayed)
        assertEquals("event-2", again.id)

        val full = ledger(temporaryDirectory())
        repeat(MutationLedger.MAXIMUM_ENTRIES) { index ->
            full.perform("%08x-0000-4000-8000-000000000000".format(index), fingerprintA, "cal", {}) { commit -> commit(); "e$index" }
        }
        val overflow = runCatching { full.perform(REQUEST_B, fingerprintA, "cal", {}) { commit -> commit(); "late" } }.exceptionOrNull() as MutationLedger.LedgerException
        assertEquals(MutationLedger.Failure.FULL, overflow.failure)
        assertEquals(SystemServiceError.LIMIT_EXCEEDED, MutationLedger.error(MutationLedger.Failure.FULL))
    }

    @Test fun ledgerRejectsACorruptFile() {
        val directory = temporaryDirectory()
        File(directory, "receipts.json").writeText("{\"formatVersion\":1,\"entries\":[{\"requestID\":\"x\"}]}")
        val corrupt = runCatching { ledger(directory).perform(REQUEST_A, fingerprintA, "cal", {}) { commit -> commit(); "event" } }.exceptionOrNull() as MutationLedger.LedgerException
        assertEquals(MutationLedger.Failure.CORRUPT, corrupt.failure)
        assertEquals(SystemServiceError.UNAVAILABLE, MutationLedger.error(MutationLedger.Failure.CORRUPT))
    }

    private fun execution(manifest: JSONObject?, hasManifest: Boolean, actionID: String? = null, environments: Map<String, String> = emptyMap()) =
        com.everettjf.scriptwidget.core.runtime.ExecutionRequest(
            com.everettjf.scriptwidget.core.runtime.PreparedPackage("", emptyMap(), manifest, hasManifest, actionID, emptyMap()),
            com.everettjf.scriptwidget.core.runtime.MemoryPackageFiles(emptyMap()), environments = environments, packageID = OWNER)

    @Test fun callContextReadsTheManifestAndSharesTheExecutionBudgets() {
        val manifest = JSONObject("{\"permissions\":[\"services\",\"network\"],\"networkDomains\":[\"api.github.com\"],\"minimumRuntimeVersion\":\"1.6\"}")
        val request = execution(manifest, true, actionID = "save")
        val context = CallContext.from(request)
        assertTrue(context.isInstalled); assertTrue(context.declares("services")); assertFalse(context.declares("calendar"))
        assertTrue(context.allowsHost("api.github.com")); assertFalse(context.allowsHost("example.com"))
        assertTrue(context.isAction); assertFalse(context.isTimelineProjection); assertEquals("1.6", context.minimumRuntimeVersion)
        // The eight-query budget belongs to the execution, whichever API or context object spends it.
        repeat(5) { assertTrue(context.consumeDataQuery()) }
        val second = CallContext.from(request)
        repeat(3) { assertTrue(second.consumeDataQuery()) }
        assertFalse(context.consumeDataQuery()); assertFalse(second.consumeDataQuery())
        assertTrue(context.isActive)
        request.session.finished = true
        assertFalse(context.isActive)

        assertTrue(CallContext.from(execution(null, false, environments = mapOf("timeline-is-projection" to "true"))).isTimelineProjection)
        assertTrue(CallContext.from(execution(null, false, environments = mapOf("widget-size" to "live-activity"))).isLiveActivity)
    }

    @Test fun aPresentButUnreadableManifestDeclaresNothingAndIsNotLegacy() {
        val malformed = CallContext.from(execution(null, hasManifest = true))
        assertTrue(malformed.hasManifest)
        assertFalse(malformed.declares("location"))
        assertFalse(LocationPolicy.packageAllows(malformed))
        val legacy = CallContext.from(execution(null, hasManifest = false))
        assertTrue(LocationPolicy.packageAllows(legacy))
        assertFalse(legacy.declares("calendar"))
    }

    @Test fun logLinesCarryOnlyTheOperationAndCode() {
        val lines = ArrayList<String>()
        val previous = SystemLog.sink
        SystemLog.sink = { lines += it }
        try {
            SystemLog.call("calendar.events", SystemLog.code("[permission_denied] Allow calendar access in ScriptWidget"))
            SystemLog.call("location.current", SystemLog.code("Location request timed out"))
        } finally { SystemLog.sink = previous }
        assertEquals(listOf("calendar.events -> permission_denied", "location.current -> error"), lines)
    }

    @Test fun privateFileRefusesOversizedContentAndLinks() {
        val directory = temporaryDirectory()
        val file = PrivateFile(File(directory, "small.json"), 8)
        assertNull(file.read())
        assertFalse(file.write("123456789"))
        assertTrue(file.write("12345678"))
        assertEquals("12345678", file.read())
        File(directory, "small.json").writeText("123456789")
        assertTrue(runCatching { file.read() }.exceptionOrNull() is PrivateFile.Unreadable)
        val target = File(directory, "target.json").also { it.writeText("{}") }
        val link = File(directory, "link.json")
        java.nio.file.Files.createSymbolicLink(link.toPath(), target.toPath())
        assertTrue(runCatching { PrivateFile(link, 1024).read() }.exceptionOrNull() is PrivateFile.Unreadable)
    }
}
