package com.everettjf.scriptwidget.core.system

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** `$icloud` on the JVM: a temporary directory is the sync folder and each [Device] has its own cache. */
class CloudJsonStoreTest {
    private val folderDirectory = temporaryDirectory()
    private val account = "a".repeat(64)
    private val third = "33333333-3333-4333-8333-333333333333"

    /** One simulated device: a private cache and a switchable view of the sync folder. */
    private inner class Device(var folder: CloudFolder? = CloudFolder(account, FileSyncFolder(folderDirectory))) {
        val directory = temporaryDirectory()
        val store = CloudJsonStore(directory) { folder }
        val jobs = ArrayList<() -> Unit>()
        var now = NOW
        var received = 0
        val module = CloudJsonModule(store, clock = { now }, background = { jobs += it }).also { it.onRevisionsReceived = { received += 1 } }
        fun read(name: String = "note.json", installation: String = OWNER) = JSONObject(store.read(installation, name))
        fun write(text: String, expected: String, name: String = "note.json", installation: String = OWNER, resolving: Boolean = false) =
            JSONObject(store.write(installation, name, JSONObject().put("text", text), expected, resolving))
        fun sync(installation: String = OWNER) = JSONObject(store.synchronize(installation))
        fun cachedFiles(): List<File> = File(directory, "cache").walkTopDown().filter { it.isFile }.toList()
    }

    private fun widget(installation: String = OWNER, permissions: Set<String> = setOf("icloud"), runtime: String? = "1.5", action: Boolean = false, projection: Boolean = false,
                       liveActivity: Boolean = false, queries: Int = 8, hasManifest: Boolean = true) =
        context(permissions, installation = installation, hasManifest = hasManifest, runtime = runtime, action = action, projection = projection, liveActivity = liveActivity, queries = queries)

    private fun storeDirectory(store: String) = File(folderDirectory, "WidgetData/$store")
    private fun remoteFiles(store: String): List<File> = storeDirectory(store).walkTopDown().filter { it.isFile }.toList()
    private fun revisionBytes(name: String, parents: List<String>, value: String) = """{"formatVersion":1,"name":"$name","parents":${JSONArray(parents)},"value":$value}""".toByteArray()

    /** Puts a file into the folder as another writer would; returns its name without `.json`. */
    private fun plant(store: String, document: String, bytes: ByteArray, id: String = CloudJsonRules.hash(bytes)): String {
        File(storeDirectory(store), document).mkdirs()
        File(storeDirectory(store), "$document/$id.json").writeBytes(bytes)
        return id
    }

    /** Two devices connected to one store, both holding the first revision. */
    private fun pair(): Triple<Device, Device, String> {
        val a = Device(); val b = Device()
        val store = a.store.connect(OWNER)
        assertEquals(store, b.store.connect(OWNER, existingStore = store))
        a.write("first", "")
        a.sync(); b.sync()
        return Triple(a, b, store)
    }

    @Test fun documentNamesAreFlatLowercaseFileNames() {
        for (name in listOf("note.json", "a.json", "habit-log_2.json", "a" + "b".repeat(58) + ".json")) assertTrue(name, CloudJsonRules.validName(name))
        for (name in listOf("", "note", "Note.json", "1note.json", "-a.json", "_a.json", "note.JSON", "note.json.json", "a/b.json", "../note.json", "/note.json", "a\\b.json", "..json", ".json",
            "note.json/", "note .json", "nöte.json", "a" + "b".repeat(59) + ".json", "note.json\n", "note\u0000.json", "https://x/note.json")) assertFalse(name, CloudJsonRules.validName(name))
        assertTrue(CloudJsonRules.validStore(OWNER)); assertFalse(CloudJsonRules.validStore(REQUEST_A.uppercase())); assertFalse(CloudJsonRules.validStore("../$OWNER"))
        assertTrue(CloudJsonRules.isTemporary(".revision-$OWNER")); assertFalse(CloudJsonRules.isTemporary(".revision-x")); assertFalse(CloudJsonRules.isTemporary("revision-$OWNER"))
        val device = Device(); device.store.connect(OWNER)
        for (name in listOf<Any?>(null, 5, "", "Note.json", "../note.json", "a/b.json", JSONObject())) {
            assertRejectsWith(CloudJsonError.INVALID_NAME.message) { device.store.read(OWNER, name) }
            assertRejects("icloud:invalidName") { device.store.write(OWNER, name, JSONObject(), "", false) }
        }
        assertEquals("[icloud:invalidName] iCloud JSON operation could not complete. Existing records are preserved.", CloudJsonError.INVALID_NAME.message)
    }

    @Test fun revisionFileFormat() {
        // The documented example file, byte for byte, named by the hash of those bytes.
        val bytes = CloudJsonRules.encodeRevision("note.json", emptyList(), mapOf("text" to "Read a chapter"))
        assertEquals("""{"formatVersion":1,"name":"note.json","parents":[],"value":{"text":"Read a chapter"}}""", bytes.toString(Charsets.UTF_8))
        val id = CloudJsonRules.hash(bytes)
        assertTrue(CloudJsonRules.validRevision(id))
        val revision = CloudJsonRules.decode(bytes, id, "note.json")
        assertEquals(mapOf("text" to "Read a chapter"), revision.value); assertTrue(revision.parents.isEmpty())
        // Deterministic: key order and number spelling of the input do not matter; parents are sorted.
        val one = CloudJsonRules.plain(JSONObject("""{"b":[1,2.5,true,null,"x/y"],"a":{"z":1.0,"y":-0.5},"é":"ü"}"""))
        val two = CloudJsonRules.plain(JSONObject("""{"é":"ü","a":{"y":-0.5,"z":1},"b":[1,2.5,true,null,"x/y"]}"""))
        assertEquals(CloudJsonRules.canonical(one), CloudJsonRules.canonical(two))
        assertEquals("""{"a":{"y":-0.5,"z":1},"b":[1,2.5,true,null,"x/y"],"é":"ü"}""", CloudJsonRules.canonical(one))
        val parents = listOf("f".repeat(64), "0".repeat(64))
        assertEquals(parents.sorted(), CloudJsonRules.decode(CloudJsonRules.encodeRevision("note.json", parents, emptyMap()), CloudJsonRules.hash(CloudJsonRules.encodeRevision("note.json", parents, emptyMap())), "note.json").parents)
        // Another writer's key order is accepted: identity is the hash of the bytes.
        val foreign = """{"value":{"b":1,"a":2},"parents":[],"name":"note.json","formatVersion":1}""".toByteArray()
        assertEquals(mapOf("b" to 1L, "a" to 2L), CloudJsonRules.decode(foreign, CloudJsonRules.hash(foreign), "note.json").value)
    }

    @Test fun hostileRevisionFilesAreInvalidData() {
        fun rejected(text: String, name: String = "note.json") { val bytes = text.toByteArray(); assertRejectsWith(CloudJsonError.INVALID_DATA.message) { CloudJsonRules.decode(bytes, CloudJsonRules.hash(bytes), name) } }
        val good = revisionBytes("note.json", emptyList(), """{"text":"x"}""")
        val goodID = CloudJsonRules.hash(good)
        CloudJsonRules.decode(good, goodID, "note.json")
        // The name must be the hash of the bytes, in lowercase hexadecimal.
        assertRejects("icloud:invalidData") { CloudJsonRules.decode(good, "0".repeat(64), "note.json") }
        assertRejects("icloud:invalidData") { CloudJsonRules.decode(good, goodID.uppercase(), "note.json") }
        assertRejects("icloud:invalidData") { CloudJsonRules.decode(good, goodID.dropLast(1), "note.json") }
        assertRejects("icloud:invalidData") { CloudJsonRules.decode(good, "../$goodID", "note.json") }
        // The file must say which document it belongs to, and that must be where it was found.
        assertRejects("icloud:invalidData") { CloudJsonRules.decode(good, goodID, "other.json") }
        assertRejects("icloud:invalidData") { CloudJsonRules.decode(good, goodID, "../note.json") }
        val self = "1".repeat(64); val other = "2".repeat(64)
        for (text in listOf(
            "", "not json", "[]", "null", "\"text\"", """{"formatVersion":1,"name":"note.json","parents":[],"value":{}} trailing""",
            """{"formatVersion":1,"name":"note.json","parents":[]}""", // a field is missing
            """{"formatVersion":1,"name":"note.json","parents":[],"value":{},"extra":1}""", // an unknown field
            """{"formatVersion":1,"formatVersion":1,"name":"note.json","parents":[],"value":{}}""", // a repeated key
            """{"formatVersion":1,"name":"note.json","parents":[],"value":{"a":1,"a":2}}""",
            """{"formatVersion":2,"name":"note.json","parents":[],"value":{}}""", """{"formatVersion":1.5,"name":"note.json","parents":[],"value":{}}""", """{"formatVersion":"1","name":"note.json","parents":[],"value":{}}""",
            """{"formatVersion":1,"name":"note.json","parents":"$other","value":{}}""", """{"formatVersion":1,"name":"note.json","parents":[1],"value":{}}""",
            """{"formatVersion":1,"name":"note.json","parents":["$other","$self"],"value":{}}""", // not sorted
            """{"formatVersion":1,"name":"note.json","parents":["$self","$self"],"value":{}}""", // repeated
            """{"formatVersion":1,"name":"note.json","parents":["abc"],"value":{}}""", """{"formatVersion":1,"name":"note.json","parents":["../$self"],"value":{}}""",
            """{"formatVersion":1,"name":"note.json","parents":[],"value":[]}""", """{"formatVersion":1,"name":"note.json","parents":[],"value":"x"}""", """{"formatVersion":1,"name":"note.json","parents":[],"value":null}""",
        )) rejected(text)
        // Bytes that are not UTF-8.
        val binary = byteArrayOf(0xC3.toByte(), 0x28) + good
        assertRejects("icloud:invalidData") { CloudJsonRules.decode(binary, CloudJsonRules.hash(binary), "note.json") }
        // A value above 64 KiB, and a file above 128 KiB.
        rejected(String(revisionBytes("note.json", emptyList(), """{"text":"${"x".repeat(CloudJsonRules.MAXIMUM_VALUE_BYTES)}"}""")))
        rejected(String(revisionBytes("note.json", emptyList(), "{}")) + " ".repeat(CloudJsonRules.MAXIMUM_FILE_BYTES))
        // Nesting: 32 levels inside the value are accepted, one more is not; a very deep document does not crash the reader.
        fun nested(levels: Int) = String(revisionBytes("note.json", emptyList(), "{\"a\":".repeat(levels) + "1" + "}".repeat(levels)))
        nested(32).toByteArray().let { CloudJsonRules.decode(it, CloudJsonRules.hash(it), "note.json") }
        rejected(nested(33)); rejected(nested(600)); rejected(nested(20000))
        // A revision cannot name itself as its parent: its id is the hash of the bytes naming it.
        val selfParent = revisionBytes("note.json", listOf(goodID), "{}")
        assertRejects("icloud:invalidData") { CloudJsonRules.decode(selfParent, goodID, "note.json") }
    }

    @Test fun revisionGraphHeadsTokensAndCycles() {
        fun revision(id: Char, vararg parents: Char, name: String = "note.json") = CloudRevision(id.toString().repeat(64), name, parents.map { it.toString().repeat(64) }.sorted(), mapOf("id" to id.toString()), ByteArray(0))
        fun heads(vararg revisions: CloudRevision) = CloudJsonGraph.heads(revisions.toList(), "note.json").map { it.id.take(1) }
        assertEquals(emptyList<String>(), heads())
        assertEquals("", CloudJsonGraph.token(emptyList()))
        assertEquals(listOf("a"), heads(revision('a')))
        assertEquals(listOf("c"), heads(revision('c', 'b'), revision('a'), revision('b', 'a')))
        // Two writers on the same parent: both heads are kept, in id order whatever the input order.
        assertEquals(listOf("b", "c"), heads(revision('c', 'a'), revision('a'), revision('b', 'a')))
        // A resolution names both heads and becomes the only head; three-way forks work the same.
        assertEquals(listOf("d"), heads(revision('a'), revision('b', 'a'), revision('c', 'a'), revision('d', 'b', 'c')))
        assertEquals(listOf("b", "c", "d"), heads(revision('a'), revision('b', 'a'), revision('c', 'a'), revision('d', 'a')))
        // Two independent first writes are a conflict too.
        assertEquals(listOf("a", "b"), heads(revision('a'), revision('b')))
        // Other documents do not take part.
        assertEquals(listOf("a"), heads(revision('a'), revision('b', name = "other.json")))
        // A parent that has not arrived yet: the history is not reliable.
        assertRejectsWith(CloudJsonError.UNAVAILABLE.message) { heads(revision('b', 'a')) }
        assertRejects("icloud:unavailable") { heads(revision('a'), revision('b', 'a'), revision('c', 'z')) }
        // Parent links that loop are refused instead of producing "no data".
        assertRejectsWith(CloudJsonError.INVALID_DATA.message) { heads(revision('a', 'b'), revision('b', 'a')) }
        assertRejects("icloud:invalidData") { heads(revision('r'), revision('a', 'c'), revision('b', 'a'), revision('c', 'b')) }
        assertRejects("icloud:invalidData") { heads(revision('a', 'a')) }

        // The token is a digest of the sorted head ids: equal for equal heads, different otherwise.
        val one = CloudJsonGraph.token(listOf(revision('b'), revision('c')))
        assertEquals(CloudJsonRules.hash(("b".repeat(64) + "\n" + "c".repeat(64)).toByteArray()), one)
        assertFalse(one == CloudJsonGraph.token(listOf(revision('b'))))
        val response = JSONObject(CloudJsonGraph.response(listOf(revision('a'), revision('b', 'a'), revision('c', 'a')), "note.json", pending = true))
        assertEquals("conflict", response.getString("state")); assertTrue(response.isNull("value")); assertEquals(one, response.getString("revision"))
        assertEquals("""[{"id":"${"b".repeat(64)}","value":{"id":"b"}},{"id":"${"c".repeat(64)}","value":{"id":"c"}}]""", Canonical.encode(response.getJSONArray("conflicts")))
    }

    @Test fun readWriteAndStaleRevisions() {
        val device = Device()
        assertRejectsWith(CloudJsonError.NOT_CONNECTED.message) { device.read() }
        assertRejects("icloud:notConnected") { device.write("x", "") }
        assertRejects("icloud:notConnected") { device.store.status(OWNER) }
        assertRejects("icloud:notConnected") { device.sync() }
        val store = device.store.connect(OWNER)
        assertTrue(CloudJsonRules.validStore(store)); assertTrue(storeDirectory(store).isDirectory)

        // Nothing cached: null with an empty token, which says nothing about the folder.
        val empty = device.read()
        assertEquals("""{"conflicts":[],"revision":"","state":"cached","value":null}""", Canonical.encode(empty))
        val written = device.write("one", "")
        assertEquals(setOf("value", "revision", "state", "conflicts"), written.keys().asSequence().toSet())
        assertEquals("pending", written.getString("state")); assertEquals("one", written.getJSONObject("value").getString("text")); assertEquals(0, written.getJSONArray("conflicts").length())
        val token = written.getString("revision")
        assertTrue(CloudJsonRules.validRevision(token))
        // A write stays on the device until an exchange: the folder still has no revision.
        assertTrue(remoteFiles(store).isEmpty())
        val cached = device.read()
        assertEquals("cached", cached.getString("state")); assertEquals(token, cached.getString("revision")); assertEquals("one", cached.getJSONObject("value").getString("text"))

        // A token that is not the current one never overwrites history.
        for (stale in listOf<Any?>("", "0".repeat(64), token.uppercase(), null, 7)) assertRejectsWith(CloudJsonError.STALE_REVISION.message) { device.store.write(OWNER, "note.json", JSONObject(), stale, false) }
        assertEquals(1, device.cachedFiles().size)
        val second = device.write("two", token)
        assertFalse(token == second.getString("revision"))
        assertRejects("icloud:staleRevision") { device.write("three", token) }
        assertEquals("two", device.read().getJSONObject("value").getString("text"))
        // resolveJSON without a conflict is an ordinary guarded write.
        assertEquals("pending", device.write("three", second.getString("revision"), resolving = true).getString("state"))
        assertRejects("icloud:staleRevision") { device.write("four", second.getString("revision"), resolving = true) }
        // Documents of one store are independent.
        assertTrue(device.read("other.json").isNull("value"))
        device.write("o", "", name = "other.json")
        assertEquals("three", device.read().getJSONObject("value").getString("text"))

        val status = JSONObject(device.store.status(OWNER))
        assertEquals(setOf("state", "store", "uploaded", "uploadState", "conflictPolicy"), status.keys().asSequence().toSet())
        assertEquals("connected", status.getString("state")); assertEquals(store, status.getString("store")); assertTrue(status.isNull("uploaded"))
        assertEquals("unknown", status.getString("uploadState")); assertEquals("preserveAllVersions", status.getString("conflictPolicy"))
        assertEquals(listOf("note.json:3:1", "other.json:1:1"), device.store.documents(OWNER).map { "${it.name}:${it.revisions}:${it.heads}" })
    }

    @Test fun valuesMustBeBoundedJsonObjects() {
        val device = Device(); device.store.connect(OWNER)
        for (value in listOf<Any?>(null, "text", 5, true, JSONArray("[1]"), JSONObject.NULL, mapOf("n" to Double.NaN), mapOf("n" to Any()), mapOf(1 to "x"))) {
            assertRejectsWith(CloudJsonError.INVALID_DATA.message) { device.store.write(OWNER, "note.json", value, "", false) }
        }
        var deep = JSONObject().put("leaf", 1)
        repeat(31) { deep = JSONObject().put("a", deep) }
        device.store.write(OWNER, "deep.json", deep, "", false)
        assertRejects("icloud:invalidData") { device.store.write(OWNER, "deeper.json", JSONObject().put("a", deep), "", false) }
        // 64 KiB of encoded value is the limit; one byte more is refused and nothing is stored.
        val overhead = """{"text":""}""".length
        device.write("x".repeat(CloudJsonRules.MAXIMUM_VALUE_BYTES - overhead), "", name = "big.json")
        assertRejectsWith(CloudJsonError.LIMIT_EXCEEDED.message) { device.write("x".repeat(CloudJsonRules.MAXIMUM_VALUE_BYTES - overhead + 1), "", name = "bigger.json") }
        assertEquals(2, device.cachedFiles().size)
        // The token is checked before the value: a stale write of a bad value is stale.
        assertRejects("icloud:staleRevision") { device.store.write(OWNER, "big.json", null, "", false) }
        // Unicode, slashes and numbers survive a round trip.
        val value = JSONObject("""{"text":"a/b \"q\" é 😀 \n","n":[1,-2.5,1e21,0],"flag":false,"none":null,"nested":{"k":"v"}}""")
        device.store.write(OWNER, "round.json", value, "", false)
        assertEquals(Canonical.encode(value), Canonical.encode(device.read("round.json").getJSONObject("value")))
    }

    @Test fun concurrentWritesAreKeptAsAConflictAndResolved() {
        val (a, b, store) = pair()
        val base = a.read().getString("revision")
        assertEquals(base, b.read().getString("revision"))
        assertEquals("first", b.read().getJSONObject("value").getString("text"))

        // Both devices write on the same base while "offline".
        val fromA = a.write("from A", base); val fromB = b.write("from B", base)
        assertEquals("pending", fromA.getString("state")); assertEquals("pending", fromB.getString("state"))
        val syncA = a.sync()
        assertEquals("""{"downloadedRevisions":0,"materializedRevisions":2,"state":"pending","uploaded":null}""", Canonical.encode(syncA))
        val syncB = b.sync()
        assertEquals(1, syncB.getInt("downloadedRevisions")); assertEquals(3, syncB.getInt("materializedRevisions")); assertTrue(syncB.isNull("uploaded"))
        // B sees the fork at once; A sees it after its next exchange.
        assertEquals("from A", a.read().getJSONObject("value").getString("text"))
        assertEquals(1, a.sync().getInt("downloadedRevisions"))
        for (device in listOf(a, b)) {
            val conflict = device.read()
            assertEquals("conflict", conflict.getString("state")); assertTrue(conflict.isNull("value"))
            val conflicts = conflict.getJSONArray("conflicts")
            assertEquals(2, conflicts.length())
            assertEquals(setOf("id", "value"), conflicts.getJSONObject(0).keys().asSequence().toSet())
            assertEquals(setOf("from A", "from B"), (0..1).map { conflicts.getJSONObject(it).getJSONObject("value").getString("text") }.toSet())
            assertTrue(conflicts.getJSONObject(0).getString("id") < conflicts.getJSONObject(1).getString("id"))
            assertEquals(listOf("note.json:3:2"), device.store.documents(OWNER).map { "${it.name}:${it.revisions}:${it.heads}" })
        }
        // Both devices hold the same token for the same two heads.
        val token = a.read().getString("revision")
        assertEquals(token, b.read().getString("revision"))
        // Neither file was overwritten or removed.
        assertEquals(3, remoteFiles(store).size)

        // An ordinary write cannot pick a winner, with either the old or the current token.
        assertRejectsWith(CloudJsonError.CONFLICT.message) { a.write("mine wins", token) }
        assertRejectsWith(CloudJsonError.STALE_REVISION.message) { a.write("mine wins", base) }
        assertRejects("icloud:staleRevision") { a.write("merged", fromA.getString("revision"), resolving = true) }

        // An explicit resolution descends from every observed head.
        val resolved = a.write("from A + from B", token, resolving = true)
        assertEquals("pending", resolved.getString("state")); assertEquals("from A + from B", resolved.getJSONObject("value").getString("text"))
        // B has not exchanged yet: it still has the conflict, and its token is now stale on A.
        assertEquals("conflict", b.read().getString("state"))
        assertRejects("icloud:staleRevision") { a.write("again", token, resolving = true) }
        a.sync(); assertEquals(1, b.sync().getInt("downloadedRevisions"))
        for (device in listOf(a, b)) {
            val merged = device.read()
            assertEquals("cached", merged.getString("state")); assertEquals("from A + from B", merged.getJSONObject("value").getString("text")); assertEquals(0, merged.getJSONArray("conflicts").length())
        }
        // The originals remain next to the resolution.
        assertEquals(4, remoteFiles(store).size); assertEquals(4, a.cachedFiles().size); assertEquals(4, b.cachedFiles().size)
        // A repeated exchange changes nothing.
        assertEquals("""{"downloadedRevisions":0,"materializedRevisions":4,"state":"pending","uploaded":null}""", Canonical.encode(b.sync()))
    }

    @Test fun resolutionRacingWithAThirdWriteStaysAConflict() {
        val (a, b, _) = pair()
        val base = a.read().getString("revision")
        a.write("A1", base); b.write("B1", base); a.sync(); b.sync(); a.sync()
        val token = a.read().getString("revision")
        // A resolves what it observed while B, still offline, resolves differently.
        a.write("A merge", token, resolving = true); b.write("B merge", token, resolving = true)
        a.sync(); b.sync(); a.sync()
        val both = a.read()
        assertEquals("conflict", both.getString("state"))
        assertEquals(setOf("A merge", "B merge"), (0..1).map { both.getJSONArray("conflicts").getJSONObject(it).getJSONObject("value").getString("text") }.toSet())
        // The same write on two devices is the same revision, so it converges without a conflict.
        val again = a.read().getString("revision")
        a.write("agreed", again, resolving = true); b.write("agreed", again, resolving = true)
        a.sync(); b.sync(); a.sync()
        assertEquals("agreed", a.read().getJSONObject("value").getString("text")); assertEquals("cached", b.read().getString("state"))
    }

    @Test fun exchangeMovesRevisionsInBothDirections() {
        val a = Device(); val b = Device()
        val store = a.store.connect(OWNER); b.store.connect(OWNER, existingStore = store)
        // A cold device reads nothing, then discovers the folder's data after an exchange.
        a.write("a1", "", name = "a.json"); a.write("a2", a.read("a.json").getString("revision"), name = "a.json")
        b.write("b1", "", name = "b.json")
        assertTrue(b.read("a.json").isNull("value"))
        assertEquals(0, a.sync().getInt("downloadedRevisions"))
        assertEquals(2, remoteFiles(store).size)
        val exchanged = b.sync()
        assertEquals(2, exchanged.getInt("downloadedRevisions")); assertEquals(3, exchanged.getInt("materializedRevisions"))
        assertEquals(3, remoteFiles(store).size)
        assertEquals("a2", b.read("a.json").getJSONObject("value").getString("text"))
        assertEquals(1, a.sync().getInt("downloadedRevisions"))
        assertEquals("b1", a.read("b.json").getJSONObject("value").getString("text"))
        // Folder files are byte-identical to the cache files and named by their hash.
        for (file in remoteFiles(store)) {
            assertEquals(file.nameWithoutExtension, CloudJsonRules.hash(file.readBytes()))
            assertTrue(a.cachedFiles().any { it.name == file.name && it.readBytes().contentEquals(file.readBytes()) })
        }
        // No temporary files are left behind.
        assertTrue(storeDirectory(store).walkTopDown().none { it.name.startsWith(".revision-") })
    }

    @Test fun limitsFailWithoutPruning() {
        val device = Device(); val store = device.store.connect(OWNER)
        // 2 MiB of revisions per store, counted with room for one more maximal file.
        var token = ""
        var written = 0
        val text = "y".repeat(60 * 1024)
        while (true) {
            try { token = device.write(text + written, token).getString("revision"); written += 1 } catch (error: SystemReject) { assertEquals(CloudJsonError.LIMIT_EXCEEDED.message, error.message); break }
            assertTrue(written < 64)
        }
        assertTrue(written in 30..33)
        assertEquals(text + (written - 1), device.read().getJSONObject("value").getString("text"))
        assertEquals(written, device.cachedFiles().size)

        // 128 document names per store.
        val names = Device(CloudFolder("b".repeat(64), FileSyncFolder(temporaryDirectory()))); names.store.connect(OWNER)
        repeat(CloudJsonRules.MAXIMUM_DOCUMENTS) { names.write("v", "", name = "d$it.json") }
        assertRejectsWith(CloudJsonError.LIMIT_EXCEEDED.message) { names.write("v", "", name = "one-more.json") }
        // 256 revisions per store: updating an existing document is refused too once the store is full.
        var revision = names.read("d0.json").getString("revision")
        repeat(CloudJsonRules.MAXIMUM_REVISIONS - CloudJsonRules.MAXIMUM_DOCUMENTS) { revision = names.write("v$it", revision, name = "d0.json").getString("revision") }
        assertRejects("icloud:limitExceeded") { names.write("full", revision, name = "d0.json") }
        assertEquals(CloudJsonRules.MAXIMUM_REVISIONS, names.cachedFiles().size)
        assertEquals("v${CloudJsonRules.MAXIMUM_REVISIONS - CloudJsonRules.MAXIMUM_DOCUMENTS - 1}", names.read("d0.json").getJSONObject("value").getString("text"))

        // An exchange whose union would not fit is refused as a whole; the cache is unchanged.
        val small = Device(); small.store.connect(OWNER, existingStore = store)
        small.write("local", "", name = "local.json")
        repeat(CloudJsonRules.MAXIMUM_REVISIONS) { plant(store, "flood.json", revisionBytes("flood.json", emptyList(), """{"n":$it}""")) }
        assertRejectsWith(CloudJsonError.LIMIT_EXCEEDED.message) { small.sync() }
        assertEquals(1, small.cachedFiles().size)
        plant(store, "flood.json", revisionBytes("flood.json", emptyList(), """{"n":-1}"""))
        assertRejects("icloud:limitExceeded") { small.sync() }
    }

    @Test fun hostileFolderContentsStopTheExchangeAndPreserveTheCache() {
        fun attempt(expected: CloudJsonError, hostile: (store: String, device: Device) -> Unit) {
            folderDirectory.listFiles()?.forEach { it.deleteRecursively() }
            val device = Device(); val store = device.store.connect(OWNER)
            device.write("safe", ""); device.sync()
            hostile(store, device)
            assertRejectsWith(expected.message) { device.sync() }
            // The cache still answers with the last good value and holds nothing new.
            assertEquals("safe", device.read().getJSONObject("value").getString("text"))
            assertEquals(1, device.cachedFiles().size)
            assertRejectsWith(expected.message) { device.sync() }
        }
        val good = revisionBytes("note.json", emptyList(), """{"text":"evil"}""")
        // A file whose name is not the hash of its content.
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> plant(store, "note.json", good, "0".repeat(64)) }
        // An edited revision: the user changed the text of an existing file in place.
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> remoteFiles(store).single().writeText("""{"formatVersion":1,"name":"note.json","parents":[],"value":{"text":"edited"}}""") }
        // A truncated (half-written) revision.
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> plant(store, "note.json", good.copyOf(20), CloudJsonRules.hash(good)) }
        // Content that is not JSON, named by its own hash.
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> plant(store, "note.json", "<html>not json</html>".toByteArray()) }
        // An oversized file is refused before it is parsed.
        attempt(CloudJsonError.UNAVAILABLE) { store, _ -> plant(store, "note.json", ByteArray(CloudJsonRules.MAXIMUM_FILE_BYTES + 1) { 'x'.code.toByte() }) }
        // Names that try to leave the store or do not follow the rules.
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> plant(store, "..json", good) }
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> plant(store, "Note.json", revisionBytes("Note.json", emptyList(), "{}")) }
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> plant(store, "note.json", good, "..%2f..%2f" + CloudJsonRules.hash(good)) }
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> plant(store, "note.json", good, CloudJsonRules.hash(good) + " (1)") }
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> File(storeDirectory(store), "stray.json").writeText("{}") }
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> File(storeDirectory(store), "note.json/nested").mkdirs() }
        attempt(CloudJsonError.UNAVAILABLE) { store, _ -> File(storeDirectory(store), "note.json/readme.txt").writeText("hello") }
        // A revision filed under another document's directory.
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> plant(store, "other.json", good) }
        // Links are never followed, for a document directory or a revision file.
        val outside = temporaryDirectory().also { File(it, "note.json").mkdirs(); File(it, "secret.json").writeBytes(good) }
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> Files.createSymbolicLink(File(storeDirectory(store), "linked.json").toPath(), File(outside, "note.json").toPath()) }
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> Files.createSymbolicLink(File(storeDirectory(store), "note.json/${CloudJsonRules.hash(good)}.json").toPath(), File(outside, "secret.json").toPath()) }
        // Two files that name each other as parents cannot both carry a valid hash.
        attempt(CloudJsonError.INVALID_DATA) { store, _ ->
            val one = "1".repeat(64); val two = "2".repeat(64)
            plant(store, "note.json", revisionBytes("note.json", listOf(two), "{}"), one); plant(store, "note.json", revisionBytes("note.json", listOf(one), "{}"), two)
        }
        // Repeated keys, unknown fields and deep nesting inside an otherwise well-named file.
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> plant(store, "note.json", """{"formatVersion":1,"name":"note.json","parents":[],"value":{"a":1,"a":2}}""".toByteArray()) }
        attempt(CloudJsonError.INVALID_DATA) { store, _ -> plant(store, "note.json", revisionBytes("note.json", emptyList(), "{\"a\":".repeat(40) + "1" + "}".repeat(40))) }
        // More entries than a store may hold.
        attempt(CloudJsonError.LIMIT_EXCEEDED) { store, _ -> repeat(CloudJsonRules.MAXIMUM_DOCUMENTS + 1) { File(storeDirectory(store), "x$it.json").mkdirs() } }
    }

    @Test fun harmlessFolderEntriesAreSkippedAndMissingParentsBlockReads() {
        val device = Device(); val store = device.store.connect(OWNER)
        device.write("safe", ""); device.sync()
        // Finder metadata and another writer's unfinished file are ignored without being read.
        File(storeDirectory(store), ".DS_Store").writeText("metadata")
        File(storeDirectory(store), "note.json/.DS_Store").writeText("metadata")
        File(storeDirectory(store), "note.json/.revision-$OTHER_OWNER").writeText("half")
        assertEquals(0, device.sync().getInt("downloadedRevisions"))
        assertEquals(1, device.cachedFiles().size)

        // A child arrives before its parent: reads of that document wait instead of guessing.
        val parent = revisionBytes("late.json", emptyList(), """{"n":1}""")
        val child = revisionBytes("late.json", listOf(CloudJsonRules.hash(parent)), """{"n":2}""")
        plant(store, "late.json", child)
        assertEquals(1, device.sync().getInt("downloadedRevisions"))
        assertRejectsWith(CloudJsonError.UNAVAILABLE.message) { device.read("late.json") }
        assertRejects("icloud:unavailable") { device.store.write(OWNER, "late.json", JSONObject(), "", false) }
        assertEquals("safe", device.read().getJSONObject("value").getString("text"))
        plant(store, "late.json", parent)
        assertEquals(1, device.sync().getInt("downloadedRevisions"))
        assertEquals(2, device.read("late.json").getJSONObject("value").getInt("n"))
    }

    @Test fun removedStoreIsNotRecreatedAndFolderChangesDenyAccess() {
        val device = Device(); val store = device.store.connect(OWNER)
        device.write("kept", ""); device.sync()
        // The store was deleted in the folder: no exchange, no silent re-upload, cached reads go on.
        storeDirectory(store).deleteRecursively()
        assertRejectsWith(CloudJsonError.UNAVAILABLE.message) { device.sync() }
        assertFalse(storeDirectory(store).exists())
        assertEquals("kept", device.read().getJSONObject("value").getString("text"))
        device.write("still local", device.read().getString("revision"))

        // Another folder is another identity: the old connection is refused, not reinterpreted.
        val original = device.folder
        device.folder = CloudFolder("c".repeat(64), FileSyncFolder(temporaryDirectory()))
        assertRejectsWith(CloudJsonError.ACCOUNT_CHANGED.message) { device.read() }
        assertRejects("icloud:accountChanged") { device.write("x", "") }
        assertRejects("icloud:accountChanged") { device.sync() }
        assertRejects("icloud:accountChanged") { device.store.status(OWNER) }
        // No folder at all.
        device.folder = null
        assertRejects("icloud:accountChanged") { device.read() }
        assertRejectsWith(CloudJsonError.UNAVAILABLE.message) { device.store.connect(OTHER_OWNER) }
        assertRejects("icloud:unavailable") { device.store.availableStores() }
        // Choosing the first folder again restores the connection and the cache.
        device.folder = original
        assertEquals("still local", device.read().getJSONObject("value").getString("text"))
        // A folder that became unreachable reports it in status and rejects an exchange; reads still work.
        device.folder = CloudFolder(account, FileSyncFolder(File(folderDirectory, "gone")))
        assertEquals("unavailable", JSONObject(device.store.status(OWNER)).getString("state"))
        assertRejects("icloud:unavailable") { device.sync() }
        assertEquals("still local", device.read().getJSONObject("value").getString("text"))
    }

    @Test fun packagesAreIsolatedUnlessConnectedToTheSameStore() {
        val device = Device()
        val first = device.store.connect(OWNER)
        val second = device.store.connect(OTHER_OWNER)
        assertFalse(first == second)
        device.write("reading log", "", installation = OWNER)
        // The same file name in another store is independent data.
        assertTrue(device.read(installation = OTHER_OWNER).isNull("value"))
        device.write("something else", "", installation = OTHER_OWNER)
        assertEquals("reading log", device.read(installation = OWNER).getJSONObject("value").getString("text"))
        device.sync(OWNER); device.sync(OTHER_OWNER)
        assertEquals(1, remoteFiles(first).size); assertEquals(1, remoteFiles(second).size)
        assertEquals(listOf(first, second).sorted(), device.store.availableStores())

        // A package that was never connected has no access, whatever it is called.
        assertRejects("icloud:notConnected") { device.read(installation = third) }
        assertRejects("icloud:notConnected") { device.store.read("note.json", "note.json") }
        // Explicitly connected to the first store, it shares that store's documents and nothing else.
        assertEquals(first, device.store.connect(third, existingStore = first))
        assertEquals("reading log", device.read(installation = third).getJSONObject("value").getString("text"))
        device.write("updated by statistics", device.read(installation = third).getString("revision"), installation = third)
        assertEquals("updated by statistics", device.read(installation = OWNER).getJSONObject("value").getString("text"))
        assertEquals("something else", device.read(installation = OTHER_OWNER).getJSONObject("value").getString("text"))

        // Only an existing store can be joined, and only by a well-formed id.
        assertRejectsWith(CloudJsonError.UNAVAILABLE.message) { device.store.connect(third, existingStore = "44444444-4444-4444-8444-444444444444") }
        for (id in listOf("", "../$first", first.uppercase(), "WidgetData", "note.json")) assertRejectsWith(CloudJsonError.INVALID_NAME.message) { device.store.connect(third, existingStore = id) }
        assertEquals(first, device.store.connection(third))

        // Disconnect revokes one grant and keeps every file; reconnecting brings the data back.
        device.store.disconnect(third)
        assertRejects("icloud:notConnected") { device.read(installation = third) }
        assertEquals("updated by statistics", device.read(installation = OWNER).getJSONObject("value").getString("text"))
        assertEquals(1, remoteFiles(first).size)
        device.store.connect(third, existingStore = first)
        assertEquals("updated by statistics", device.read(installation = third).getJSONObject("value").getString("text"))
        // Connecting a different store keeps the previous store and its cache.
        device.store.connect(third)
        assertTrue(device.read(installation = third).isNull("value"))
        assertEquals("updated by statistics", device.read(installation = OWNER).getJSONObject("value").getString("text"))
    }

    @Test fun malformedGrantFailsClosed() {
        val device = Device(); val store = device.store.connect(OWNER)
        val grant = File(device.directory, "grants/$OWNER.json")
        assertEquals("""{"account":"$account","store":"$store","version":1}""", grant.readText())
        for (text in listOf("", "{}", "not json", """{"account":"$account","store":"$store","version":2}""", """{"account":"$account","store":"../x","version":1}""",
            """{"account":"short","store":"$store","version":1}""", """{"account":"$account","store":"$store","version":1,"extra":true}""", "x".repeat(4096))) {
            grant.writeText(text)
            assertRejectsWith(CloudJsonError.INVALID_DATA.message) { device.read() }
            assertRejects("icloud:invalidData") { device.write("x", "") }
        }
        // An explicit reconnect in the app replaces the broken grant.
        device.store.connect(OWNER, existingStore = store)
        assertTrue(device.read().isNull("value"))
        // An identity that is not an installation never has a grant, and never becomes a path.
        assertRejects("icloud:notConnected") { device.store.read("../$OWNER", "note.json") }
        assertRejects("icloud:notConnected") { device.store.connect("preview") }
    }

    @Test fun gateOrderAndReadOnlyRules() {
        val device = Device(); device.store.connect(OWNER)
        val module = device.module
        val value = JSONObject().put("text", "x")
        fun all(context: () -> CallContext, message: String, readsToo: Boolean = true) {
            if (readsToo) { assertRejectsWith(message) { module.readJSON(context(), "note.json") }; assertRejectsWith(message) { module.status(context()) } }
            assertRejectsWith(message) { module.writeJSON(context(), "note.json", value, "") }
            assertRejectsWith(message) { module.resolveJSON(context(), "note.json", value, "") }
            assertRejectsWith(message) { module.sync(context()) }
        }
        val readOnly = "[icloud:read_only] Writes and sync require a user action; future/Live Activity presentations cannot access iCloud JSON."
        val undeclared = "[permission_denied] Declare icloud in widget.json and connect this installation in the app."
        // Previews and unmanaged packages are not installations.
        all({ widget(installation = "preview", action = true) }, "[icloud:unavailable] Install the widget and connect iCloud JSON in the app. Native CLI and template previews cannot access iCloud.")
        // The manifest must declare icloud on Runtime 1.5 or later; this comes before the read-only rules.
        all({ widget(permissions = emptySet(), action = true) }, undeclared)
        all({ widget(hasManifest = false, action = true) }, undeclared)
        all({ widget(runtime = "1.4", action = true) }, undeclared)
        all({ widget(runtime = null, projection = true) }, undeclared)
        // Future timeline entries and Live Activity presentations cannot use the API at all, even from an action.
        all({ widget(projection = true, action = true) }, readOnly)
        all({ widget(liveActivity = true, action = true) }, readOnly)
        // Normal rendering reads but never changes records or exchanges files.
        all({ widget() }, readOnly, readsToo = false)
        assertTrue(JSONObject(module.readJSON(widget(), "note.json")).isNull("value"))
        assertEquals("connected", JSONObject(module.status(widget(runtime = "1.6"))).getString("state"))
        assertTrue(device.cachedFiles().isEmpty()); assertTrue(device.jobs.isEmpty())
        // The read-only rule comes before name, connection and token checks.
        assertRejectsWith(readOnly) { module.writeJSON(widget(installation = third), "Bad Name", null, null) }
        assertRejects("icloud:invalidName") { module.writeJSON(widget(action = true), "Bad Name", null, null) }
        assertRejects("icloud:notConnected") { module.readJSON(widget(installation = third), "note.json") }

        // A user action may write, resolve and sync.
        val written = JSONObject(module.writeJSON(widget(action = true), "note.json", value, ""))
        assertEquals("pending", written.getString("state"))
        assertEquals("pending", JSONObject(module.resolveJSON(widget(action = true), "note.json", value.put("text", "y"), written.getString("revision"))).getString("state"))
        assertTrue(JSONObject(module.sync(widget(action = true))).isNull("uploaded"))

        // Every call takes one of the eight queries; a spent budget is reported as read_only, as on iPhone.
        val budget = widget(action = true, queries = 2)
        module.readJSON(budget, "note.json"); assertRejects("icloud:invalidName") { module.readJSON(budget, "Bad") }
        assertRejectsWith(readOnly) { module.readJSON(budget, "note.json") }
        assertEquals(setOf("\$icloud"), module.apis); assertTrue(module.handles("icloud.sync")); assertFalse(module.handles("maps.search"))
    }

    @Test fun writesExchangeInTheBackgroundForTheSameInstallation() {
        val a = Device(); val b = Device()
        val store = a.store.connect(OWNER); b.store.connect(OWNER, existingStore = store)
        val value = JSONObject().put("text", "from A")
        a.module.writeJSON(widget(action = true), "note.json", value, "")
        // The result was delivered before any folder I/O; the exchange is a separate job.
        assertTrue(remoteFiles(store).isEmpty()); assertEquals(1, a.jobs.size)
        a.jobs.removeAt(0)()
        assertEquals(1, remoteFiles(store).size); assertEquals(0, a.received)
        // A failed write or a read schedules nothing.
        runCatching { a.module.writeJSON(widget(action = true), "note.json", value, "stale") }
        a.module.readJSON(widget(), "note.json")
        assertTrue(a.jobs.isEmpty())

        // B picks the revision up on foreground recovery and asks for a widget redraw once.
        b.module.recover(listOf(OWNER, third))
        assertEquals(1, b.jobs.size)
        b.jobs.removeAt(0)()
        assertEquals(1, b.received)
        assertEquals("from A", b.read().getJSONObject("value").getString("text"))
        // Recovery runs at most every 15 seconds.
        b.now += 14_999; b.module.recover(listOf(OWNER)); assertTrue(b.jobs.isEmpty())
        b.now += 1; b.module.recover(listOf(OWNER)); assertEquals(1, b.jobs.size)
        b.jobs.removeAt(0)(); assertEquals(1, b.received)

        // A job never follows a removed installation, and its failure is only a code.
        a.module.writeJSON(widget(action = true), "note.json", value.put("text", "two"), a.read().getString("revision"))
        a.module.retire(OWNER)
        val lines = ArrayList<String>()
        val previous = SystemLog.sink
        SystemLog.sink = { lines += it }
        try { a.jobs.removeAt(0)() } finally { SystemLog.sink = previous }
        assertEquals(listOf("icloud.exchange -> icloud:notConnected"), lines)
        assertEquals(1, remoteFiles(store).size)
        assertEquals("icloud:notConnected", a.module.exchange(OWNER)); assertNull(b.module.exchange(OWNER))
        // Retiring keeps the files: reconnecting finds the unsent revision in the cache.
        a.store.connect(OWNER, existingStore = store)
        assertEquals("two", a.read().getJSONObject("value").getString("text"))
    }

    @Test fun fileFolderNeverOverwritesOrLeavesItsDirectory() {
        val directory = temporaryDirectory()
        val folder = FileSyncFolder(directory)
        assertTrue(folder.isAvailable); assertFalse(FileSyncFolder(File(directory, "missing")).isAvailable)
        val sub = folder.createDirectory(folder.root, "docs")
        assertEquals("docs", folder.createDirectory(folder.root, "docs").name)
        val file = folder.createFile(sub, "a.json", "one".toByteArray())
        assertEquals("one", String(folder.read(file, 16)))
        // An existing name is never replaced.
        try { folder.createFile(sub, "a.json", "two".toByteArray()); org.junit.Assert.fail() } catch (error: SyncFolderException) { assertFalse(error.tooMany) }
        assertEquals("one", File(directory, "docs/a.json").readText())
        assertEquals(listOf("a.json"), File(directory, "docs").list()!!.toList())
        // Names are single path components.
        for (name in listOf("", ".", "..", "../escape.json", "a/b.json", "a\\b.json", "/abs.json", "nul\u0000.json")) {
            try { folder.createFile(sub, name, ByteArray(1)); org.junit.Assert.fail(name) } catch (error: SyncFolderException) { }
            try { folder.createDirectory(sub, name); org.junit.Assert.fail(name) } catch (error: SyncFolderException) { }
        }
        assertFalse(File(directory, "escape.json").exists())
        // Bounded reads and listings; links are reported, not followed.
        try { folder.read(file, 2); org.junit.Assert.fail() } catch (error: SyncFolderException) { }
        folder.createFile(sub, "b.json", ByteArray(1))
        try { folder.children(sub, 1); org.junit.Assert.fail() } catch (error: SyncFolderException) { assertTrue(error.tooMany) }
        Files.createSymbolicLink(File(directory, "docs/link.json").toPath(), File(directory, "docs/a.json").toPath())
        val kinds = folder.children(sub, 10).associate { it.name to it.kind }
        assertEquals(SyncNode.Kind.OTHER, kinds["link.json"]); assertEquals(SyncNode.Kind.FILE, kinds["a.json"])
        assertEquals(SyncNode.Kind.DIRECTORY, folder.children(folder.root, 10).single().kind)
        try { folder.read(folder.children(sub, 10).first { it.name == "link.json" }, 16); org.junit.Assert.fail() } catch (error: SyncFolderException) { }
        try { folder.children(SyncNode("x", SyncNode.Kind.DIRECTORY, 0, File(directory, "missing")), 10); org.junit.Assert.fail() } catch (error: SyncFolderException) { }
    }
}
