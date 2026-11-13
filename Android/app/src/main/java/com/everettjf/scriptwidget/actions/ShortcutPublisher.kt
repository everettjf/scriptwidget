package com.everettjf.scriptwidget.actions

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.R
import com.everettjf.scriptwidget.core.surfaces.ActionPlanner
import com.everettjf.scriptwidget.core.surfaces.ShortcutCandidate
import com.everettjf.scriptwidget.core.surfaces.ShortcutPlanner
import com.everettjf.scriptwidget.live.LiveUpdates
import org.json.JSONArray
import java.util.concurrent.Executors

/**
 * Publishes every installed package's declared `actions` as launcher
 * shortcuts (long-press the app icon). The launcher limits how many an app
 * may have, so the most recently used actions come first.
 */
object ShortcutPublisher {
    private const val TAG = "ScriptWidget"
    private const val PREFERENCES = "action-shortcuts"
    private const val KEY_RECENT = "recent"
    internal const val ACTION_RUN = "com.everettjf.scriptwidget.action.RUN_SHORTCUT"
    internal const val EXTRA_INSTALLATION = "installation"
    internal const val EXTRA_ACTION = "action"

    /** Every declared action of every installed package with a valid manifest. */
    fun candidates(context: Context): List<ShortcutCandidate> {
        AppServices.attach(context.applicationContext)
        return AppServices.library.list().flatMap { installed ->
            ActionRunner.declared(installed)?.actions.orEmpty().map { ShortcutCandidate(installed.installation, it.id, it.title, installed.displayName, it.systemImage) }
        }
    }

    /**
     * Makes the launcher's dynamic shortcuts match the installed packages:
     * new actions appear, edited titles are updated, and shortcuts of removed
     * actions are deleted (pinned copies are disabled with an explanation).
     * Reads the library, so call it from a background thread.
     *
     * @return the ids that are now published, in rank order; empty when the launcher has no shortcut support.
     */
    @Synchronized
    fun sync(context: Context): List<String> {
        val application = context.applicationContext
        val manager = application.getSystemService(ShortcutManager::class.java) ?: return emptyList()
        return try {
            val all = candidates(application)
            val selected = ShortcutPlanner.select(all, recent(application), manager.maxShortcutCountPerActivity)
            if (!manager.setDynamicShortcuts(selected.mapIndexed { rank, candidate -> info(application, candidate, rank) })) {
                Log.i(TAG, "Shortcut update was rate limited")
            }
            // Pinned shortcuts outlive the dynamic list: keep valid ones current and switch off the rest.
            val valid = all.associateBy { it.id }
            val published = selected.map { it.id }.toSet()
            val pinned = manager.pinnedShortcuts.filter { ShortcutPlanner.parse(it.id) != null }
            val stale = pinned.filter { it.id !in valid }.map { it.id }
            if (stale.isNotEmpty()) manager.disableShortcuts(stale, application.getString(R.string.shortcut_unavailable))
            val kept = pinned.filter { it.id in valid }
            if (kept.any { !it.isEnabled }) manager.enableShortcuts(kept.filter { !it.isEnabled }.map { it.id })
            kept.filter { it.id !in published }.map { info(application, valid.getValue(it.id), 0) }.takeIf { it.isNotEmpty() }?.let { manager.updateShortcuts(it) }
            selected.map { it.id }
        } catch (error: Exception) {
            Log.w(TAG, "Could not publish shortcuts", error)
            emptyList()
        }
    }

    /** Remembers that a shortcut was used so it ranks first, and tells the launcher. */
    fun recordUse(context: Context, installation: String, actionID: String) {
        val application = context.applicationContext
        val id = ShortcutPlanner.id(installation, actionID)
        val updated = ShortcutPlanner.touch(recent(application), id)
        application.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().putString(KEY_RECENT, JSONArray(updated).toString()).apply()
        runCatching { application.getSystemService(ShortcutManager::class.java)?.reportShortcutUsed(id) }
    }

    private fun recent(context: Context): List<String> {
        val text = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(KEY_RECENT, null) ?: return emptyList()
        val array = runCatching { JSONArray(text) }.getOrNull() ?: return emptyList()
        return (0 until minOf(array.length(), ShortcutPlanner.MAXIMUM_RECENT)).mapNotNull { array.opt(it) as? String }
    }

    private fun info(context: Context, candidate: ShortcutCandidate, rank: Int): ShortcutInfo {
        val intent = Intent(context, ShortcutActionActivity::class.java)
            .setAction(ACTION_RUN)
            .putExtra(EXTRA_INSTALLATION, candidate.installation)
            .putExtra(EXTRA_ACTION, candidate.actionID)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        return ShortcutInfo.Builder(context, candidate.id)
            .setShortLabel(candidate.title)
            .setLongLabel("${candidate.title} · ${candidate.packageName}".take(80))
            .setIcon(Icon.createWithResource(context, ControlIconResources.drawable(candidate.systemImage)))
            .setIntent(intent)
            .setRank(rank)
            .build()
    }
}

/**
 * Keeps the system surfaces in step with the library. `Library` does not call
 * these itself; call them from wherever packages change.
 */
object SurfaceHooks {
    private val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "scriptwidget-surfaces") }

    /**
     * Call after a package was installed, imported, renamed, duplicated or
     * edited. Republishes shortcuts, frees tiles of packages that no longer
     * exist and ends their Live Updates. Returns immediately.
     */
    fun onLibraryChanged(context: Context) {
        val application = context.applicationContext
        executor.execute { runCatching { reconcile(application) } }
    }

    /** Call after a package was deleted: frees its tiles, ends its Live Update and removes its shortcuts. Returns immediately. */
    fun onPackageDeleted(context: Context, installation: String) {
        val application = context.applicationContext
        executor.execute {
            runCatching { ControlTileStore.get(application).retire(installation) }
            runCatching { LiveUpdates.end(application, installation) }
            runCatching { reconcile(application) }
        }
    }

    /** The work of [onLibraryChanged], done on the calling (background) thread. */
    fun reconcile(context: Context) {
        AppServices.attach(context.applicationContext)
        val installations = AppServices.library.list().map { it.installation }.toSet()
        ControlTileStore.get(context).retain { it.installation in installations }
        LiveUpdates.reconcile(context)
        ShortcutPublisher.sync(context)
    }
}

/**
 * Invisible activity a launcher shortcut starts. It hands the request to
 * [SurfaceActionReceiver] and finishes at once, so no window appears.
 */
class ShortcutActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val installation = intent?.getStringExtra(ShortcutPublisher.EXTRA_INSTALLATION)
        val action = intent?.getStringExtra(ShortcutPublisher.EXTRA_ACTION)
        if (intent?.action == ShortcutPublisher.ACTION_RUN && !installation.isNullOrEmpty() && !action.isNullOrEmpty()) {
            sendBroadcast(Intent(this, SurfaceActionReceiver::class.java)
                .setAction(ShortcutPublisher.ACTION_RUN)
                .putExtra(ShortcutPublisher.EXTRA_INSTALLATION, installation)
                .putExtra(ShortcutPublisher.EXTRA_ACTION, action)
                .addFlags(Intent.FLAG_RECEIVER_FOREGROUND))
        }
        finish()
    }
}

/** Runs a shortcut's action while the broadcast keeps the process alive. */
class SurfaceActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ShortcutPublisher.ACTION_RUN) return
        val installation = intent.getStringExtra(ShortcutPublisher.EXTRA_INSTALLATION) ?: return
        val action = intent.getStringExtra(ShortcutPublisher.EXTRA_ACTION) ?: return
        val application = context.applicationContext
        // The script has five seconds; a broadcast may run for ten.
        val pending = goAsync()
        ActionRunner.runAsync(application, installation, action, ActionPlanner.SOURCE_SHORTCUT, null, null) { result ->
            try {
                if (result.ok) ShortcutPublisher.recordUse(application, installation, action)
                Toast.makeText(application, if (result.ok) application.getString(R.string.shortcut_done) else result.message, Toast.LENGTH_SHORT).show()
            } finally {
                pending.finish()
            }
            // Ranking changed, or the action is gone: bring the launcher's list up to date.
            SurfaceHooks.onLibraryChanged(application)
        }
    }
}
