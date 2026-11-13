package com.everettjf.scriptwidget.core.surfaces

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ControlSurfacesTest {
    private val first = "11111111-1111-4111-8111-111111111111"
    private val second = "22222222-2222-4222-8222-222222222222"

    private fun rejects(code: String, block: () -> Unit) {
        try {
            block()
            fail("expected $code")
        } catch (error: ControlSlotException) {
            assertEquals(code, error.code)
        }
    }

    // MARK: - Icons

    @Test fun knownSymbolsMapToBuiltInIcons() {
        assertEquals("refresh", ControlIcons.key("arrow.clockwise"))
        assertEquals("timer", ControlIcons.key("timer"))
        assertEquals("lightbulb", ControlIcons.key("lightbulb"))
        assertEquals("home", ControlIcons.key("house"))
        assertEquals("check", ControlIcons.key("checkmark.circle"))
    }

    @Test fun variantSuffixesAreDropped() {
        assertEquals("lightbulb", ControlIcons.key("lightbulb.fill"))
        assertEquals("bell", ControlIcons.key("bell.badge.fill"))
        assertEquals("play", ControlIcons.key("play.circle.fill"))
        assertEquals("moon", ControlIcons.key("moon.stars.fill"))
        assertEquals("star", ControlIcons.key("Star.Fill"))
        assertEquals("refresh", ControlIcons.key("arrow.clockwise.circle"))
    }

    @Test fun unknownSymbolsUseTheGenericIcon() {
        assertEquals(ControlIcons.GENERIC, ControlIcons.key("tortoise.fill"))
        assertEquals(ControlIcons.GENERIC, ControlIcons.key("arrow"))
        assertEquals(ControlIcons.GENERIC, ControlIcons.key(""))
        assertEquals(ControlIcons.GENERIC, ControlIcons.key(null))
        assertEquals(ControlIcons.GENERIC, ControlIcons.key("a".repeat(200)))
    }

    @Test fun everyMappedKeyHasADrawableKey() {
        for (symbol in listOf("arrow.clockwise", "timer", "power", "lightbulb", "bell", "play", "pause", "star", "heart", "house", "lock", "bolt", "checkmark", "plus", "moon", "unknown")) {
            assertTrue(symbol, ControlIcons.key(symbol) in ControlIcons.keys)
        }
        assertEquals(16, ControlIcons.keys.size)
    }

    // MARK: - Slots

    @Test fun controlsTakeTheLowestFreeSlot() {
        val (one, slotOne) = ControlSlots.EMPTY.assign(first, "refresh")
        assertEquals(1, slotOne)
        val (two, slotTwo) = one.assign(first, "focus")
        assertEquals(2, slotTwo)
        val (three, slotThree) = two.unassign(1).assign(second, "refresh")
        assertEquals(1, slotThree)
        assertEquals(second, three.get(1)?.installation)
        assertEquals(2, three.slotOf(first, "FOCUS"))
        assertEquals(3, three.firstFree())
        assertNull(three.get(3))
        assertNull(three.get(0))
    }

    @Test fun aSpecificSlotCanBeChosenButNeverReplaced() {
        val (slots, slot) = ControlSlots.EMPTY.assign(first, "refresh", 5)
        assertEquals(5, slot)
        rejects("slot_taken") { slots.assign(first, "focus", 5) }
        rejects("already_assigned") { slots.assign(first, "refresh", 6) }
        rejects("already_assigned") { slots.assign(first, "Refresh") }
        rejects("invalid_slot") { slots.assign(first, "focus", 0) }
        rejects("invalid_slot") { slots.assign(first, "focus", 9) }
        rejects("invalid_control") { slots.assign(first, "../focus") }
        rejects("invalid_control") { slots.assign("short", "focus") }
        // The same control id of another installation is a different control.
        assertEquals(1, slots.assign(second, "refresh").second)
    }

    @Test fun onlyEightSlotsExist() {
        var slots = ControlSlots.EMPTY
        for (index in 1..8) slots = slots.assign(first, "c$index").first
        assertEquals(8, slots.assigned().size)
        assertNull(slots.firstFree())
        rejects("slots_full") { slots.assign(first, "c9") }
        assertEquals(4, slots.unassign(4).assign(first, "c9").second)
    }

    @Test fun retiringAPackageFreesItsSlots() {
        val slots = ControlSlots.EMPTY.assign(first, "a").first.assign(second, "a").first.assign(first, "b").first
        val retired = slots.retire(first)
        assertEquals(listOf(2), retired.assigned().keys.toList())
        assertEquals(1, slots.retain { it.controlID == "b" }.assigned().size)
        assertEquals(slots, slots.unassign(7))
    }

    @Test fun storedTextRoundTripsAndDropsInvalidEntries() {
        val slots = ControlSlots.EMPTY.assign(first, "refresh", 3).first.assign(second, "focus", 8).first
        assertEquals(slots, ControlSlots.decode(slots.encode()))
        assertEquals(ControlSlots.EMPTY, ControlSlots.decode(null))
        assertEquals(ControlSlots.EMPTY, ControlSlots.decode("not json"))
        assertEquals(ControlSlots.EMPTY, ControlSlots.decode("x".repeat(20000)))
        val damaged = """{"0":{"installation":"$first","control":"a"},"9":{"installation":"$first","control":"b"},"01":{"installation":"$first","control":"c"},
            "2":{"installation":"$first","control":"../d"},"3":"text","4":{"installation":7,"control":"e"},
            "5":{"installation":"$first","control":"ok"},"6":{"installation":"$first","control":"OK"}}"""
        assertEquals(listOf(5), ControlSlots.decode(damaged).assigned().keys.toList())
    }

    // MARK: - Shortcuts

    private fun candidate(installation: String, action: String, title: String, name: String) = ShortcutCandidate(installation, action, title, name, "star")

    @Test fun shortcutIdsAreStableAndParseBack() {
        assertEquals("action/$first/refresh", ShortcutPlanner.id(first, "refresh"))
        assertEquals(first to "refresh", ShortcutPlanner.parse("action/$first/refresh"))
        assertNull(ShortcutPlanner.parse("other/$first/refresh"))
        assertNull(ShortcutPlanner.parse("action/$first"))
        assertNull(ShortcutPlanner.parse("action/$first/a/b"))
        assertNull(ShortcutPlanner.parse(null))
    }

    @Test fun recentlyUsedShortcutsComeFirstWithinTheLimit() {
        val all = listOf(
            candidate(first, "b", "Beta", "Zeta"), candidate(first, "a", "Alpha", "Zeta"),
            candidate(second, "c", "Gamma", "alpha"), candidate(second, "d", "Delta", "alpha"),
        )
        assertEquals(listOf("d", "c", "a", "b"), ShortcutPlanner.select(all, emptyList(), 10).map { it.actionID })
        val recent = listOf(ShortcutPlanner.id(first, "b"), ShortcutPlanner.id(second, "gone"), ShortcutPlanner.id(second, "c"))
        assertEquals(listOf("b", "c", "d", "a"), ShortcutPlanner.select(all, recent, 10).map { it.actionID })
        assertEquals(listOf("b", "c"), ShortcutPlanner.select(all, recent, 2).map { it.actionID })
        assertTrue(ShortcutPlanner.select(all, recent, 0).isEmpty())
        assertEquals(1, ShortcutPlanner.select(listOf(all[0], all[0]), emptyList(), 10).size)
    }

    @Test fun usingAShortcutMovesItToTheFrontOfTheBoundedHistory() {
        assertEquals(listOf("c", "a", "b"), ShortcutPlanner.touch(listOf("a", "b", "c"), "c"))
        assertEquals(listOf("d", "a"), ShortcutPlanner.touch(listOf("a"), "d"))
        val long = (1..40).map { "id$it" }
        val touched = ShortcutPlanner.touch(long, "new")
        assertEquals(ShortcutPlanner.MAXIMUM_RECENT, touched.size)
        assertEquals("new", touched.first())
    }
}
