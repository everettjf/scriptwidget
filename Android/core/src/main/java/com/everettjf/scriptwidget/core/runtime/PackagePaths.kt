package com.everettjf.scriptwidget.core.runtime

/** Package-relative path handling, mirroring `normalizePackagePath` in the shared engine. */
object PackagePaths {
    /** Returns the normalized relative path, or null when it could leave the package. */
    fun normalize(relativePath: String?): String? {
        if (relativePath.isNullOrEmpty() || relativePath.startsWith("/")) return null
        if (relativePath.contains('\\') || relativePath.contains('\u0000')) return null
        val parts = ArrayList<String>()
        for (part in relativePath.split('/')) {
            when (part) {
                "", "." -> continue
                ".." -> if (parts.isEmpty()) return null else parts.removeAt(parts.size - 1)
                else -> parts.add(part)
            }
        }
        return if (parts.isEmpty()) null else parts.joinToString("/")
    }
}

/** Read-only view of one installed package. Paths are already normalized. */
interface PackageFiles {
    fun paths(): List<String>
    fun exists(path: String): Boolean
    /** UTF-8 text of a script or data file, or null for missing and binary files. */
    fun readText(path: String): String?
    fun readBytes(path: String): ByteArray?
}

class MemoryPackageFiles(private val text: Map<String, String>, private val binary: Map<String, ByteArray> = emptyMap()) : PackageFiles {
    override fun paths(): List<String> = (text.keys + binary.keys).sorted()
    override fun exists(path: String): Boolean = text.containsKey(path) || binary.containsKey(path)
    override fun readText(path: String): String? = text[path]
    override fun readBytes(path: String): ByteArray? = binary[path] ?: text[path]?.toByteArray()
}
