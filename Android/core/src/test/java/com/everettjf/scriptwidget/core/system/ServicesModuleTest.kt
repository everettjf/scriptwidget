package com.everettjf.scriptwidget.core.system

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ServicesModuleTest {
    private class MemoryVault : ServiceVault {
        var text: String? = null
        var failure: ServiceError? = null
        override fun read(): String? { failure?.let { throw it.reject() }; return text }
        override fun write(text: String?) { failure?.let { throw it.reject() }; this.text = text }
    }

    private class FakeTransport : ServiceTransport {
        var requests = ArrayList<Pair<String, Map<String, String>>>()
        var response: () -> ServiceHttpResponse = { json(profileBody()) }
        override fun get(url: String, headers: Map<String, String>): ServiceHttpResponse { requests += url to headers; return response() }
    }

    companion object {
        const val TOKEN = "github_pat_11ABCDEFG0abcdefghijkl_mnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefgh"
        fun profileBody(id: Any = 9919, login: String = "octo_cat"): JSONObject = JSONObject()
            .put("id", id).put("login", login).put("name", "The Octocat").put("public_repos", 8).put("total_private_repos", 3)
            .put("followers", 120).put("following", 5).put("email", "octo@example.com").put("location", "San Francisco").put("plan", JSONObject().put("name", "pro"))
        fun json(body: JSONObject, status: Int = 200, type: String? = "application/json; charset=utf-8", rateLimited: Boolean = false) =
            ServiceHttpResponse(status, type, rateLimited, body.toString().toByteArray())
    }

    private val vault = MemoryVault()
    private val transport = FakeTransport()
    private val connections = ServiceConnections(vault, transport) { NOW }
    private val module = ServicesModule(connections)
    private val full = setOf("services", "network")
    private val domains = listOf("api.github.com")
    private fun widget(permissions: Set<String> = full, hosts: List<String> = domains, installation: String = OWNER, queries: Int = 8, network: Int = 32) =
        context(permissions, installation = installation, domains = hosts, runtime = "1.4", queries = queries, network = network)
    private fun connectAndGrant() { connections.connect(TOKEN); connections.setGrant(OWNER, true); transport.requests.clear() }

    @Test fun onlyFineGrainedTokensAreAccepted() {
        assertTrue(ServiceConnection.validToken(TOKEN))
        for (bad in listOf("", "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB", "github_pat_short", "github_pat_" + "a".repeat(245), "github_pat_abc def0123456789012345", "Bearer $TOKEN")) assertFalse(bad, ServiceConnection.validToken(bad))
        assertRejects("service_credential") { connections.connect("ghp_0123456789abcdefghijklmnopqrstuvwxyzAB") }
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun profileMappingKeepsOnlyDocumentedFields() {
        val profile = GitHubProfile.decode(json(profileBody()), TOKEN)
        assertEquals(setOf("service", "subject", "username", "displayName", "publicRepositories", "privateRepositories", "followers", "following"), profile.keys().asSequence().toSet())
        assertEquals("github", profile.getString("service")); assertEquals("9919", profile.get("subject")); assertEquals("octo_cat", profile.getString("username"))
        assertEquals("The Octocat", profile.getString("displayName")); assertEquals(8, profile.getInt("publicRepositories")); assertEquals(3, profile.getInt("privateRepositories"))
        assertFalse(profile.toString().contains("example.com")); assertFalse(profile.toString().contains("San Francisco"))

        // A missing optional value is null, never zero.
        val sparse = GitHubProfile.decode(json(JSONObject().put("id", 7).put("login", "a").put("public_repos", 0).put("name", JSONObject.NULL)), TOKEN)
        assertTrue(sparse.isNull("displayName")); assertTrue(sparse.isNull("privateRepositories")); assertTrue(sparse.isNull("followers")); assertTrue(sparse.isNull("following"))
        assertEquals(0, sparse.getInt("publicRepositories"))
    }

    @Test fun malformedProviderResponsesAreUnavailable() {
        val bad = listOf(
            JSONObject(profileBody().toString()).apply { remove("public_repos") }, JSONObject(profileBody().toString()).apply { remove("id") },
            profileBody(id = 0), profileBody(id = -4), profileBody(id = true), profileBody(id = 1.5), profileBody(id = "9919"),
            profileBody(login = ""), profileBody(login = "-leading"), profileBody(login = "has space"), profileBody(login = "x".repeat(40)),
            profileBody().put("followers", -1), profileBody().put("following", "many"), profileBody().put("public_repos", 2.5),
            profileBody().put("name", "x".repeat(257)), profileBody().put("name", "bell\u0007"), profileBody().put("name", 12),
            profileBody().put("name", "leaked $TOKEN"),
        )
        for (body in bad) assertRejects("service_unavailable") { GitHubProfile.decode(json(body), TOKEN) }
        assertRejects("service_unavailable") { GitHubProfile.decode(ServiceHttpResponse(200, "application/json", false, "[1,2]".toByteArray()), TOKEN) }
        assertRejects("service_unavailable") { GitHubProfile.decode(ServiceHttpResponse(200, "application/json", false, ByteArray(GitHubProfile.MAXIMUM_RESPONSE_BYTES + 1) { 32 }), TOKEN) }
    }

    @Test fun httpStatusMapping() {
        val body = profileBody()
        assertRejects("service_expired") { GitHubProfile.validateHTTP(json(body, 401)) }
        assertRejects("service_rate_limit") { GitHubProfile.validateHTTP(json(body, 429)) }
        assertRejects("service_rate_limit") { GitHubProfile.validateHTTP(json(body, 403, rateLimited = true)) }
        assertRejects("service_permission") { GitHubProfile.validateHTTP(json(body, 403)) }
        assertRejects("service_unavailable") { GitHubProfile.validateHTTP(json(body, 500)) }
        assertRejects("service_unavailable") { GitHubProfile.validateHTTP(json(body, 204)) }
        assertRejects("service_unavailable") { GitHubProfile.validateHTTP(json(body, 302)) }
        assertRejects("service_unavailable") { GitHubProfile.validateHTTP(json(body, 200, "text/html")) }
        assertRejects("service_unavailable") { GitHubProfile.validateHTTP(json(body, 200, null)) }
        GitHubProfile.validateHTTP(json(body, 200, "Application/JSON"))
    }

    @Test fun connectVerifiesStoresAndNeverExposesTheToken() {
        assertNull(connections.summary())
        assertEquals("octo_cat", connections.connect("  $TOKEN\n"))
        val (url, headers) = transport.requests.single()
        assertEquals("https://api.github.com/user", url)
        assertEquals(mapOf("Authorization" to "Bearer $TOKEN", "User-Agent" to "ScriptWidget", "Accept" to "application/vnd.github+json", "X-GitHub-Api-Version" to "2026-03-10"), headers)
        val summary = connections.summary()!!
        assertEquals("octo_cat", summary.username); assertTrue(summary.grants.isEmpty())
        assertFalse(connections.connection().toString().contains("github_pat_"))
        assertTrue(connections.setGrant(OWNER, true))
        assertFalse(connections.setGrant("My Widget", true))
        assertEquals(setOf(OWNER), connections.summary()!!.grants)
        // Reconnecting is a new connection without the previous grants.
        val before = connections.connection()!!.connectionID
        connections.connect(TOKEN)
        assertNotEquals(before, connections.connection()!!.connectionID)
        assertTrue(connections.summary()!!.grants.isEmpty())
        connections.disconnect()
        assertNull(connections.summary()); assertFalse(connections.setGrant(OWNER, true))
        // A rejected token is not stored.
        transport.response = { json(profileBody(), 401) }
        assertRejects("service_expired") { connections.connect(TOKEN) }
        assertNull(vault.text)
    }

    @Test fun storedRecordsAreValidatedAsUntrusted() {
        connections.connect(TOKEN)
        val stored = JSONObject(vault.text!!)
        for (bad in listOf(JSONObject(stored.toString()).put("formatVersion", 2), JSONObject(stored.toString()).put("token", "ghp_classic"), JSONObject(stored.toString()).put("subject", "abc"),
            JSONObject(stored.toString()).put("connectionID", "x"), JSONObject(stored.toString()).put("grants", org.json.JSONArray(listOf("not-an-owner"))), JSONObject(stored.toString()).apply { remove("username") })) {
            vault.text = bad.toString()
            assertRejects("service_storage") { module.status(widget(), "github") }
        }
        vault.text = "not json"
        assertRejects("service_storage") { module.profile(widget(), "github") }
    }

    @Test fun gateOrder() {
        assertRejects("service_permission") { module.status(widget(setOf("network")), "spotify") }
        assertRejects("service_permission") { module.status(context(full, hasManifest = false), "github") }
        assertRejects("service_permission") { module.profile(widget(installation = "preview"), "github") }
        assertRejects("service_operation") { module.status(context(full, projection = true, queries = 0), "spotify") }
        assertRejects("service_operation") { module.profile(widget(), "") }
        assertRejectsWith("[timeline_read_only] Read services in the current entry, then reuse a display snapshot") { module.status(context(full, projection = true, queries = 0), "github") }
        assertRejectsWith("[timeline_read_only] Read services in the current entry, then reuse a display snapshot") { module.profile(context(full, liveActivity = true), "github") }
        assertRejectsWith("[query_limit] Too many system data queries") { module.status(widget(queries = 0), "github") }
        vault.failure = ServiceError.STORAGE
        assertRejects("service_storage") { module.status(widget(), "github") }
        vault.failure = ServiceError.LOCKED
        assertRejects("service_locked") { module.profile(widget(), "github") }
    }

    @Test fun statusValuesMakeNoNetworkRequest() {
        assertEquals("notConnected", module.status(widget(), "github"))
        connections.connect(TOKEN); transport.requests.clear()
        assertEquals("notGranted", module.status(widget(), "github"))
        connections.setGrant(OWNER, true)
        assertEquals("connected", module.status(widget(), "github"))
        assertEquals("notGranted", module.status(widget(installation = OTHER_OWNER), "github"))
        // status needs only the services permission.
        assertEquals("connected", module.status(widget(setOf("services"), emptyList()), "github"))
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun profileRequiresConnectionGrantNetworkAndBudget() {
        assertRejects("service_not_connected") { module.profile(widget(), "github") }
        connections.connect(TOKEN); transport.requests.clear()
        assertRejects("service_permission") { module.profile(widget(), "github") } // no grant yet
        connections.setGrant(OWNER, true)
        assertRejects("service_permission") { module.profile(widget(setOf("services")), "github") }
        assertRejects("service_permission") { module.profile(widget(hosts = listOf("example.com")), "github") }
        assertRejects("service_permission") { module.profile(widget(installation = OTHER_OWNER), "github") }
        assertRejectsWith("[network_limit] Too many concurrent or total network requests.") { module.profile(widget(network = 0), "github") }
        assertTrue(transport.requests.isEmpty())

        val profile = module.profile(widget(hosts = listOf("*.github.com")), "github")
        assertEquals(8, profile.length()); assertEquals("octo_cat", profile.getString("username"))
        assertFalse(profile.toString().contains("github_pat_"))
        assertEquals("https://api.github.com/user", transport.requests.single().first)
    }

    @Test fun profileFailures() {
        connectAndGrant()
        transport.response = { json(profileBody(id = 424242)) }
        assertRejects("service_credential") { module.profile(widget(), "github") } // a response for another user
        transport.response = { throw java.io.IOException("offline") }
        assertRejects("service_unavailable") { module.profile(widget(), "github") }
        transport.response = { json(profileBody(), 401) }
        assertRejects("service_expired") { module.profile(widget(), "github") }
        transport.response = { json(profileBody(), 403, rateLimited = true) }
        assertRejects("service_rate_limit") { module.profile(widget(), "github") }
    }

    @Test fun changesDuringARequestInvalidateItsResult() {
        connectAndGrant()
        transport.response = { connections.setGrant(OWNER, false); json(profileBody()) }
        assertRejects("service_permission") { module.profile(widget(), "github") }
        connections.setGrant(OWNER, true)
        transport.response = { connections.disconnect(); json(profileBody()) }
        assertRejects("service_conflict") { module.profile(widget(), "github") }
        connectAndGrant()
        var reconnected = false
        transport.response = { if (!reconnected) { reconnected = true; connections.connect(TOKEN) }; json(profileBody()) }
        assertRejects("service_conflict") { module.profile(widget(), "github") }
    }
}
