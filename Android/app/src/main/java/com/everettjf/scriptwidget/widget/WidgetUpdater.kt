package com.everettjf.scriptwidget.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.util.SizeF
import android.util.TypedValue
import android.widget.RemoteViews
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.InstalledPackage
import com.everettjf.scriptwidget.MainActivity
import com.everettjf.scriptwidget.R
import com.everettjf.scriptwidget.core.RunRequest
import com.everettjf.scriptwidget.core.render.RenderOutput
import org.json.JSONObject

/** What a tap asked for. Carried in the broadcast and replayed against the package. */
class WidgetAction(val type: String, val actionID: String?, val function: String?, val stateKey: String?, val value: Boolean?)

/**
 * Draws one placed widget: runs its package, renders one bitmap per size the
 * launcher reports, and attaches transparent tap targets over links, buttons
 * and toggles.
 */
object WidgetUpdater {
    private const val TAG = "ScriptWidget"
    private const val MAXIMUM_HIT_REGIONS = 24
    private const val MAXIMUM_SIZES = 2
    private const val MAXIMUM_LIVE_TEXTS = 6
    private const val MAXIMUM_GIFS = 2
    private const val SWING_FRAMES = 16
    private const val SPIN_FRAMES = 36
    private const val SPIN_BUDGET_BYTES = 2L * 1024 * 1024
    /** All GIF frames of one widget size together; part of the Android 17 widget bitmap budget. */
    private const val GIF_BUDGET_BYTES = 3L * 1024 * 1024
    /** A running timer and the current time update themselves; other date styles are redrawn on refresh. */
    private val LIVE_DATE_STYLES = setOf("timer", "time")

    /** Draws the widget and returns the views that were sent to the launcher, or null when the widget is gone. */
    fun update(context: Context, appWidgetId: Int, action: WidgetAction? = null): RemoteViews? {
        AppServices.attach(context.applicationContext)
        val manager = AppWidgetManager.getInstance(context)
        if (manager.getAppWidgetInfo(appWidgetId) == null) return null
        val binding = AppServices.widgets.get(appWidgetId)
        if (binding == null) {
            return message(context, appWidgetId, context.getString(R.string.widget_choose)).also { manager.updateAppWidget(appWidgetId, it) }
        }
        val installed = AppServices.library.findByInstallation(binding.installation)
        if (installed == null) {
            return message(context, appWidgetId, context.getString(R.string.widget_missing)).also { manager.updateAppWidget(appWidgetId, it) }
        }
        val started = System.nanoTime()
        val runtime = AppServices.runtime
        val family = ScriptWidgetProvider.family(context, appWidgetId)
        val dark = runtime.isDarkMode()
        if (action != null) perform(installed, family, binding.parameter, dark, action)

        val request = RunRequest(installed.files, installed.installation, family, binding.parameter, dark, buildDirectory = installed.buildDirectory)
        val result = runtime.run(request)
        // The other theme: the same tree unless the script asked which theme is active.
        val otherRequest = RunRequest(installed.files, installed.installation, family, binding.parameter, !dark, buildDirectory = installed.buildDirectory)
        val otherResult = if (result.dependsOnAppearance) runtime.run(otherRequest) else result
        val sizes = sizes(context, manager.getAppWidgetOptions(appWidgetId), family)
        val density = context.resources.displayMetrics.density
        // Android 17 rejects updates whose bitmaps exceed 6 x screen pixels; stay well inside.
        val metrics = context.resources.displayMetrics
        val budget = (metrics.widthPixels.toLong() * metrics.heightPixels * 6L * 70L / 100L) / (sizes.size * 2)

        // "Remove animations" in system accessibility settings keeps GIFs on their first frame.
        val animate = runCatching { android.provider.Settings.Global.getFloat(context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) }.getOrDefault(1f) > 0f
        val views = LinkedHashMap<SizeF, RemoteViews>()
        var bitmapBytes = 0L
        for (size in sizes) {
            val output = runtime.render(request, result, size.width, size.height, density, budget, LIVE_DATE_STYLES, liveGifs = animate, liveMotion = animate)
            val other = runtime.render(otherRequest, otherResult, size.width, size.height, density, budget, LIVE_DATE_STYLES, darkMode = !dark, liveGifs = animate, liveMotion = animate)
            // Identical drawings need one bitmap; otherwise the launcher picks by its own theme.
            val themed = if (other.bitmap.sameAs(output.bitmap)) null else other
            bitmapBytes += output.bitmap.allocationByteCount + (themed?.bitmap?.allocationByteCount ?: 0)
            views[size] = build(context, appWidgetId, installed, output, size, themed, dark)
        }
        val combined = if (views.size == 1) views.values.first() else RemoteViews(views)
        manager.updateAppWidget(appWidgetId, combined)
        AppServices.widgets.markUpdated(appWidgetId, System.currentTimeMillis())
        result.nextTimelineTransition?.let { WidgetScheduler.scheduleAt(context, appWidgetId, it) }
        Log.i(TAG, "widget $appWidgetId ${installed.name} $family sizes=${sizes.joinToString { "${it.width.toInt()}x${it.height.toInt()}" }} " +
            "error=${result.execution.error?.kind} exec=${result.execution.elapsedMilliseconds}ms bitmaps=${bitmapBytes / 1024}KiB total=${(System.nanoTime() - started) / 1_000_000}ms")
        return combined
    }

    /** Runs the tapped action before the widget is redrawn. */
    private fun perform(installed: InstalledPackage, family: String, parameter: String, dark: Boolean, action: WidgetAction) {
        val runtime = AppServices.runtime
        val environments = HashMap<String, String>()
        environments["action-source"] = "widget"
        if (action.type == "toggle" && action.value != null) {
            // The toggle's new state is saved first, then offered to the action as action-value.
            if (!action.stateKey.isNullOrEmpty() && Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$").matches(action.stateKey) && installed.permissions.contains("storage")) {
                runtime.storage.setString(installed.installation, action.stateKey, if (action.value) "true" else "false")
            }
            environments["action-value"] = if (action.value) "true" else "false"
            environments["control-value"] = environments["action-value"]!!
        }
        when {
            !action.actionID.isNullOrEmpty() -> {
                environments["action-id"] = action.actionID
                runtime.run(RunRequest(installed.files, installed.installation, family, parameter, dark, actionID = action.actionID, extraEnvironments = environments, buildDirectory = installed.buildDirectory))
            }
            !action.function.isNullOrEmpty() -> {
                runtime.run(RunRequest(installed.files, installed.installation, family, parameter, dark, callFunction = action.function, extraEnvironments = environments, buildDirectory = installed.buildDirectory))
            }
        }
    }

    /** Sizes in dp the launcher may show this widget at (portrait and landscape). */
    private fun sizes(context: Context, options: Bundle, family: String): List<SizeF> {
        val reported = options.getParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, SizeF::class.java)
            ?.filter { it.width > 0 && it.height > 0 }?.distinct().orEmpty()
        if (reported.isNotEmpty()) return reported.take(MAXIMUM_SIZES)
        val minWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
        val maxHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)
        val maxWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH)
        val minHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)
        val result = ArrayList<SizeF>()
        if (minWidth > 0 && maxHeight > 0) result += SizeF(minWidth.toFloat(), maxHeight.toFloat())
        if (maxWidth > 0 && minHeight > 0 && (maxWidth != minWidth || minHeight != maxHeight)) result += SizeF(maxWidth.toFloat(), minHeight.toFloat())
        if (result.isNotEmpty()) return result
        return listOf(when (family) { "small" -> SizeF(160f, 160f); "large" -> SizeF(330f, 330f); "extraLarge" -> SizeF(680f, 330f); else -> SizeF(330f, 160f) })
    }

    private fun build(context: Context, appWidgetId: Int, installed: InstalledPackage, output: RenderOutput, size: SizeF, other: RenderOutput? = null, dark: Boolean = false): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_root)
        if (other == null) views.setImageViewBitmap(R.id.widget_image, output.bitmap.asShared())
        else {
            val light = if (dark) other.bitmap else output.bitmap
            val night = if (dark) output.bitmap else other.bitmap
            views.setIcon(R.id.widget_image, "setImageIcon", android.graphics.drawable.Icon.createWithBitmap(light), android.graphics.drawable.Icon.createWithBitmap(night))
        }
        views.setContentDescription(R.id.widget_image, installed.displayName)
        // With no tap target of its own, the widget opens its package in the app.
        views.setOnClickPendingIntent(R.id.widget_image, openApp(context, appWidgetId, installed))
        views.removeAllViews(R.id.widget_dynamic)
        for ((index, slot) in output.dateSlots.take(MAXIMUM_LIVE_TEXTS).withIndex()) {
            val otherColor = other?.dateSlots?.getOrNull(index)?.color ?: slot.color
            liveText(context, slot, size, if (dark) otherColor else slot.color, if (dark) slot.color else otherColor)?.let { views.addView(R.id.widget_dynamic, it) }
        }
        for (slot in output.gifSlots.take(MAXIMUM_GIFS)) {
            val data = installed.files.readBytes(slot.source.removePrefix("res:")) ?: continue
            val scale = output.scale
            val frames = com.everettjf.scriptwidget.core.render.GifSampler.sample(data, (slot.bounds.width() * scale).toInt(), (slot.bounds.height() * scale).toInt(), GIF_BUDGET_BYTES / MAXIMUM_GIFS) ?: continue
            val flipper = RemoteViews(context.packageName, R.layout.widget_gif)
            flipper.setViewLayoutMargin(R.id.widget_gif, RemoteViews.MARGIN_LEFT, slot.bounds.left.coerceAtLeast(0f), TypedValue.COMPLEX_UNIT_DIP)
            flipper.setViewLayoutMargin(R.id.widget_gif, RemoteViews.MARGIN_TOP, slot.bounds.top.coerceAtLeast(0f), TypedValue.COMPLEX_UNIT_DIP)
            flipper.setViewLayoutWidth(R.id.widget_gif, slot.bounds.width().coerceAtLeast(1f), TypedValue.COMPLEX_UNIT_DIP)
            flipper.setViewLayoutHeight(R.id.widget_gif, slot.bounds.height().coerceAtLeast(1f), TypedValue.COMPLEX_UNIT_DIP)
            flipper.setInt(R.id.widget_gif, "setFlipInterval", frames.intervalMilliseconds)
            for (frame in frames.frames) {
                val image = RemoteViews(context.packageName, R.layout.widget_gif_frame)
                image.setImageViewBitmap(R.id.widget_gif_frame, frame)
                flipper.addView(R.id.widget_gif, image)
            }
            views.addView(R.id.widget_dynamic, flipper)
        }
        for (slot in output.motionSlots) motion(context, slot, size)?.let { views.addView(R.id.widget_dynamic, it) }
        views.removeAllViews(R.id.widget_overlay)
        for ((index, region) in output.hitRegions.take(MAXIMUM_HIT_REGIONS).withIndex()) {
            val intent = pendingIntent(context, appWidgetId, index, region.interaction) ?: continue
            val hit = RemoteViews(context.packageName, R.layout.widget_hit)
            val left = region.bounds.left.coerceIn(0f, size.width)
            val top = region.bounds.top.coerceIn(0f, size.height)
            hit.setViewLayoutMargin(R.id.widget_hit, RemoteViews.MARGIN_LEFT, left, TypedValue.COMPLEX_UNIT_DIP)
            hit.setViewLayoutMargin(R.id.widget_hit, RemoteViews.MARGIN_TOP, top, TypedValue.COMPLEX_UNIT_DIP)
            hit.setViewLayoutWidth(R.id.widget_hit, (region.bounds.right.coerceAtMost(size.width) - left).coerceAtLeast(1f), TypedValue.COMPLEX_UNIT_DIP)
            hit.setViewLayoutHeight(R.id.widget_hit, (region.bounds.bottom.coerceAtMost(size.height) - top).coerceAtLeast(1f), TypedValue.COMPLEX_UNIT_DIP)
            hit.setOnClickPendingIntent(R.id.widget_hit, intent)
            views.addView(R.id.widget_overlay, hit)
        }
        return views
    }

    /**
     * A timer or clock the launcher keeps current without waking the app.
     * The view is wider than the measured text because the system font has
     * other metrics than the bundled one; it grows away from its alignment edge.
     */
    private fun liveText(context: Context, slot: com.everettjf.scriptwidget.core.render.DateSlot, size: SizeF, lightColor: Int, nightColor: Int): RemoteViews? {
        val style = slot.style ?: return null
        val timer = slot.description.optString("style") == "timer"
        val layout = when (slot.align) {
            "center" -> if (timer) (if (style.weight >= 600) R.layout.widget_timer_center_bold else R.layout.widget_timer_center_regular)
                else (if (style.weight >= 600) R.layout.widget_clock_center_bold else R.layout.widget_clock_center_regular)
            "right" -> if (timer) (if (style.weight >= 600) R.layout.widget_timer_end_bold else R.layout.widget_timer_end_regular)
                else (if (style.weight >= 600) R.layout.widget_clock_end_bold else R.layout.widget_clock_end_regular)
            else -> if (timer) (if (style.weight >= 600) R.layout.widget_timer_start_bold else R.layout.widget_timer_start_regular)
                else (if (style.weight >= 600) R.layout.widget_clock_start_bold else R.layout.widget_clock_start_regular)
        }
        val views = RemoteViews(context.packageName, layout)
        val extra = slot.bounds.width() * 0.35f + 12f
        val left = when (slot.align) { "center" -> slot.bounds.left - extra / 2f; "right" -> slot.bounds.left - extra; else -> slot.bounds.left }.coerceAtLeast(0f)
        val width = (slot.bounds.width() + extra).coerceAtMost(size.width - left).coerceAtLeast(1f)
        val id = R.id.widget_live_text
        views.setViewLayoutMargin(id, RemoteViews.MARGIN_LEFT, left, TypedValue.COMPLEX_UNIT_DIP)
        views.setViewLayoutMargin(id, RemoteViews.MARGIN_TOP, slot.bounds.top.coerceAtLeast(0f), TypedValue.COMPLEX_UNIT_DIP)
        views.setViewLayoutWidth(id, width, TypedValue.COMPLEX_UNIT_DIP)
        views.setViewLayoutHeight(id, slot.bounds.height().coerceAtLeast(1f), TypedValue.COMPLEX_UNIT_DIP)
        views.setTextViewTextSize(id, TypedValue.COMPLEX_UNIT_DIP, style.size)
        views.setColorInt(id, "setTextColor", lightColor, nightColor)
        if (timer) {
            val target = slot.description.optLong("target")
            val now = System.currentTimeMillis()
            // Counts down to the target, then up from it, like Text(date, style: .timer).
            views.setChronometerCountDown(id, target > now)
            views.setChronometer(id, android.os.SystemClock.elapsedRealtime() + (target - now), null, true)
        }
        return views
    }

    /**
     * Moves an animated view. Clock effects become the one visible hand of a
     * system clock, so they show the real time. A swing becomes frames of the
     * same bitmap at different offsets that the launcher flips through.
     */
    private fun motion(context: Context, slot: com.everettjf.scriptwidget.core.render.MotionSlot, size: SizeF): RemoteViews? {
        val side = slot.sizePoints
        if (slot.description.optString("kind") == "clock" && slot.description.optString("type") == "clock") return spin(context, slot)
        if (slot.description.optString("kind") == "clock") {
            val views = RemoteViews(context.packageName, R.layout.widget_clock_hand)
            val id = R.id.widget_clock_hand
            views.setViewLayoutMargin(id, RemoteViews.MARGIN_LEFT, slot.anchor.x - side / 2f, TypedValue.COMPLEX_UNIT_DIP)
            views.setViewLayoutMargin(id, RemoteViews.MARGIN_TOP, slot.anchor.y - side / 2f, TypedValue.COMPLEX_UNIT_DIP)
            views.setViewLayoutWidth(id, side, TypedValue.COMPLEX_UNIT_DIP)
            views.setViewLayoutHeight(id, side, TypedValue.COMPLEX_UNIT_DIP)
            // The hand is drawn at its bitmap's pixel size, so tag the bitmap with the density it was drawn for.
            slot.bitmap.density = (context.resources.displayMetrics.densityDpi * (slot.bitmap.width / (side * context.resources.displayMetrics.density))).toInt()
            val icon = android.graphics.drawable.Icon.createWithBitmap(slot.bitmap)
            val method = when (slot.description.optString("type")) { "clockSecond" -> "setSecondHand"; "clockHour" -> "setHourHand"; else -> "setMinuteHand" }
            views.setIcon(id, method, icon)
            val zone = slot.description.optString("timezone")
            if (zone.isNotEmpty() && zone != "current" && java.util.TimeZone.getAvailableIDs().contains(zone)) views.setString(id, "setTimeZone", zone)
            return views
        }
        val distance = slot.description.optDouble("distance", 10.0).toFloat()
        val duration = slot.description.optDouble("duration", 1.0).toFloat()
        val horizontal = slot.description.optString("axis") == "x"
        val reach = kotlin.math.abs(distance)
        val flipper = RemoteViews(context.packageName, R.layout.widget_swing)
        val boxWidth = side + if (horizontal) reach * 2f else 0f
        val boxHeight = side + if (horizontal) 0f else reach * 2f
        flipper.setViewLayoutMargin(R.id.widget_swing, RemoteViews.MARGIN_LEFT, slot.anchor.x - boxWidth / 2f, TypedValue.COMPLEX_UNIT_DIP)
        flipper.setViewLayoutMargin(R.id.widget_swing, RemoteViews.MARGIN_TOP, slot.anchor.y - boxHeight / 2f, TypedValue.COMPLEX_UNIT_DIP)
        flipper.setViewLayoutWidth(R.id.widget_swing, boxWidth, TypedValue.COMPLEX_UNIT_DIP)
        flipper.setViewLayoutHeight(R.id.widget_swing, boxHeight, TypedValue.COMPLEX_UNIT_DIP)
        // One full swing (there and back) takes twice the duration, as on iPhone.
        flipper.setInt(R.id.widget_swing, "setFlipInterval", (2000f * duration / SWING_FRAMES).toInt().coerceAtLeast(40))
        for (index in 0 until SWING_FRAMES) {
            val offset = (kotlin.math.sin(index.toDouble() / SWING_FRAMES * 2.0 * Math.PI) * distance).toFloat()
            val frame = RemoteViews(context.packageName, R.layout.widget_swing_frame)
            // Every frame shares one bitmap; only its position changes.
            frame.setImageViewBitmap(R.id.widget_swing_image, slot.bitmap)
            frame.setViewLayoutWidth(R.id.widget_swing_image, side, TypedValue.COMPLEX_UNIT_DIP)
            frame.setViewLayoutHeight(R.id.widget_swing_image, side, TypedValue.COMPLEX_UNIT_DIP)
            frame.setViewLayoutMargin(R.id.widget_swing_image, RemoteViews.MARGIN_LEFT, if (horizontal) reach + offset else 0f, TypedValue.COMPLEX_UNIT_DIP)
            frame.setViewLayoutMargin(R.id.widget_swing_image, RemoteViews.MARGIN_TOP, if (horizontal) 0f else reach + offset, TypedValue.COMPLEX_UNIT_DIP)
            flipper.addView(R.id.widget_swing, frame)
        }
        return flipper
    }

    /**
     * A clock effect with a custom interval: the view turns half a circle
     * every `interval` seconds (backwards when negative). No system view
     * turns at an arbitrary rate, so the launcher flips through rotated
     * frames. Unlike the standard hands, the phase is not tied to the time.
     */
    private fun spin(context: Context, slot: com.everettjf.scriptwidget.core.render.MotionSlot): RemoteViews {
        val side = slot.sizePoints
        val interval = slot.description.optDouble("interval", 10.0)
        val period = (2.0 * kotlin.math.abs(interval)).coerceIn(0.5, 3600.0)
        // Fast turns get fewer frames so each frame stays on screen long enough to be drawn.
        val frames = (period * 1000.0 / 60.0).toInt().coerceIn(8, SPIN_FRAMES)
        // All frames together stay inside a fixed share of the widget bitmap budget.
        var pixels = slot.bitmap.width
        while (pixels.toLong() * pixels * 4L * frames > SPIN_BUDGET_BYTES && pixels > 16) pixels = pixels * 3 / 4
        val flipper = RemoteViews(context.packageName, R.layout.widget_gif)
        flipper.setViewLayoutMargin(R.id.widget_gif, RemoteViews.MARGIN_LEFT, slot.anchor.x - side / 2f, TypedValue.COMPLEX_UNIT_DIP)
        flipper.setViewLayoutMargin(R.id.widget_gif, RemoteViews.MARGIN_TOP, slot.anchor.y - side / 2f, TypedValue.COMPLEX_UNIT_DIP)
        flipper.setViewLayoutWidth(R.id.widget_gif, side, TypedValue.COMPLEX_UNIT_DIP)
        flipper.setViewLayoutHeight(R.id.widget_gif, side, TypedValue.COMPLEX_UNIT_DIP)
        flipper.setInt(R.id.widget_gif, "setFlipInterval", (period * 1000.0 / frames).toInt().coerceAtLeast(40))
        val paint = android.graphics.Paint(android.graphics.Paint.FILTER_BITMAP_FLAG or android.graphics.Paint.ANTI_ALIAS_FLAG)
        for (index in 0 until frames) {
            val frame = Bitmap.createBitmap(pixels, pixels, Bitmap.Config.ARGB_8888)
            val canvas = android.graphics.Canvas(frame)
            val degrees = 360f * index / frames * (if (interval < 0) -1f else 1f)
            canvas.rotate(degrees, pixels / 2f, pixels / 2f)
            canvas.drawBitmap(slot.bitmap, null, android.graphics.RectF(0f, 0f, pixels.toFloat(), pixels.toFloat()), paint)
            val image = RemoteViews(context.packageName, R.layout.widget_gif_frame)
            image.setImageViewBitmap(R.id.widget_gif_frame, frame)
            flipper.addView(R.id.widget_gif, image)
        }
        return flipper
    }

    private fun Bitmap.asShared(): Bitmap = this

    private fun openApp(context: Context, appWidgetId: Int, installed: InstalledPackage): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setData(Uri.parse("scriptwidget://package/${Uri.encode(installed.installation)}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(context, appWidgetId, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun pendingIntent(context: Context, appWidgetId: Int, index: Int, interaction: JSONObject): PendingIntent? {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val identity = Uri.parse("scriptwidget-tap://$appWidgetId/$index")
        when (interaction.optString("type")) {
            "link" -> {
                val url = interaction.optString("url")
                if (url.isEmpty()) return null
                val intent = Intent(context, LinkActivity::class.java).setData(identity).putExtra(LinkActivity.EXTRA_URL, url)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
                return PendingIntent.getActivity(context, 0, intent, flags)
            }
            "button", "toggle" -> {
                val intent = Intent(context, WidgetActionReceiver::class.java).setData(identity)
                    .putExtra(WidgetActionReceiver.EXTRA_WIDGET, appWidgetId)
                    .putExtra(WidgetActionReceiver.EXTRA_INTERACTION, interaction.toString())
                return PendingIntent.getBroadcast(context, 0, intent, flags)
            }
        }
        return null
    }

    /** A plain text widget for the unconfigured and missing-package states. */
    private fun message(context: Context, appWidgetId: Int, text: String): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_loading)
        views.setTextViewText(R.id.widget_message, text)
        val intent = Intent(context, WidgetConfigActivity::class.java)
            .setData(Uri.parse("scriptwidget-config://$appWidgetId"))
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        views.setOnClickPendingIntent(android.R.id.background, PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        return views
    }
}
