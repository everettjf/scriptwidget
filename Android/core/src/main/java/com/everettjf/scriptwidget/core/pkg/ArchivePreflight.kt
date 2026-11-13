package com.everettjf.scriptwidget.core.pkg

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * Central-directory validation of an untrusted `.swt` archive, ported from
 * `ScriptPackageArchivePreflight.validate` in Swift (and `preflightArchive` in `archive.js`).
 * It inspects bytes only and never inflates or writes anything.
 */
internal object ArchivePreflight {
    /** One central-directory entry that passed validation. [parts] are the non-empty path components. */
    class Entry(val name: String, val parts: List<String>, val isDirectory: Boolean, val uncompressedSize: Long, val crc: Long)

    private const val END_SIGNATURE = 0x06054B50L
    private const val CENTRAL_SIGNATURE = 0x02014B50L
    private const val UINT32_MAX = 0xFFFFFFFFL

    /**
     * Validates the whole archive and returns its entries, or throws.
     *
     * Rejected: empty or oversized archives; a missing, multi-disk, trailing-garbage or
     * out-of-bounds central directory; more entries than allowed; encrypted entries; compression
     * other than stored/deflate; malformed ZIP64 sizes; entry names that are not UTF-8, are
     * absolute, contain a backslash, colon, NUL, control character, `.` or `..` component, or
     * nest too deeply; duplicate, case-colliding or file-versus-directory clashing paths; symbolic
     * links and other special files; a declared file size or declared total above the limits;
     * and a large file that claims zero compressed bytes.
     */
    fun validate(data: ByteArray, limits: ArchiveLimits): List<Entry> {
        if (data.isEmpty() || data.size > limits.maximumArchiveBytes) fail(PackageErrors.ARCHIVE_SIZE, "Archive must be between 1 byte and 32 MiB.")
        val end = endOfCentralDirectory(data) ?: fail(PackageErrors.ARCHIVE_MALFORMED, "Archive has no valid ZIP central directory.")
        if (u16(data, end + 4) != 0 || u16(data, end + 6) != 0 || u16(data, end + 8) != u16(data, end + 10)) {
            fail(PackageErrors.ARCHIVE_MULTI_DISK, "Multi-disk ZIP archives are not supported.")
        }
        if (end + 22 + u16(data, end + 20) != data.size) fail(PackageErrors.ARCHIVE_MALFORMED, "Archive has a malformed ZIP footer.")
        val count = u16(data, end + 10)
        val centralSize = u32(data, end + 12)
        val centralOffset = u32(data, end + 16)
        if (count <= 0 || count > limits.maximumFileCount) {
            fail(PackageErrors.ARCHIVE_TOO_MANY_ENTRIES, "Archive must contain 1–${limits.maximumFileCount} entries.")
        }
        if (centralOffset + centralSize > data.size) fail(PackageErrors.ARCHIVE_MALFORMED, "Archive central directory is out of bounds.")

        var cursor = centralOffset.toInt()
        var expanded = 0L
        val collisions = Collisions()
        val entries = ArrayList<Entry>(count)
        repeat(count) {
            if (cursor + 46 > data.size || u32(data, cursor) != CENTRAL_SIGNATURE) {
                fail(PackageErrors.ARCHIVE_MALFORMED, "Archive central directory contains an invalid entry.")
            }
            val flags = u16(data, cursor + 8)
            val method = u16(data, cursor + 10)
            val crc = u32(data, cursor + 16)
            val nameLength = u16(data, cursor + 28)
            val extraLength = u16(data, cursor + 30)
            val commentLength = u16(data, cursor + 32)
            val external = u32(data, cursor + 38)
            val entryEnd = cursor + 46 + nameLength + extraLength + commentLength
            if (nameLength == 0 || entryEnd > data.size) fail(PackageErrors.ARCHIVE_MALFORMED, "Archive contains a truncated filename.")
            val extraStart = cursor + 46 + nameLength
            val sizes = resolvedSizes(u32(data, cursor + 20), u32(data, cursor + 24), data, extraStart, extraStart + extraLength)
                ?: fail(PackageErrors.ARCHIVE_MALFORMED, "Archive contains malformed ZIP64 size metadata.")
            val (compressed, uncompressed) = sizes
            if (flags and 0x1 != 0) fail(PackageErrors.ARCHIVE_ENCRYPTED, "Encrypted package entries are not supported.")
            if (method != 0 && method != 8) fail(PackageErrors.ARCHIVE_UNSUPPORTED_COMPRESSION, "Unsupported ZIP compression method $method.")
            val name = decodeUtf8(data, cursor + 46, nameLength)
            val parts = name?.let { entryParts(it, limits.maximumPathDepth) }
            if (name == null || parts == null) fail(PackageErrors.ARCHIVE_UNSAFE_PATH, "Archive contains an unsafe or non-UTF-8 path.")
            val isDirectory = name.endsWith("/")
            if (!collisions.add(name, parts, isDirectory)) {
                fail(PackageErrors.ARCHIVE_PATH_COLLISION, "Archive contains duplicate or case-colliding paths.")
            }
            // Unix mode in the high half: only regular files (0x8000), directories (0x4000) or
            // an absent type are accepted; 0xA000 is a symbolic link.
            val type = ((external ushr 16) and 0xF000L).toInt()
            if (type == 0xA000) fail(PackageErrors.ARCHIVE_SYMLINK, "Symbolic links are not allowed in ScriptWidget packages.")
            if (type != 0 && type != 0x8000 && type != 0x4000) {
                fail(PackageErrors.ARCHIVE_SYMLINK, "Only regular files and directories are allowed in ScriptWidget packages.")
            }
            if (!isDirectory) {
                // Sizes are unsigned 64-bit; a negative Long is far above any limit.
                if (uncompressed < 0 || uncompressed > limits.maximumFileBytes) {
                    fail(PackageErrors.ARCHIVE_FILE_TOO_LARGE, "Package file $name exceeds 25 MiB.")
                }
                expanded += uncompressed
                if (expanded > limits.maximumExpandedBytes) fail(PackageErrors.ARCHIVE_EXPANDED_TOO_LARGE, "Expanded package exceeds 64 MiB.")
                if (uncompressed > 1024 * 1024 && compressed == 0L) {
                    fail(PackageErrors.ARCHIVE_INVALID_RATIO, "Archive entry $name has an invalid compression ratio.")
                }
            }
            entries.add(Entry(name, parts, isDirectory, uncompressed, crc))
            cursor = entryEnd
        }
        if (cursor.toLong() != centralOffset + centralSize) {
            fail(PackageErrors.ARCHIVE_MALFORMED, "Archive entries do not match the declared central directory.")
        }
        return entries
    }

    /**
     * Components of an archive entry name, or null when the name is unsafe: a leading slash,
     * any backslash, colon (drive or stream syntax) or NUL, a `.`/`..` component, a component
     * that is too long or holds control characters, no components, or more than [maximumDepth].
     */
    fun entryParts(name: String, maximumDepth: Int): List<String>? {
        if (name.startsWith("/") || name.contains('\\') || name.contains(':') || name.contains('\u0000')) return null
        val parts = name.split('/').filter { it.isNotEmpty() }
        if (parts.isEmpty() || parts.size > maximumDepth || !parts.all(PackagePathRules::validComponent)) return null
        return parts
    }

    /**
     * Tracks every file and directory prefix seen so far. Two spellings of one identity
     * (case or Unicode form), a repeated path, and a path used as both file and directory would
     * overwrite or shadow each other on extraction, so each is a collision.
     */
    private class Collisions {
        private val fullPaths = HashSet<String>()
        private val spellings = HashMap<String, String>()
        private val directories = HashMap<String, Boolean>()

        fun add(name: String, parts: List<String>, isDirectory: Boolean): Boolean {
            if (!fullPaths.add(PackageNames.identity(name).trim('/'))) return false
            val prefix = StringBuilder()
            for ((index, part) in parts.withIndex()) {
                if (index > 0) prefix.append('/')
                prefix.append(part)
                val path = prefix.toString()
                val spelling = spellings.getOrPut(PackageNames.identity(path)) { path }
                if (spelling != path) return false
                val directory = index < parts.size - 1 || isDirectory
                if (directories.getOrPut(path) { directory } != directory) return false
            }
            return true
        }
    }

    private fun resolvedSizes(compressed32: Long, uncompressed32: Long, data: ByteArray, extraStart: Int, extraEnd: Int): Pair<Long, Long>? {
        if (compressed32 != UINT32_MAX && uncompressed32 != UINT32_MAX) return compressed32 to uncompressed32
        var compressed = compressed32
        var uncompressed = uncompressed32
        var cursor = extraStart
        while (cursor + 4 <= extraEnd) {
            val identifier = u16(data, cursor)
            val end = cursor + 4 + u16(data, cursor + 2)
            if (end > extraEnd) return null
            if (identifier == 0x0001) {
                var value = cursor + 4
                if (uncompressed32 == UINT32_MAX) {
                    if (value + 8 > end) return null
                    uncompressed = u64(data, value)
                    value += 8
                }
                if (compressed32 == UINT32_MAX) {
                    if (value + 8 > end) return null
                    compressed = u64(data, value)
                }
                return compressed to uncompressed
            }
            cursor = end
        }
        return null
    }

    private fun endOfCentralDirectory(data: ByteArray): Int? {
        if (data.size < 22) return null
        val lowerBound = maxOf(0, data.size - 65_557)
        var index = data.size - 22
        while (index >= lowerBound) {
            if (u32(data, index) == END_SIGNATURE) return index
            index -= 1
        }
        return null
    }

    private fun decodeUtf8(data: ByteArray, offset: Int, length: Int): String? = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(data, offset, length)).toString()
    } catch (_: CharacterCodingException) {
        null
    }

    private fun u16(data: ByteArray, index: Int): Int =
        if (index < 0 || index + 2 > data.size) 0 else (data[index].toInt() and 0xFF) or ((data[index + 1].toInt() and 0xFF) shl 8)

    private fun u32(data: ByteArray, index: Int): Long =
        if (index < 0 || index + 4 > data.size) 0 else u16(data, index).toLong() or (u16(data, index + 2).toLong() shl 16)

    private fun u64(data: ByteArray, index: Int): Long =
        if (index < 0 || index + 8 > data.size) 0 else u32(data, index) or (u32(data, index + 4) shl 32)

    private fun fail(code: String, message: String): Nothing = throw PackageException(code, message)
}
