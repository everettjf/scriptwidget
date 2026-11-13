package com.everettjf.scriptwidget.core.system

import android.service.notification.NotificationListenerService

/**
 * The component the user enables under "Notification access" so `$music` may read the active
 * media session. Android ties `MediaSessionManager.getActiveSessions` to an enabled notification
 * listener; this one deliberately does nothing with notifications: it overrides no callback,
 * reads none and stores none.
 */
class MediaSessionAccessService : NotificationListenerService()
