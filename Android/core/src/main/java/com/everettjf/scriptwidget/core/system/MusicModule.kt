package com.everettjf.scriptwidget.core.system

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONObject
import java.util.Collections
import java.util.WeakHashMap

/** The `$music` rejections, with the Apple runtime's codes. */
enum class MusicError(val message: String) {
    PERMISSION("[music_permission] Install this widget, declare music and allow Music access in ScriptWidget Settings."),
    UNAVAILABLE("[music_unavailable] Current Music app playback is unavailable on this platform."),
    SNAPSHOT("[music_snapshot] Playback information could not be read."),
    READ_ONLY("[timeline_read_only] Prepare Music display data in the current entry"),
    QUERY_LIMIT("[query_limit] Too many system data queries");

    fun reject(): SystemReject = SystemReject(message)
}

/**
 * What the system reports for one media session, before any bounding. [state] is a
 * `PlaybackState.STATE_*` value; times are milliseconds; [hasMetadata] is false when the session
 * publishes no metadata at all.
 */
class MediaSessionReading(val state: Int, val hasMetadata: Boolean, val title: String?, val artist: String?, val album: String?, val durationMilliseconds: Long?, val positionMilliseconds: Long?)

/** One playback snapshot with exactly the documented fields. */
class MusicSnapshot(val state: String, val hasItem: Boolean, val title: String?, val artist: String?, val album: String?, val duration: Double?, val position: Double?, val capturedAt: Long) {
    fun toJson(): JSONObject = JSONObject().put("provider", MusicRules.PROVIDER).put("state", state).put("hasItem", hasItem)
        .put("title", title ?: JSONObject.NULL).put("artist", artist ?: JSONObject.NULL).put("album", album ?: JSONObject.NULL)
        .put("duration", duration ?: JSONObject.NULL).put("position", position ?: JSONObject.NULL)
        .put("capturedAt", IsoDates.format(capturedAt))
}

/** Pure rules of `$music`. */
object MusicRules {
    /**
     * The `provider` value on Android: the snapshot comes from the device's active media
     * session, which can belong to any media app. It is never `appleMusic`.
     */
    const val PROVIDER = "androidMediaSession"
    val STATES = setOf("playing", "paused", "stopped", "interrupted", "seeking", "unknown")
    const val MAXIMUM_SECONDS = 604_800.0
    const val MAXIMUM_TEXT_CHARACTERS = 256
    const val MAXIMUM_TEXT_BYTES = 512

    /**
     * `PlaybackState` to the documented states. Buffering, connecting, errors and unknown values
     * are `unknown`; Android has no interruption state, so `interrupted` is never produced.
     */
    fun state(playbackState: Int): String = when (playbackState) {
        PlaybackState.STATE_PLAYING -> "playing"
        PlaybackState.STATE_PAUSED -> "paused"
        PlaybackState.STATE_STOPPED, PlaybackState.STATE_NONE -> "stopped"
        PlaybackState.STATE_FAST_FORWARDING, PlaybackState.STATE_REWINDING, PlaybackState.STATE_SKIPPING_TO_NEXT,
        PlaybackState.STATE_SKIPPING_TO_PREVIOUS, PlaybackState.STATE_SKIPPING_TO_QUEUE_ITEM -> "seeking"
        else -> "unknown"
    }

    /** Text without control or format characters, at most 256 characters and 512 UTF-8 bytes; null when nothing is left. */
    fun text(raw: String?): String? {
        var value = raw?.filterNot { Character.isISOControl(it) || Character.getType(it) == Character.FORMAT.toInt() }?.trim() ?: return null
        value = value.substring(0, value.offsetByCodePoints(0, minOf(MAXIMUM_TEXT_CHARACTERS, value.codePointCount(0, value.length))))
        while (value.toByteArray().size > MAXIMUM_TEXT_BYTES) value = value.substring(0, value.offsetByCodePoints(value.length, -1))
        return value.ifEmpty { null }
    }

    /**
     * The snapshot for [reading], or for no active session when it is null (`stopped`, no item).
     * - `hasItem` is whether the session publishes metadata; without it title, artist, album and duration are null.
     * - `duration` is positive and at most 604800 seconds, else null; `position` is 0…604800, else null.
     */
    fun snapshot(reading: MediaSessionReading?, nowMilliseconds: Long): MusicSnapshot {
        if (reading == null) return MusicSnapshot("stopped", false, null, null, null, null, null, nowMilliseconds)
        val duration = reading.durationMilliseconds?.let { it / 1000.0 }?.takeIf { it > 0 && it <= MAXIMUM_SECONDS }
        val position = reading.positionMilliseconds?.let { it / 1000.0 }?.takeIf { it >= 0 && it <= MAXIMUM_SECONDS }
        val item = reading.hasMetadata
        return MusicSnapshot(state(reading.state), item, if (item) text(reading.title) else null, if (item) text(reading.artist) else null,
            if (item) text(reading.album) else null, if (item) duration else null, position, nowMilliseconds)
    }

    /** The invariants every delivered snapshot satisfies; a violation is `music_snapshot`. */
    fun valid(snapshot: MusicSnapshot): Boolean {
        fun ok(value: String?) = value == null || (value.toByteArray().size <= MAXIMUM_TEXT_BYTES && !SystemOptions.hasControlCharacters(value))
        return snapshot.state in STATES && ok(snapshot.title) && ok(snapshot.artist) && ok(snapshot.album) &&
            (snapshot.hasItem || (snapshot.title == null && snapshot.artist == null && snapshot.album == null && snapshot.duration == null)) &&
            (snapshot.duration == null || (snapshot.duration.isFinite() && snapshot.duration > 0 && snapshot.duration <= MAXIMUM_SECONDS)) &&
            (snapshot.position == null || (snapshot.position.isFinite() && snapshot.position >= 0 && snapshot.position <= MAXIMUM_SECONDS))
    }
}

/** The system side of `$music`. */
interface MusicPlatform {
    /** The device can report media sessions at all. */
    fun isAvailable(): Boolean
    /** The user enabled notification access for this app, which Android requires for reading other apps' media sessions. */
    fun accessEnabled(): Boolean
    /** The most relevant active session, or null when nothing is active. Throws when access is missing. */
    fun read(): MediaSessionReading?
}

/**
 * `$music`: `isAvailable()`, `authorizationStatus()` and `current()`, read-only.
 *
 * On Android the snapshot is the device's active media session, whichever app owns it. Reading
 * it needs notification access, which only the user can enable in system settings; that is the
 * Android authorization. Nothing is persisted or logged, and no playback is started or changed.
 *
 * `current()` checks, in the Apple runtime's order: an installed package that declares `music`
 * (`music_permission`); not a future timeline entry or Live Activity (`timeline_read_only`); the
 * eight-query budget (`query_limit`); platform availability (`music_unavailable`); authorization
 * (`music_permission`). One snapshot is shared by all calls of an execution, and permission and
 * authorization are checked again before delivery.
 */
class MusicModule(
    private val platform: MusicPlatform,
    private val prompts: PermissionPrompts,
    private val clock: SystemClock = SystemClock { System.currentTimeMillis() },
) : NativeModule {
    override val apis: Set<String> = setOf("\$music")

    /** One snapshot (or failure) per execution, dropped with the execution. Never written to disk. */
    private val snapshots: MutableMap<Any, Result<MusicSnapshot>> = Collections.synchronizedMap(WeakHashMap())

    override fun handles(operation: String): Boolean = operation.startsWith("music.")

    override fun call(request: ExecutionRequest, operation: String, payload: String?): String? {
        val context = CallContext.from(request)
        val value = when (operation) {
            "music.isAvailable" -> isAvailable(context).toString()
            "music.authorizationStatus" -> JSONObject.quote(authorizationStatus(context))
            else -> throw IllegalArgumentException("Unsupported operation $operation")
        }
        SystemLog.call(operation, "ok")
        return value
    }

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        when (operation) {
            "music.current" -> runSystemCall(operation, done) { current(context, request.session).toString() }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    /** An installed Package 2.0 widget that declares `music`. */
    fun permitted(context: CallContext): Boolean = context.isInstalled && context.declares(PERMISSION)

    /** Package access and a platform that can report sessions. It does not mean access is authorized. */
    fun isAvailable(context: CallContext): Boolean = permitted(context) && platform.isAvailable()

    /**
     * `undeclared` without package access; `unavailable` without a platform adapter; `authorized`
     * when notification access is enabled; otherwise `denied` once the app has sent the user to
     * the system setting, `notDetermined` before that. `restricted` is never produced on Android.
     */
    fun authorizationStatus(context: CallContext): String = if (permitted(context)) systemStatus() else "undeclared"

    /** The device-level state shown in the app, without a package check. */
    fun systemStatus(): String = when {
        !platform.isAvailable() -> "unavailable"
        platform.accessEnabled() -> "authorized"
        prompts.asked(PROMPT) -> "denied"
        else -> "notDetermined"
    }

    /** The snapshot for this execution. [execution] identifies the execution whose calls share one read. */
    fun current(context: CallContext, execution: Any): JSONObject {
        if (!permitted(context)) throw MusicError.PERMISSION.reject()
        if (context.isTimelineProjection || context.isLiveActivity) throw MusicError.READ_ONLY.reject()
        if (!context.consumeDataQuery()) throw MusicError.QUERY_LIMIT.reject()
        if (!platform.isAvailable()) throw MusicError.UNAVAILABLE.reject()
        if (!platform.accessEnabled()) throw MusicError.PERMISSION.reject()
        val result = synchronized(snapshots) {
            snapshots.getOrPut(execution) {
                runCatching { MusicRules.snapshot(platform.read(), clock.now()).also { if (!MusicRules.valid(it)) throw MusicError.SNAPSHOT.reject() } }
            }
        }
        if (!permitted(context) || !platform.accessEnabled()) throw MusicError.PERMISSION.reject()
        val snapshot = result.getOrElse { error -> throw if (error is SecurityException) MusicError.PERMISSION.reject() else MusicError.SNAPSHOT.reject() }
        return snapshot.toJson()
    }

    companion object {
        const val PERMISSION = "music"
        const val PROMPT = "music"
    }
}

/**
 * Reads the active media sessions through `MediaSessionManager`. [listener] is the app's
 * `NotificationListenerService`; the user enables it in system settings, and without that the
 * system refuses the read. Only playback state and the current item's text are read: no artwork,
 * queue, package name or transport control.
 */
class AndroidMusicPlatform(context: Context, listener: Class<*>) : MusicPlatform {
    private val appContext = context.applicationContext
    private val component = ComponentName(appContext, listener)

    override fun isAvailable(): Boolean = appContext.getSystemService(MediaSessionManager::class.java) != null

    override fun accessEnabled(): Boolean = appContext.getSystemService(NotificationManager::class.java)?.isNotificationListenerAccessGranted(component) == true

    override fun read(): MediaSessionReading? {
        val manager = appContext.getSystemService(MediaSessionManager::class.java) ?: throw IllegalStateException("media sessions unavailable")
        val sessions = manager.getActiveSessions(component)
        // The system lists sessions by priority; prefer one that is playing right now.
        val controller = sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: sessions.firstOrNull() ?: return null
        return reading(controller)
    }

    private fun reading(controller: MediaController): MediaSessionReading {
        val playback = controller.playbackState
        val metadata = controller.metadata
        val state = playback?.state ?: PlaybackState.STATE_NONE
        var position = playback?.position?.takeIf { it != PlaybackState.PLAYBACK_POSITION_UNKNOWN }
        if (position != null && playback != null && state == PlaybackState.STATE_PLAYING && playback.lastPositionUpdateTime > 0) {
            // The session reports the position at its last update; advance it to now.
            position += ((android.os.SystemClock.elapsedRealtime() - playback.lastPositionUpdateTime) * playback.playbackSpeed).toLong()
        }
        val duration = metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION)?.takeIf { it > 0 }
        if (position != null && duration != null && position > duration) position = duration
        return MediaSessionReading(state, metadata != null,
            metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: metadata?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE),
            metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST),
            metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM), duration, position)
    }
}
