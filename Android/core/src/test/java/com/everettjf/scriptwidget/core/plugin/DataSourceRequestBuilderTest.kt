package com.everettjf.scriptwidget.core.plugin

import com.everettjf.scriptwidget.core.plugin.PluginFixtures.failure
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DataSourceRequestBuilderTest {
    private val plugin = PluginFixtures.manifest()
    private val github = PluginStore.BUILT_INS.first { it.id == "app.scriptwidget.datasource.github" }
    private val weather = PluginStore.BUILT_INS.first { it.id == "app.scriptwidget.datasource.open-meteo" }

    // Swift: testRequestBuilderMapsPathQueryHeaderAndJSONBody
    @Test
    fun mapsPathQueryHeaderAndJSONBody() {
        val prepared = DataSourceRequestBuilder.prepare(plugin, "update", mapOf("user" to "hello world", "X-Token" to "secret", "enabled" to true))
        assertEquals("https://api.example.com/users/hello%20world?page=1", prepared.uri.toString())
        assertEquals("POST", prepared.method)
        assertEquals("secret", prepared.headers["X-Token"])
        assertEquals("ScriptWidget-DataSource/1", prepared.headers["User-Agent"])
        assertEquals("application/json", prepared.headers["Content-Type"])
        assertEquals(true, JSONObject(String(prepared.body!!)).get("enabled"))
    }

    @Test
    fun defaultsFillMissingValuesAndSuppliedValuesWin() {
        assertEquals("https://api.github.com/repos/everettjf/scriptwidget", DataSourceRequestBuilder.prepare(github, "repository", emptyMap()).uri.toString())
        assertEquals("https://api.github.com/repos/quickjs-ng/quickjs", DataSourceRequestBuilder.prepare(github, "repository", mapOf("owner" to "quickjs-ng", "repo" to "quickjs")).uri.toString())
        val forecast = DataSourceRequestBuilder.prepare(weather, "forecast", mapOf("latitude" to 48.85, "longitude" to 2, "undeclared" to "ignored"))
        assertEquals("https://api.open-meteo.com/v1/forecast?latitude=48.85&longitude=2&current=temperature_2m,weather_code&timezone=auto", forecast.uri.toString())
        assertNull(forecast.body)
        assertEquals(setOf("User-Agent"), forecast.headers.keys)
    }

    @Test
    fun pathValuesCannotChangeThePathStructure() {
        fun path(owner: Any?) = DataSourceRequestBuilder.prepare(github, "repository", mapOf("owner" to owner, "repo" to "r")).uri.rawPath
        assertEquals("/repos/a%2Fb/r", path("a/b"))
        assertEquals("/repos/a%3Fx=1%23f/r", path("a?x=1#f"))
        assertEquals("/repos/%7Brepo%7D/r", path("{repo}"))
        assertEquals("/repos/%E4%BD%A0%E5%A5%BD%25/r", path("你好%"))
        assertEquals("/repos/a-b_c.d~e!$&'()*+,=:@/r", path("a-b_c.d~e!$&'()*+,=:@"))
        assertEquals("/repos/a%3Bb%20c%5Cd/r", path("a;b c\\d"))
        assertEquals("/repos/1/r", path(true))
        assertEquals("/repos/42/r", path(42))
        for (value in listOf("..", ".")) assertEquals("Could not encode owner.", failure { path(value) }.message)
        assertEquals("Could not encode owner.", failure { path(JSONObject().put("a", 1)) }.message)
        assertEquals("Could not encode owner.", failure { path(Double.NaN) }.message)
    }

    @Test
    fun queryValuesCannotAddQueryItems() {
        fun query(value: Any?) = DataSourceRequestBuilder.prepare(weather, "forecast", mapOf("timezone" to value)).uri.rawQuery.substringAfter("timezone=")
        assertEquals("a%26b%3Dc%23d", query("a&b=c#d"))
        assertEquals("Europe/Paris", query("Europe/Paris"))
        assertEquals("a%20b+c", query("a b+c"))
        assertEquals("%E2%82%AC", query("€"))
        assertEquals("0", query(false))
        assertEquals("1.5", query(1.5))
        // An empty optional value is omitted; null falls back to the default.
        assertTrue(!DataSourceRequestBuilder.prepare(weather, "forecast", mapOf("timezone" to "")).uri.rawQuery.contains("timezone"))
        assertEquals("auto", query(JSONObject.NULL))
        assertEquals("auto", query(null))
    }

    @Test
    fun missingRequiredParametersAreReported() {
        assertEquals("Missing required parameter user.", failure { DataSourceRequestBuilder.prepare(plugin, "update", mapOf("X-Token" to "t", "enabled" to true)) }.message)
        assertEquals("Missing required parameter X-Token.", failure { DataSourceRequestBuilder.prepare(plugin, "update", mapOf("user" to "u", "enabled" to true)) }.message)
        val error = failure { DataSourceRequestBuilder.prepare(plugin, "update", mapOf("user" to "u", "X-Token" to "t", "enabled" to "")) }
        assertEquals("Missing required parameter enabled.", error.message)
        assertEquals(PluginException.Kind.INVALID_PARAMETERS, error.kind)
        // A supplied empty string does not fall back to the default (Swift behavior).
        assertEquals("Missing required parameter latitude.", failure { DataSourceRequestBuilder.prepare(weather, "forecast", mapOf("latitude" to "")) }.message)
    }

    @Test
    fun unknownOperationIsNotFound() {
        val error = failure { DataSourceRequestBuilder.prepare(plugin, "missing", emptyMap()) }
        assertEquals(PluginException.Kind.NOT_FOUND, error.kind)
        assertEquals("Operation missing was not found in ${PluginFixtures.ID}.", error.message)
    }

    @Test
    fun headerValuesCannotInjectHeaders() {
        val values = mapOf("user" to "u", "enabled" to true)
        for (token in listOf("a\r\nX-Evil: 1", "a\nb", "a\u0000b")) {
            assertEquals("Could not encode X-Token.", failure { DataSourceRequestBuilder.prepare(plugin, "update", values + ("X-Token" to token)) }.message)
        }
        assertEquals("Could not encode X-Token.", failure { DataSourceRequestBuilder.prepare(plugin, "update", values + ("X-Token" to JSONArray())) }.message)
    }

    @Test
    fun reservedHeadersAreSetByTheRuntime() {
        val custom = PluginFixtures.manifest { root ->
            PluginFixtures.parameter(root, 2).put("id", "user-agent")
            PluginFixtures.operation(root).getJSONArray("parameters").put(JSONObject().put("id", "content-type").put("label", "Type").put("location", "header").put("required", false))
        }
        val prepared = DataSourceRequestBuilder.prepare(custom, "update", mapOf("user" to "u", "user-agent" to "Mozilla", "content-type" to "text/plain", "enabled" to 1))
        assertEquals(mapOf("User-Agent" to "ScriptWidget-DataSource/1", "Content-Type" to "application/json"), prepared.headers)
    }

    @Test
    fun jsonBodyKeepsStructuredValues() {
        val nested = JSONObject().put("tags", JSONArray(listOf("a", "b")))
        val prepared = DataSourceRequestBuilder.prepare(plugin, "update", mapOf("user" to "u", "X-Token" to "t", "enabled" to nested))
        assertEquals("b", JSONObject(String(prepared.body!!)).getJSONObject("enabled").getJSONArray("tags").getString(1))
        val number = DataSourceRequestBuilder.prepare(plugin, "update", mapOf("user" to "u", "X-Token" to "t", "enabled" to 3))
        assertEquals(3, JSONObject(String(number.body!!)).getInt("enabled"))
    }

    @Test
    fun basePathAndPortArePreserved() {
        val versioned = PluginFixtures.manifest { it.put("baseURL", "https://api.example.com:8443/v2") }
        assertEquals("https://api.example.com:8443/v2/status", DataSourceRequestBuilder.prepare(versioned, "status", emptyMap()).uri.toString())
        val slash = PluginFixtures.manifest { it.put("baseURL", "https://api.example.com/") }
        assertEquals("https://api.example.com/status", DataSourceRequestBuilder.prepare(slash, "status", emptyMap()).uri.toString())
    }

    @Test
    fun requestsCannotLeaveTheDeclaredHosts() {
        // Not reachable through the validator; the builder still refuses a tampered manifest.
        val escaped = plugin.copy(baseURL = "https://evil.example.net")
        val error = failure { DataSourceRequestBuilder.prepare(escaped, "status", emptyMap()) }
        assertEquals(PluginException.Kind.PERMISSION, error.kind)
        assertEquals("Plugin request escaped its declared hosts.", error.message)
        assertEquals("Plugin request escaped its declared hosts.", failure { DataSourceRequestBuilder.prepare(plugin.copy(baseURL = "http://api.example.com"), "status", emptyMap()) }.message)
        assertEquals("Invalid plugin baseURL.", failure { DataSourceRequestBuilder.prepare(plugin.copy(baseURL = "not a url"), "status", emptyMap()) }.message)
        val unresolved = plugin.copy(operations = listOf(plugin.operations[1].copy(path = "/x/{gone}")))
        assertEquals("A path parameter is unresolved.", failure { DataSourceRequestBuilder.prepare(unresolved, "status", emptyMap()) }.message)
    }

    // MARK: - Response mapping

    private val jsonOperation = plugin.operations[0]
    private val textOperation = plugin.operations[1]

    @Test
    fun jsonResponsesPassThroughUnchanged() {
        val body = """{"temperature": 21.50, "tags": ["a", null], "big": 12345678901234567890}"""
        assertEquals(body, DataSourceResponseMapper.map(jsonOperation, 200, body.toByteArray()))
        assertEquals("[1,2]", DataSourceResponseMapper.map(jsonOperation, 204, "﻿[1,2]".toByteArray()))
        assertEquals("""{"a":1,"a":2}""", DataSourceResponseMapper.map(jsonOperation, 200, """{"a":1,"a":2}""".toByteArray()))
    }

    @Test
    fun invalidJsonResponsesAreRejected() {
        for (body in listOf("", "<html>", "{\"a\":}", "{} trailing", "\"text\"", "42", "null", "{'a':1}")) {
            val error = failure { DataSourceResponseMapper.map(jsonOperation, 200, body.toByteArray()) }
            assertEquals(body, "Data source returned invalid JSON", error.message)
            assertEquals(PluginException.Kind.NETWORK, error.kind)
        }
        assertEquals("Data source returned invalid JSON", failure { DataSourceResponseMapper.map(jsonOperation, 200, byteArrayOf(0x7B, 0xC3.toByte(), 0x28, 0x7D)) }.message)
    }

    @Test
    fun textResponsesBecomeJsonStrings() {
        assertEquals("\"line 1\\n\\\"quoted\\\" é\"", DataSourceResponseMapper.map(textOperation, 200, "line 1\n\"quoted\" é".toByteArray()))
        assertEquals("\"\"", DataSourceResponseMapper.map(textOperation, 200, ByteArray(0)))
        assertEquals("Data source returned non-UTF-8 text", failure { DataSourceResponseMapper.map(textOperation, 200, byteArrayOf(0xFF.toByte(), 0xFE.toByte())) }.message)
    }

    @Test
    fun failedAndOversizeResponsesAreRejected() {
        for (status in listOf(199, 301, 404, 500)) assertEquals("Data source request failed", failure { DataSourceResponseMapper.map(jsonOperation, status, "{}".toByteArray()) }.message)
        val oversize = ByteArray(DataSourceResponseMapper.MAXIMUM_RESPONSE_BYTES + 1) { 'a'.code.toByte() }
        assertEquals("Data source response exceeds 2 MiB.", failure { DataSourceResponseMapper.map(textOperation, 200, oversize) }.message)
        assertEquals(2 * 1024 * 1024, DataSourceResponseMapper.MAXIMUM_RESPONSE_BYTES)
    }
}
