package com.everettjf.scriptwidget.widget

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.widget.RemoteViews
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.MainActivity
import com.everettjf.scriptwidget.R
import com.everettjf.scriptwidget.core.render.ListSlot
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The scrolling part of `<list>` widgets. The rows travel inside the widget
 * update as images, a few rows per image, and the launcher scrolls them.
 *
 * What a tap does stays in this app. A row only carries a number; the
 * launcher sends that number back and it is looked up in the taps saved for
 * the widget, so a launcher cannot supply a link or an action of its own.
 */
object WidgetLists {
    private const val TAG = "ScriptWidget"
    /** Tap number of a place in the list that has no tap target of its own. */
    const val TAP_OPEN_APP = -1
    private const val MAXIMUM_TAPS = 400
    /**
     * An image smaller than this is copied into the update itself, and one
     * update may carry about 800 KB; larger images are passed by reference.
     */
    private const val INLINE_IMAGE_BYTES = 16 * 1024
    private const val MAXIMUM_INLINE_BYTES = 320 * 1024

    /** The list of one widget size as drawn for the light and the dark theme. */
    class Drawn(val light: ListSlot, val night: ListSlot?)

    /** Collects what one widget update adds: the taps of every size, and the bytes copied into the update. */
    class Update {
        val taps = JSONArray()
        var inlineBytes = 0
    }

    private fun file(context: Context, appWidgetId: Int) = File(File(context.filesDir, "widget-lists"), "$appWidgetId.json")

    /** The rows of one widget size as collection items. Pieces that no longer fit in the update are left out. */
    fun items(context: Context, drawn: Drawn, update: Update): RemoteViews.RemoteCollectionItems {
        val builder = RemoteViews.RemoteCollectionItems.Builder().setHasStableIds(true).setViewTypeCount(1)
        // The dark drawing is used only when it has the same pieces; otherwise both themes show the light one.
        val nightPieces = drawn.night?.pieces?.takeIf { it.size == drawn.light.pieces.size }
        for ((position, piece) in drawn.light.pieces.withIndex()) {
            val night = nightPieces?.get(position)?.png?.takeIf { !it.contentEquals(piece.png) }
            val inline = listOfNotNull(piece.png, night).filter { it.size < INLINE_IMAGE_BYTES }.sumOf { it.size }
            if (update.inlineBytes + inline > MAXIMUM_INLINE_BYTES) break
            update.inlineBytes += inline
            val views = RemoteViews(context.packageName, R.layout.widget_list_row)
            val lightIcon = Icon.createWithData(piece.png, 0, piece.png.size)
            // The launcher decodes the image and picks the one for its own theme.
            if (night == null) views.setImageViewIcon(R.id.widget_row_image, lightIcon)
            else views.setIcon(R.id.widget_row_image, "setImageIcon", lightIcon, Icon.createWithData(night, 0, night.size))
            views.setViewLayoutHeight(R.id.widget_row_image, piece.heightPoints, TypedValue.COMPLEX_UNIT_DIP)
            // Outside a tap target a tap opens the package in the app, like the rest of the widget.
            views.setOnClickFillInIntent(R.id.widget_row, Intent().putExtra(ListTapActivity.EXTRA_TAP, TAP_OPEN_APP))
            for (region in piece.hitRegions) {
                if (update.taps.length() >= MAXIMUM_TAPS) break
                val target = RemoteViews(context.packageName, R.layout.widget_list_hit)
                val left = region.bounds.left.coerceAtLeast(0f)
                val top = region.bounds.top.coerceIn(0f, piece.heightPoints)
                target.setViewLayoutMargin(R.id.widget_hit, RemoteViews.MARGIN_LEFT, left, TypedValue.COMPLEX_UNIT_DIP)
                target.setViewLayoutMargin(R.id.widget_hit, RemoteViews.MARGIN_TOP, top, TypedValue.COMPLEX_UNIT_DIP)
                target.setViewLayoutWidth(R.id.widget_hit, (region.bounds.right - left).coerceAtLeast(1f), TypedValue.COMPLEX_UNIT_DIP)
                target.setViewLayoutHeight(R.id.widget_hit, (region.bounds.bottom.coerceAtMost(piece.heightPoints) - top).coerceAtLeast(1f), TypedValue.COMPLEX_UNIT_DIP)
                target.setOnClickFillInIntent(R.id.widget_hit, Intent().putExtra(ListTapActivity.EXTRA_TAP, update.taps.length()))
                update.taps.put(region.interaction)
                views.addView(R.id.widget_row_overlay, target)
            }
            builder.addItem(position.toLong(), views)
        }
        return builder.build()
    }

    /** Saves what each tap number of the widget does. Call it before the update is sent. */
    @Synchronized
    fun saveTaps(context: Context, appWidgetId: Int, update: Update) {
        val file = file(context, appWidgetId)
        if (update.taps.length() == 0) { file.delete(); return }
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, file.name + ".tmp")
        temporary.writeText(update.taps.toString())
        if (!temporary.renameTo(file)) Log.w(TAG, "Could not save the list taps of widget $appWidgetId")
    }

    @Synchronized
    fun remove(context: Context, appWidgetId: Int) { file(context, appWidgetId).delete() }

    /** What the tap numbered [tap] does, as this app saved it; null for an unknown number. */
    @Synchronized
    fun interaction(context: Context, appWidgetId: Int, tap: Int): JSONObject? {
        if (tap < 0) return null
        val file = file(context, appWidgetId).takeIf { it.isFile && it.length() < 2L * 1024 * 1024 } ?: return null
        return runCatching { JSONArray(file.readText()).optJSONObject(tap) }.getOrNull()
    }

    /**
     * Where every tap in the list goes. A collection needs one template for
     * all its items, and the launcher fills in only the tap number.
     */
    fun tapTemplate(context: Context, appWidgetId: Int): PendingIntent {
        val intent = Intent(context, ListTapActivity::class.java).setData(Uri.parse("scriptwidget-list-tap://$appWidgetId"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
    }
}

/**
 * Receives a tap in a list. It is invisible and finishes at once: a link is
 * opened, a button or toggle is handed to [WidgetActionReceiver].
 *
 * The widget and the tap number are the only input. The widget comes from
 * the address this app put in the template; the number is looked up in the
 * taps this app saved for that widget.
 */
class ListTapActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try { handle() } catch (error: Throwable) { Log.w("ScriptWidget", "List tap failed", error) }
        finish()
    }

    private fun handle() {
        val appWidgetId = intent.data?.takeIf { it.scheme == "scriptwidget-list-tap" }?.host?.toIntOrNull() ?: return
        AppServices.attach(applicationContext)
        val binding = AppServices.widgets.get(appWidgetId) ?: return
        val interaction = WidgetLists.interaction(this, appWidgetId, intent.getIntExtra(EXTRA_TAP, WidgetLists.TAP_OPEN_APP))
        when (interaction?.optString("type")) {
            "link" -> LinkActivity.open(this, interaction.optString("url"))
            "button", "toggle" -> sendBroadcast(Intent(this, WidgetActionReceiver::class.java)
                .putExtra(WidgetActionReceiver.EXTRA_WIDGET, appWidgetId).putExtra(WidgetActionReceiver.EXTRA_INTERACTION, interaction.toString()))
            else -> startActivity(Intent(this, MainActivity::class.java)
                .setData(Uri.parse("scriptwidget://package/${Uri.encode(binding.installation)}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP))
        }
    }

    companion object { const val EXTRA_TAP = "tap" }
}
