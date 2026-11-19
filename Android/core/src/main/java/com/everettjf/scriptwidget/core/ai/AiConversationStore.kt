package com.everettjf.scriptwidget.core.ai

import org.json.JSONObject
import java.io.File

/** What a list of conversations shows, without the sources. */
class AiConversationSummary(val id: String, val title: String, val packageId: String?, val versionCount: Int, val updatedAt: Long)

/**
 * Conversations as files, one JSON file each, in a directory that belongs to
 * the app. Port of `AIConversationStore`.
 *
 * Files that cannot be read, are too large or are not conversations are
 * ignored, never deleted and never partly used. Only the newest
 * [AiConversationLimits.MAX_CONVERSATIONS] are kept.
 *
 * All methods block; call them off the main thread.
 */
class AiConversationStore(private val directory: File) {

    @Synchronized
    fun save(conversation: AiConversation): Boolean {
        if (!AiConversation.SAFE_ID.matches(conversation.id)) return false
        val bytes = conversation.toJson().toString().toByteArray(Charsets.UTF_8)
        if (bytes.size > AiConversationLimits.MAX_FILE_BYTES) return false
        return runCatching {
            directory.mkdirs()
            val target = file(conversation.id)
            val temporary = File(directory, "${conversation.id}.tmp")
            temporary.writeBytes(bytes)
            if (!temporary.renameTo(target)) { temporary.delete(); return false }
            prune()
            true
        }.getOrDefault(false)
    }

    @Synchronized
    fun load(id: String): AiConversation? {
        if (!AiConversation.SAFE_ID.matches(id)) return null
        return read(file(id))
    }

    @Synchronized
    fun delete(id: String) {
        if (AiConversation.SAFE_ID.matches(id)) file(id).delete()
    }

    /** Newest first. With [draftsOnly], conversations that belong to an installed widget are left out. */
    @Synchronized
    fun summaries(draftsOnly: Boolean = false): List<AiConversationSummary> =
        all().filter { !draftsOnly || it.isDraft }.filter { it.turns.isNotEmpty() }.sortedByDescending { it.updatedAt }
            .map { AiConversationSummary(it.id, it.title, it.packageId, it.versions.size, it.updatedAt) }

    /** The newest conversation of an installed widget. */
    @Synchronized
    fun latest(packageId: String): AiConversation? = all().filter { it.packageId == packageId }.maxByOrNull { it.updatedAt }

    /** A widget was deleted: its conversations go with it. */
    @Synchronized
    fun deleteForPackage(packageId: String) {
        for (conversation in all()) if (conversation.packageId == packageId) file(conversation.id).delete()
    }

    private fun file(id: String) = File(directory, "$id.json")

    private fun files(): List<File> = directory.listFiles { file -> file.isFile && file.name.endsWith(".json") }?.toList() ?: emptyList()

    private fun all(): List<AiConversation> = files().mapNotNull { read(it) }

    private fun read(file: File): AiConversation? {
        if (!file.isFile || file.length() > AiConversationLimits.MAX_FILE_BYTES) return null
        val conversation = runCatching { AiConversation.fromJson(JSONObject(file.readText(Charsets.UTF_8))) }.getOrNull() ?: return null
        // The name is the id: a file copied under another name is not trusted.
        return conversation.takeIf { file.name == "${it.id}.json" }
    }

    private fun prune() {
        val known = files().mapNotNull { file -> read(file)?.let { file to it.updatedAt } }
        if (known.size <= AiConversationLimits.MAX_CONVERSATIONS) return
        for ((file, _) in known.sortedByDescending { it.second }.drop(AiConversationLimits.MAX_CONVERSATIONS)) file.delete()
    }
}
