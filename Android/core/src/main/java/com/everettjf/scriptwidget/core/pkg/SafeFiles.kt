package com.everettjf.scriptwidget.core.pkg

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.util.UUID

/**
 * Link-refusing filesystem primitives shared by the package layer. Every lookup uses
 * `NOFOLLOW_LINKS`, so a symbolic link is seen as a link and never as its target.
 *
 * Unlike the Swift implementation these cannot hold directory descriptors (`openat`), so a
 * check and the following open are separate system calls. The final component is still opened
 * with `NOFOLLOW_LINKS`; package directories live in app-private storage.
 */
internal object SafeFiles {
    /** Attributes of [path] itself (never of a link target), or null when it is absent or unreadable. */
    fun attributes(path: Path): BasicFileAttributes? = try {
        Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
    } catch (_: IOException) {
        null
    }

    /** True when something, including a dangling link, occupies [path]. */
    fun occupied(path: Path): Boolean = Files.exists(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path)

    /** [path] when it is a real directory rather than a link to one, else null. */
    fun realDirectory(path: Path): Path? = path.takeIf { attributes(it)?.let { a -> a.isDirectory && !a.isSymbolicLink } == true }

    /** Entry names of [directory], or null when it cannot be listed or is implausibly large. */
    fun names(directory: Path): List<String>? = try {
        Files.newDirectoryStream(directory).use { stream ->
            val result = ArrayList<String>()
            for (entry in stream) {
                result.add(entry.fileName.toString())
                if (result.size > PackageLimits.MAX_DIRECTORY_ENTRIES) return null
            }
            result
        }
    } catch (_: IOException) {
        null
    }

    /**
     * False when [names] holds a different spelling of [name] (another case or Unicode form).
     * Such aliases resolve to one file on some filesystems and two on others, so they are refused.
     */
    fun unambiguous(names: List<String>, name: String): Boolean {
        val identity = PackageNames.identity(name)
        return names.none { it != name && PackageNames.identity(it) == identity }
    }

    /**
     * False for a regular file with more than one hard link: a second link could expose or alter
     * a file outside the package. Platforms without the `unix` attribute view cannot create such
     * links through this layer and are treated as singly linked.
     */
    fun singlyLinked(path: Path): Boolean = try {
        (Files.getAttribute(path, "unix:nlink", LinkOption.NOFOLLOW_LINKS) as Number).toInt() <= 1
    } catch (_: UnsupportedOperationException) {
        true
    } catch (_: IllegalArgumentException) {
        true
    } catch (_: IOException) {
        false
    }

    /**
     * Resolves [parts] below [root] to an existing regular file, or null.
     *
     * Each component must be spelled exactly as stored, must not be a link, and must not have a
     * case alias; intermediate components must be directories. The canonical path of the result
     * must still be inside the canonical root, which catches anything the walk could have missed.
     */
    fun existingFile(root: Path, parts: List<String>): Path? {
        var directory = realDirectory(root) ?: return null
        for ((index, name) in parts.withIndex()) {
            val siblings = names(directory) ?: return null
            if (name !in siblings || !unambiguous(siblings, name)) return null
            val child = directory.resolve(name)
            val info = attributes(child) ?: return null
            if (info.isSymbolicLink) return null
            if (index < parts.size - 1) {
                if (!info.isDirectory) return null
                directory = child
            } else {
                if (!info.isRegularFile || !singlyLinked(child) || !inside(root, child)) return null
                return child
            }
        }
        return null
    }

    /** True when the canonical form of [path] is strictly below the canonical form of [root]. */
    fun inside(root: Path, path: Path): Boolean = try {
        val realRoot = root.toRealPath()
        val real = path.toRealPath()
        real != realRoot && real.startsWith(realRoot)
    } catch (_: IOException) {
        false
    }

    /** Reads [file] without following a link, or returns null when it holds more than [maximumBytes]. */
    fun readBounded(file: Path, maximumBytes: Long): ByteArray? = try {
        Files.newInputStream(file, LinkOption.NOFOLLOW_LINKS).use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            var total = 0L
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                // The size is counted while reading, never taken from metadata that may change.
                if (total > maximumBytes) return null
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    } catch (_: IOException) {
        null
    }

    /** Strict UTF-8 decoding: malformed input yields null instead of replacement characters. */
    fun decodeUtf8(bytes: ByteArray): String? = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString()
    } catch (_: CharacterCodingException) {
        null
    }

    /** Creates [file] exclusively, writes [bytes] and flushes them to storage. */
    fun writeNew(file: Path, bytes: ByteArray) {
        FileChannel.open(file, StandardOpenOption.WRITE, StandardOpenOption.CREATE_NEW, LinkOption.NOFOLLOW_LINKS).use { channel ->
            val buffer = ByteBuffer.wrap(bytes)
            while (buffer.hasRemaining()) channel.write(buffer)
            channel.force(true)
        }
    }

    /** Creates a uniquely named private working directory below [stagingRoot]. */
    fun newWorkDirectory(stagingRoot: Path, prefix: String): Path = try {
        Files.createDirectories(stagingRoot)
        if (realDirectory(stagingRoot) == null) throw IOException("Staging directory is a link")
        Files.createDirectory(stagingRoot.resolve("$prefix-${UUID.randomUUID()}"))
    } catch (error: IOException) {
        throw PackageException(PackageErrors.STORAGE_UNAVAILABLE, "The staging directory is unavailable.", error)
    }

    /**
     * Publishes a prepared directory with one atomic rename, so observers see either nothing or
     * the complete package. [destination] must be free; callers hold the store lock because Java
     * has no exclusive rename.
     */
    fun publish(prepared: Path, destination: Path) {
        if (occupied(destination)) throw PackageException(PackageErrors.PACKAGE_EXISTS, "A package with this name already exists.")
        try {
            Files.move(prepared, destination, StandardCopyOption.ATOMIC_MOVE)
        } catch (error: AtomicMoveNotSupportedException) {
            throw PackageException(PackageErrors.STORAGE_UNAVAILABLE, "Staging and library directories must share a filesystem.", error)
        } catch (error: IOException) {
            throw PackageException(PackageErrors.STORAGE_UNAVAILABLE, "The package could not be published.", error)
        }
    }

    /** Removes [path] and everything below it. Links are removed, never followed. Best effort. */
    fun deleteTree(path: Path) {
        if (!occupied(path)) return
        try {
            Files.walkFileTree(path, object : SimpleFileVisitor<Path>() {
                override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                    Files.deleteIfExists(file)
                    return FileVisitResult.CONTINUE
                }

                override fun visitFileFailed(file: Path, exc: IOException): FileVisitResult = FileVisitResult.CONTINUE

                override fun postVisitDirectory(dir: Path, exc: IOException?): FileVisitResult {
                    Files.deleteIfExists(dir)
                    return FileVisitResult.CONTINUE
                }
            })
        } catch (_: IOException) {
            // Leftovers stay inside the private staging directory and are retried by later cleanups.
        }
    }
}
