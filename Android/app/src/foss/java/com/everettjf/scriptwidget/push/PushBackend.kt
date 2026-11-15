package com.everettjf.scriptwidget.push

import android.content.Context

/**
 * The `foss` flavor contains no Firebase or other Google library, so it has
 * no push-triggered refresh. `Push.configured` is false and nothing here runs.
 */
object PushBackend {
    const val AVAILABLE = false

    fun start(context: Context) {}

    fun token(onToken: (String) -> Unit) {}
}
