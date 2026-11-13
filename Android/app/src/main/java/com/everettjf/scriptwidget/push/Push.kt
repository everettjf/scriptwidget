package com.everettjf.scriptwidget.push

import android.content.Context
import android.util.Log
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.BuildConfig
import com.everettjf.scriptwidget.core.push.PushRegistration
import com.everettjf.scriptwidget.widget.ScriptWidgetProvider
import com.everettjf.scriptwidget.widget.WidgetScheduler
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import java.util.concurrent.Executors

/** Sends a registration body; replaced in tests. Returns the HTTP status. */
fun interface PushTransport {
    fun post(target: com.everettjf.scriptwidget.core.push.PushTarget, body: ByteArray): Int
}

/**
 * Push-triggered widget refresh for packages that declare `pushUpdates`.
 *
 * It needs a Firebase project. The build reads its identifiers from
 * `Android/firebase.properties` (git-ignored); without that file push stays
 * off and widgets keep refreshing on their schedule. The package never sees
 * the token: the app posts it to the package's declared registration URL.
 */
object Push {
    private const val TAG = "ScriptWidget"
    private val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "scriptwidget-push").apply { isDaemon = true } }

    /** True when this build was given a Firebase project. */
    val configured: Boolean get() = BuildConfig.FIREBASE_PROJECT_ID.isNotEmpty() && BuildConfig.FIREBASE_APP_ID.isNotEmpty() &&
        BuildConfig.FIREBASE_API_KEY.isNotEmpty() && BuildConfig.FIREBASE_SENDER_ID.isNotEmpty()

    var transport: PushTransport = PushTransport { target, body ->
        AppServices.runtime.fetch.perform("POST", target.url, mapOf("Content-Type" to "application/json"), body, 5000) { PushRegistration.allowedRedirect(target, it) }.status
    }

    /** Starts Firebase when configured and registers the current token. Safe to call more than once. */
    fun start(context: Context) {
        if (!configured) return
        runCatching {
            if (FirebaseApp.getApps(context).isEmpty()) {
                FirebaseApp.initializeApp(context, FirebaseOptions.Builder()
                    .setProjectId(BuildConfig.FIREBASE_PROJECT_ID).setApplicationId(BuildConfig.FIREBASE_APP_ID)
                    .setApiKey(BuildConfig.FIREBASE_API_KEY).setGcmSenderId(BuildConfig.FIREBASE_SENDER_ID).build())
            }
            FirebaseMessaging.getInstance().token.addOnSuccessListener { token -> executor.execute { register(context.applicationContext, token) } }
        }.onFailure { Log.w(TAG, "push.start -> unavailable") }
    }

    /**
     * Posts [token] for every package that is placed as a widget and declares
     * an allowed `pushUpdates` target. A package is registered again only when
     * the token or its target changed. Returns how many registrations were sent.
     */
    fun register(context: Context, token: String): Int {
        AppServices.attach(context.applicationContext)
        val preferences = context.getSharedPreferences("push", Context.MODE_PRIVATE)
        val placed = ScriptWidgetProvider.allIds(context).toList().mapNotNull { AppServices.widgets.get(it)?.installation }.toSet()
        var sent = 0
        for (installed in AppServices.library.list()) {
            if (installed.installation !in placed) continue
            val target = PushRegistration.target(installed.manifest) ?: continue
            val body = PushRegistration.body(target, token) ?: continue
            // A digest of what was registered, so the token itself is not stored a second time.
            val fingerprint = java.security.MessageDigest.getInstance("SHA-256").digest(body + target.url.toString().toByteArray()).joinToString("") { "%02x".format(it) }
            if (preferences.getString(installed.installation, null) == fingerprint) continue
            val status = runCatching { transport.post(target, body) }.getOrDefault(0)
            Log.i(TAG, "push.register -> ${if (status in 200..299) "ok" else "failed"}")
            if (status in 200..299) { preferences.edit().putString(installed.installation, fingerprint).apply(); sent += 1 }
        }
        return sent
    }

    /** Called when the set of placed widgets or their packages changes. */
    fun refreshRegistrations(context: Context) {
        if (!configured) return
        runCatching { FirebaseMessaging.getInstance().token.addOnSuccessListener { token -> executor.execute { register(context.applicationContext, token) } } }
    }

    /**
     * Redraws the widgets of the package a push names. The message carries
     * only `packageID` and `channel`; anything else in it is ignored, and a
     * push for a package without a matching declaration does nothing.
     * Returns the widget ids that were scheduled.
     */
    fun handle(context: Context, data: Map<String, String>): IntArray {
        AppServices.attach(context.applicationContext)
        val packageID = data["packageID"]
        val channel = data["channel"]
        val installations = AppServices.library.list().filter { PushRegistration.matches(it.manifest, packageID, channel) }.map { it.installation }.toSet()
        val ids = ScriptWidgetProvider.allIds(context).filter { AppServices.widgets.get(it)?.installation in installations }.toIntArray()
        WidgetScheduler.refresh(context, ids)
        Log.i(TAG, "push.message -> widgets=${ids.size}")
        return ids
    }
}

class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) { Push.register(applicationContext, token) }
    override fun onMessageReceived(message: RemoteMessage) { Push.handle(applicationContext, message.data) }
}
