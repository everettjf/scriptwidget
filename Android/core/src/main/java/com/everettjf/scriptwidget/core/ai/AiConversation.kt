package com.everettjf.scriptwidget.core.ai

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Bounds of a conversation. Port of `AIConversationLimits`. */
object AiConversationLimits {
    /** One generation and up to three repairs. */
    const val MAX_ATTEMPTS_PER_TURN = 4
    const val MAX_VERSIONS = 30
    const val MAX_CONVERSATIONS = 50
    const val MAX_REQUEST_CHARACTERS = 4_000
    const val MAX_FILE_BYTES = 12 * 1024 * 1024
    /** History sent to the model: the newest turns, shortened. */
    const val HISTORY_TURNS = 12
    const val HISTORY_REQUEST_CHARACTERS = 500
    const val HISTORY_NOTE_CHARACTERS = 200
    /** The version before the current one is sent for reference when it is small. */
    const val PREVIOUS_SOURCE_CHARACTERS = 8_000
    const val TITLE_CHARACTERS = 40
    const val NOTE_CHARACTERS = 300
    const val ERROR_CHARACTERS = 600
}

/** One version of the widget's source a turn produced. Port of `AIConversationVersion`. */
class AiConversationVersion(
    val id: String,
    /** 1-based, in the order the versions were made; never reused. */
    val number: Int,
    val source: String,
    val parentId: String?,
    val createdAt: Long,
    /** Hosts the widget declared it contacts; empty for a widget that stays offline. */
    val networkDomains: List<String>,
) {
    /** The canonical declaration JSON of this version, or null when it declares no network use. */
    val declarationJson: String? get() = if (networkDomains.isEmpty()) null else AiManifestDeclaration(listOf("network"), networkDomains).toJson()
}

/** What became of one request. Port of `AIConversationTurn`. */
class AiConversationTurn(
    val id: String,
    /** The user's own words; empty for a manual edit. */
    val request: String,
    /** The version the turn started from; null for the first turn of a new widget. */
    val baseVersionId: String?,
    var status: Status,
    /** The model's one-sentence account of what it did. */
    var note: String? = null,
    /** Why the turn did not succeed; safe to show. */
    var errorSummary: String? = null,
    /** How many attempts failed to run before the turn ended. */
    var repairs: Int = 0,
    /** The version a successful turn produced. */
    var versionId: String? = null,
    /** The last attempt of a turn that never ran, for the user to look at. */
    var failedSource: String? = null,
    var usage: AiTokenUsage = AiTokenUsage.ZERO,
    val createdAt: Long,
    /** The user went back to an older version and continued from there. */
    var isAbandoned: Boolean = false,
    /** Not a request: the widget's code was changed outside the conversation. */
    val isManualEdit: Boolean = false,
) {
    enum class Status(val id: String) {
        /** Waiting for the model or running the result. Never read back from disk as such. */
        RUNNING("running"),
        SUCCEEDED("succeeded"),
        /** Every attempt failed to run; the widget was left as it was. */
        UNCONVERGED("unconverged"),
        /** The provider could not be reached or refused the request. */
        FAILED("failed"),
        CANCELLED("cancelled"),
        /** The app closed while the turn was running. */
        INTERRUPTED("interrupted");

        companion object { fun fromId(id: String?): Status? = entries.firstOrNull { it.id == id } }
    }
}

/**
 * A multi-turn AI conversation about one widget: what the user asked in each
 * turn, what came of it, and every version of the source a successful turn
 * produced. Port of `AIConversation`.
 *
 * A conversation never holds a credential and names no provider: the profile
 * that is active when a turn is sent is used.
 *
 * Not thread-safe: change it from one thread.
 */
class AiConversation(
    val id: String = UUID.randomUUID().toString(),
    var title: String = "",
    var size: AiWidgetSize = AiWidgetSize.MEDIUM,
    val turns: MutableList<AiConversationTurn> = ArrayList(),
    val versions: MutableList<AiConversationVersion> = ArrayList(),
    var currentVersionId: String? = null,
    /** Counts versions ever made, so a number is not reused after pruning. */
    var versionCounter: Int = 0,
    /** The installation id of the widget the conversation belongs to, which survives a rename; null while it is a draft. */
    var packageId: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
    var updatedAt: Long = createdAt,
) {
    val isDraft: Boolean get() = packageId == null
    val currentVersion: AiConversationVersion? get() = version(currentVersionId)
    val latestVersion: AiConversationVersion? get() = versions.maxByOrNull { it.number }
    val totalUsage: AiTokenUsage get() = turns.fold(AiTokenUsage.ZERO) { sum, turn -> sum + turn.usage }
    val isRunning: Boolean get() = turns.any { it.status == AiConversationTurn.Status.RUNNING }

    fun version(id: String?): AiConversationVersion? = id?.let { wanted -> versions.firstOrNull { it.id == wanted } }

    fun turn(id: String): AiConversationTurn? = turns.firstOrNull { it.id == id }

    /**
     * Starts a turn from the current version. Turns made after that version
     * are marked abandoned: the conversation continues from where the user is.
     */
    fun beginTurn(request: String, now: Long = System.currentTimeMillis()): AiConversationTurn {
        abandonTurnsOffCurrentPath()
        val turn = AiConversationTurn(
            id = UUID.randomUUID().toString(),
            request = request.take(AiConversationLimits.MAX_REQUEST_CHARACTERS),
            baseVersionId = currentVersionId,
            status = AiConversationTurn.Status.RUNNING,
            createdAt = now,
        )
        turns += turn
        if (title.isEmpty()) title = titleFrom(request)
        updatedAt = now
        return turn
    }

    /** Records a version and makes it the current one. */
    fun addVersion(source: String, networkDomains: List<String> = emptyList(), now: Long = System.currentTimeMillis()): AiConversationVersion {
        versionCounter += 1
        val version = AiConversationVersion(UUID.randomUUID().toString(), versionCounter, source, currentVersionId, now, networkDomains.toList())
        versions += version
        currentVersionId = version.id
        pruneVersions()
        updatedAt = now
        return version
    }

    /** Shows another version. Returns false when it does not exist. */
    fun selectVersion(id: String, now: Long = System.currentTimeMillis()): Boolean {
        if (version(id) == null) return false
        currentVersionId = id
        updatedAt = now
        return true
    }

    /** The turns the model is told about: finished, not abandoned, not manual edits, oldest first. */
    fun historyForPrompt(): List<AiConversationTurn> =
        turns.filter { it.status == AiConversationTurn.Status.SUCCEEDED && !it.isAbandoned && !it.isManualEdit }.takeLast(AiConversationLimits.HISTORY_TURNS)

    /**
     * Takes over code that did not come from the AI: what the installed widget
     * holds when it differs from every version the conversation knows as current.
     * Returns whether a version was added.
     */
    fun adoptExternalSource(source: String, networkDomains: List<String> = emptyList(), now: Long = System.currentTimeMillis()): Boolean {
        if (currentVersion?.source == source) return false
        abandonTurnsOffCurrentPath()
        val base = currentVersionId
        val version = addVersion(source, networkDomains, now)
        turns += AiConversationTurn(
            id = UUID.randomUUID().toString(), request = "", baseVersionId = base, status = AiConversationTurn.Status.SUCCEEDED,
            versionId = version.id, createdAt = now, isManualEdit = true,
        )
        return true
    }

    /** A turn left running by a closed app can never finish. */
    fun markRunningTurnsInterrupted() {
        for (turn in turns) if (turn.status == AiConversationTurn.Status.RUNNING) turn.status = AiConversationTurn.Status.INTERRUPTED
    }

    private fun abandonTurnsOffCurrentPath() {
        val current = currentVersionId ?: return
        if (version(current) == null) return
        for (turn in turns) {
            // A turn whose version was pruned keeps the state it had.
            val produced = version(turn.versionId) ?: continue
            turn.isAbandoned = !(produced.id == current || isAncestor(produced.id, current))
        }
    }

    private fun isAncestor(candidate: String, versionId: String): Boolean {
        var cursor = version(versionId)?.parentId
        var steps = 0
        while (cursor != null && steps <= versions.size) {
            if (cursor == candidate) return true
            cursor = version(cursor)?.parentId
            steps += 1
        }
        return false
    }

    /** Keeps the newest versions and always the current one. */
    private fun pruneVersions() {
        val excess = versions.size - AiConversationLimits.MAX_VERSIONS
        if (excess <= 0) return
        val removed = versions.filter { it.id != currentVersionId }.sortedBy { it.number }.take(excess).map { it.id }.toSet()
        versions.removeAll { it.id in removed }
    }

    fun toJson(): JSONObject {
        val root = JSONObject()
        root.put("formatVersion", FORMAT_VERSION)
        root.put("id", id)
        root.put("title", title)
        root.put("size", size.family)
        root.put("currentVersionId", currentVersionId ?: JSONObject.NULL)
        root.put("versionCounter", versionCounter)
        root.put("packageId", packageId ?: JSONObject.NULL)
        root.put("createdAt", createdAt)
        root.put("updatedAt", updatedAt)
        root.put("versions", JSONArray().also { array ->
            for (version in versions) array.put(JSONObject()
                .put("id", version.id).put("number", version.number).put("source", version.source)
                .put("parentId", version.parentId ?: JSONObject.NULL).put("createdAt", version.createdAt)
                .put("networkDomains", JSONArray(version.networkDomains)))
        })
        root.put("turns", JSONArray().also { array ->
            for (turn in turns) array.put(JSONObject()
                .put("id", turn.id).put("request", turn.request).put("baseVersionId", turn.baseVersionId ?: JSONObject.NULL)
                .put("status", turn.status.id).put("note", turn.note ?: JSONObject.NULL).put("errorSummary", turn.errorSummary ?: JSONObject.NULL)
                .put("repairs", turn.repairs).put("versionId", turn.versionId ?: JSONObject.NULL).put("failedSource", turn.failedSource ?: JSONObject.NULL)
                .put("promptTokens", turn.usage.promptTokens).put("completionTokens", turn.usage.completionTokens).put("totalTokens", turn.usage.totalTokens)
                .put("createdAt", turn.createdAt).put("isAbandoned", turn.isAbandoned).put("isManualEdit", turn.isManualEdit))
        })
        return root
    }

    companion object {
        const val FORMAT_VERSION = 1

        fun titleFrom(request: String): String {
            val line = request.lineSequence().firstOrNull { it.isNotBlank() }?.trim().orEmpty()
            return if (line.length > AiConversationLimits.TITLE_CHARACTERS) line.take(AiConversationLimits.TITLE_CHARACTERS) + "…" else line
        }

        /**
         * Reads a saved conversation, failing closed: an unknown format version or a
         * malformed field gives null, never a partly read conversation.
         */
        fun fromJson(root: JSONObject): AiConversation? = runCatching {
            if (root.getInt("formatVersion") != FORMAT_VERSION) return null
            val versions = ArrayList<AiConversationVersion>()
            val versionArray = root.getJSONArray("versions")
            for (index in 0 until versionArray.length()) {
                val item = versionArray.getJSONObject(index)
                val domains = item.optJSONArray("networkDomains")?.let { array -> List(array.length()) { array.getString(it) } } ?: emptyList()
                versions += AiConversationVersion(item.getString("id"), item.getInt("number"), item.getString("source"), text(item, "parentId"), item.getLong("createdAt"), domains)
            }
            val turns = ArrayList<AiConversationTurn>()
            val turnArray = root.getJSONArray("turns")
            for (index in 0 until turnArray.length()) {
                val item = turnArray.getJSONObject(index)
                turns += AiConversationTurn(
                    id = item.getString("id"), request = item.getString("request"), baseVersionId = text(item, "baseVersionId"),
                    status = AiConversationTurn.Status.fromId(item.getString("status")) ?: return null,
                    note = text(item, "note"), errorSummary = text(item, "errorSummary"), repairs = item.optInt("repairs"),
                    versionId = text(item, "versionId"), failedSource = text(item, "failedSource"),
                    usage = AiTokenUsage(item.optInt("promptTokens"), item.optInt("completionTokens"), item.optInt("totalTokens")),
                    createdAt = item.getLong("createdAt"), isAbandoned = item.optBoolean("isAbandoned"), isManualEdit = item.optBoolean("isManualEdit"),
                )
            }
            val id = root.getString("id")
            if (!SAFE_ID.matches(id)) return null
            AiConversation(
                id = id, title = root.optString("title"), size = AiWidgetSize.fromFamily(root.optString("size")),
                turns = turns, versions = versions, currentVersionId = text(root, "currentVersionId"),
                versionCounter = root.getInt("versionCounter"), packageId = text(root, "packageId"),
                createdAt = root.getLong("createdAt"), updatedAt = root.getLong("updatedAt"),
            ).also { it.markRunningTurnsInterrupted() }
        }.getOrNull()

        /** Conversation ids become file names. */
        val SAFE_ID = Regex("^[A-Za-z0-9-]{8,64}$")

        private fun text(item: JSONObject, key: String): String? = if (item.isNull(key)) null else item.getString(key)
    }
}
