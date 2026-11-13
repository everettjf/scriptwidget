package com.everettjf.scriptwidget.core.pkg

import com.everettjf.scriptwidget.core.runtime.PackageFiles
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.Locale

/**
 * One installed package as shown in the library. The manifest fields are display values read
 * leniently from `widget.json`; they are null when the manifest is absent, unreadable or the
 * field is not a string. They are not validated.
 */
data class PackageInfo(
    val name: String,
    val directory: File,
    /** True when any spelling of `widget.json` is present; such a package is never treated as legacy. */
    val hasManifest: Boolean,
    val manifestId: String?,
    val manifestName: String?,
    val manifestVersion: String?,
)

/**
 * The library of installed packages, one directory per package under `libraryRoot/<PackageName>/`.
 * Ported from `ScriptManager` in Swift.
 *
 * Everything that enters the library is prepared in a unique directory under [stagingRoot] and
 * published with one atomic rename, so a failed create, import or duplicate leaves no partial
 * package. [stagingRoot] must be on the same filesystem as [libraryRoot] and must not be inside
 * it. Package names follow [PackageNames.isValid], and a name is usable only when no other
 * library entry has the same identity after case folding and NFC normalization.
 *
 * Mutations are serialized per store instance; use one instance per library.
 */
class PackageStore(libraryRoot: File, stagingRoot: File, private val limits: ArchiveLimits = ArchiveLimits()) {
    private val library: Path = libraryRoot.toPath().toAbsolutePath().normalize()
    private val staging: Path = stagingRoot.toPath().toAbsolutePath().normalize()
    private val lock = Any()

    /** Installed packages sorted by name. Entries that are links, files, invalid or ambiguous names are not packages. */
    fun list(): List<PackageInfo> {
        val names = libraryNames()
        return names.sorted().mapNotNull { name ->
            if (!PackageNames.isValid(name) || !SafeFiles.unambiguous(names, name)) return@mapNotNull null
            SafeFiles.realDirectory(library.resolve(name))?.let { info(name, it) }
        }
    }

    /** Read-only, boundary-checked view of an installed package. */
    fun files(name: String): DiskPackageFiles = DiskPackageFiles(existing(name).toFile())

    /**
     * [recommended] if it is free, otherwise the first free `"<stem> (n)"` for n in 1…10000, with
     * the stem shortened to keep the name limits (`ScriptManager.getValidPackageName`).
     *
     * @throws PackageException `invalid_name` when [recommended] is invalid or no name is free.
     */
    fun uniqueName(recommended: String): String = synchronized(lock) {
        requireValid(recommended)
        val identities = libraryNames().mapTo(HashSet(), PackageNames::identity)
        fun available(name: String) = PackageNames.isValid(name) && PackageNames.identity(name) !in identities
        if (available(recommended)) return recommended
        for (index in 1..PackageLimits.MAX_NAME_ATTEMPTS) {
            val candidate = PackageNames.withSuffix(recommended, " ($index)")
            if (available(candidate)) return candidate
        }
        throw PackageException(PackageErrors.INVALID_NAME, "No free package name is available.")
    }

    /**
     * Creates a package named exactly [name] from [mainSource] and a manifest. Without
     * [manifestJson] a default Package 2.0 manifest is generated. The source is written to the
     * manifest's `entry` (default `main.jsx`). The package becomes visible only after source and
     * manifest are fully written.
     *
     * [manifestJson] must be a JSON object of at most 256 KiB with a safe `.js`/`.jsx` entry path;
     * its semantic validation is the caller's responsibility.
     *
     * @throws PackageException `invalid_name`, `package_exists`, `invalid_manifest`, `invalid_entry`, `file_too_large`.
     */
    fun create(name: String, mainSource: String, manifestJson: String? = null): PackageInfo {
        requireValid(name)
        val source = mainSource.toByteArray(Charsets.UTF_8)
        if (source.size > PackageLimits.MAX_SCRIPT_BYTES) throw PackageException(PackageErrors.FILE_TOO_LARGE, "Script source exceeds 512 KiB.")
        val manifestBytes: ByteArray
        var entry = PackageManifests.LEGACY_ENTRY
        if (manifestJson == null) {
            manifestBytes = PackageManifests.encode(PackageManifests.newManifest(name))
        } else {
            manifestBytes = manifestJson.toByteArray(Charsets.UTF_8)
            if (manifestBytes.size > PackageLimits.MAX_METADATA_BYTES) throw PackageException(PackageErrors.FILE_TOO_LARGE, "widget.json exceeds 256 KiB.")
            val manifest = PackageManifests.parse(manifestJson) ?: throw PackageException(PackageErrors.INVALID_MANIFEST, "widget.json is invalid.")
            entry = PackageManifests.string(manifest, "entry") ?: throw PackageException(PackageErrors.INVALID_MANIFEST, "widget.json is invalid.")
            if (PackagePathRules.visibleComponents(entry) == null || entry == PackageManifests.FILE_NAME || !entryFile.containsMatchIn(entry)) {
                throw PackageException(PackageErrors.INVALID_ENTRY, "entry must be a package-relative .js or .jsx file.")
            }
        }
        return staged("create") { prepared ->
            PackageFileWriter.write(prepared, entry, source)
            PackageFileWriter.write(prepared, PackageManifests.FILE_NAME, manifestBytes)
            PackageTree.validate(prepared, limits)
            synchronized(lock) {
                if (!free(name)) throw PackageException(PackageErrors.PACKAGE_EXISTS, "A package with this name already exists.")
                SafeFiles.publish(prepared, library.resolve(name))
            }
            info(name, library.resolve(name))
        }
    }

    /**
     * Imports a `.swt` archive and returns the installed package.
     *
     * The archive is preflighted and extracted by [PackageArchive.extract]. The installed
     * directory name comes from the manifest's `name`, never from the archive file name; on a
     * collision it gets the next free `" (n)"` suffix ([uniqueName]). A package without
     * `widget.json` is legacy: it must contain `main.jsx` and receives a generated manifest named
     * after the archive's top-level directory, or [suggestedName] when the files sit at the archive
     * root. A present manifest is authoritative: a wrongly cased, non-UTF-8, non-object or
     * nameless `widget.json` fails the import instead of being reinterpreted as legacy.
     *
     * [validate] runs on the staged package before publication (plug the shared manifest
     * validator in here); if it throws, nothing is installed. A rejected import leaves nothing in
     * the library or the staging directory.
     */
    fun importArchive(input: InputStream, suggestedName: String?, validate: ((PackageFiles) -> Unit)? = null): PackageInfo =
        PackageArchive.extract(input, staging.toFile(), limits).use { extracted ->
            val prepared = extracted.directory.toPath()
            val files = DiskPackageFiles(extracted.directory)
            val name: String
            if (manifestPresent(prepared)) {
                name = PackageManifests.string(readManifest(files), "name") ?: throw PackageException(PackageErrors.INVALID_MANIFEST, "widget.json is invalid.")
            } else {
                if (!files.exists(PackageManifests.LEGACY_ENTRY)) throw PackageException(PackageErrors.MISSING_ENTRY, "Entry file main.jsx does not exist.")
                name = extracted.rootName ?: suggestedName?.takeIf(PackageNames::isValid) ?: "Imported Widget"
                requireValid(name)
                PackageFileWriter.write(prepared, PackageManifests.FILE_NAME, PackageManifests.encode(legacyManifest(name, files)))
            }
            requireValid(name)
            validate?.invoke(files)
            synchronized(lock) {
                val installed = uniqueName(name)
                extracted.moveTo(library.resolve(installed).toFile())
                info(installed, library.resolve(installed))
            }
        }

    /**
     * Exports an installed package as a `.swt` archive under one top-level directory named after
     * the package. `__Build`, dot-files and links are not exported. A legacy package is exported
     * with a generated `widget.json` (the installed package is not modified); a package whose
     * present manifest is unreadable is not exported.
     */
    fun exportArchive(name: String, output: OutputStream) {
        val directory = existing(name)
        val files = DiskPackageFiles(directory.toFile())
        val extras = HashMap<String, ByteArray>()
        if (manifestPresent(directory)) {
            readManifest(files)
        } else {
            if (!files.exists(PackageManifests.LEGACY_ENTRY)) throw PackageException(PackageErrors.MISSING_ENTRY, "Entry file main.jsx does not exist.")
            extras[PackageManifests.FILE_NAME] = PackageManifests.encode(legacyManifest(name, files))
        }
        PackageArchive.export(directory.toFile(), name, output, extras, limits)
    }

    /**
     * Copies a package to a new `"<name> Remix"` package (made unique like [uniqueName]) and
     * returns it. The source tree must be free of links and special files. `__Build` and
     * dot-files are not copied. A Package 2.0 copy gets a fresh `id` and its new name; a legacy
     * package stays legacy (`ScriptManager.duplicateScript`).
     */
    fun duplicate(name: String): PackageInfo {
        val source = existing(name)
        PackageTree.validate(source, limits)
        val files = DiskPackageFiles(source.toFile())
        val manifest = if (manifestPresent(source)) readManifest(files) else null
        return staged("duplicate") { prepared ->
            for (path in files.paths()) {
                val bytes = files.readBytes(path, limits.maximumFileBytes) ?: throw PackageException(PackageErrors.UNSAFE_FILE, "Package file could not be verified.")
                PackageFileWriter.write(prepared, path, bytes)
            }
            synchronized(lock) {
                val copy = uniqueName(PackageNames.withSuffix(name, " Remix"))
                if (manifest != null) {
                    manifest.put("id", PackageManifests.freshId()).put("name", copy)
                    PackageFileWriter.write(prepared, PackageManifests.FILE_NAME, PackageManifests.encode(manifest))
                }
                PackageTree.validate(prepared, limits)
                SafeFiles.publish(prepared, library.resolve(copy))
                info(copy, library.resolve(copy))
            }
        }
    }

    /**
     * Renames a package directory atomically. The manifest is left unchanged, as in Swift.
     * [newName] must be valid and free; a change of case only is refused as ambiguous.
     */
    fun rename(name: String, newName: String): PackageInfo = synchronized(lock) {
        val source = existing(name)
        requireValid(newName)
        if (name != newName) {
            if (!free(newName)) throw PackageException(PackageErrors.PACKAGE_EXISTS, "A package with this name already exists.")
            SafeFiles.publish(source, library.resolve(newName))
        }
        info(newName, library.resolve(newName))
    }

    /**
     * Deletes a package. The directory first leaves the library with one atomic rename into
     * staging, so it disappears at once; its contents are then removed without following links.
     */
    fun delete(name: String) = synchronized(lock) {
        val directory = existing(name)
        try {
            val work = SafeFiles.newWorkDirectory(staging, "delete")
            try {
                Files.move(directory, work.resolve("package"), StandardCopyOption.ATOMIC_MOVE)
            } finally {
                SafeFiles.deleteTree(work)
            }
        } catch (_: IOException) {
            SafeFiles.deleteTree(directory)
        } catch (_: PackageException) {
            SafeFiles.deleteTree(directory)
        }
        if (SafeFiles.occupied(directory)) throw PackageException(PackageErrors.STORAGE_UNAVAILABLE, "The widget could not be deleted.")
    }

    /**
     * Atomically writes one file of an installed package. See [PackageFileWriter.write] for the
     * path, link and size rules. A new file is refused once the package holds 500 files.
     */
    fun writeFile(name: String, relativePath: String, bytes: ByteArray) = synchronized(lock) {
        val directory = existing(name)
        val files = DiskPackageFiles(directory.toFile())
        if (!files.exists(relativePath) && files.paths().size >= limits.maximumFileCount) {
            throw PackageException(PackageErrors.TOO_MANY_ENTRIES, "Package contains too many entries.")
        }
        PackageFileWriter.write(directory, relativePath, bytes)
    }

    /**
     * Bytes of one file of an installed package, at most 25 MiB, under the rules of [DiskPackageFiles].
     *
     * @throws PackageException `invalid_path` for an unsafe path, `file_not_found` when the file is missing, refused or too large.
     */
    fun readFile(name: String, relativePath: String): ByteArray {
        val directory = existing(name)
        if (PackagePathRules.visibleComponents(relativePath) == null) throw PackageException(PackageErrors.INVALID_PATH, "Invalid package path.")
        return DiskPackageFiles(directory.toFile()).readBytes(relativePath, PackageLimits.MAX_FILE_BYTES)
            ?: throw PackageException(PackageErrors.FILE_NOT_FOUND, "File not found: $relativePath")
    }

    /** Runs [build] on a fresh staging directory that is removed afterwards unless it was published. */
    private fun <T> staged(prefix: String, build: (Path) -> T): T {
        val work = SafeFiles.newWorkDirectory(staging, prefix)
        try {
            return build(Files.createDirectory(work.resolve("package")))
        } catch (error: IOException) {
            throw PackageException(PackageErrors.STORAGE_UNAVAILABLE, "The package could not be prepared.", error)
        } finally {
            SafeFiles.deleteTree(work)
        }
    }

    private fun libraryNames(): List<String> {
        val names = try {
            Files.createDirectories(library)
            SafeFiles.realDirectory(library)?.let(SafeFiles::names)
        } catch (_: IOException) {
            null
        }
        return names ?: throw PackageException(PackageErrors.STORAGE_UNAVAILABLE, "The widget library is unavailable.")
    }

    private fun requireValid(name: String) {
        if (!PackageNames.isValid(name)) throw PackageException(PackageErrors.INVALID_NAME, "Invalid package name.")
    }

    /** True when no library entry shares the identity of [name]. */
    private fun free(name: String): Boolean {
        val identity = PackageNames.identity(name)
        return libraryNames().none { PackageNames.identity(it) == identity }
    }

    /** Directory of an installed package: a valid, exactly spelled, unambiguous name that is a real directory. */
    private fun existing(name: String): Path {
        requireValid(name)
        val names = libraryNames()
        val directory = if (name in names && SafeFiles.unambiguous(names, name)) SafeFiles.realDirectory(library.resolve(name)) else null
        return directory ?: throw PackageException(PackageErrors.PACKAGE_NOT_FOUND, "Package not found.")
    }

    /**
     * True when the package has a manifest. Any other spelling of `widget.json` is an error: on a
     * case-insensitive platform it would be the manifest, so it must not be skipped as legacy.
     */
    private fun manifestPresent(directory: Path): Boolean {
        val names = SafeFiles.names(directory) ?: throw PackageException(PackageErrors.UNSAFE_FILE, "Package directory could not be verified.")
        val spellings = names.filter { it.lowercase(Locale.ROOT) == PackageManifests.FILE_NAME }
        if (spellings.any { it != PackageManifests.FILE_NAME }) throw PackageException(PackageErrors.INVALID_MANIFEST_CASE, "Use the exact file name widget.json.")
        return spellings.isNotEmpty()
    }

    private fun readManifest(files: DiskPackageFiles): JSONObject =
        files.readBytes(PackageManifests.FILE_NAME, PackageLimits.MAX_METADATA_BYTES.toLong())
            ?.let(SafeFiles::decodeUtf8)
            ?.let(PackageManifests::parse)
            ?: throw PackageException(PackageErrors.INVALID_MANIFEST, "widget.json is invalid.")

    private fun legacyManifest(name: String, files: DiskPackageFiles): JSONObject {
        val metadata = files.readBytes(PackageManifests.LEGACY_METADATA, PackageLimits.MAX_METADATA_BYTES.toLong())?.let(SafeFiles::decodeUtf8)
        return PackageManifests.legacyManifest(name, metadata)
    }

    private fun info(name: String, directory: Path): PackageInfo {
        val names = SafeFiles.names(directory).orEmpty()
        val hasManifest = names.any { it.lowercase(Locale.ROOT) == PackageManifests.FILE_NAME }
        val summary = if (PackageManifests.FILE_NAME in names) {
            DiskPackageFiles(directory.toFile()).readBytes(PackageManifests.FILE_NAME, PackageLimits.MAX_METADATA_BYTES.toLong())
                ?.let(SafeFiles::decodeUtf8)?.let(PackageManifests::parse)?.let(PackageManifests::summary)
        } else {
            null
        }
        return PackageInfo(name, directory.toFile(), hasManifest, summary?.id, summary?.name, summary?.version)
    }

    private companion object {
        val entryFile = Regex("\\.(js|jsx)$", RegexOption.IGNORE_CASE)
    }
}
