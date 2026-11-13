package com.everettjf.scriptwidget.core.api

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.icu.util.Calendar
import android.icu.util.TimeZone
import android.icu.util.ULocale
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.os.SystemClock
import android.provider.Settings
import android.text.format.DateFormat
import org.json.JSONArray
import org.json.JSONObject
import java.util.Date

/**
 * Snapshots behind `$device` and `$system`. Values are captured once per
 * execution, like the native iOS runtime. None of them needs a permission.
 */
object DeviceInfo {
    fun device(context: Context): JSONObject {
        val metrics = context.resources.displayMetrics
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.let { it.getIntExtra(BatteryManager.EXTRA_LEVEL, -1).toDouble() / maxOf(1, it.getIntExtra(BatteryManager.EXTRA_SCALE, 100)) } ?: -1.0
        val state = when (battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)) {
            BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
            BatteryManager.BATTERY_STATUS_FULL -> "full"
            BatteryManager.BATTERY_STATUS_DISCHARGING, BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "unplugged"
            else -> "unknown"
        }
        val storage = runCatching { StatFs(Environment.getDataDirectory().path) }.getOrNull()
        return JSONObject()
            .put("screen", JSONObject().put("width", metrics.widthPixels / metrics.density.toDouble()).put("height", metrics.heightPixels / metrics.density.toDouble()).put("scale", metrics.density.toDouble()))
            .put("language", ULocale.getDefault().language)
            .put("model", Build.MODEL)
            .put("name", Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL)
            .put("battery", JSONObject().put("level", level).put("state", state))
            .put("systemVersion", Build.VERSION.RELEASE)
            .put("totalDiskSpace", storage?.totalBytes ?: 0L)
            .put("freeDiskSpace", storage?.availableBytes ?: 0L)
    }

    fun system(context: Context): JSONObject {
        val locale = ULocale.getDefault()
        val zone = TimeZone.getDefault()
        val now = Date()
        val calendar = Calendar.getInstance(locale)
        val power = context.getSystemService(PowerManager::class.java)
        val activity = context.getSystemService(ActivityManager::class.java)
        val memory = ActivityManager.MemoryInfo().also { activity?.getMemoryInfo(it) }
        val brightness = runCatching { Settings.System.getInt(context.contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255.0 }.getOrDefault(0.5)
        val animationScale = runCatching { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) }.getOrDefault(1f)
        val packageInfo = runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
        val thermal = when (power?.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE, PowerManager.THERMAL_STATUS_LIGHT -> "nominal"
            PowerManager.THERMAL_STATUS_MODERATE -> "fair"
            PowerManager.THERMAL_STATUS_SEVERE -> "serious"
            PowerManager.THERMAL_STATUS_CRITICAL, PowerManager.THERMAL_STATUS_EMERGENCY, PowerManager.THERMAL_STATUS_SHUTDOWN -> "critical"
            else -> "nominal"
        }
        val languages = context.resources.configuration.locales.let { list -> JSONArray(List(list.size()) { list[it].toLanguageTag() }) }
        return JSONObject()
            .put("appInfo", JSONObject().put("name", "ScriptWidget").put("bundleId", context.packageName)
                .put("version", packageInfo?.versionName ?: "").put("build", packageInfo?.longVersionCode?.toString() ?: ""))
            .put("locale", locale.toString())
            .put("preferredLanguages", languages)
            .put("timeZone", JSONObject().put("identifier", zone.id)
                .put("abbreviation", zone.getDisplayName(zone.inDaylightTime(now), TimeZone.SHORT, locale))
                .put("offsetSeconds", zone.getOffset(now.time) / 1000))
            .put("is24HourClock", DateFormat.is24HourFormat(context))
            .put("calendarInfo", JSONObject().put("identifier", calendar.type.let { if (it == "gregorian") "gregorian" else it })
                .put("firstWeekday", calendar.firstDayOfWeek).put("minimumDaysInFirstWeek", calendar.minimalDaysInFirstWeek))
            .put("systemUptime", SystemClock.elapsedRealtime() / 1000.0)
            .put("memory", JSONObject().put("physical", memory.totalMem))
            .put("thermalState", thermal)
            .put("lowPowerMode", power?.isPowerSaveMode ?: false)
            .put("brightness", brightness.coerceIn(0.0, 1.0))
            .put("reduceMotionEnabled", animationScale == 0f)
            .put("platform", "android")
            .put("hostName", Build.MODEL)
            .put("processName", "ScriptWidget")
            .put("osVersionString", "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            .put("processorCount", Runtime.getRuntime().availableProcessors())
            .put("activeProcessorCount", Runtime.getRuntime().availableProcessors())
    }
}
