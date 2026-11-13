package com.everettjf.scriptwidget.core.push

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

class PushRegistrationTest {
    private fun manifest(url: String = "https://push.example.com/widget/register", permissions: String = """["network"]""", domains: String = """["push.example.com"]""", channel: String = "scores") =
        JSONObject("""{"id":"com.example.scores","permissions":$permissions,"networkDomains":$domains,"pushUpdates":{"registrationURL":"$url","channel":"$channel"}}""")

    @Test fun aDeclaredHttpsHostIsATarget() {
        val target = PushRegistration.target(manifest())
        assertNotNull(target)
        assertEquals("com.example.scores", target!!.packageID)
        assertEquals("scores", target.channel)
        assertEquals("push.example.com", target.url.host)
    }

    @Test fun undeclaredInsecureOrPrivateTargetsAreRefused() {
        assertNull(PushRegistration.target(JSONObject("""{"id":"x","permissions":["network"],"networkDomains":[]}""")))
        assertNull("http", PushRegistration.target(manifest(url = "http://push.example.com/register")))
        assertNull("host not declared", PushRegistration.target(manifest(domains = """["other.example.com"]""")))
        assertNull("no network permission", PushRegistration.target(manifest(permissions = "[]")))
        assertNull("private host", PushRegistration.target(manifest(url = "https://192.168.1.10/register", domains = """["192.168.1.10"]""")))
        assertNull("credentials", PushRegistration.target(manifest(url = "https://user:pw@push.example.com/register")))
        assertNull("empty channel", PushRegistration.target(manifest(channel = "")))
        assertNull(PushRegistration.target(null))
    }

    @Test fun wildcardDomainsCoverSubdomainsOnly() {
        assertNotNull(PushRegistration.target(manifest(url = "https://a.example.com/r", domains = """["*.example.com"]""")))
        assertNull(PushRegistration.target(manifest(url = "https://example.com/r", domains = """["*.example.com"]""")))
    }

    @Test fun theBodyCarriesTheSameFieldsAsIosPlusThePlatform() {
        val body = JSONObject(String(PushRegistration.body(PushRegistration.target(manifest())!!, "token-123")!!))
        assertEquals("token-123", body.getString("token"))
        assertEquals("com.example.scores", body.getString("packageID"))
        assertEquals("scores", body.getString("channel"))
        assertEquals("android", body.getString("platform"))
        assertEquals(4, body.length())
        assertNull("oversized", PushRegistration.body(PushRegistration.target(manifest())!!, "t".repeat(9000)))
    }

    @Test fun redirectsStayOnDeclaredHttpsHosts() {
        val target = PushRegistration.target(manifest(domains = """["push.example.com","cdn.example.com"]"""))!!
        assertTrue(PushRegistration.allowedRedirect(target, URI("https://cdn.example.com/x")))
        assertFalse(PushRegistration.allowedRedirect(target, URI("http://cdn.example.com/x")))
        assertFalse(PushRegistration.allowedRedirect(target, URI("https://evil.example.org/x")))
        assertFalse(PushRegistration.allowedRedirect(target, URI("https://127.0.0.1/x")))
    }

    @Test fun aPushMustNameThePackageAndItsChannel() {
        assertTrue(PushRegistration.matches(manifest(), "com.example.scores", "scores"))
        assertFalse(PushRegistration.matches(manifest(), "com.example.scores", "other"))
        assertFalse(PushRegistration.matches(manifest(), "com.example.other", "scores"))
        assertFalse(PushRegistration.matches(manifest(domains = "[]"), "com.example.scores", "scores"))
        assertFalse(PushRegistration.matches(manifest(), null, null))
    }
}
