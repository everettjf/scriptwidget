package com.everettjf.scriptwidget.actions

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.InstalledPackage
import com.everettjf.scriptwidget.R
import com.everettjf.scriptwidget.core.surfaces.ActionPlanner
import com.everettjf.scriptwidget.core.surfaces.ControlAssignment
import com.everettjf.scriptwidget.core.surfaces.ControlIcons
import com.everettjf.scriptwidget.core.surfaces.ControlSlots
import com.everettjf.scriptwidget.core.surfaces.DeclaredControl

/** Drawables for the icon keys of [ControlIcons]. */
object ControlIconResources {
    /** The drawable for an SF Symbol name; unknown names get the generic icon. */
    fun drawable(systemImage: String?): Int = when (ControlIcons.key(systemImage)) {
        "refresh" -> R.drawable.ic_control_refresh
        "timer" -> R.drawable.ic_control_timer
        "power" -> R.drawable.ic_control_power
        "lightbulb" -> R.drawable.ic_control_lightbulb
        "bell" -> R.drawable.ic_control_bell
        "play" -> R.drawable.ic_control_play
        "pause" -> R.drawable.ic_control_pause
        "star" -> R.drawable.ic_control_star
        "heart" -> R.drawable.ic_control_heart
        "home" -> R.drawable.ic_control_home
        "lock" -> R.drawable.ic_control_lock
        "bolt" -> R.drawable.ic_control_bolt
        "check" -> R.drawable.ic_control_check
        "add" -> R.drawable.ic_control_add
        "moon" -> R.drawable.ic_control_moon
        else -> R.drawable.ic_control_generic
    }
}

/** Persists which package control each Quick Settings slot shows. */
class ControlTileStore private constructor(context: Context) {
    private val preferences = context.getSharedPreferences("control-tiles", Context.MODE_PRIVATE)

    /** The current assignment. */
    fun slots(): ControlSlots = synchronized(this) { ControlSlots.decode(preferences.getString(KEY, null)) }

    /**
     * Assigns a control to [slot], or to the lowest free slot, and returns the slot used.
     * @throws com.everettjf.scriptwidget.core.surfaces.ControlSlotException when the rules refuse it.
     */
    fun assign(installation: String, controlID: String, slot: Int? = null): Int = synchronized(this) {
        val (updated, used) = slots().assign(installation, controlID, slot)
        save(updated)
        used
    }

    /** Frees [slot]. */
    fun unassign(slot: Int) = synchronized(this) { save(slots().unassign(slot)) }

    /** Frees every slot of a deleted package. */
    fun retire(installation: String) = synchronized(this) { save(slots().retire(installation)) }

    /** Frees the slots [valid] rejects. */
    fun retain(valid: (ControlAssignment) -> Boolean) = synchronized(this) { save(slots().retain(valid)) }

    private fun save(slots: ControlSlots) { preferences.edit().putString(KEY, slots.encode()).apply() }

    companion object {
        private const val KEY = "slots"
        @Volatile private var instance: ControlTileStore? = null

        fun get(context: Context): ControlTileStore = instance ?: synchronized(this) {
            instance ?: ControlTileStore(context.applicationContext).also { instance = it }
        }
    }
}

/** A slot's control together with the package that declares it. */
class ResolvedControl(val installed: InstalledPackage, val control: DeclaredControl) {
    /** Second line of the tile: the package name, then the control's own subtitle. */
    val subtitle: String get() = control.subtitle?.trim()?.takeIf { it.isNotEmpty() }?.let { "${installed.displayName} · $it" } ?: installed.displayName
}

/** Helpers shared by the tile services and the Controls screen. */
object ControlTiles {
    private val services: List<Class<out TileService>> = listOf(
        ControlTileService1::class.java, ControlTileService2::class.java, ControlTileService3::class.java, ControlTileService4::class.java,
        ControlTileService5::class.java, ControlTileService6::class.java, ControlTileService7::class.java, ControlTileService8::class.java,
    )

    /** The tile service of [slot] (1 to 8). */
    fun component(context: Context, slot: Int): ComponentName = ComponentName(context, services[slot - 1])

    /** The control [slot] shows, or null when it is free, its package is gone or the control is no longer declared. */
    fun resolve(context: Context, slot: Int): ResolvedControl? {
        AppServices.attach(context.applicationContext)
        val assignment = ControlTileStore.get(context).slots().get(slot) ?: return null
        return resolve(assignment)
    }

    /** The package and control an assignment names, or null when either is gone or the manifest is invalid. */
    fun resolve(assignment: ControlAssignment): ResolvedControl? {
        val installed = AppServices.library.findByInstallation(assignment.installation) ?: return null
        val control = ActionRunner.declared(installed)?.control(assignment.controlID) ?: return null
        return ResolvedControl(installed, control)
    }

    /**
     * Asks the system to offer [slot]'s tile to the user. The app must be in
     * the foreground. [completion] receives a `StatusBarManager.TILE_ADD_REQUEST_*` value.
     */
    fun requestAdd(context: Context, slot: Int, completion: (Int) -> Unit) {
        val resolved = resolve(context, slot)
        val manager = context.getSystemService(StatusBarManager::class.java)
        if (resolved == null || manager == null) { completion(StatusBarManager.TILE_ADD_REQUEST_ERROR_BAD_COMPONENT); return }
        manager.requestAddTileService(
            component(context, slot), resolved.control.title,
            Icon.createWithResource(context, ControlIconResources.drawable(resolved.control.systemImage)),
            context.mainExecutor,
        ) { result -> completion(result) }
    }
}

/**
 * One of the eight Quick Settings tiles. Android needs every tile declared in
 * the app manifest, so the control a tile shows is looked up by its [slot].
 */
abstract class ControlTileService(private val slot: Int) : TileService() {
    override fun onStartListening() { render(null) }

    override fun onTileAdded() { render(null) }

    override fun onClick() {
        val resolved = ControlTiles.resolve(applicationContext, slot)
        if (resolved == null) { render(null); return }
        // Package code never runs behind a secure lock screen without the user unlocking first.
        if (isSecure && isLocked) unlockAndRun { perform(resolved) } else perform(resolved)
    }

    private fun perform(resolved: ResolvedControl) {
        val control = resolved.control
        val value = if (control.isToggle) !ActionRunner.toggleValue(resolved.installed, control) else null
        if (value != null) render(value)
        val application = applicationContext
        ActionRunner.runAsync(application, resolved.installed.installation, control.actionID, ActionPlanner.SOURCE_CONTROL, value, control.id) { result ->
            if (!result.ok) Toast.makeText(application, result.message, Toast.LENGTH_LONG).show()
            render(null)
        }
    }

    /** Draws the tile. [pendingValue] shows a toggle's new state before its action has finished. */
    private fun render(pendingValue: Boolean?) {
        // The tile is only available while the system is bound and listening.
        val tile = runCatching { qsTile }.getOrNull() ?: return
        val resolved = runCatching { ControlTiles.resolve(applicationContext, slot) }.getOrNull()
        if (resolved == null) {
            val assigned = ControlTileStore.get(applicationContext).slots().get(slot) != null
            tile.state = Tile.STATE_UNAVAILABLE
            tile.label = getString(R.string.control_tile_label, slot)
            tile.subtitle = getString(if (assigned) R.string.control_tile_removed else R.string.control_tile_unassigned)
            tile.icon = Icon.createWithResource(this, R.drawable.ic_control_generic)
            tile.stateDescription = null
        } else {
            val control = resolved.control
            val on = control.isToggle && (pendingValue ?: ActionRunner.toggleValue(resolved.installed, control))
            tile.state = if (on) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            tile.label = control.title
            tile.subtitle = resolved.subtitle
            tile.contentDescription = "${control.title}, ${resolved.subtitle}"
            tile.icon = Icon.createWithResource(this, ControlIconResources.drawable(control.systemImage))
            tile.stateDescription = if (control.isToggle) getString(if (on) R.string.control_tile_on else R.string.control_tile_off) else null
        }
        runCatching { tile.updateTile() }
    }
}

class ControlTileService1 : ControlTileService(1)
class ControlTileService2 : ControlTileService(2)
class ControlTileService3 : ControlTileService(3)
class ControlTileService4 : ControlTileService(4)
class ControlTileService5 : ControlTileService(5)
class ControlTileService6 : ControlTileService(6)
class ControlTileService7 : ControlTileService(7)
class ControlTileService8 : ControlTileService(8)
