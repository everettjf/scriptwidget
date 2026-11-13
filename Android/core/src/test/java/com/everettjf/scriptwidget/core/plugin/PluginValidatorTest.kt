package com.everettjf.scriptwidget.core.plugin

import com.everettjf.scriptwidget.core.plugin.PluginFixtures.array
import com.everettjf.scriptwidget.core.plugin.PluginFixtures.assertRejected
import com.everettjf.scriptwidget.core.plugin.PluginFixtures.failure
import com.everettjf.scriptwidget.core.plugin.PluginFixtures.operation
import com.everettjf.scriptwidget.core.plugin.PluginFixtures.parameter
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PluginValidatorTest {
    // Swift: testBuiltInPluginsValidate
    @Test
    fun builtInPluginsValidate() {
        assertEquals(2, PluginStore.BUILT_INS.size)
        for (plugin in PluginStore.BUILT_INS) assertEquals(plugin.id, emptyList<PluginValidationIssue>(), PluginValidator.validate(plugin))
    }

    @Test
    fun builtInPluginsSurviveEncodingAndDecoding() {
        for (plugin in PluginStore.BUILT_INS) assertEquals(plugin, PluginValidator.decode(plugin.toJson().toByteArray()))
        val manifest = PluginFixtures.manifest()
        assertEquals(manifest, PluginValidator.decode(manifest.toJson().toByteArray()))
    }

    @Test
    fun decodesEveryField() {
        val manifest = PluginFixtures.manifest()
        assertEquals(PluginFixtures.ID, manifest.id)
        assertEquals("https://api.example.com", manifest.baseURL)
        assertEquals(listOf("api.example.com"), manifest.hosts)
        val update = manifest.operations[0]
        assertEquals("POST", update.method)
        assertEquals(PluginResponseType.JSON, update.responseType)
        assertEquals(PluginParameter("page", "Page", PluginParameterLocation.QUERY, false, "1"), update.parameters[1])
        assertNull(update.parameters[2].defaultValue)
        assertEquals(PluginResponseType.TEXT, manifest.operations[1].responseType)
    }

    // Swift: testManifestDecoderFailsClosedAndRejectsHTTP
    @Test
    fun unknownKeysFailClosedAtEveryLevel() {
        assertRejected("plugin.json contains unknown fields.") { it.put("unexpected", true) }
        assertRejected("plugin.json contains unknown fields.") { it.put("nativeLibrary", "libplugin.so") }
        assertRejected("Plugin operation contains unknown fields.") { operation(it).put("script", "fetch()") }
        assertRejected("Plugin operation contains unknown fields.") { parameter(it, 0).put("secret", "x") }
    }

    @Test
    fun httpBaseURLIsRejected() {
        val unsafe = PluginStore.BUILT_INS[0].copy(baseURL = "http://api.open-meteo.com")
        assertFalse(PluginValidator.validate(unsafe).isEmpty())
        assertRejected("baseURL must be an HTTPS URL without credentials, query, or fragment.") { it.put("baseURL", "http://api.example.com") }
    }

    @Test
    fun baseURLRules() {
        val message = "baseURL must be an HTTPS URL without credentials, query, or fragment."
        for (url in listOf("ftp://api.example.com", "https://user:pw@api.example.com", "https://user@api.example.com", "https://api.example.com?key=1",
            "https://api.example.com/#top", "api.example.com", "https:///path", "", "https://api example.com", "file:///etc/hosts")) {
            assertRejected(message) { it.put("baseURL", url) }
        }
        assertRejected("baseURL host must be included in hosts.") { it.put("baseURL", "https://other.example.com") }
        // A port and a base path are allowed.
        assertEquals("https://api.example.com:8443/v2", PluginFixtures.manifest { it.put("baseURL", "https://api.example.com:8443/v2") }.baseURL)
    }

    @Test
    fun versionsFailClosed() {
        assertRejected("Unsupported Data Source Plugin format 2.") { it.put("formatVersion", 2) }
        assertRejected("Unsupported Data Source Plugin format 0.") { it.put("formatVersion", 0) }
        assertRejected("\"formatVersion\" is missing or has the wrong type") { it.put("formatVersion", "1") }
        assertRejected("\"formatVersion\" is missing or has the wrong type") { it.put("formatVersion", 1.5) }
        assertRejected("\"formatVersion\" is missing or has the wrong type") { it.remove("formatVersion") }
        assertRejected("Plugin requires unsupported runtime 2.0.") { it.put("minimumRuntimeVersion", "2.0") }
        assertRejected("Plugin requires unsupported runtime 1.6.") { it.put("minimumRuntimeVersion", "1.6") }
        assertRejected("Plugin version must use semantic versioning.") { it.put("version", "1.0") }
        assertRejected("Plugin version must use semantic versioning.") { it.put("version", "v1.0.0") }
        assertEquals("1.0.0-beta.1", PluginFixtures.manifest { it.put("version", "1.0.0-beta.1") }.version)
    }

    @Test
    fun identifierAndNameRules() {
        for (id in listOf("ab", "-abc", "has space", "a/b/c", "a".repeat(129), "abc\n")) assertRejected("Plugin id must be a stable 3–128 character identifier.") { it.put("id", id) }
        assertRejected("Plugin name must contain 1–80 characters.") { it.put("name", "  ") }
        assertRejected("Plugin name must contain 1–80 characters.") { it.put("name", "n".repeat(81)) }
        assertEquals(80, PluginFixtures.manifest { it.put("name", "n".repeat(80)) }.name.length)
    }

    @Test
    fun privateAndLocalHostsAreRejected() {
        for (host in listOf("localhost", "127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.0.1", "printer.local")) {
            assertRejected("Plugin host must be a public Internet host: $host.") { it.put("baseURL", "https://$host").put("hosts", array(host)) }
        }
        assertRejected("Plugin host must be a public Internet host: *.local.") { it.put("hosts", array("api.example.com", "*.local")) }
        assertRejected("baseURL") { it.put("baseURL", "https://[::1]").put("hosts", array("api.example.com")) }
    }

    @Test
    fun hostDeclarationRules() {
        assertRejected("A plugin must declare 1–20 HTTPS hosts.") { it.put("hosts", JSONArray()) }
        assertRejected("A plugin must declare 1–20 HTTPS hosts.") { it.put("hosts", JSONArray((0..20).map { index -> if (index == 0) "api.example.com" else "h$index.example.com" })) }
        assertRejected("Plugin hosts must be unique.") { it.put("hosts", array("api.example.com", "api.example.com")) }
        for (host in listOf("https://api.example.com", "api.example.com/path", "api.example.com:443", "API.example.com", ".example.com", "example.com.", "api.*.com", "*example.com", "*.*.example.com", "exa mple.com")) {
            assertRejected("Invalid plugin host declaration: $host.") { it.put("hosts", array("api.example.com", host)) }
        }
        assertRejected("\"hosts\" is missing or has the wrong type") { it.put("hosts", array("api.example.com", 7)) }
        assertEquals(listOf("*.example.com"), PluginFixtures.manifest { it.put("hosts", array("*.example.com")) }.hosts)
    }

    @Test
    fun operationRules() {
        assertRejected("A plugin must contain 1–50 operations.") { it.put("operations", JSONArray()) }
        assertRejected("A plugin must contain 1–50 operations.") { root ->
            root.put("operations", JSONArray((0..50).map { JSONObject(operation(root, 1).toString()).put("id", "status-$it") }))
        }
        assertRejected("Operation ids must be unique.") { operation(it, 1).put("id", "UPDATE") }
        assertRejected("Operation id is invalid: a b.") { operation(it, 1).put("id", "a b") }
        for (method in listOf("get", "HEAD", "OPTIONS", "CONNECT", "TRACE", "")) assertRejected("Operation status has an unsupported HTTP method.") { operation(it, 1).put("method", method) }
        val pathMessage = "Operation path must be an absolute URL path without traversal, query, or fragment."
        for (path in listOf("", "status", "/a/../b", "/status?x=1", "/status#top", "//evil.example.com/..")) assertRejected(pathMessage) { operation(it, 1).put("path", path) }
        assertRejected("\"responseType\" is missing or has the wrong type") { operation(it, 1).put("responseType", "xml") }
        assertRejected("\"title\" is missing or has the wrong type") { operation(it, 1).remove("title") }
        assertRejected("plugin.json contains unknown fields.") { it.put("operations", "none") }
        assertRejected("Plugin operation contains unknown fields.") { operation(it, 1).put("parameters", "none") }
    }

    @Test
    fun parameterDeclarationRules() {
        assertRejected("Operation status has too many parameters.") { root ->
            operation(root, 1).put("parameters", JSONArray((0..30).map { JSONObject().put("id", "param-$it").put("label", "P").put("location", "query").put("required", false) }))
        }
        assertRejected("Operation parameter ids must be unique.") { parameter(it, 1).put("id", "ENABLED") }
        assertRejected("Invalid parameter id: p!.") { parameter(it, 1).put("id", "p!") }
        assertRejected("Path parameter page has no matching placeholder.") { parameter(it, 1).put("location", "path") }
        assertRejected("Placeholder user must be a path parameter.") { parameter(it, 0).put("location", "query") }
        assertRejected("Path placeholder team has no declared parameter.") { operation(it).put("path", "/teams/{team}/users/{user}") }
        assertRejected("\"location\" is missing or has the wrong type") { parameter(it, 1).put("location", "cookie") }
        assertRejected("\"required\" is missing or has the wrong type") { parameter(it, 1).put("required", "yes") }
        assertRejected("\"required\" is missing or has the wrong type") { parameter(it, 1).remove("required") }
        assertRejected("\"defaultValue\" is missing or has the wrong type") { parameter(it, 1).put("defaultValue", 1) }
        assertRejected("\"label\" is missing or has the wrong type") { parameter(it, 1).put("label", 5) }
    }

    @Test
    fun everyIssueIsReported() {
        val error = failure { PluginValidator.decode(PluginFixtures.json { it.put("id", "x").put("version", "1").put("formatVersion", 3) }) }
        assertEquals("Unsupported Data Source Plugin format 3.\nPlugin id must be a stable 3–128 character identifier.\nPlugin version must use semantic versioning.", error.message)
    }

    @Test
    fun oversizeAndMalformedDocumentsAreRejected() {
        val padded = PluginFixtures.json { it.put("summary", "s".repeat(PluginValidator.MAXIMUM_MANIFEST_BYTES)) }
        assertEquals("plugin.json exceeds 256 KiB.", failure { PluginValidator.decode(padded) }.message)
        assertEquals("plugin.json must be an object.", failure { PluginValidator.decode("[]".toByteArray()) }.message)
        assertEquals("plugin.json must be UTF-8 JSON.", failure { PluginValidator.decode(byteArrayOf(0x7B, 0xFF.toByte(), 0x7D)) }.message)
        val valid = String(PluginFixtures.json())
        for (text in listOf("", "{", "$valid trailing", "$valid$valid", valid.replace("\"formatVersion\"", "formatVersion"), valid.replace('"', '\''),
            valid.replaceFirst("{", "{ // comment\n"), valid.replaceFirst("{", "{\"id\":\"dev.scriptwidget.first\","))) {
            assertEquals(text.take(40), "plugin.json is not valid JSON.", failure { PluginValidator.decode(text.toByteArray()) }.message)
        }
    }

    @Test
    fun strictJsonAcceptsOnlyTheStandardGrammar() {
        assertEquals(mapOf("a" to listOf(1L, 2.5, true, null, "x\n\u00e9")), StrictJson.parse(""" {"a": [1, 2.5, true, null, "x\n\u00e9"]} """))
        for (text in listOf("01", "1.", ".5", "+1", "[1,]", "{\"a\":1,}", "\"a\tb\"", "nul", "NaN", "\"\\x41\"", "[" .repeat(600) + "]".repeat(600))) {
            assertTrue(text.take(20), runCatching { StrictJson.parse(text) }.exceptionOrNull() is StrictJson.JsonException)
        }
        assertEquals("\"a\\\"b\\\\c/d\\n\\u0001\"", StrictJson.quote("a\"b\\c/d\n\u0001"))
    }

    @Test
    fun domainDeclarationsMatchSwift() {
        assertTrue(PluginValidator.isValidDomainDeclaration("api.example.com"))
        assertTrue(PluginValidator.isValidDomainDeclaration("*.example.com"))
        assertFalse(PluginValidator.isValidDomainDeclaration("Api.example.com"))
        assertFalse(PluginValidator.isValidDomainDeclaration("api.example.com:8443"))
        assertFalse(PluginValidator.isValidDomainDeclaration("a*.example.com"))
    }
}
