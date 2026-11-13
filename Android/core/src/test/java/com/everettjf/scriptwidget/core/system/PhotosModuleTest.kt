package com.everettjf.scriptwidget.core.system

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class PhotosModuleTest {
    private val directory = temporaryDirectory()
    private var now = NOW
    private val library = PhotoLibrary(File(directory, "photos"))
    private val module = PhotosModule(library, File(directory, "photo-snapshots")) { now }
    private val declared = setOf("photos")

    private fun jpeg(size: Int = 2000): ByteArray = ByteArray(size).also { it[0] = 0xFF.toByte(); it[1] = 0xD8.toByte(); it[2] = 0xFF.toByte(); it[3] = 0xE0.toByte() }
    private fun add(takenAt: Long, width: Int = 4000, height: Int = 3000): PhotoEntry = library.add(Thumbnail(jpeg(), 768, 576), width, height, takenAt, now)!!
    private fun ids(result: JSONObject): List<String> = (0 until result.getJSONArray("items").length()).map { result.getJSONArray("items").getJSONObject(it).getString("id") }

    @Test fun queryBounds() {
        val defaults = PhotoQuery.parse(null)
        assertEquals(4, defaults.limit); assertEquals(0, defaults.offset); assertEquals(3600.0, defaults.maxAgeSeconds, 0.0)
        assertEquals("2:63", PhotoQuery.parse(JSONObject().put("limit", 2).put("offset", 63)).identity)
        for (bad in listOf(JSONObject().put("limit", 0), JSONObject().put("limit", 5), JSONObject().put("limit", 1.5), JSONObject().put("limit", true),
            JSONObject().put("offset", -1), JSONObject().put("offset", 64), JSONObject().put("maxAgeSeconds", 86_401), JSONObject().put("maxAgeSeconds", -1),
            JSONObject().put("maxAgeSeconds", "60"), JSONObject().put("album", "x"))) {
            assertRejectsWith("[invalid_options] Invalid photo options or selection") { PhotoQuery.parse(bad) }
        }
        assertEquals(0.5, PhotoQuery.parse(JSONObject().put("maxAgeSeconds", 0.5)).maxAgeSeconds, 0.0)
    }

    @Test fun thumbnailSizeNeverExceeds768AndNeverScalesUp() {
        assertEquals(768 to 576, ThumbnailPlan.fit(4000, 3000))
        assertEquals(576 to 768, ThumbnailPlan.fit(3000, 4000))
        assertEquals(500 to 300, ThumbnailPlan.fit(500, 300))
        assertEquals(768 to 768, ThumbnailPlan.fit(768, 768))
        assertEquals(1 to 768, ThumbnailPlan.fit(1, 10_000))
        assertEquals(0 to 0, ThumbnailPlan.fit(0, 100))
    }

    @Test fun thumbnailEncodingLowersQualityThenSizeUntilItFits() {
        val attempts = ArrayList<Triple<Int, Int, Int>>()
        val byQuality = ThumbnailPlan.encode(4000, 3000) { width, height, quality -> attempts += Triple(width, height, quality); jpeg(if (quality > 65) 200 * 1024 else 100 * 1024) }!!
        assertEquals(listOf(Triple(768, 576, 85), Triple(768, 576, 75), Triple(768, 576, 65)), attempts)
        assertEquals(768, byQuality.width); assertTrue(byQuality.bytes.size <= PhotoLimits.MAXIMUM_THUMBNAIL_BYTES)

        val bySize = ThumbnailPlan.encode(4000, 3000) { width, _, _ -> jpeg(if (width > 500) 300 * 1024 else 64 * 1024) }!!
        assertTrue(bySize.width <= 500); assertTrue(bySize.width >= 96)

        var calls = 0
        assertNull(ThumbnailPlan.encode(4000, 3000) { _, _, _ -> calls += 1; jpeg(PhotoLimits.MAXIMUM_THUMBNAIL_BYTES + 1) })
        assertTrue(calls in 5..80)
        assertNotNull(ThumbnailPlan.encode(100, 100) { _, _, _ -> jpeg(PhotoLimits.MAXIMUM_THUMBNAIL_BYTES) })
        assertNull(ThumbnailPlan.encode(100, 100) { _, _, _ -> ByteArray(500) }) // not a JPEG
        assertNull(ThumbnailPlan.encode(100, 100) { _, _, _ -> null })
        assertNull(ThumbnailPlan.encode(0, 100) { _, _, _ -> jpeg() })
    }

    @Test fun libraryHoldsAtMost24BoundedJpegsWithOpaqueIds() {
        assertNull(library.add(Thumbnail(jpeg(PhotoLimits.MAXIMUM_THUMBNAIL_BYTES + 1), 768, 576), 4000, 3000, now, now))
        assertNull(library.add(Thumbnail(ByteArray(100), 768, 576), 4000, 3000, now, now))
        assertNull(library.add(Thumbnail(jpeg(), 768, 576), 0, 3000, now, now))
        repeat(PhotoLimits.MAXIMUM_SELECTED) { add(now + it) }
        assertNull(library.add(Thumbnail(jpeg(), 768, 576), 4000, 3000, now, now))
        val entries = library.list()
        assertEquals(24, entries.size)
        assertEquals(entries.map { it.takenAt }.sortedDescending(), entries.map { it.takenAt })
        assertTrue(entries.all { CallContext.isOwner(it.id) })
        assertTrue(library.remove(entries[0].id))
        assertEquals(23, library.list().size)
        assertNull(library.read(entries[0]))
        File(directory, "photos/index.json").writeText("{\"formatVersion\":1,\"photos\":[{\"id\":\"../../etc/passwd\",\"width\":1,\"height\":1,\"takenAt\":1,\"revision\":1}]}")
        assertTrue(runCatching { library.list() }.exceptionOrNull() is PhotoLibrary.Corrupt)
        assertRejectsWith("[unavailable] Photos could not be loaded") { module.items(context(declared), null) }
        library.clear()
        assertTrue(library.list().isEmpty())
    }

    @Test fun gateOrder() {
        val denied = "[permission_denied] Allow Photos access and choose photos or albums in ScriptWidget Settings"
        add(now)
        assertRejectsWith(denied) { module.items(context(emptySet()), JSONObject().put("limit", 9)) }
        assertRejectsWith(denied) { module.items(context(declared, hasManifest = false), null) }
        assertRejectsWith(denied) { module.items(context(declared, installation = "preview"), null) }
        assertRejectsWith("[invalid_options] Invalid photo options or selection") { module.items(context(declared, queries = 0), JSONObject().put("limit", 9)) }
        assertRejectsWith("[invalid_options] Invalid photo options or selection") { module.items(context(declared), null, invalidOptions = true) }
        assertRejectsWith("[query_limit] Too many system data queries") { module.items(context(declared, queries = 0), null) }
        library.clear()
        // Nothing selected is the same setup state as missing access, never an empty success.
        assertRejectsWith(denied) { module.items(context(declared), null) }
        assertEquals("limited", module.authorizationStatus(context(declared)))
        assertEquals("undeclared", module.authorizationStatus(context(setOf("calendar"))))
        assertTrue(module.permitted(context(declared))); assertFalse(module.permitted(context(emptySet())))
        assertTrue(module.requestAuthorization(context(declared)))
        assertTrue(module.requestAuthorization(context(declared, projection = true, queries = 0)))
        assertRejectsWith("[query_limit] Too many system data queries") { module.requestAuthorization(context(declared, queries = 0)) }
        assertRejectsWith(denied) { module.requestAuthorization(context(emptySet())) }
    }

    @Test fun itemsReturnAtMostFourNewestFirstAsDataUrls() {
        val entries = (0 until 6).map { add(now - it * 1000L, width = 4000 + it) }
        val result = module.items(context(declared), null)
        assertEquals(entries.take(4).map { it.id }, ids(result))
        assertEquals(setOf("status", "items", "unavailableCount", "fetchedAt", "source", "stale"), result.keys().asSequence().toSet())
        assertEquals("ready", result.getString("status")); assertEquals(0, result.getInt("unavailableCount")); assertEquals("system", result.getString("source")); assertFalse(result.getBoolean("stale"))
        val first = result.getJSONArray("items").getJSONObject(0)
        assertEquals(setOf("id", "image", "width", "height"), first.keys().asSequence().toSet())
        assertTrue(first.getString("image").startsWith("data:image/jpeg;base64,/9j/"))
        assertEquals(4000, first.getInt("width")); assertEquals(3000, first.getInt("height"))
        assertEquals(entries.drop(4).map { it.id }, ids(module.items(context(declared), JSONObject().put("offset", 4))))
        assertEquals(listOf(entries[1].id, entries[2].id), ids(module.items(context(declared), JSONObject().put("offset", 1).put("limit", 2))))
        assertTrue(module.items(context(declared), JSONObject().put("offset", 20)).getJSONArray("items").length() == 0)
    }

    @Test fun snapshotRules() {
        add(now); add(now - 1000)
        val options = { JSONObject().put("maxAgeSeconds", 600) }
        val first = module.items(context(declared), options())
        assertEquals("system", first.getString("source"))
        now += 300_000
        val cached = module.items(context(declared), options())
        assertEquals("cache", cached.getString("source")); assertFalse(cached.getBoolean("stale")); assertEquals(first.getString("fetchedAt"), cached.getString("fetchedAt"))
        // A different page never reuses the snapshot; maxAgeSeconds 0 always refreshes.
        assertEquals("system", module.items(context(declared), options().put("limit", 1)).getString("source"))
        now += 1
        assertEquals("system", module.items(context(declared), JSONObject().put("maxAgeSeconds", 0).put("limit", 1)).getString("source"))
        now += 601_000
        assertEquals("system", module.items(context(declared), options().put("limit", 1)).getString("source"))
        // Future entries only read a matching prepared snapshot, and report staleness against maxAge.
        now += 700_000
        val projected = module.items(context(declared, projection = true), options().put("limit", 1))
        assertEquals("cache", projected.getString("source")); assertTrue(projected.getBoolean("stale"))
        assertRejectsWith("[cache_miss] Open this widget in ScriptWidget to prepare its photo snapshot") { module.items(context(declared, projection = true), options().put("limit", 2)) }
        // The 24-hour lifetime also applies to prepared snapshots.
        module.items(context(declared), options().put("limit", 1))
        now += 86_401_000
        assertRejectsWith("[cache_miss] Open this widget in ScriptWidget to prepare its photo snapshot") { module.items(context(declared, liveActivity = true), options().put("limit", 1)) }
    }

    @Test fun selectionChangesInvalidateSnapshotsAndMissingFilesAreCounted() {
        val newest = add(now)
        val older = add(now - 1000)
        module.items(context(declared), null)
        library.remove(newest.id)
        val afterRemoval = module.items(context(declared), null)
        assertEquals("system", afterRemoval.getString("source")); assertEquals(listOf(older.id), ids(afterRemoval))
        assertRejectsWith("[cache_miss] Open this widget in ScriptWidget to prepare its photo snapshot") {
            add(now + 5000); module.items(context(declared, projection = true), null)
        }
        // A thumbnail file that disappeared is reported, not silently dropped.
        File(directory, "photos/${older.id}.jpg").delete()
        val partial = module.items(context(declared), JSONObject().put("maxAgeSeconds", 0))
        assertEquals(1, partial.getInt("unavailableCount")); assertEquals("ready", partial.getString("status")); assertEquals(1, partial.getJSONArray("items").length())
        File(directory, "photos").listFiles()!!.filter { it.name.endsWith(".jpg") }.forEach { it.delete() }
        val none = module.items(context(declared), JSONObject().put("maxAgeSeconds", 0))
        assertEquals("unavailable", none.getString("status")); assertEquals(2, none.getInt("unavailableCount"))
    }

    @Test fun snapshotMatchingAndPartialRetry() {
        val entries = listOf(PhotoEntry(OWNER, 10, 10, 1, 1), PhotoEntry(OTHER_OWNER, 10, 10, 1, 1))
        val query = PhotoQuery(4, 0, 3600.0)
        val text = PhotoSnapshot.encode("scope", query, entries, 2, now)
        assertEquals(now to 2, PhotoSnapshot.match(text, "scope", query, entries, now + 1000))
        assertNull(PhotoSnapshot.match(text, "other", query, entries, now))
        assertNull(PhotoSnapshot.match(text, "scope", PhotoQuery(4, 1, 3600.0), entries, now))
        assertNull(PhotoSnapshot.match(text, "scope", query, entries.reversed(), now))
        assertNull(PhotoSnapshot.match(text, "scope", query, listOf(entries[0], PhotoEntry(OTHER_OWNER, 10, 10, 1, 2)), now)) // edited photo
        assertNull(PhotoSnapshot.match(text, "scope", query, entries, now - 1))
        assertNull(PhotoSnapshot.match(text, "scope", query, entries, now + 86_401_000))
        assertNull(PhotoSnapshot.match("{}", "scope", query, entries, now))
        assertTrue(PhotoSnapshot.usable(now, 2, 2, query, false, now + 3_600_000))
        assertFalse(PhotoSnapshot.usable(now, 2, 2, query, false, now + 3_601_000))
        // Partial results are retried after at most 60 seconds.
        assertTrue(PhotoSnapshot.usable(now, 1, 2, query, false, now + 60_000))
        assertFalse(PhotoSnapshot.usable(now, 1, 2, query, false, now + 61_000))
        assertTrue(PhotoSnapshot.usable(now, 1, 2, query, true, now + 61_000))
    }
}
