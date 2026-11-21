package com.everettjf.scriptwidget.core.api

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ThemeColorsToneTest {
    private val gray = mapOf(100 to 0xFFFFFFFF.toInt(), 95 to 0xFFF0F0F0.toInt(), 10 to 0xFF1A1A1A.toInt(), 0 to 0xFF000000.toInt())

    @Test fun aPublishedToneIsUsedAsItIs() {
        assertEquals(0xFFF0F0F0.toInt(), ThemeColorsTones.of(gray, 95))
    }

    @Test fun aToneBetweenTwoIsBlended() {
        // 98 is three fifths of the way from 95 to 100: 0xF0 + 0.6 * (0xFF - 0xF0) = 249 = 0xF9.
        assertEquals(0xFFF9F9F9.toInt(), ThemeColorsTones.of(gray, 98))
        // 6 is three fifths of the way from 0 to 10: 0.6 * 0x1A = 15.6, rounded to 16.
        assertEquals(0xFF101010.toInt(), ThemeColorsTones.of(gray, 6))
    }

    @Test fun aToneOutsideThePublishedOnesHasNoColor() {
        assertNull(ThemeColorsTones.of(mapOf(40 to 0xFF336699.toInt(), 80 to 0xFF99CCFF.toInt()), 90))
    }
}

/** Reaches the internal blend without loading Android's color resources. */
private object ThemeColorsTones {
    fun of(published: Map<Int, Int>, tone: Int) = ThemeColors.toneColor(published, tone)
}
