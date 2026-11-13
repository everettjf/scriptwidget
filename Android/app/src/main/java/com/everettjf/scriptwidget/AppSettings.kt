package com.everettjf.scriptwidget

import android.content.Context

/** User preferences that are not secrets. */
class AppSettings(context: Context) {
    private val preferences = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    /** Draw default-design text with the device font instead of the bundled one. */
    var useSystemFont: Boolean
        get() = preferences.getBoolean("useSystemFont", false)
        set(value) { preferences.edit().putBoolean("useSystemFont", value).apply() }

    /** Minutes between background refreshes; WorkManager enforces a 15-minute floor. */
    var refreshMinutes: Int
        get() = preferences.getInt("refreshMinutes", 30).coerceIn(15, 24 * 60)
        set(value) { preferences.edit().putInt("refreshMinutes", value.coerceIn(15, 24 * 60)).apply() }

    var starterTemplatesInstalled: Boolean
        get() = preferences.getBoolean("starterTemplatesInstalled", false)
        set(value) { preferences.edit().putBoolean("starterTemplatesInstalled", value).apply() }
}
