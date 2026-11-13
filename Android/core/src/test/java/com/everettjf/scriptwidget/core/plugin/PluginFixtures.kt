package com.everettjf.scriptwidget.core.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail

object PluginFixtures {
    const val ID = "dev.scriptwidget.test-source"

    /** The plugin of `testRequestBuilderMapsPathQueryHeaderAndJSONBody` in the Swift tests. */
    const val BASE = """{
      "formatVersion": 1, "id": "dev.scriptwidget.test-source", "name": "Test Source", "version": "1.0.0",
      "summary": "Test", "symbol": "network", "author": "Tests", "license": "MIT", "minimumRuntimeVersion": "1.0",
      "baseURL": "https://api.example.com", "hosts": ["api.example.com"],
      "operations": [
        {"id": "update", "title": "Update", "method": "POST", "path": "/users/{user}", "responseType": "json", "parameters": [
          {"id": "user", "label": "User", "location": "path", "required": true},
          {"id": "page", "label": "Page", "location": "query", "required": false, "defaultValue": "1"},
          {"id": "X-Token", "label": "Token", "location": "header", "required": true, "defaultValue": null},
          {"id": "enabled", "label": "Enabled", "location": "jsonBody", "required": true}
        ]},
        {"id": "status", "title": "Status", "method": "GET", "path": "/status", "responseType": "text", "parameters": []}
      ]
    }"""

    fun json(mutate: (JSONObject) -> Unit = {}): ByteArray = JSONObject(BASE).also(mutate).toString().toByteArray()

    fun manifest(mutate: (JSONObject) -> Unit = {}): PluginManifest = PluginValidator.decode(json(mutate))

    fun operation(root: JSONObject, index: Int = 0): JSONObject = root.getJSONArray("operations").getJSONObject(index)

    fun parameter(root: JSONObject, index: Int): JSONObject = operation(root).getJSONArray("parameters").getJSONObject(index)

    fun array(vararg values: Any): JSONArray = JSONArray(values.toList())

    /** Runs [block] and returns the [PluginException] it must throw. */
    fun failure(block: () -> Unit): PluginException {
        try {
            block()
        } catch (error: PluginException) {
            return error
        }
        fail("Expected a PluginException")
        throw IllegalStateException()
    }

    fun assertRejected(expected: String, mutate: (JSONObject) -> Unit) {
        val error = failure { PluginValidator.decode(json(mutate)) }
        assertEquals(PluginException.Kind.INVALID_MANIFEST, error.kind)
        assertTrue("Expected \"$expected\" in \"${error.message}\"", error.message.contains(expected))
    }
}
