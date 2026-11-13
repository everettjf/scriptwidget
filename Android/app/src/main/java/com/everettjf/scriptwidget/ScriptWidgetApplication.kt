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

    /** Instructions of the Skills the user enabled, appended to AI requests; null when none are enabled. */
    fun skillsPrompt(): String? = runCatching { GalleryServices.get(requireContext()).skills.enabledSkillsPromptText() }.getOrNull()?.takeIf { it.isNotBlank() }

    /**
     * Full Package 2.0 validation (manifest rules and a compile of every script) for packages
     * that arrive from outside: archives and Gallery downloads. Throws when the package is invalid.
     */
    fun validatePackage(files: com.everettjf.scriptwidget.core.runtime.PackageFiles) {
        try {
            runtime.compiler.prepare(files)
        } catch (error: com.everettjf.scriptwidget.core.runtime.RuntimeError) {
            throw IllegalArgumentException(error.message)
        }
    }

    val plugins: com.everettjf.scriptwidget.core.plugin.PluginStore by lazy { com.everettjf.scriptwidget.core.plugin.PluginStore(java.io.File(requireContext().filesDir, "Plugins")) }
    val runtime: WidgetRuntime by lazy {
        val modules = listOf<com.everettjf.scriptwidget.core.runtime.NativeModule>(com.everettjf.scriptwidget.core.plugin.DataSourceModule(plugins))
        WidgetRuntime(requireContext(), modules).also { it.renderer.fonts.useSystemFont = settings.useSystemFont }
    }
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
