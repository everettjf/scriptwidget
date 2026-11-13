package com.everettjf.scriptwidget.core.system

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.everettjf.scriptwidget.core.api.FetchModule
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Script-visible connected-service errors, with the Apple runtime's codes and wording. */
enum class ServiceError(val message: String) {
    EXPIRED("[service_expired] Start a new service authorization."),
    CREDENTIAL("[service_credential] The service credential is invalid. Reconnect in the app."),
    LOCKED("[service_locked] Unlock this device to use the connected service."),
    STORAGE("[service_storage] Secure credential storage is unavailable."),
    CONFLICT("[service_conflict] Service settings changed. Reload before saving."),
    NOT_CONNECTED("[service_not_connected] Connect a service in the app."),
    PERMISSION("[service_permission] Allow this service operation in the app."),
    OPERATION("[service_operation] This service operation is unsupported."),
    NETWORK_LIMIT("[network_limit] Too many concurrent or total network requests."),
    RATE_LIMIT("[service_rate_limit] The service is rate limited. Try again later."),
    UNAVAILABLE("[service_unavailable] The service is currently unavailable.");

    fun reject(): SystemReject = SystemReject(message)
}

/**
 * The connected GitHub account. [token] exists only inside the encrypted
 * vault and the request broker; [toString] is redacted so it cannot reach a log.
 */
class ServiceConnection(val connectionID: String, val subject: String, val username: String, val token: String, val grants: Set<String>, val connectedAt: Long) {
    override fun toString(): String = "<private service connection>"

    fun encode(): String = JSONObject().put("formatVersion", 1).put("connectionID", connectionID).put("subject", subject).put("username", username)
        .put("token", token).put("grants", JSONArray(grants.sorted())).put("connectedAt", connectedAt).toString()

    fun withGrants(next: Set<String>): ServiceConnection = ServiceConnection(connectionID, subject, username, token, next, connectedAt)

    companion object {
        /** A fine-grained personal access token: `github_pat_` followed by letters, digits and underscores, at most 255 bytes. */
        private val tokenPattern = Regex("^github_pat_[A-Za-z0-9_]{20,244}$")
        const val MAXIMUM_GRANTS = 256

        fun validToken(token: String): Boolean = tokenPattern.matches(token)

        /** @throws SystemReject `service_storage` when the stored record is not exactly the expected shape. */
        fun decode(text: String): ServiceConnection = try {
            val root = JSONObject(text)
            val array = root.getJSONArray("grants")
            val grants = List(array.length()) { array.get(it) as? String ?: throw ServiceError.STORAGE.reject() }
            val connection = ServiceConnection(root.getString("connectionID"), root.getString("subject"), root.getString("username"), root.getString("token"), grants.toSet(), root.getLong("connectedAt"))
            if (root.get("formatVersion") != 1 || !CallContext.isOwner(connection.connectionID) || !Regex("^[1-9][0-9]{0,15}$").matches(connection.subject) ||
                !GitHubProfile.validUsername(connection.username) || !validToken(connection.token) || grants.size > MAXIMUM_GRANTS ||
                grants.toSet().size != grants.size || !grants.all { CallContext.isOwner(it) }) throw ServiceError.STORAGE.reject()
            connection
        } catch (error: org.json.JSONException) { throw ServiceError.STORAGE.reject() }
    }
}

/** Encrypted storage for the single connection record. Implementations throw [SystemReject] (`service_storage`/`service_locked`) on failure. */
interface ServiceVault {
    /** The decrypted record, or null when no account is connected. */
    fun read(): String?
    /** Stores [text] encrypted; null removes the record. */
    fun write(text: String?)
}

/** A response from the fixed profile request. Printing it never reveals its body. */
class ServiceHttpResponse(val status: Int, val contentType: String?, val rateLimited: Boolean, val body: ByteArray) {
    override fun toString(): String = "<private native service response>"
}

/** Sends the fixed authenticated GET. Any thrown exception is treated as `service_unavailable`. */
fun interface ServiceTransport { fun get(url: String, headers: Map<String, String>): ServiceHttpResponse }

/** The fixed GitHub profile request and the small typed projection of its response. */
object GitHubProfile {
    const val HOST = "api.github.com"
    const val URL = "https://api.github.com/user"
    const val MAXIMUM_RESPONSE_BYTES = 128 * 1024
    private const val MAXIMUM_SAFE_INTEGER = 9_007_199_254_740_991.0
    private val username = Regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,38}$")

    fun validUsername(value: String): Boolean = username.matches(value)

    /** The only headers ever sent. Scripts cannot add, remove or read them. */
    fun headers(token: String): Map<String, String> = linkedMapOf(
        "Authorization" to "Bearer $token", "User-Agent" to "ScriptWidget",
        "Accept" to "application/vnd.github+json", "X-GitHub-Api-Version" to "2026-03-10",
    )

    /**
     * HTTP status rules: 401 is `service_expired`; 429, or 403 with a rate-limit signal, is
     * `service_rate_limit`; other 403 is `service_permission`; anything but 200 with
     * `application/json` and at most 128 KiB is `service_unavailable`.
     */
    fun validateHTTP(response: ServiceHttpResponse) {
        if (response.body.size > MAXIMUM_RESPONSE_BYTES) throw ServiceError.UNAVAILABLE.reject()
        if (response.status == 401) throw ServiceError.EXPIRED.reject()
        if (response.status == 429 || (response.status == 403 && response.rateLimited)) throw ServiceError.RATE_LIMIT.reject()
        if (response.status == 403) throw ServiceError.PERMISSION.reject()
        if (response.status != 200) throw ServiceError.UNAVAILABLE.reject()
        if (response.contentType?.substringBefore(';')?.trim()?.lowercase() != "application/json") throw ServiceError.UNAVAILABLE.reject()
    }

    /**
     * Maps the provider response to exactly `service, subject, username, displayName,
     * publicRepositories, privateRepositories, followers, following`. Missing optional values are
     * null, never zero. Email, location and every other provider field are dropped. A text field
     * that contains the token rejects the whole response.
     */
    fun decode(response: ServiceHttpResponse, token: String): JSONObject {
        validateHTTP(response)
        val unavailable = { ServiceError.UNAVAILABLE.reject() }
        val root = runCatching { JSONObject(String(response.body, Charsets.UTF_8)) }.getOrNull() ?: throw unavailable()
        fun integer(key: String, required: Boolean): Long? {
            if (!root.has(key) || root.isNull(key)) { if (required) throw unavailable(); return null }
            val value = (root.get(key) as? Number)?.toDouble() ?: throw unavailable()
            if (!value.isFinite() || value < 0 || value > MAXIMUM_SAFE_INTEGER || Math.rint(value) != value) throw unavailable()
            return value.toLong()
        }
        fun text(key: String, required: Boolean, maximum: Int): String? {
            if (!root.has(key) || root.isNull(key)) { if (required) throw unavailable(); return null }
            val value = root.get(key) as? String ?: throw unavailable()
            if (value.toByteArray().size > maximum || SystemOptions.hasControlCharacters(value) || (token.isNotEmpty() && value.contains(token)) || (required && value.isEmpty())) throw unavailable()
            return value
        }
        val id = integer("id", true) ?: throw unavailable()
        val login = text("login", true, 39) ?: throw unavailable()
        if (id <= 0 || !validUsername(login)) throw unavailable()
        fun nullable(value: Any?): Any = value ?: JSONObject.NULL
        return JSONObject().put("service", "github").put("subject", id.toString()).put("username", login)
            .put("displayName", nullable(text("name", false, 256))).put("publicRepositories", integer("public_repos", true))
            .put("privateRepositories", nullable(integer("total_private_repos", false)))
            .put("followers", nullable(integer("followers", false))).put("following", nullable(integer("following", false)))
    }
}

/**
 * Account connection and per-widget grants, used by the app's settings and
 * by [ServicesModule]. The token is verified against GitHub before it is
 * stored and is never returned by any method here.
 */
class ServiceConnections(private val vault: ServiceVault, private val transport: ServiceTransport, private val clock: SystemClock = SystemClock { System.currentTimeMillis() }) {
    private val lock = Any()

    /** What the app may show about the account. */
    class Summary(val username: String, val grants: Set<String>, val connectedAt: Long)

    internal fun connection(): ServiceConnection? = synchronized(lock) { vault.read()?.let { ServiceConnection.decode(it) } }

    /** Account name and grants for the settings UI, or null when not connected. @throws SystemReject when the vault is unreadable. */
    fun summary(): Summary? = connection()?.let { Summary(it.username, it.grants, it.connectedAt) }

    /**
     * Verifies [token] with the fixed profile request and stores a new connection. A new
     * connection has a new identity and no widget grants: reconnecting never inherits access.
     * @return the GitHub login. @throws SystemReject with a `service_*` code.
     */
    fun connect(token: String): String {
        val trimmed = token.trim()
        if (!ServiceConnection.validToken(trimmed)) throw ServiceError.CREDENTIAL.reject()
        val profile = fetch(trimmed)
        val connection = ServiceConnection(UUID.randomUUID().toString(), profile.getString("subject"), profile.getString("username"), trimmed, emptySet(), clock.now())
        synchronized(lock) { vault.write(connection.encode()) }
        SystemLog.call("services.connect", "ok")
        return connection.username
    }

    /** Removes the token and every grant. */
    fun disconnect() {
        synchronized(lock) { vault.write(null) }
        SystemLog.call("services.disconnect", "ok")
    }

    /** Grants or revokes the profile read for one installed widget. False when not connected or the owner is not an installation. */
    fun setGrant(installation: String, granted: Boolean): Boolean = synchronized(lock) {
        val current = vault.read()?.let { ServiceConnection.decode(it) } ?: return@synchronized false
        if (!CallContext.isOwner(installation)) return@synchronized false
        val next = if (granted) current.grants + installation else current.grants - installation
        if (next.size > ServiceConnection.MAXIMUM_GRANTS) return@synchronized false
        vault.write(current.withGrants(next).encode())
        true
    }

    internal fun fetch(token: String): JSONObject {
        val response = try { transport.get(GitHubProfile.URL, GitHubProfile.headers(token)) } catch (error: SystemReject) { throw error } catch (error: Exception) { throw ServiceError.UNAVAILABLE.reject() }
        return GitHubProfile.decode(response, token)
    }
}

/**
 * `$services`: `status("github")` and `profile("github")`. A script cannot
 * choose an account, URL, header or token, and no method returns credentials.
 */
class ServicesModule(private val connections: ServiceConnections) : NativeModule {
    override val apis: Set<String> = setOf("\$services")

    override fun handles(operation: String): Boolean = operation.startsWith("services.")

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        val service = payload?.opt("service") as? String ?: ""
        when (operation) {
            "services.status" -> runSystemCall(operation, done) { JSONObject.quote(status(context, service)) }
            "services.profile" -> runSystemCall(operation, done) { profile(context, service).toString() }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    private fun permitted(context: CallContext): Boolean = context.isInstalled && context.declares("services")

    /**
     * Checks shared by both methods, in the Apple runtime's order: installed owner with the
     * `services` permission (`service_permission`), a supported provider (`service_operation`),
     * no future entry or Live Activity (`timeline_read_only`), the query budget (`query_limit`).
     */
    private fun admit(context: CallContext, service: String): ServiceConnection? {
        if (!permitted(context)) throw ServiceError.PERMISSION.reject()
        if (service != "github") throw ServiceError.OPERATION.reject()
        if (context.isTimelineProjection || context.isLiveActivity) throw SystemReject("[timeline_read_only] Read services in the current entry, then reuse a display snapshot")
        if (!context.consumeDataQuery()) throw SystemReject("[query_limit] Too many system data queries")
        return connections.connection()
    }

    /** Authority is checked again before delivery: a disconnect, reconnect or grant change invalidates a pending result. */
    private fun confirm(context: CallContext, connection: ServiceConnection?, needsGrant: Boolean) {
        if (!permitted(context)) throw ServiceError.PERMISSION.reject()
        val current = connections.connection()
        if (current?.connectionID != connection?.connectionID) throw ServiceError.CONFLICT.reject()
        if (needsGrant && current?.grants?.contains(context.installation) != true) throw ServiceError.PERMISSION.reject()
    }

    /** `notConnected`, `notGranted` or `connected`. Makes no network request. */
    fun status(context: CallContext, service: String): String {
        val connection = admit(context, service)
        val status = if (connection == null) "notConnected" else if (context.installation in connection.grants) "connected" else "notGranted"
        confirm(context, connection, needsGrant = false)
        return status
    }

    /**
     * The fixed authenticated profile read. Beyond [status]: a connection (`service_not_connected`),
     * this installation's grant and `network` with `api.github.com` declared (`service_permission`),
     * the network budget (`network_limit`), and a response for the connected user ID (`service_credential`).
     */
    fun profile(context: CallContext, service: String): JSONObject {
        val connection = admit(context, service) ?: throw ServiceError.NOT_CONNECTED.reject()
        if (context.installation !in connection.grants) throw ServiceError.PERMISSION.reject()
        if (!context.allowsHost(GitHubProfile.HOST)) throw ServiceError.PERMISSION.reject()
        if (!context.consumeNetworkRequest()) throw ServiceError.NETWORK_LIMIT.reject()
        val result = runCatching { connections.fetch(connection.token) }
        confirm(context, connection, needsGrant = true)
        val profile = result.getOrElse { throw (it as? SystemReject ?: ServiceError.UNAVAILABLE.reject()) }
        if (profile.getString("subject") != connection.subject) throw ServiceError.CREDENTIAL.reject()
        return profile
    }
}

/** The profile request through [FetchModule.perform]: public addresses only, five-second timeout, every redirect refused. */
class FetchServiceTransport(private val fetch: FetchModule = FetchModule()) : ServiceTransport {
    override fun get(url: String, headers: Map<String, String>): ServiceHttpResponse {
        val response = fetch.perform("GET", URI(url), headers, null, 5_000) { false }
        if (response.body.size > GitHubProfile.MAXIMUM_RESPONSE_BYTES) throw ServiceError.UNAVAILABLE.reject()
        val rateLimited = response.headers["x-ratelimit-remaining"] == "0" || response.headers.containsKey("retry-after")
        return ServiceHttpResponse(response.status, response.headers["content-type"], rateLimited, response.body)
    }
}

/**
 * [ServiceVault] backed by an AES-256-GCM key that lives in the Android
 * Keystore and never leaves it. The file holds a version byte, the nonce and
 * the ciphertext; the record is bound to its purpose with associated data.
 */
class KeystoreServiceVault(private val file: File) : ServiceVault {
    override fun read(): String? {
        if (!file.exists()) return null
        return try {
            val bytes = file.readBytes()
            if (bytes.size < 1 + NONCE_BYTES + 16 || bytes.size > MAXIMUM_BYTES || bytes[0] != VERSION) throw ServiceError.STORAGE.reject()
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(create = false) ?: throw ServiceError.STORAGE.reject(), GCMParameterSpec(128, bytes, 1, NONCE_BYTES))
            cipher.updateAAD(ASSOCIATED_DATA)
            String(cipher.doFinal(bytes, 1 + NONCE_BYTES, bytes.size - 1 - NONCE_BYTES), Charsets.UTF_8)
        } catch (error: SystemReject) { throw error } catch (error: Exception) { throw ServiceError.STORAGE.reject() }
    }

    override fun write(text: String?) {
        try {
            if (text == null) { file.delete(); return }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
            cipher.updateAAD(ASSOCIATED_DATA)
            val sealed = cipher.doFinal(text.toByteArray())
            file.parentFile?.mkdirs()
            val temporary = File(file.parentFile, file.name + ".tmp")
            temporary.writeBytes(byteArrayOf(VERSION) + cipher.iv + sealed)
            if (!temporary.renameTo(file)) { temporary.delete(); throw ServiceError.STORAGE.reject() }
        } catch (error: SystemReject) { throw error } catch (error: Exception) { throw ServiceError.STORAGE.reject() }
    }

    private fun key(create: Boolean): SecretKey? {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        if (!create) return null
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        return generator.generateKey()
    }

    private companion object {
        const val ALIAS = "scriptwidget.services.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val NONCE_BYTES = 12
        const val MAXIMUM_BYTES = 64 * 1024
        const val VERSION: Byte = 1
        val ASSOCIATED_DATA = "scriptwidget.services.github.v1".toByteArray()
    }
}
