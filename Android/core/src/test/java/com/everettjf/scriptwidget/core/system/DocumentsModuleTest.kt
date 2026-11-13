package com.everettjf.scriptwidget.core.system

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class DocumentsModuleTest {
    private val directory = temporaryDirectory()
    private val store = DocumentStore(directory)
    private val module = DocumentsModule(store)
    private val declared = setOf("documents")
    private fun widget(installation: String = OWNER, queries: Int = 8) = context(declared, installation = installation, queries = queries)
    private fun csv(text: String) = DocumentRules.csv(text.toByteArray())
    private fun rows(result: JSONObject): List<List<String>> = result.getJSONArray("rows").let { rows -> List(rows.length()) { r -> rows.getJSONArray(r).let { row -> List(row.length()) { row.getString(it) } } } }
    private fun headers(result: JSONObject): List<String> = result.getJSONArray("headers").let { h -> List(h.length()) { h.getString(it) } }

    @Test fun csvBasics() {
        val table = csv("name,city\nAda,London\nLinus,Helsinki\n")
        assertEquals(setOf("headers", "rows", "truncated"), table.keys().asSequence().toSet())
        assertEquals(listOf("name", "city"), headers(table))
        assertEquals(listOf(listOf("Ada", "London"), listOf("Linus", "Helsinki")), rows(table))
        assertFalse(table.getBoolean("truncated"))
        // No trailing newline, CR LF and bare CR line endings, and a byte-order mark all parse the same.
        for (text in listOf("name,city\nAda,London\nLinus,Helsinki", "name,city\r\nAda,London\r\nLinus,Helsinki\r\n", "name,city\rAda,London\rLinus,Helsinki", "﻿name,city\nAda,London\nLinus,Helsinki\n")) {
            assertEquals(Canonical.encode(table), Canonical.encode(csv(text)))
        }
        // A header alone is a table without rows; empty cells are kept.
        assertTrue(rows(csv("only\n")).isEmpty())
        assertEquals(listOf(listOf("", "x"), listOf("y", "")), rows(csv("a,b\n,x\ny,\n")))
        assertEquals(listOf(listOf("né", "東京 🗼")), rows(csv("who,where\nné,東京 🗼\n")))
    }

    @Test fun csvQuoting() {
        val table = csv("id,text\n1,\"a, b\"\n2,\"line one\nline two\"\n3,\"she said \"\"hi\"\"\"\n4,\"\"\n5,\"cr\r\nlf\"\n")
        assertEquals(listOf(listOf("1", "a, b"), listOf("2", "line one\nline two"), listOf("3", "she said \"hi\""), listOf("4", ""), listOf("5", "cr\r\nlf")), rows(table))
        assertEquals(listOf("a b", "c"), headers(csv("\"a b\",c\n1,2")))
        // A quoted empty last field still ends its row.
        assertEquals(listOf(listOf("1", "")), rows(csv("a,b\n1,\"\"")))
        val malformed = listOf(
            "a,b\n1,x\"y\"\n", // a quote inside an unquoted field
            "a,b\n1,\"x\"y\n", // text after a closing quote
            "a,b\n1,\"x\" \n", // even a space after a closing quote
            "a,b\n1,\"x\"\"y\n", // unclosed after an escaped quote
            "a,b\n1,\"never closed\n", // unclosed quote
            "a,b\n1,\"x\"\"\"y\n",
        )
        for (text in malformed) assertRejects("invalid_options") { csv(text) }
    }

    @Test fun csvShapeRules() {
        val invalid = listOf(
            "", "\n", "﻿", // no header
            "a,,c\n1,2,3\n", // an empty header name
            "a,b,a\n1,2,3\n", // duplicate header names
            "a,b\n1\n", "a,b\n1,2,3\n", // ragged rows
            "a,b\n1,2\n\n3,4\n", // a blank line is a row with one empty cell
        )
        for (text in invalid) assertRejects("invalid_options") { csv(text) }
        assertRejects("invalid_options") { DocumentRules.csv(byteArrayOf('a'.code.toByte(), ','.code.toByte(), 0xC3.toByte(), 0x28)) } // invalid UTF-8
        assertRejects("invalid_options") { DocumentRules.csv(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 'a'.code.toByte(), 0)) } // UTF-16
        // A single-column file may contain blank lines: each is one empty cell.
        assertEquals(listOf(listOf("1"), listOf(""), listOf("2")), rows(csv("a\n1\n\n2\n")))
    }

    @Test fun csvLimits() {
        val header32 = (1..32).joinToString(",") { "c$it" }
        assertEquals(32, headers(csv("$header32\n")).size)
        assertRejects("limit_exceeded") { csv("$header32,c33\n") }
        val body500 = (1..500).joinToString("\n") { "$it" }
        assertEquals(500, rows(csv("n\n$body500\n")).size)
        assertEquals(500, rows(csv("n\n$body500")).size)
        assertRejects("limit_exceeded") { csv("n\n$body500\n501\n") }
        // 8 KiB per cell, counted in UTF-8 bytes, quoted or not.
        assertEquals(8192, rows(csv("v\n${"x".repeat(8192)}\n"))[0][0].length)
        assertRejects("limit_exceeded") { csv("v\n${"x".repeat(8193)}\n") }
        assertRejects("limit_exceeded") { csv("v\n\"${"x".repeat(8193)}\"\n") }
        assertEquals(4096, rows(csv("v\n${"é".repeat(4096)}\n"))[0][0].length)
        assertRejects("limit_exceeded") { csv("v\n${"é".repeat(4097)}\n") }
        assertEquals(2048, rows(csv("v\n${"🗼".repeat(2048)}\n"))[0][0].codePointCount(0, 4096))
        assertRejects("limit_exceeded") { csv("v\n${"🗼".repeat(2048)}x\n") }
        // 256 KiB per file.
        val filler = "v\n" + (1..31).joinToString("\n") { "y".repeat(8191) } + "\n"
        assertTrue(filler.length < DocumentRules.MAXIMUM_BYTES)
        assertEquals(31, rows(csv(filler)).size)
        assertRejects("invalid_options") { DocumentRules.csv(ByteArray(DocumentRules.MAXIMUM_BYTES + 1) { 'a'.code.toByte() }) }
    }

    @Test fun jsonRules() {
        assertEquals("{\"b\":[1,2.5,true,null,\"x\"],\"a\":{\"nested\":\"é\"}}", DocumentRules.json("{\"b\": [1, 2.5, true, null, \"x\"], \"a\": {\"nested\": \"é\"}}".toByteArray()))
        assertEquals("[]", DocumentRules.json(" [ ] \n".toByteArray()))
        assertEquals("{}", DocumentRules.json("﻿{}".toByteArray()))
        assertEquals("[9007199254740993,-0.5,1.0E21]", DocumentRules.json("[9007199254740993,-0.5,1e21]".toByteArray()))
        for (root in listOf("\"text\"", "42", "true", "null")) assertRejects("invalid_options") { DocumentRules.json(root.toByteArray()) }
        // Content is data: anything that is not strict JSON is refused, never evaluated.
        for (text in listOf("", "{", "{'a':1}", "{a:1}", "[1,]", "[1] [2]", "// comment\n[]", "alert(1)", "[NaN]", "[1e999]")) {
            assertRejectsWith(SystemServiceError.FAILED) { DocumentRules.json(text.toByteArray()) }
        }
        assertRejectsWith(SystemServiceError.FAILED) { DocumentRules.json(byteArrayOf('['.code.toByte(), '"'.code.toByte(), 0xC3.toByte(), 0x28, '"'.code.toByte(), ']'.code.toByte())) }
        assertRejects("limit_exceeded") { DocumentRules.json(("[" + " ".repeat(DocumentRules.MAXIMUM_BYTES) + "]").toByteArray()) }
        assertNotNull(DocumentRules.json(("[" + " ".repeat(DocumentRules.MAXIMUM_BYTES - 2) + "]").toByteArray()))
    }

    @Test fun namesAndTypes() {
        assertEquals("json", DocumentRules.type("Data.JSON", null)); assertEquals("csv", DocumentRules.type("table.csv", "text/plain"))
        assertEquals("json", DocumentRules.type("download", "application/json")); assertEquals("csv", DocumentRules.type("export", "text/comma-separated-values"))
        assertNull(DocumentRules.type("notes.txt", "text/plain")); assertNull(DocumentRules.type("script.js", "application/javascript")); assertNull(DocumentRules.type("json", null))
        assertEquals("data.json", DocumentRules.name("/storage/emulated/0/Download/data.json"))
        assertEquals("ab.csv", DocumentRules.name("a\u0000b​.csv")); assertEquals("Untitled", DocumentRules.name("  \n")); assertEquals("Untitled", DocumentRules.name(null))
        assertEquals(255, DocumentRules.name("x".repeat(400)).length)
        assertTrue(DocumentRules.name("🗼".repeat(100)).toByteArray().size <= 255)
        assertTrue(DocumentRules.validID("11111111-1111-4111-8111-111111111111")); assertFalse(DocumentRules.validID("../index.json")); assertFalse(DocumentRules.validID("11111111-1111-4111-8111-11111111111G"))
    }

    @Test fun policyOrderAndEmptyState() {
        assertRejects("permission_denied") { module.list(context(emptySet())) }
        assertRejects("permission_denied") { module.list(context(declared, runtime = "1.5")) }
        assertRejects("permission_denied") { module.list(context(declared, hasManifest = false)) }
        assertRejects("permission_denied") { module.list(context(declared, installation = "preview")) }
        assertRejects("read_only") { module.list(context(declared, projection = true)) }
        assertRejects("read_only") { module.readJSON(context(declared, liveActivity = true), "x") }
        assertRejects("query_limit") { module.readCSV(widget(queries = 0), "x") }
        // Without an import the list is empty and no identifier is readable.
        assertEquals("[]", module.list(widget()).toString())
        for (id in listOf<Any?>(null, 5, "", "not-an-id", "../index.json", "11111111-1111-4111-8111-111111111111")) {
            assertRejects("permission_denied") { module.readJSON(widget(), id) }
            assertRejects("permission_denied") { module.readCSV(widget(), id) }
        }
        val budget = widget(queries = 2)
        module.list(budget); module.list(budget)
        assertRejects("query_limit") { module.list(budget) }
    }

    @Test fun importedCopiesAreReadableOnlyByTheirInstallationAndType() {
        val json = store.add(OWNER, "/sdcard/goals.json", "json", "{\"goal\":3}".toByteArray(), "content://provider/doc/1")!!
        val table = store.add(OWNER, "table.csv", "csv", "a,b\n1,2\n".toByteArray(), null)!!
        val theirs = store.add(OTHER_OWNER, "theirs.json", "json", "[1]".toByteArray(), null)!!
        assertTrue(DocumentRules.validID(json.id)); assertEquals("goals.json", json.name)

        val listed = module.list(widget())
        assertEquals(2, listed.length())
        assertEquals("{\"bytes\":10,\"id\":\"${json.id}\",\"name\":\"goals.json\",\"type\":\"json\"}", Canonical.encode(listed.getJSONObject(0)))
        assertFalse("the source never reaches a script", listed.toString().contains("content://"))
        assertEquals("{\"goal\":3}", module.readJSON(widget(), json.id))
        assertEquals(listOf(listOf("1", "2")), rows(module.readCSV(widget(), table.id)))
        // The wrong reader, another installation's identifier and another installation are all denied.
        assertRejects("permission_denied") { module.readCSV(widget(), json.id) }
        assertRejects("permission_denied") { module.readJSON(widget(), table.id) }
        assertRejects("permission_denied") { module.readJSON(widget(), theirs.id) }
        assertRejects("permission_denied") { module.readJSON(widget(OTHER_OWNER), json.id) }
        assertEquals("[1]", module.readJSON(widget(OTHER_OWNER), theirs.id))

        // A copy whose size no longer matches its record is not served.
        val home = File(directory, ownerFileName(OWNER, ""))
        assertFalse(home.name.contains(OWNER))
        File(home, json.id).writeText("{\"goal\":3,\"tampered\":true}")
        assertRejects("permission_denied") { module.readJSON(widget(), json.id) }
        assertTrue(store.replace(OWNER, json.id, "{\"goal\":4}".toByteArray()))
        assertEquals("{\"goal\":4}", module.readJSON(widget(), json.id))
        assertFalse(store.replace(OWNER, theirs.id, "[]".toByteArray()))

        assertEquals("content://provider/doc/1", store.remove(OWNER, json.id)!!.source)
        assertNull(store.remove(OWNER, json.id))
        assertRejects("permission_denied") { module.readJSON(widget(), json.id) }
        assertEquals(1, module.list(widget()).length())
    }

    @Test fun storeLimitsAndFailClosed() {
        assertNull(store.add("preview", "a.json", "json", "{}".toByteArray(), null))
        assertNull(store.add(OWNER, "a.txt", "txt", "{}".toByteArray(), null))
        assertNull(store.add(OWNER, "big.json", "json", ByteArray(DocumentRules.MAXIMUM_BYTES + 1), null))
        assertNotNull(store.add(OWNER, "max.csv", "csv", ByteArray(DocumentRules.MAXIMUM_BYTES) { 'a'.code.toByte() }, null))
        repeat(7) { assertNotNull(store.add(OWNER, "f$it.json", "json", "[$it]".toByteArray(), "content://provider/doc/$it")) }
        assertNull("at most eight files", store.add(OWNER, "ninth.json", "json", "[]".toByteArray(), null))
        assertEquals(8, module.list(widget()).length())
        assertNotNull(store.add(OTHER_OWNER, "theirs.json", "json", "[]".toByteArray(), null))

        // A malformed index is unavailable, never an empty list, and nothing can be added on top of it.
        val index = File(File(directory, ownerFileName(OWNER, "")), "index.json")
        val good = index.readText()
        for (bad in listOf("{}", "not json", good.replace("\"formatVersion\":1", "\"formatVersion\":2"), good.replace("\"type\":\"csv\"", "\"type\":\"exe\""),
            JSONObject(good).apply { getJSONArray("documents").getJSONObject(0).put("id", "../../escape") }.toString(),
            JSONObject(good).apply { getJSONArray("documents").put(getJSONArray("documents").getJSONObject(0)) }.toString())) {
            index.writeText(bad)
            assertRejects("unavailable") { module.list(widget()) }
            assertRejects("unavailable") { module.readJSON(widget(), "11111111-1111-4111-8111-111111111111") }
            assertNull(store.add(OWNER, "more.json", "json", "[]".toByteArray(), null))
        }
        // Retiring removes the copies and reports the sources whose read permission can be released.
        assertEquals(emptyList<String>(), module.retire(OWNER))
        index.parentFile!!.mkdirs(); index.writeText(good)
        assertEquals((0..6).map { "content://provider/doc/$it" }, module.retire(OWNER))
        assertFalse(index.parentFile!!.exists())
        assertEquals("[]", module.list(widget()).toString())
        assertEquals(1, module.list(widget(OTHER_OWNER)).length())
    }
}
