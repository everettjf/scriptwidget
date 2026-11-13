package com.everettjf.scriptwidget.core.gallery

import com.everettjf.scriptwidget.core.api.FetchModule
import com.everettjf.scriptwidget.core.pkg.SafeFiles
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.URI
import java.util.Locale

/** One GET request of the Gallery layer. Requests never carry a body, cookies or credentials. */
class GalleryRequest(val url: String, val headers: Map<String, String>, val timeoutMilliseconds: Int)

/**
 * A completed response. [finalUrl] is the URL that produced the body after redirects; callers
 * re-check it against the trust rule instead of assuming the transport did.
 */
class GalleryResponse(val status: Int, val body: ByteArray, headers: Map<String, String>, val finalUrl: String) {
    private val headers: Map<String, String> = headers.mapKeys { it.key.lowercase(Locale.ROOT) }

    /** Case-insensitive header lookup. */
    fun header(name: String): String? = headers[name.lowercase(Locale.ROOT)]
}

/**
 * Network access of the Gallery, injectable so tests run offline (`GalleryTransport` in Swift).
 * Implementations block and must be called off the main thread.
 */
fun interface GalleryTransport {
    /** @throws IOException or [GalleryException] when no response was obtained. */
    @Throws(IOException::class)
    fun fetch(request: GalleryRequest): GalleryResponse
}

/**
 * The production transport: a bounded HTTPS GET through [FetchModule.perform], which resolves
 * the host and refuses private, loopback and link-local addresses.
 *
 * The start URL and every redirect hop must pass [GalleryIndexValidator.isRawGitHubUrl]; a
 * redirect anywhere else ends the request instead of being followed. Responses are limited to
 * [FetchModule.MAXIMUM_RESPONSE_BYTES].
 */
class FetchGalleryTransport(private val fetch: FetchModule = FetchModule()) : GalleryTransport {
    override fun fetch(request: GalleryRequest): GalleryResponse {
        if (!GalleryIndexValidator.isRawGitHubUrl(request.url)) {
            throw GalleryException(GalleryException.Kind.NETWORK, "Gallery requests must use raw.githubusercontent.com over HTTPS.")
        }
        var final = URI(request.url)
        try {
            val response = fetch.perform("GET", final, request.headers, null, request.timeoutMilliseconds) { target ->
                GalleryIndexValidator.isTrustedRedirect(target).also { trusted -> if (trusted) final = target }
            }
            return GalleryResponse(response.status, response.body, response.headers, final.toString())
        } catch (error: FetchModule.FetchException) {
            throw GalleryException(GalleryException.Kind.NETWORK, error.message ?: "The Gallery request failed.", error)
        } catch (error: IOException) {
            throw GalleryException(GalleryException.Kind.NETWORK, "GitHub could not be reached.", error)
        }
    }
}

/**
 * A validated index and where it came from. [isOffline] is true when the network attempt failed
 * and the last fully validated cache is shown instead; [offlineReason] then says why.
 */
data class GallerySnapshot(val index: GalleryIndex, val isOffline: Boolean, val fetchedAt: Long, val offlineReason: String? = null)

/**
 * On-disk copy of the last index that passed validation, with its ETag and fetch time
 * (`GalleryIndexCache` in Swift). The cache holds bytes only; they are validated again on every
 * load, so a tampered or outdated cache file is never trusted.
 */
class GalleryIndexCache(val directory: File) {
    class Entry(val data: ByteArray, val etag: String?, val fetchedAt: Long)

    private val indexFile get() = File(directory, "index.json").toPath()
    private val metadataFile get() = File(directory, "metadata.json").toPath()

    /** The cached bytes and metadata, or null when either file is missing, oversized or unreadable. */
    fun load(): Entry? {
        val data = SafeFiles.readBounded(indexFile, GalleryIndexValidator.MAX_INDEX_BYTES.toLong()) ?: return null
        val metadata = SafeFiles.readBounded(metadataFile, MAX_METADATA_BYTES)?.let(SafeFiles::decodeUtf8)?.let(GalleryFiles::parseObject) ?: return null
        val fetchedAt = (metadata.opt("fetchedAt") as? Number)?.toLong() ?: return null
        return Entry(data, metadata.opt("etag") as? String, fetchedAt)
    }

    /** Stores a validated index. Each file is replaced atomically. */
    @Throws(IOException::class)
    fun save(data: ByteArray, etag: String?, fetchedAt: Long) {
        GalleryFiles.writeAtomically(indexFile, data)
        val metadata = JSONObject().put("fetchedAt", fetchedAt)
        if (etag != null) metadata.put("etag", etag)
        GalleryFiles.writeAtomically(metadataFile, metadata.toString().toByteArray(Charsets.UTF_8))
    }

    private companion object {
        const val MAX_METADATA_BYTES = 16L * 1024
    }
}

/**
 * Loads the Gallery index (`GalleryClient` in Swift).
 *
 * Trust: [indexUrl] must be an HTTPS `raw.githubusercontent.com` URL; the response must be HTTP
 * 200 from a URL that still passes that rule; and the body must pass
 * [GalleryIndexValidator.decode] before it is cached or returned. A rate-limit or error status
 * is reported, never treated as content. When the network attempt fails for any reason, the
 * last cache that still validates is returned marked offline; without one the failure is thrown.
 */
class GalleryRepository(
    private val transport: GalleryTransport,
    private val cache: GalleryIndexCache,
    val indexUrl: String = DEFAULT_INDEX_URL,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /**
     * Returns a validated index. A cache younger than 15 minutes is used without a request
     * unless [forceRefresh] is set; otherwise the index is fetched with `If-None-Match` when an
     * ETag is known. Blocking: call off the main thread.
     *
     * @throws GalleryException when no validated index is available.
     */
    fun load(forceRefresh: Boolean = false): GallerySnapshot {
        if (!GalleryIndexValidator.isRawGitHubUrl(indexUrl)) {
            throw GalleryException(GalleryException.Kind.INVALID_INDEX, "Gallery index must use raw.githubusercontent.com over HTTPS.")
        }
        val cached = cache.load()
        val cachedIndex = cached?.let { runCatching { GalleryIndexValidator.decode(it.data) }.getOrNull() }
        if (!forceRefresh && cached != null && cachedIndex != null && now() - cached.fetchedAt in 0 until CACHE_MILLISECONDS) {
            return GallerySnapshot(cachedIndex, isOffline = false, fetchedAt = cached.fetchedAt)
        }

        val headers = LinkedHashMap<String, String>()
        headers["Accept"] = "application/json"
        headers["User-Agent"] = USER_AGENT
        if (cached != null && cachedIndex != null && cached.etag != null) headers["If-None-Match"] = cached.etag
        try {
            val response = try {
                transport.fetch(GalleryRequest(indexUrl, headers, INDEX_TIMEOUT_MILLISECONDS))
            } catch (error: IOException) {
                throw GalleryException(GalleryException.Kind.NETWORK, "GitHub could not be reached.", error)
            }
            if (response.status == 304 && cached != null && cachedIndex != null) {
                val date = now()
                cache.save(cached.data, cached.etag, date)
                return GallerySnapshot(cachedIndex, isOffline = false, fetchedAt = date)
            }
            if (response.status != 200) throw GalleryException(GalleryException.Kind.NETWORK, httpMessage(response))
            if (!GalleryIndexValidator.isRawGitHubUrl(response.finalUrl)) {
                throw GalleryException(GalleryException.Kind.NETWORK, "Gallery redirected to an untrusted host.")
            }
            val index = GalleryIndexValidator.decode(response.body)
            val date = now()
            cache.save(response.body, response.header("ETag"), date)
            return GallerySnapshot(index, isOffline = false, fetchedAt = date)
        } catch (error: Exception) {
            if (cached != null && cachedIndex != null) {
                return GallerySnapshot(cachedIndex, isOffline = true, fetchedAt = cached.fetchedAt, offlineReason = error.message ?: "The Gallery could not be refreshed.")
            }
            throw when (error) {
                is GalleryException -> error
                is IOException -> GalleryException(GalleryException.Kind.NETWORK, "The Gallery cache could not be written.", error)
                else -> error
            }
        }
    }

    private fun httpMessage(response: GalleryResponse): String {
        if (response.status == 403 || response.status == 429) {
            return if (response.header("X-RateLimit-Remaining") == "0") "GitHub rate limit reached. Try again after the reset time."
            else "GitHub temporarily limited Gallery requests. Try again later."
        }
        return "GitHub returned HTTP ${response.status}."
    }

    companion object {
        /** `GalleryClient.defaultIndexURL`: the curated index in this repository is the trust root. */
        const val DEFAULT_INDEX_URL = "https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/index.json"
        const val USER_AGENT = "ScriptWidget-Gallery/1"
        /** The index is cached for 15 minutes. */
        const val CACHE_MILLISECONDS = 15L * 60 * 1000
        const val INDEX_TIMEOUT_MILLISECONDS = 20_000
    }
}
