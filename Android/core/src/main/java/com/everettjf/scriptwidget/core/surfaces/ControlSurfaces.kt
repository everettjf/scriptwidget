package com.everettjf.scriptwidget.core.surfaces

import org.json.JSONObject

/**
 * Maps an SF Symbol name to one of the icons Android ships for tiles and
 * shortcuts. Android cannot draw SF Symbols, so unknown names get [GENERIC].
 */
object ControlIcons {
    const val GENERIC = "generic"

    /** Every key [key] can return; the app has one drawable per key. */
    val keys: Set<String> = linkedSetOf(
        "refresh", "timer", "power", "lightbulb", "bell", "play", "pause", "star", "heart",
        "home", "lock", "bolt", "check", "add", "moon", GENERIC,
    )

    private val symbols: Map<String, String> = mapOf(
        "arrow.clockwise" to "refresh", "arrow.counterclockwise" to "refresh", "arrow.triangle.2.circlepath" to "refresh", "arrow.2.circlepath" to "refresh",
        "timer" to "timer", "clock" to "timer", "stopwatch" to "timer", "alarm" to "timer", "hourglass" to "timer",
        "power" to "power", "togglepower" to "power",
        "lightbulb" to "lightbulb", "lamp.desk" to "lightbulb", "lamp.table" to "lightbulb", "lamp.floor" to "lightbulb", "light.max" to "lightbulb",
        "bell" to "bell", "bell.badge" to "bell", "bell.slash" to "bell",
        "play" to "play", "playpause" to "play", "pause" to "pause", "stop" to "pause",
        "star" to "star", "sparkles" to "star", "heart" to "heart",
        "house" to "home", "lock" to "lock", "lock.open" to "lock",
        "bolt" to "bolt", "flame" to "bolt",
        "checkmark" to "check", "checkmark.circle" to "check", "checkmark.seal" to "check", "checklist" to "check",
        "plus" to "add", "plus.circle" to "add",
        "moon" to "moon", "moon.stars" to "moon", "moon.zzz" to "moon", "bed.double" to "moon",
    )

    /**
     * The icon key for [systemImage]. Variant suffixes such as `.fill` or
     * `.circle.fill` are dropped one component at a time until a known name remains.
     */
    fun key(systemImage: String?): String {
        var name = systemImage?.trim()?.lowercase().orEmpty()
        if (name.length > 80) return GENERIC
        while (name.isNotEmpty()) {
            symbols[name]?.let { return it }
            val cut = name.lastIndexOf('.')
            if (cut <= 0) break
            name = name.substring(0, cut)
        }
        return GENERIC
    }
}

/** The package control a Quick Settings slot shows. */
class ControlAssignment(val installation: String, val controlID: String) {
    override fun equals(other: Any?): Boolean = other is ControlAssignment && other.installation == installation && other.controlID.equals(controlID, ignoreCase = true)
    override fun hashCode(): Int = installation.hashCode() * 31 + controlID.lowercase().hashCode()
}

/** Why a slot change was refused. */
class ControlSlotException(val code: String, message: String) : Exception(message)

/**
 * The assignment of package controls to the eight statically declared Quick
 * Settings tiles. Immutable: every change returns a new value. Slots are
 * numbered from 1 to [COUNT].
 */
class ControlSlots private constructor(private val slots: Map<Int, ControlAssignment>) {
    /** The control in [slot], or null when the slot is free or out of range. */
    fun get(slot: Int): ControlAssignment? = slots[slot]

    /** Assigned slots in ascending order. */
    fun assigned(): Map<Int, ControlAssignment> = slots.toSortedMap()

    /** The slot that shows this control, or null. */
    fun slotOf(installation: String, controlID: String): Int? {
        val wanted = ControlAssignment(installation, controlID)
        return slots.entries.firstOrNull { it.value == wanted }?.key
    }

    /** The lowest free slot, or null when all eight are taken. */
    fun firstFree(): Int? = (1..COUNT).firstOrNull { it !in slots }

    /**
     * Puts a control into [slot], or into the lowest free slot when [slot] is null.
     * A control occupies at most one slot and never replaces another control.
     * @return the new assignment and the slot that was used.
     * @throws ControlSlotException with `invalid_control`, `invalid_slot`, `already_assigned`, `slot_taken` or `slots_full`.
     */
    fun assign(installation: String, controlID: String, slot: Int? = null): Pair<ControlSlots, Int> {
        if (!validInstallation(installation) || !validControl(controlID)) throw ControlSlotException("invalid_control", "This control cannot be assigned.")
        if (slot != null && slot !in 1..COUNT) throw ControlSlotException("invalid_slot", "Choose a tile between 1 and $COUNT.")
        if (slotOf(installation, controlID) != null) throw ControlSlotException("already_assigned", "This control already has a tile.")
        if (slot != null && slot in slots) throw ControlSlotException("slot_taken", "That tile already shows another control.")
        val target = slot ?: firstFree() ?: throw ControlSlotException("slots_full", "All $COUNT tiles are in use. Remove one first.")
        return ControlSlots(slots + (target to ControlAssignment(installation, controlID))) to target
    }

    /** Frees [slot]; freeing a free slot changes nothing. */
    fun unassign(slot: Int): ControlSlots = ControlSlots(slots - slot)

    /** Frees every slot of a package, for when it is deleted. */
    fun retire(installation: String): ControlSlots = retain { it.installation != installation }

    /** Keeps only the assignments [valid] accepts, for when packages or their controls change. */
    fun retain(valid: (ControlAssignment) -> Boolean): ControlSlots = ControlSlots(slots.filterValues(valid))

    /** JSON text for [decode]. */
    fun encode(): String {
        val json = JSONObject()
        for ((slot, value) in assigned()) json.put(slot.toString(), JSONObject().put("installation", value.installation).put("control", value.controlID))
        return json.toString()
    }

    override fun equals(other: Any?): Boolean = other is ControlSlots && other.slots == slots
    override fun hashCode(): Int = slots.hashCode()

    companion object {
        /** Number of tile services declared in the app manifest. */
        const val COUNT = 8
        val EMPTY = ControlSlots(emptyMap())

        private val controlPattern = Regex("^[A-Za-z0-9][A-Za-z0-9.-]{0,63}$")
        private fun validInstallation(value: String) = value.length in 8..64 && value.none { it.isWhitespace() || it.isISOControl() }
        private fun validControl(value: String) = controlPattern.matches(value)

        /** Reads stored text. Unreadable text is empty; entries that are out of range, malformed or duplicated are dropped. */
        fun decode(text: String?): ControlSlots {
            if (text.isNullOrEmpty() || text.length > 16 * 1024) return EMPTY
            val json = runCatching { JSONObject(text) }.getOrNull() ?: return EMPTY
            val result = LinkedHashMap<Int, ControlAssignment>()
            for (key in json.keys().asSequence().toList().sorted()) {
                val slot = key.toIntOrNull()?.takeIf { it in 1..COUNT && it.toString() == key } ?: continue
                val entry = json.opt(key) as? JSONObject ?: continue
                val installation = entry.opt("installation") as? String ?: continue
                val control = entry.opt("control") as? String ?: continue
                if (!validInstallation(installation) || !validControl(control)) continue
                val value = ControlAssignment(installation, control)
                if (result.values.none { it == value }) result[slot] = value
            }
            return ControlSlots(result)
        }
    }
}

/** A declared action that can be offered as a launcher shortcut. */
class ShortcutCandidate(val installation: String, val actionID: String, val title: String, val packageName: String, val systemImage: String) {
    val id: String get() = ShortcutPlanner.id(installation, actionID)
}

/** Chooses and names the dynamic shortcuts for declared actions. */
object ShortcutPlanner {
    private const val PREFIX = "action/"
    /** How many recently used shortcut ids are remembered. */
    const val MAXIMUM_RECENT = 32

    /** `action/<installation>/<action id>`: stable across renames because it uses the installation identity. */
    fun id(installation: String, actionID: String): String = "$PREFIX$installation/$actionID"

    /** The (installation, action id) a shortcut id names, or null when it is not one of ours. */
    fun parse(id: String?): Pair<String, String>? {
        if (id == null || !id.startsWith(PREFIX)) return null
        val parts = id.removePrefix(PREFIX).split('/')
        return if (parts.size == 2 && parts.none { it.isEmpty() }) parts[0] to parts[1] else null
    }

    /**
     * At most [limit] shortcuts: the ones in [recent] first, most recently
     * used first, then the rest by package and title.
     */
    fun select(candidates: List<ShortcutCandidate>, recent: List<String>, limit: Int): List<ShortcutCandidate> {
        if (limit <= 0) return emptyList()
        val unique = candidates.distinctBy { it.id }
        val order = recent.withIndex().associate { it.value to it.index }
        val used = unique.filter { it.id in order }.sortedBy { order.getValue(it.id) }
        val rest = unique.filter { it.id !in order }.sortedWith(compareBy({ it.packageName.lowercase() }, { it.title.lowercase() }, { it.id }))
        return (used + rest).take(limit)
    }

    /** [recent] with [id] moved to the front, bounded to [MAXIMUM_RECENT]. */
    fun touch(recent: List<String>, id: String): List<String> = (listOf(id) + recent.filter { it != id }).take(MAXIMUM_RECENT)
}
