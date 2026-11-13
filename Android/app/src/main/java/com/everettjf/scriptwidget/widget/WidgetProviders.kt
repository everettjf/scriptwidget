package com.everettjf.scriptwidget.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.os.Bundle
import com.everettjf.scriptwidget.AppServices

/** Base provider. Each size is its own provider so the launcher lists three widgets. */
abstract class ScriptWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        WidgetScheduler.refresh(context, appWidgetIds)
    }

    override fun onAppWidgetOptionsChanged(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int, newOptions: Bundle) {
        WidgetScheduler.refresh(context, intArrayOf(appWidgetId))
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        AppServices.attach(context.applicationContext)
        appWidgetIds.forEach { AppServices.widgets.remove(it) }
    }

    companion object {
        val providers = listOf(SmallWidgetProvider::class.java to "small", MediumWidgetProvider::class.java to "medium", LargeWidgetProvider::class.java to "large", ExtraLargeWidgetProvider::class.java to "extraLarge")

        /** `$getenv("widget-size")` value for a placed widget. */
        fun family(context: Context, appWidgetId: Int): String {
            val provider = AppWidgetManager.getInstance(context).getAppWidgetInfo(appWidgetId)?.provider?.className
            return providers.firstOrNull { it.first.name == provider }?.second ?: "medium"
        }

        fun allIds(context: Context): IntArray {
            val manager = AppWidgetManager.getInstance(context)
            return providers.flatMap { manager.getAppWidgetIds(ComponentName(context, it.first)).toList() }.toIntArray()
        }
    }
}

class SmallWidgetProvider : ScriptWidgetProvider()
class MediumWidgetProvider : ScriptWidgetProvider()
class LargeWidgetProvider : ScriptWidgetProvider()
class ExtraLargeWidgetProvider : ScriptWidgetProvider()
