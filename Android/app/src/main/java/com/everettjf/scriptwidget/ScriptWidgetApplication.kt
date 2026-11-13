package com.everettjf.scriptwidget

import android.app.Application
import android.content.Context
import android.content.res.Configuration
import com.everettjf.scriptwidget.core.WidgetRuntime
import com.everettjf.scriptwidget.widget.WidgetScheduler
import com.everettjf.scriptwidget.widget.WidgetStore

/** Process-wide services. Created lazily so widget broadcasts start quickly. */
object AppServices {
    @Volatile private var context: Context? = null

    fun attach(application: Context) { context = application.applicationContext }

    private fun requireContext(): Context = context ?: error("AppServices used before Application.onCreate")

    val runtime: WidgetRuntime by lazy { WidgetRuntime(requireContext()).also { it.renderer.fonts.useSystemFont = settings.useSystemFont } }
    val library: Library by lazy { Library(requireContext()) }
    val widgets: WidgetStore by lazy { WidgetStore(requireContext()) }
    val settings: AppSettings by lazy { AppSettings(requireContext()) }
}

class ScriptWidgetApplication : Application() {
    private var nightMode = 0

    override fun onCreate() {
        super.onCreate()
        AppServices.attach(this)
        nightMode = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
        WidgetScheduler.schedulePeriodicRefresh(this)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // A bitmap does not follow the system theme by itself: redraw when it changes.
        val mode = newConfig.uiMode and Configuration.UI_MODE_NIGHT_MASK
        if (mode != nightMode) {
            nightMode = mode
            WidgetScheduler.refreshAll(this)
        }
    }
}
