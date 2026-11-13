package com.everettjf.scriptwidget.core.system

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ContactsModuleTest {
    private val directory = temporaryDirectory()
    private val store = ContactStore(directory)
    private val module = ContactsModule(store)
    private val declared = setOf("contacts")
    private fun widget(installation: String = OWNER, queries: Int = 8) = context(declared, installation = installation, queries = queries)
    private fun pick(key: String, name: String = "Ada Lovelace", installation: String = OWNER) =
        store.put(installation, key, name, "Analytical Engines", listOf("+44 20 7946 0000"), listOf("ada@example.com"))

    @Test fun onlyTheDocumentedFieldsAreKeptAndBounded() {
        val contact = ContactRules.bounded("11111111-1111-4111-8111-111111111111", "  Ada\u0000 Lovelace​ ", null,
            listOf("+44 20 7946 0000", null, "", "+44 20 7946 0000", "2", "3", "4"), listOf("a@example.com", " b@example.com ", "c@example.com", "d@example.com"))
        assertEquals("Ada Lovelace", contact.name); assertEquals("", contact.organization)
        assertEquals(listOf("+44 20 7946 0000", "2", "3"), contact.phones)
        assertEquals(listOf("a@example.com", "b@example.com", "c@example.com"), contact.emails)
        assertEquals(setOf("id", "name", "organization", "phones", "emails"), contact.toJson().keys().asSequence().toSet())
        assertTrue(ContactRules.valid(contact))

        val long = ContactRules.bounded("11111111-1111-4111-8111-111111111111", "n".repeat(300), "o".repeat(300), listOf("5".repeat(200)), listOf("e".repeat(300)))
        assertEquals(256, long.name.length); assertEquals(256, long.organization.length); assertEquals(128, long.phones[0].length); assertEquals(256, long.emails[0].length)
        assertEquals(256, ContactRules.text("🗼".repeat(300), 256).codePointCount(0, 512))
        assertTrue(ContactRules.valid(long))
        assertFalse(ContactRules.valid(SelectedContact("not-an-id", "n", "", emptyList(), emptyList())))
        assertFalse(ContactRules.valid(SelectedContact(contact.id, "n", "", listOf("1", "2", "3", "4"), emptyList())))
        assertFalse(ContactRules.valid(SelectedContact(contact.id, "n\nm", "", emptyList(), emptyList())))
        assertFalse(ContactRules.valid(SelectedContact(contact.id, "n", "", emptyList(), listOf(""))))
    }

    @Test fun policyOrderAndEmptyState() {
        assertRejects("permission_denied") { module.selected(context(emptySet())) }
        assertRejects("permission_denied") { module.selected(context(declared, runtime = "1.5")) }
        assertRejects("permission_denied") { module.selected(context(declared, hasManifest = false)) }
        assertRejects("permission_denied") { module.selected(context(declared, installation = "preview")) }
        assertRejects("read_only") { module.selected(context(declared, projection = true)) }
        assertRejects("read_only") { module.selected(context(declared, liveActivity = true)) }
        assertRejects("query_limit") { module.selected(widget(queries = 0)) }
        assertEquals("[]", module.selected(widget()).toString())
    }

    @Test fun selectionIsPerInstallationAndReplacesTheSameContact() {
        assertTrue(pick("lookup-1")); assertTrue(pick("lookup-2", "Grace Hopper")); assertTrue(pick("lookup-1", installation = OTHER_OWNER))
        val mine = module.selected(widget())
        assertEquals(2, mine.length())
        val ada = mine.getJSONObject(0)
        assertEquals("{\"emails\":[\"ada@example.com\"],\"id\":\"${ada.getString("id")}\",\"name\":\"Ada Lovelace\",\"organization\":\"Analytical Engines\",\"phones\":[\"+44 20 7946 0000\"]}", Canonical.encode(ada))
        assertTrue("identifiers are app-made UUIDs, not system contact keys", ContactRules.validID(ada.getString("id")))
        assertEquals("Grace Hopper", mine.getJSONObject(1).getString("name"))
        val theirs = module.selected(widget(OTHER_OWNER))
        assertEquals(1, theirs.length())
        assertFalse(theirs.getJSONObject(0).getString("id") == ada.getString("id"))

        // Picking the same system contact again updates it in place and keeps its identifier.
        assertTrue(store.put(OWNER, "lookup-1", "Ada King", "", emptyList(), listOf("ada@example.org")))
        val updated = module.selected(widget()).getJSONObject(0)
        assertEquals(ada.getString("id"), updated.getString("id")); assertEquals("Ada King", updated.getString("name")); assertEquals(0, updated.getJSONArray("phones").length())
        assertEquals(2, module.selected(widget()).length())

        // Neither the system key nor the installation is stored in clear or used as a file name.
        val file = directory.listFiles()!!.first { it.name == ownerFileName(OWNER, ".json") }
        assertFalse(file.readText().contains("lookup-1")); assertFalse(file.name.contains(OWNER))

        assertFalse(store.remove(OTHER_OWNER, ada.getString("id")))
        assertTrue(store.remove(OWNER, ada.getString("id")))
        assertEquals(1, module.selected(widget()).length())
        module.retire(OWNER)
        assertEquals("[]", module.selected(widget()).toString())
        assertEquals(1, module.selected(widget(OTHER_OWNER)).length())
    }

    @Test fun limitsAndFailClosed() {
        assertFalse(pick("k", installation = "preview"))
        repeat(20) { assertTrue(pick("lookup-$it", "Person $it")) }
        assertFalse("at most twenty contacts", pick("lookup-20"))
        assertTrue("replacing still works at capacity", pick("lookup-3", "Renamed"))
        assertEquals(20, module.selected(widget()).length())

        val file = File(directory, ownerFileName(OWNER, ".json"))
        val good = file.readText()
        val extra = JSONObject(good).apply { getJSONArray("contacts").getJSONObject(0).put("note", "private") }.toString()
        val oversized = JSONObject(good).apply { getJSONArray("contacts").getJSONObject(0).put("name", "n".repeat(257)) }.toString()
        val duplicated = JSONObject(good).apply { getJSONArray("contacts").let { it.put(1, it.getJSONObject(0)) } }.toString()
        for (bad in listOf("{}", "not json", good.replace("\"formatVersion\":1", "\"formatVersion\":9"), extra, oversized, duplicated)) {
            file.writeText(bad)
            assertRejects("unavailable") { module.selected(widget()) }
            assertFalse(pick("lookup-new"))
        }
        store.clear(OWNER)
        assertEquals("[]", module.selected(widget()).toString())
    }
}
