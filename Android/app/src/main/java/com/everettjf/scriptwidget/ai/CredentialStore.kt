package com.everettjf.scriptwidget.ai

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * API keys for AI providers, the Android counterpart of `AIKeychain`.
 *
 * Each secret is encrypted with AES-256-GCM under a key that is generated
 * inside the Android Keystore and cannot be exported. Only the ciphertext is
 * written, to a private file in the no-backup directory, so a key is never in
 * SharedPreferences, a package, a prompt, a log, or a device backup. The slot
 * name is authenticated with the ciphertext, so a file copied to another slot
 * does not decrypt.
 *
 * All methods do blocking I/O and Keystore work: call them off the main thread.
 */
class CredentialStore(context: Context) {
    private val directory = File(context.applicationContext.noBackupFilesDir, "ai-credentials")
    private val lock = Any()

    /** The secret stored in [slot], or null when none is stored or it can no longer be decrypted. */
    fun get(slot: String): String? = synchronized(lock) {
        val file = file(slot) ?: return null
        if (!file.isFile || file.length() !in MINIMUM_FILE_BYTES..MAXIMUM_FILE_BYTES) return null
        try {
            val bytes = file.readBytes()
            if (bytes[0] != FORMAT_VERSION) return null
            val ivLength = bytes[1].toInt()
            if (ivLength != IV_BYTES || bytes.size <= 2 + ivLength) return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(create = false) ?: return null, GCMParameterSpec(TAG_BITS, bytes, 2, ivLength))
            cipher.updateAAD(slot.toByteArray(Charsets.UTF_8))
            String(cipher.doFinal(bytes, 2 + ivLength, bytes.size - 2 - ivLength), Charsets.UTF_8).takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            // Fail closed: a damaged file or a lost Keystore key means "no credential". Nothing is logged.
            null
        }
    }

    /** True when [slot] holds a ciphertext file. Cheap: it does not decrypt. */
    fun has(slot: String): Boolean = synchronized(lock) { file(slot)?.isFile == true }

    /**
     * Stores [secret] in [slot], replacing any previous value. A blank secret removes the slot.
     * @return false when the secret could not be stored; the previous value is then kept.
     */
    fun set(slot: String, secret: String): Boolean = synchronized(lock) {
        val file = file(slot) ?: return false
        val value = secret.trim()
        if (value.isEmpty()) { file.delete(); return true }
        if (value.length > MAXIMUM_SECRET_CHARACTERS) return false
        try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            // The Keystore generates a fresh random IV for every encryption.
            cipher.init(Cipher.ENCRYPT_MODE, key(create = true) ?: return false)
            cipher.updateAAD(slot.toByteArray(Charsets.UTF_8))
            val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            val iv = cipher.iv
            if (iv.size != IV_BYTES) return false
            directory.mkdirs()
            val temporary = File(directory, file.name + ".tmp")
            temporary.outputStream().use { output ->
                output.write(byteArrayOf(FORMAT_VERSION, iv.size.toByte()))
                output.write(iv)
                output.write(encrypted)
                output.fd.sync()
            }
            if (!temporary.renameTo(file)) { temporary.delete(); return false }
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Deletes the secret in [slot], if any. */
    fun remove(slot: String) { synchronized(lock) { file(slot)?.delete() } }

    private fun file(slot: String): File? = if (SLOT.matches(slot)) File(directory, "$slot.bin") else null

    private fun key(create: Boolean): SecretKey? {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        if (!create) return null
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "scriptwidget.ai.credentials.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val FORMAT_VERSION: Byte = 1
        const val IV_BYTES = 12
        const val TAG_BITS = 128
        const val MAXIMUM_SECRET_CHARACTERS = 4096
        const val MINIMUM_FILE_BYTES = (2 + IV_BYTES + TAG_BITS / 8).toLong()
        const val MAXIMUM_FILE_BYTES = 64L * 1024
        val SLOT = Regex("[a-z0-9_-]{1,64}")
    }
}
