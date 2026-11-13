package com.everettjf.scriptwidget.core.gallery

import com.everettjf.scriptwidget.core.gallery.GalleryFixtures.assertKind
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

class GalleryTrustTest {
    @Test
    fun acceptsOnlyBareHttpsRawGitHubUrls() {
        for (url in listOf(
            "https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/index.json",
            "HTTPS://RAW.GitHubUserContent.com/a/b",
            "https://raw.githubusercontent.com/a/b%20c.png",
        )) assertTrue(url, GalleryIndexValidator.isRawGitHubUrl(url))
    }

    @Test
    fun rejectsEveryOtherUrlShape() {
        for (url in untrusted) assertFalse(url, GalleryIndexValidator.isRawGitHubUrl(url))
    }

    @Test
    fun redirectsAreTrustedOnlyOnTheSameRule() {
        assertTrue(GalleryIndexValidator.isTrustedRedirect(URI("https://raw.githubusercontent.com/a/b")))
        for (url in listOf(
            "https://evil.example/a/b", "http://raw.githubusercontent.com/a/b", "https://github.com/a/b",
            "https://objects.githubusercontent.com/a", "https://raw.githubusercontent.com/a?token=1", "https://127.0.0.1/a",
        )) assertFalse(url, GalleryIndexValidator.isTrustedRedirect(URI(url)))
    }

    @Test
    fun productionTransportRefusesUntrustedStartUrlsBeforeAnyRequest() {
        val transport = FetchGalleryTransport()
        for (url in listOf("https://evil.example/index.json", "http://raw.githubusercontent.com/a", "https://raw.githubusercontent.com/a?b=c")) {
            assertKind(GalleryException.Kind.NETWORK) { transport.fetch(GalleryRequest(url, emptyMap(), 1000)) }
        }
    }

    companion object {
        val untrusted = listOf(
            // Scheme
            "http://raw.githubusercontent.com/a/b", "ftp://raw.githubusercontent.com/a/b", "file:///raw.githubusercontent.com/a",
            "//raw.githubusercontent.com/a/b", "raw.githubusercontent.com/a/b", "https:raw.githubusercontent.com/a/b", "",
            // Host
            "https://github.com/a/b", "https://gist.githubusercontent.com/a/b", "https://raw.githubusercontent.com.evil.example/a",
            "https://evilraw.githubusercontent.com/a", "https://raw.githubusercontent.com./a", "https://raw.githubusercontent.co/a",
            "https://raw.githubуsercontent.com/a", "https://140.82.112.3/a", "https:///a/b",
            // User info
            "https://user@raw.githubusercontent.com/a", "https://user:pass@raw.githubusercontent.com/a",
            "https://raw.githubusercontent.com@evil.example/a", "https://raw.githubusercontent.com:x@evil.example/a",
            // Port
            "https://raw.githubusercontent.com:443/a", "https://raw.githubusercontent.com:8443/a", "https://raw.githubusercontent.com:/a",
            // Query and fragment
            "https://raw.githubusercontent.com/a?token=1", "https://raw.githubusercontent.com/a?", "https://raw.githubusercontent.com/a#x",
            "https://raw.githubusercontent.com/a#",
            // Unparseable
            "https://raw.githubusercontent.com/a b", "https://raw.githubusercontent.com\\@evil.example/a", "https://raw.githubusercontent.com/\u0000",
        )
    }
}
