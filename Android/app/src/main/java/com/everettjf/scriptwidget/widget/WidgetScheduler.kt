package com.everettjf.scriptwidget.widget

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.everettjf.scriptwidget.AppServices
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/** Queues widget redraws. Work is unique per widget, so bursts collapse into one run. */
object WidgetScheduler {
    fun refresh(context: Context, appWidgetIds: IntArray) {
        if (appWidgetIds.isEmpty()) return
        val manager = WorkManager.getInstance(context)
        for (id in appWidgetIds) {
            val request = OneTimeWorkRequestBuilder<WidgetUpdateWorker>()
                .setInputData(workDataOf("ids" to intArrayOf(id)))
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
            manager.enqueueUniqueWork("widget-$id", ExistingWorkPolicy.REPLACE, request)
        }
    }

    fun refreshAll(context: Context) = refresh(context, ScriptWidgetProvider.allIds(context))

    /** Redraws every widget that shows the given package. */
    fun refreshPackage(context: Context, installation: String) {
        AppServices.attach(context.applicationContext)
        refresh(context, ScriptWidgetProvider.allIds(context).filter { AppServices.widgets.get(it)?.installation == installation }.toIntArray())
    }

    fun schedulePeriodicRefresh(context: Context) {
        AppServices.attach(context.applicationContext)
        val minutes = AppServices.settings.refreshMinutes.toLong()
        val request = PeriodicWorkRequestBuilder<WidgetUpdateWorker>(minutes, TimeUnit.MINUTES).setInputData(workDataOf("all" to true)).build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork("widget-refresh", ExistingPeriodicWorkPolicy.UPDATE, request)
    }
}

class WidgetUpdateWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result = withContext(Dispatchers.Default) {
        AppServices.attach(applicationContext)
        val ids = if (inputData.getBoolean("all", false)) ScriptWidgetProvider.allIds(applicationContext) else inputData.getIntArray("ids") ?: IntArray(0)
        for (id in ids) runCatching { WidgetUpdater.update(applicationContext, id) }
        Result.success()
    }
}
