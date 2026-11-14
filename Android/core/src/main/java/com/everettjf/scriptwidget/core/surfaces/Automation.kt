package com.everettjf.scriptwidget.core.surfaces

import java.security.MessageDigest
import java.security.SecureRandom

/** Why an automation request was refused. [message] is returned to an ordered sender; it never contains the token. */
enum class AutomationFailure(val message: String) {
    DISABLED("Automation is turned off in ScriptWidget."),
    INVALID_REQUEST("The request is missing a field or a field is too long."),
    WRONG_TOKEN("The token is not the one shown in ScriptWidget."),
    TOO_MANY_REQUESTS("Too many requests. Try again in a minute."),
    PACKAGE_NOT_FOUND("No widget package has this name."),
    PACKAGE_NOT_ALLOWED("This package is not allowed to be run by other apps."),
}

class AutomationRejected(val failure: AutomationFailure) : Exception(failure.message)

/** One request from another app. [action] is null for a refresh. */
class AutomationRequest(val command: String, val packageName: String?, val action: String?, val value: Boolean?, val token: String) {
    companion object {
        const val COMMAND_RUN = "run"
        const val COMMAND_REFRESH = "refresh"
    }
}

/**
 * The rules of the automation entry point, which other apps (Tasker,
 * MacroDroid, a shell) reach with a broadcast. Everything a sender supplies
 * is untrusted text. A request can name a package and one of the actions its
 * manifest declares, never a function or code.
 */
object Automation {
    /** Suffixes of the broadcast actions; the application ID comes first. */
    const val ACTION_RUN = ".automation.RUN_ACTION"
    const val ACTION_REFRESH = ".automation.REFRESH"
    const val FIELD_PACKAGE = "package"
    const val FIELD_ACTION = "action"
    const val FIELD_VALUE = "value"
    const val FIELD_TOKEN = "token"
    const val MAXIMUM_FIELD_LENGTH = 128
    const val TOKEN_LENGTH = 32

    /**
     * Reads a request from the fields a sender gave. [command] is decided by
     * the broadcast action, not by a field.
     * @throws AutomationRejected when a required field is missing or malformed.
     */
    fun parse(command: String, fields: Map<String, String?>): AutomationRequest {
        fun field(name: String): String? = fields[name]?.takeIf { it.isNotEmpty() }?.also {
            if (it.length > MAXIMUM_FIELD_LENGTH || it.any { character -> character.isISOControl() }) throw AutomationRejected(AutomationFailure.INVALID_REQUEST)
        }
        val token = field(FIELD_TOKEN) ?: throw AutomationRejected(AutomationFailure.INVALID_REQUEST)
        val packageName = field(FIELD_PACKAGE)
        val value = when (field(FIELD_VALUE)?.lowercase()) {
            null -> null
            "true", "1", "on" -> true
            "false", "0", "off" -> false
            else -> throw AutomationRejected(AutomationFailure.INVALID_REQUEST)
        }
        return when (command) {
            AutomationRequest.COMMAND_RUN -> AutomationRequest(
                command, packageName ?: throw AutomationRejected(AutomationFailure.INVALID_REQUEST),
                field(FIELD_ACTION) ?: throw AutomationRejected(AutomationFailure.INVALID_REQUEST), value, token,
            )
            AutomationRequest.COMMAND_REFRESH -> AutomationRequest(command, packageName, null, null, token)
            else -> throw AutomationRejected(AutomationFailure.INVALID_REQUEST)
        }
    }

    /** A new random token: 128 bits as lowercase hexadecimal. */
    fun newToken(random: SecureRandom = SecureRandom()): String =
        ByteArray(TOKEN_LENGTH / 2).also { random.nextBytes(it) }.joinToString("") { "%02x".format(it) }

    fun isValidToken(token: String?): Boolean = token != null && token.length == TOKEN_LENGTH && token.all { it in '0'..'9' || it in 'a'..'f' }

    /** Compares in constant time, so a sender learns nothing from how long a wrong guess takes. */
    fun tokensMatch(expected: String?, given: String?): Boolean {
        if (!isValidToken(expected) || given == null) return false
        return MessageDigest.isEqual(expected!!.toByteArray(Charsets.UTF_8), given.toByteArray(Charsets.UTF_8))
    }
}

/**
 * At most [maximum] requests in any [windowMilliseconds]. Wrong tokens count
 * too, so guessing is slow and a looping task cannot drain the battery.
 */
class AutomationLimiter(private val maximum: Int = 30, private val windowMilliseconds: Long = 60_000L) {
    private val times = ArrayDeque<Long>()

    @Synchronized
    fun allow(now: Long): Boolean {
        while (times.isNotEmpty() && now - times.first() >= windowMilliseconds) times.removeFirst()
        if (times.size >= maximum) return false
        times.addLast(now)
        return true
    }
}
