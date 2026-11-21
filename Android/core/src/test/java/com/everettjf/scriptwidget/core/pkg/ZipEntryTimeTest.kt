package com.everettjf.scriptwidget.core.pkg

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.time.LocalDateTime
import java.util.TimeZone
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class ZipEntryTimeTest {
    private fun archive(stamp: ZipEntry.() -> Unit): ByteArray {
        val buffer = ByteArrayOutputStream()
        ZipOutputStream(buffer, Charsets.UTF_8).use { zip ->
            for (name in listOf("widget.json", "main.jsx")) {
                zip.putNextEntry(ZipEntry(name).apply(stamp))
                zip.write(name.toByteArray())
                zip.closeEntry()
            }
        }
        return buffer.toByteArray()
    }

    private fun <T> inZone(zone: String, block: () -> T): T {
        val saved = TimeZone.getDefault()
        TimeZone.setDefault(TimeZone.getTimeZone(zone))
        try { return block() } finally { TimeZone.setDefault(saved) }
    }

    private val zones = listOf("UTC", "America/Los_Angeles", "Asia/Shanghai", "Pacific/Kiritimati", "America/St_Johns")

    /** The exporters' fixed time, 1980-01-01 00:00: read back as that local time, and the same bytes in every zone. */
    @Test fun theFixedExportTimeIsTheSameEverywhere() {
        val fixed = LocalDateTime.of(1980, 1, 1, 0, 0, 0)
        val archives = zones.map { zone -> inZone(zone) { archive { setFixedLocalTime(fixed) } } }
        for (bytes in archives) assertArrayEquals(archives.first(), bytes)
        for (zone in zones) inZone(zone) {
            ZipInputStream(ByteArrayInputStream(archives.first())).use { zip ->
                var count = 0
                while (true) {
                    val entry = zip.nextEntry ?: break
                    assertEquals("$zone ${entry.name}", fixed, entry.timeLocal)
                    count++
                }
                assertEquals(2, count)
            }
        }
    }

    /** Inside the DOS range the helper writes what `setTimeLocal` (API 35) writes. */
    @Test fun matchesSetTimeLocalInsideTheDosRange() {
        for (zone in zones) inZone(zone) {
            for (time in listOf(LocalDateTime.of(1990, 6, 15, 12, 0, 0), LocalDateTime.of(2026, 11, 21, 8, 30, 4))) {
                assertArrayEquals("$zone $time", archive { setTimeLocal(time) }, archive { setFixedLocalTime(time) })
            }
        }
    }
}
