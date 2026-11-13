package com.everettjf.scriptwidget.core.gallery

import com.everettjf.scriptwidget.core.gallery.GalleryFixtures.assertKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException

class GalleryRepositoryTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private val url = GalleryRepository.DEFAULT_INDEX_URL
    private val source = GalleryFixtures.checkedInIndex()
    private val transport = FakeTransport()
    private var clock = 1_000_000L
    private lateinit var cacheDirectory: File
    private lateinit var repository: GalleryRepository

    @Before
    fun setUp() {
        cacheDirectory = File(temporary.root, "cache")
        repository = GalleryRepository(transport, GalleryIndexCache(cacheDirectory), now = { clock })
    }

    private fun ok(body: ByteArray = source, etag: String? = "gallery-v1"): () -> GalleryResponse =
        { GalleryResponse(200, body, if (etag == null) emptyMap() else mapOf("ETag" to etag), url) }

    @Test
    fun defaultIndexUrlIsTheSwiftDefault() {
        assertEquals("https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/index.json", GalleryRepository.DEFAULT_INDEX_URL)
        assertEquals(url, repository.indexUrl)
    }

    @Test
    fun usesETagAndFallsBackToTheVerifiedOfflineCache() {
        transport.queued.add(ok())
        transport.queued.add { GalleryResponse(304, ByteArray(0), emptyMap(), url) }
        transport.queued.add { throw IOException("offline") }

        val online = repository.load(forceRefresh = true)
        assertFalse(online.isOffline)
        assertEquals("application/json", transport.requests[0].headers["Accept"])
        assertEquals("ScriptWidget-Gallery/1", transport.requests[0].headers["User-Agent"])
        assertNull(transport.requests[0].headers["If-None-Match"])

        clock += 60_000
        val revalidated = repository.load(forceRefresh = true)
        assertFalse(revalidated.isOffline)
        assertEquals(online.index, revalidated.index)
        assertEquals(clock, revalidated.fetchedAt)
        assertEquals("gallery-v1", transport.requests[1].headers["If-None-Match"])

        val fetchedAt = clock
        clock += 60_000
        val offline = repository.load(forceRefresh = true)
        assertTrue(offline.isOffline)
        assertEquals(online.index, offline.index)
        assertEquals(fetchedAt, offline.fetchedAt)
        assertTrue(offline.offlineReason!!.isNotEmpty())
        assertEquals("gallery-v1", transport.requests[2].headers["If-None-Match"])
    }

    @Test
    fun freshCacheIsUsedWithoutARequestUntilItExpiresOrARefreshIsForced() {
        transport.queued.add(ok())
        repository.load()
        clock += GalleryRepository.CACHE_MILLISECONDS - 1
        assertFalse(repository.load().isOffline)
        assertEquals(1, transport.requests.size)

        clock += 1
        transport.queued.add(ok())
        repository.load()
        assertEquals(2, transport.requests.size)

        transport.queued.add(ok())
        repository.load(forceRefresh = true)
        assertEquals(3, transport.requests.size)
    }

    @Test
    fun cacheSurvivesANewRepositoryInstance() {
        transport.queued.add(ok())
        val first = repository.load()
        val second = GalleryRepository(FakeTransport(), GalleryIndexCache(cacheDirectory), now = { clock }).load()
        assertEquals(first.index, second.index)
        assertFalse(second.isOffline)
    }

    @Test
    fun withoutACacheANetworkFailureIsReported() {
        assertKind(GalleryException.Kind.NETWORK) { repository.load() }
        assertTrue(GalleryFixtures.tree(cacheDirectory).isEmpty())
    }

    @Test
    fun anIndexServedAfterARedirectOffHostIsNeitherUsedNorCached() {
        transport.queued.add { GalleryResponse(200, source, emptyMap(), "https://evil.example/Gallery/index.json") }
        val error = assertKind(GalleryException.Kind.NETWORK) { repository.load() }
        assertTrue(error.message!!.contains("untrusted host"))
        assertTrue(GalleryFixtures.tree(cacheDirectory).isEmpty())
    }

    @Test
    fun anInvalidIndexIsNeitherUsedNorCached() {
        transport.queued.add(ok("{\"schemaVersion\":1}".toByteArray()))
        assertKind(GalleryException.Kind.INVALID_INDEX) { repository.load() }
        assertTrue(GalleryFixtures.tree(cacheDirectory).isEmpty())

        // With a validated cache, the invalid response is ignored and the cache is shown as offline.
        transport.queued.add(ok())
        val online = repository.load(forceRefresh = true)
        transport.queued.add(ok("[]".toByteArray()))
        val fallback = repository.load(forceRefresh = true)
        assertTrue(fallback.isOffline)
        assertEquals(online.index, fallback.index)
        assertEquals(online.index, GalleryIndexValidator.decode(File(cacheDirectory, "index.json").readBytes()))
    }

    @Test
    fun errorAndRateLimitStatusesAreReportedNotAccepted() {
        transport.queued.add { GalleryResponse(403, source, mapOf("x-ratelimit-remaining" to "0"), url) }
        assertTrue(assertKind(GalleryException.Kind.NETWORK) { repository.load() }.message!!.contains("rate limit reached"))
        transport.queued.add { GalleryResponse(429, source, emptyMap(), url) }
        assertTrue(assertKind(GalleryException.Kind.NETWORK) { repository.load() }.message!!.contains("temporarily limited"))
        transport.queued.add { GalleryResponse(500, source, emptyMap(), url) }
        assertTrue(assertKind(GalleryException.Kind.NETWORK) { repository.load() }.message!!.contains("HTTP 500"))
        // A 304 without a cache is not content either.
        transport.queued.add { GalleryResponse(304, ByteArray(0), emptyMap(), url) }
        assertKind(GalleryException.Kind.NETWORK) { repository.load() }
        assertTrue(GalleryFixtures.tree(cacheDirectory).isEmpty())
    }

    @Test
    fun aTamperedCacheIsNeverTrusted() {
        transport.queued.add(ok())
        repository.load()
        File(cacheDirectory, "index.json").writeText("{\"schemaVersion\":1,\"futureField\":true}")
        // Fresh by age, but no longer valid: a request is made, and with the network down nothing is shown.
        assertKind(GalleryException.Kind.NETWORK) { repository.load() }
        assertEquals(2, transport.requests.size)
        assertNull(transport.requests[1].headers["If-None-Match"])
    }

    @Test
    fun anUntrustedIndexUrlIsRefusedWithoutARequest() {
        for (bad in listOf("http://raw.githubusercontent.com/a/index.json", "https://example.com/index.json", "https://raw.githubusercontent.com/a/index.json?ref=x")) {
            val untrusted = GalleryRepository(transport, GalleryIndexCache(cacheDirectory), indexUrl = bad)
            assertKind(GalleryException.Kind.INVALID_INDEX) { untrusted.load() }
        }
        assertTrue(transport.requests.isEmpty())
    }
}
