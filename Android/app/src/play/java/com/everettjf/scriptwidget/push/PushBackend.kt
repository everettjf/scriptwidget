package com.everettjf.scriptwidget.push

import android.content.Context
import com.everettjf.scriptwidget.BuildConfig
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/** Firebase Cloud Messaging, in the `play` flavor only. The `foss` flavor has a stand-in without it. */
object PushBackend {
    const val AVAILABLE = true

    fun start(context: Context) {
        if (FirebaseApp.getApps(context).isNotEmpty()) return
        FirebaseApp.initializeApp(context, FirebaseOptions.Builder()
            .setProjectId(BuildConfig.FIREBASE_PROJECT_ID).setApplicationId(BuildConfig.FIREBASE_APP_ID)
            .setApiKey(BuildConfig.FIREBASE_API_KEY).setGcmSenderId(BuildConfig.FIREBASE_SENDER_ID).build())
    }

    fun token(onToken: (String) -> Unit) {
        FirebaseMessaging.getInstance().token.addOnSuccessListener { onToken(it) }
    }
}

class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) { Push.register(applicationContext, token) }
    override fun onMessageReceived(message: RemoteMessage) { Push.handle(applicationContext, message.data) }
}
