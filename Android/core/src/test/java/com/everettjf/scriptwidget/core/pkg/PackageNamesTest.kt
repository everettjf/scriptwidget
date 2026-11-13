package com.everettjf.scriptwidget.core.pkg

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ports `testNamesPreserveUnicodeButRejectDirectoryAndCacheEscapes` and `packageNames.test.js`. */
class PackageNamesTest {
    @Test
    fun rejectsNamesThatCouldBecomeTraversalOrReservedCachePaths() {
        val invalid = listOf(
            "", " ", "\t\n", ".", "..", "../outside", "/outside", "folder/child", "folder\\child", "__Build", "__BUILD", "__build",
            ".hidden", "name\u0000bad", "name\nbad", "name\u202Ebad", "C:relative", "c:\\windows", "bad\uD800surrogate",
            "a".repeat(81), "😀".repeat(61), "漢".repeat(80) + "x",
        )
        for (name in invalid) assertFalse(name, PackageNames.isValid(name))
        assertFalse(PackageNames.isValid(null))
    }

    @Test
    fun acceptsUnicodeDisplayNames() {
        val valid = listOf(
            "My Widget", "阅读记录", "👩‍💻 Focus", "e\u0301", "e\u0301".repeat(80), "😀".repeat(60), "Foo.Bar", "a".repeat(80),
            "漢".repeat(80), "Ratio 16:9", "Build", "__Builder", "नमस्ते\u200Dक",
        )
        for (name in valid) assertTrue(name, PackageNames.isValid(name))
    }

    @Test
    fun byteLimitAppliesIndependentlyOfGraphemeLimit() {
        // 61 four-byte scalars are 244 UTF-8 bytes; joined into fewer graphemes they still exceed 240 bytes.
        assertFalse(PackageNames.isValid("😀".repeat(61)))
        assertTrue(PackageNames.isValid("漢".repeat(80)))
        assertEquals(240, PackageNames.utf8Length("漢".repeat(80)))
    }

    @Test
    fun identityFoldsCaseAndUnicodeNormalization() {
        assertEquals(PackageNames.identity("Café"), PackageNames.identity("CAFE\u0301"))
        assertEquals("__build", PackageNames.identity("__BUILD"))
        assertFalse(PackageNames.identity("Widget") == PackageNames.identity("Widget 2"))
    }

    @Test
    fun suffixTruncatesTheStemByGraphemesToKeepLimits() {
        assertEquals("Widget (1)", PackageNames.withSuffix("Widget", " (1)"))
        val long = "a".repeat(80)
        assertEquals("a".repeat(76) + " (1)", PackageNames.withSuffix(long, " (1)"))
        assertEquals("a".repeat(74) + " Remix", PackageNames.withSuffix(long, " Remix"))
        val wide = PackageNames.withSuffix("漢".repeat(80), " (10000)")
        assertTrue(wide, PackageNames.isValid(wide))
        assertTrue(wide.endsWith(" (10000)"))
        assertEquals(72 + 8, PackageNames.graphemeCount(wide))
        val accents = PackageNames.withSuffix("e\u0301".repeat(80), " (1)")
        assertEquals("e\u0301".repeat(76) + " (1)", accents)
    }

    @Test
    fun legacyIdentifiersAndArchiveRootsMatchTheSharedEngine() {
        assertEquals("legacy.my-widget", PackageNames.legacyId("My Widget!"))
        assertEquals("legacy.widget", PackageNames.legacyId("阅读记录"))
        assertEquals("Ratio 16-9", PackageNames.archiveRootName("Ratio 16:9"))
        assertEquals("Widget", PackageNames.archiveRootName("..."))
    }
}
