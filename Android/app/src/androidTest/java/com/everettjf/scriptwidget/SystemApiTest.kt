package com.everettjf.scriptwidget

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.graphics.Bitmap
import android.net.Uri
import android.provider.CalendarContract
import androidx.core.content.FileProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.core.RunRequest
import com.everettjf.scriptwidget.core.system.CalendarSelection
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.time.Instant
import java.util.UUID

/**
 * The system data APIs against the real device services: Calendar Provider,
 * AlarmManager and the notification manager, the photo store and the
 * location snapshot. Each script renders one JSON string that the test reads.
 */
@RunWith(AndroidJUnit4::class)
class SystemApiTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val created = ArrayList<String>()
    private var calendarId: Long = -1
    private val accountName = "scriptwidget-test"

    @Before fun prepare() {
        AppServices.attach(context)
        for (permission in listOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR, Manifest.permission.POST_NOTIFICATIONS,
            Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)) {
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, permission)
        }
    }

    @After fun cleanUp() {
        created.forEach { runCatching { AppServices.library.delete(it) } }
        if (calendarId >= 0) context.contentResolver.delete(asSyncAdapter(ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, calendarId)), null, null)
        SystemModules.stores(context).calendarSelection.save(CalendarSelection(emptyList()))
    }

    private fun asSyncAdapter(uri: Uri): Uri = uri.buildUpon()
        .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
        .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
        .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL).build()

    private fun createCalendar(): Long {
        val values = ContentValues().apply {
            put(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
            put(CalendarContract.Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL)
            put(CalendarContract.Calendars.NAME, "ScriptWidget Test")
            put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, "ScriptWidget Test")
            put(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL, CalendarContract.Calendars.CAL_ACCESS_OWNER)
            put(CalendarContract.Calendars.OWNER_ACCOUNT, accountName)
            put(CalendarContract.Calendars.VISIBLE, 1)
            put(CalendarContract.Calendars.SYNC_EVENTS, 1)
        }
        calendarId = ContentUris.parseId(context.contentResolver.insert(asSyncAdapter(CalendarContract.Calendars.CONTENT_URI), values)!!)
        return calendarId
    }

    private fun addEvent(calendar: Long, title: String, start: Long, end: Long) {
        context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, ContentValues().apply {
            put(CalendarContract.Events.CALENDAR_ID, calendar)
            put(CalendarContract.Events.TITLE, title)
            put(CalendarContract.Events.DTSTART, start)
            put(CalendarContract.Events.DTEND, end)
            put(CalendarContract.Events.EVENT_TIMEZONE, "UTC")
        })
    }

    private fun manifest(permissions: List<String>, domains: List<String> = emptyList(), actions: String = "") =
        """{"entry":"main.jsx","formatVersion":2,"id":"com.example.system","name":"System Test","minimumRuntimeVersion":"1.6","networkDomains":${org.json.JSONArray(domains)},"permissions":${org.json.JSONArray(permissions)},"plugins":[],"runtimeVersion":"1.0","supportedFamilies":["systemSmall"],"version":"1.0.0"$actions}"""

    private fun install(source: String, manifest: String): InstalledPackage =
        AppServices.library.create("System Test ${System.nanoTime()}", source, manifest).also { created += it.name }

    /** Runs the package (optionally one of its actions) and returns the JSON its script rendered. */
    private fun run(installed: InstalledPackage, actionID: String? = null): String {
        val result = AppServices.runtime.run(RunRequest(installed.files, installed.installation, actionID = actionID,
            extraEnvironments = if (actionID == null) emptyMap() else mapOf("action-source" to "widget")))
        if (actionID != null) return result.execution.error?.message ?: "ok"
        assertEquals(result.execution.error?.message, null, result.execution.error)
        return Regex("\"children\":\\[(\".*\")\\]\\}$").find(result.execution.tree!!)!!.groupValues[1].let { JSONObject("{\"v\":$it}").getString("v") }
    }

    private val report = """.then(v => ${'$'}render(<text>{JSON.stringify(v)}</text>), e => ${'$'}render(<text>{JSON.stringify({error: String(e)})}</text>))"""

    @Test fun calendarReadsOnlyWhatTheUserSelected() {
        val calendar = createCalendar()
        val start = Instant.parse("2031-05-06T10:00:00Z").toEpochMilli()
        addEvent(calendar, "Design review", start, start + 3_600_000)
        val script = """${'$'}calendar.events({start: "2031-05-06T00:00:00Z", end: "2031-05-07T00:00:00Z", maxAgeSeconds: 0})$report"""
        val installed = install(script, manifest(listOf("calendar")))

        SystemModules.stores(context).calendarSelection.save(CalendarSelection(emptyList()))
        assertTrue(run(installed), JSONObject(run(installed)).optString("error").contains("No Calendar sources are selected"))

        SystemModules.stores(context).calendarSelection.save(CalendarSelection(listOf(calendar.toString())))
        val result = JSONObject(run(installed))
        assertEquals(result.toString(), "ready", result.optString("status"))
        val item = result.getJSONArray("items").getJSONObject(0)
        assertEquals("Design review", item.getString("title"))
        assertEquals(calendar.toString(), item.getString("calendarID"))
        assertEquals("system", result.getString("source"))

        val undeclared = install(script, manifest(emptyList()))
        assertTrue(JSONObject(run(undeclared)).has("error"))
    }

    @Test fun calendarWritesNeedAnActionAGrantAndReplayOnce() {
        val calendar = createCalendar()
        SystemModules.stores(context).calendarSelection.save(CalendarSelection(listOf(calendar.toString())))
        val requestID = UUID.randomUUID().toString()
        val create = """${'$'}calendar.create({requestID: "$requestID", calendarID: "$calendar", title: "From a widget", start: "2031-06-01T09:00:00Z", end: "2031-06-01T10:00:00Z"})"""
        // The entry also runs during an action, so its own attempt uses another request and title.
        val renderAttempt = create.replace(requestID, UUID.randomUUID().toString()).replace("From a widget", "Render attempt")
        val source = """
            async function add() { try { const r = await $create; ${'$'}storage.setString("result", JSON.stringify(r)); } catch (e) { ${'$'}storage.setString("result", JSON.stringify({error: String(e)})); } }
            if (${'$'}getenv("action-id") === "") { $renderAttempt$report }
        """
        val actions = ""","actions":[{"id":"add","title":"Add","systemImage":"plus","function":"add"}]"""
        val installed = install(source, manifest(listOf("calendar", "calendarWrite", "storage"), actions = actions))
        fun actionResult(): JSONObject { run(installed, "add"); return JSONObject(AppServices.runtime.storage.getString(installed.installation, "result")) }

        // Rendering is never allowed to write.
        assertTrue(run(installed), JSONObject(run(installed)).optString("error").contains("[read_only]"))
        // An action without the per-widget grant is refused.
        assertTrue(actionResult().toString(), actionResult().optString("error").contains("[permission_denied]"))

        SystemModules.stores(context).grants.set(installed.installation, "calendarWrite", true)
        val first = actionResult()
        assertEquals(first.toString(), "applied", first.optString("status"))
        assertEquals(false, first.optBoolean("replayed", true))
        val second = actionResult()
        assertEquals(second.toString(), true, second.optBoolean("replayed"))
        context.contentResolver.query(CalendarContract.Events.CONTENT_URI, arrayOf(CalendarContract.Events._ID),
            "${CalendarContract.Events.CALENDAR_ID} = ? AND ${CalendarContract.Events.TITLE} = ?", arrayOf(calendar.toString(), "From a widget"), null).use { cursor ->
            assertEquals("the same request must not create a second event", 1, cursor!!.count)
        }
    }

    @Test fun notificationsScheduleListAndCancelFromAnAction() {
        val key = "test-${System.nanoTime() % 100000}"
        val date = Instant.now().plusSeconds(3600).toString()
        val source = """
            async function add() { try { const r = await ${'$'}notifications.schedule({key: "$key", title: "Reminder", body: "From a widget", date: "$date"}); ${'$'}storage.setString("result", JSON.stringify(r)); } catch (e) { ${'$'}storage.setString("result", JSON.stringify({error: String(e)})); } }
            async function remove() { try { const r = await ${'$'}notifications.cancel("$key"); ${'$'}storage.setString("result", JSON.stringify(r)); } catch (e) { ${'$'}storage.setString("result", JSON.stringify({error: String(e)})); } }
            Promise.all([${'$'}notifications.status(), ${'$'}notifications.pending()])$report
        """
        val actions = ""","actions":[{"id":"add","title":"Add","systemImage":"bell","function":"add"},{"id":"remove","title":"Remove","systemImage":"bell.slash","function":"remove"}]"""
        val installed = install(source, manifest(listOf("notifications", "storage"), actions = actions))
        fun stored() = JSONObject(AppServices.runtime.storage.getString(installed.installation, "result"))

        run(installed, "add")
        assertTrue("without the grant: ${stored()}", stored().optString("error").contains("[permission_denied]"))
        SystemModules.stores(context).grants.set(installed.installation, "notifications", true)
        run(installed, "add")
        assertEquals(stored().toString(), "scheduled", stored().optString("status"))

        val listed = org.json.JSONArray(run(installed))
        assertEquals("authorized", listed.getJSONObject(0).getString("authorization"))
        val pending = listed.getJSONArray(1)
        assertEquals(1, pending.length())
        assertEquals(key, pending.getJSONObject(0).getString("key"))

        run(installed, "remove")
        assertEquals(stored().toString(), key, stored().optString("key"))
        assertEquals(0, org.json.JSONArray(run(installed)).getJSONArray(1).length())
    }

    @Test fun photosReturnBoundedThumbnailsOfWhatTheUserPicked() {
        val stores = SystemModules.stores(context)
        stores.photoLibrary.list().forEach { stores.photoLibrary.remove(it.id) }
        val script = """${'$'}photos.items({limit: 4}).then(v => ${'$'}render(<text>{JSON.stringify({count: v.items.length, prefix: v.items[0] ? v.items[0].image.slice(0, 23) : "", bytes: v.items[0] ? v.items[0].image.length : 0, w: v.items[0] ? v.items[0].width : 0})}</text>), e => ${'$'}render(<text>{JSON.stringify({error: String(e)})}</text>))"""
        val installed = install(script, manifest(listOf("photos")))
        assertTrue(run(installed), JSONObject(run(installed)).has("error"))

        // A large picture, handed over the way the Photo Picker does: as a content URI.
        val picture = File(context.cacheDir, "system-test/picked.jpg").apply { parentFile!!.mkdirs() }
        val bitmap = Bitmap.createBitmap(3000, 2000, Bitmap.Config.ARGB_8888).apply { eraseColor(0xFF3366CC.toInt()) }
        picture.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        val imported = stores.photoImporter.import(listOf(Uri.fromFile(picture)))
        assertEquals(1, imported)

        val result = JSONObject(run(installed))
        assertEquals(result.toString(), 1, result.optInt("count"))
        assertEquals("data:image/jpeg;base64,", result.getString("prefix"))
        assertTrue("thumbnail stays under 128 KiB as base64", result.getInt("bytes") < 180_000)
        assertEquals("width reports the original picture", 3000, result.getInt("w"))
        stores.photoLibrary.list().forEach { stores.photoLibrary.remove(it.id) }
    }

    @Test fun locationNeedsTheManifestPermissionAndNeverPromptsFromAWidget() {
        val script = """
            const flags = {available: ${'$'}location.isAvailable(), status: ${'$'}location.authorizationStatus()};
            ${'$'}location.current({maxAge: 86400}).then(v => ${'$'}render(<text>{JSON.stringify({...flags, hasLatitude: typeof v.latitude === "number", age: typeof v.age})}</text>), e => ${'$'}render(<text>{JSON.stringify({...flags, error: String(e)})}</text>))
        """
        val undeclared = JSONObject(run(install(script, manifest(emptyList()))))
        assertTrue(undeclared.toString(), undeclared.has("error"))
        val declared = JSONObject(run(install(script, manifest(listOf("location")))))
        // With permission granted the status is an authorized state; a position needs a snapshot taken by the app.
        assertTrue(declared.toString(), declared.getString("status").startsWith("authorized"))
        assertTrue(declared.toString(), declared.optBoolean("hasLatitude") || declared.has("error"))
    }

    @Test fun servicesReportNotConnectedAndRequireTheirDeclarations() {
        SystemModules.stores(context).serviceConnections.disconnect()
        val script = """${'$'}services.status("github").then(s => ${'$'}services.profile("github").then(p => ${'$'}render(<text>{JSON.stringify({s, p})}</text>), e => ${'$'}render(<text>{JSON.stringify({s, error: String(e)})}</text>)), e => ${'$'}render(<text>{JSON.stringify({error: String(e)})}</text>))"""
        val declared = JSONObject(run(install(script, manifest(listOf("services", "network"), listOf("api.github.com")))))
        assertEquals(declared.toString(), "notConnected", declared.optString("s"))
        assertTrue(declared.toString(), declared.optString("error").contains("[service_"))
        val undeclared = JSONObject(run(install(script, manifest(emptyList()))))
        assertTrue(undeclared.toString(), undeclared.optString("error").contains("[service_permission]"))
        val unknown = JSONObject(run(install(script.replace("github", "gitlab"), manifest(listOf("services", "network"), listOf("api.github.com")))))
        assertTrue(unknown.toString(), unknown.optString("error").contains("[service_operation]"))
    }
}
