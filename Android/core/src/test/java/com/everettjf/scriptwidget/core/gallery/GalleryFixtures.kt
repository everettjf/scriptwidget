package com.everettjf.scriptwidget.core.gallery

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import java.io.File
import java.io.IOException

/** Offline transport: queued responses first, then responses mapped by URL, else a network failure. */
class FakeTransport : GalleryTransport {
    val queued = ArrayDeque<() -> GalleryResponse>()
    val mapped = HashMap<String, () -> GalleryResponse>()
    val requests = ArrayList<GalleryRequest>()

    override fun fetch(request: GalleryRequest): GalleryResponse {
        requests.add(request)
        queued.removeFirstOrNull()?.let { return it() }
        return mapped[request.url]?.invoke() ?: throw IOException("No test response")
    }

    fun serve(url: String, body: ByteArray, status: Int = 200, finalUrl: String = url, headers: Map<String, String> = emptyMap()) {
        mapped[url] = { GalleryResponse(status, body, headers, finalUrl) }
    }

    fun serve(files: Map<String, ByteArray>) = files.forEach { (url, body) -> serve(url, body) }
}

object GalleryFixtures {
    const val RAW = "https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery"
    const val SOURCE = "https://github.com/everettjf/scriptwidget/tree/main/Gallery"
    const val GENERATED_AT = "2026-11-12T17:07:53.501Z"

    /** The repository checkout that contains this module. */
    val repositoryRoot: File by lazy {
        generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
            .first { File(it, "Gallery/index.json").isFile && File(it, "AGENTS.md").isFile }
    }

    fun checkedInIndex(): ByteArray = File(repositoryRoot, "Gallery/index.json").readBytes()

    /** The checked-in bytes a catalog file URL points at. */
    fun checkedInFile(file: GalleryFile): ByteArray = File(repositoryRoot, "Gallery/" + file.url.substringAfter("/Gallery/")).readBytes()

    fun file(path: String, data: ByteArray, base: String): GalleryFile =
        GalleryFile(path, "$base/$path", GalleryInstaller.sha256(data), data.size.toLong())

    fun widgetManifest(id: String, name: String, version: String, extra: String = ""): String =
        """{"formatVersion":2,"id":"$id","name":"$name","version":"$version","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall"],"permissions":[],"networkDomains":[]$extra}"""

    /** A valid widget item and the bytes served for each of its URLs. */
    fun widget(
        id: String = "com.example.fixture",
        name: String = "Fixture Widget",
        version: String = "1.0.0",
        manifest: String = widgetManifest(id, name, version),
        extra: Map<String, ByteArray> = emptyMap(),
    ): Pair<GalleryItem, Map<String, ByteArray>> {
        val contents = linkedMapOf(
            "widget.json" to manifest.toByteArray(),
            "main.jsx" to "\$render(<text>$version</text>);".toByteArray(),
        ) + extra
        return item(id, GalleryItemKind.WIDGET, name, version, contents)
    }

    fun skillManifest(id: String, name: String, version: String, extra: String = ""): String =
        """{"formatVersion":1,"id":"$id","name":"$name","version":"$version","summary":"Reviews privacy.","symbol":"lock","promptFile":"SKILL.md","tags":["privacy"],"minimumRuntimeVersion":"1.0"$extra}"""

    fun skill(
        id: String = "com.example.skill",
        name: String = "Fixture Skill",
        version: String = "1.0.0",
        manifest: String = skillManifest(id, name, version),
        instruction: String = "Prefer on-device data. ($version)",
    ): Pair<GalleryItem, Map<String, ByteArray>> =
        item(id, GalleryItemKind.SKILL, name, version, linkedMapOf("skill.json" to manifest.toByteArray(), "SKILL.md" to instruction.toByteArray()))

    private fun item(id: String, kind: GalleryItemKind, name: String, version: String, contents: Map<String, ByteArray>): Pair<GalleryItem, Map<String, ByteArray>> {
        val base = "$RAW/fixtures/$id/$version"
        val item = GalleryItem(
            id = id, kind = kind, name = name, version = version, summary = "A fixture.", symbol = "sparkles", author = "Tests",
            license = "MIT", tags = listOf("fixture"), minimumRuntimeVersion = "1.0", sourceUrl = SOURCE, featured = false,
            files = contents.map { (path, data) -> file(path, data, base) },
        )
        return item to contents.entries.associate { (path, data) -> "$base/$path" to data }
    }

    fun index(vararg items: GalleryItem): GalleryIndex = GalleryIndex(1, 0L, "https://github.com/everettjf/scriptwidget", items.toList())

    /** JSON of an index as the catalog publishes it. */
    fun json(index: GalleryIndex): JSONObject = JSONObject()
        .put("schemaVersion", index.schemaVersion)
        .put("generatedAt", GENERATED_AT)
        .put("repository", index.repository)
        .put("items", JSONArray(index.items.map { item ->
            JSONObject()
                .put("id", item.id).put("kind", item.kind.wire).put("name", item.name).put("version", item.version)
                .put("summary", item.summary).put("symbol", item.symbol).put("author", item.author).put("license", item.license)
                .put("tags", JSONArray(item.tags)).put("minimumRuntimeVersion", item.minimumRuntimeVersion)
                .put("sourceURL", item.sourceUrl).put("featured", item.featured)
                .put("files", JSONArray(item.files.map { JSONObject().put("path", it.path).put("url", it.url).put("sha256", it.sha256).put("bytes", it.bytes) }))
        }))

    fun bytes(json: JSONObject): ByteArray = json.toString().toByteArray()

    fun assertKind(kind: GalleryException.Kind, block: () -> Unit): GalleryException {
        try {
            block()
        } catch (error: GalleryException) {
            assertEquals(error.message, kind, error.kind)
            return error
        }
        fail("Expected GalleryException($kind)")
        throw AssertionError()
    }

    /** Relative paths of everything below [root], for "nothing left behind" checks. */
    fun tree(root: File): List<String> =
        if (!root.exists()) emptyList()
        else root.walkTopDown().filter { it != root }.map { it.relativeTo(root).path + if (it.isDirectory) "/" else "" }.sorted().toList()
}
