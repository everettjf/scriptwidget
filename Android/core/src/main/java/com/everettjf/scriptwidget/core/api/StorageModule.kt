package com.everettjf.scriptwidget.core.api

import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Package-scoped key-value storage behind `$storage`. Each package has its
 * own file; a package can never name or reach another package's keys. Values
 * are bounded and writes are atomic. Compare-and-set runs under the same
 * lock as plain writes, so app and widget updates do not lose records.
 */
class StorageModule(private val directory: File) : NativeModule {
    override fun handles(operation: String): Boolean = operation.startsWith("storage.")

    override fun call(request: ExecutionRequest, operation: String, payload: String?): String? {
        val arguments = if (payload == null) JSONObject() else JSONObject(payload)
        val key = arguments.optString("key")
        val writes = operation in setOf("storage.set", "storage.cas", "storage.remove", "storage.clear")
        if (writes && RuntimePolicy.isTimelineProjection(request)) return "false"
        val file = fileFor(request.packageID)
        synchronized(lockFor(file.path)) {
            return when (operation) {
                "storage.get" -> if (!validKey(key)) "null" else read(file).optJSONObject(key)?.toString() ?: "null"
                "storage.keys" -> JSONArray(read(file).keys().asSequence().sorted().toList()).toString()
                "storage.set" -> {
                    val value = arguments.optString("v")
                    val type = arguments.optString("t")
                    if (!validKey(key) || !validValue(type, value)) return "false"
                    val store = read(file)
                    if (!store.has(key) && store.length() >= MAXIMUM_KEYS) return "false"
                    store.put(key, JSONObject().put("t", type).put("v", value))
                    write(file, store).toString()
                }
                "storage.cas" -> {
                    val value = arguments.optString("v")
                    val type = arguments.optString("t")
                    val expected = arguments.optString("expected")
                    if (!validKey(key) || !validValue(type, value) || expected.toByteArray().size > MAXIMUM_VALUE_BYTES) return "false"
                    val store = read(file)
                    val current = store.optJSONObject(key)
                    // A missing key matches an empty string or an empty object.
                    val matches = if (current == null) expected == (if (type == "s") "" else "{}")
                    else current.optString("t") == type && current.optString("v") == expected
                    if (!matches) return "false"
                    if (current == null && store.length() >= MAXIMUM_KEYS) return "false"
                    store.put(key, JSONObject().put("t", type).put("v", value))
                    write(file, store).toString()
                }
                "storage.remove" -> {
                    if (!validKey(key)) return "false"
                    val store = read(file)
                    store.remove(key)
                    write(file, store).toString()
                }
                "storage.clear" -> { if (file.exists()) file.delete(); "true" }
                else -> throw IllegalArgumentException("Unsupported operation $operation")
            }
        }
    }

    /** All stored entries of a package, for the records screen and tests. */
    fun snapshot(packageID: String): JSONObject = synchronized(lockFor(fileFor(packageID).path)) { read(fileFor(packageID)) }

    fun clear(packageID: String) { synchronized(lockFor(fileFor(packageID).path)) { fileFor(packageID).delete() } }

    private fun validKey(key: String): Boolean = key.isNotEmpty() && key.toByteArray().size <= 256

    private fun validValue(type: String, value: String): Boolean {
        if (type != "s" && type != "j") return false
        if (value.toByteArray().size > MAXIMUM_VALUE_BYTES) return false
        return type == "s" || runCatching { JSONObject(value) }.isSuccess
    }

    private fun fileFor(packageID: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(packageID.toByteArray()).joinToString("") { "%02x".format(it) }
        return File(directory, "$digest.json")
    }

    private fun read(file: File): JSONObject = if (!file.isFile) JSONObject() else runCatching { JSONObject(file.readText()) }.getOrElse { JSONObject() }

    private fun write(file: File, store: JSONObject): Boolean {
        val text = store.toString()
        if (text.toByteArray().size > MAXIMUM_TOTAL_BYTES) return false
        directory.mkdirs()
        val temporary = File(directory, file.name + ".tmp")
        return runCatching {
            temporary.writeText(text)
            if (!temporary.renameTo(file)) { temporary.delete(); false } else true
        }.getOrDefault(false)
    }

    companion object {
        const val MAXIMUM_VALUE_BYTES = 256 * 1024
        const val MAXIMUM_KEYS = 1024
        const val MAXIMUM_TOTAL_BYTES = 8 * 1024 * 1024
        private val locks = ConcurrentHashMap<String, Any>()
        private fun lockFor(path: String): Any = locks.getOrPut(path) { Any() }
    }
}
