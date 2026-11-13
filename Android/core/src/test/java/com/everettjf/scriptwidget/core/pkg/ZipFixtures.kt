package com.everettjf.scriptwidget.core.pkg

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** One hand-written ZIP entry; every header field an attacker controls can be forged. */
class RawEntry(
    val name: String,
    val data: ByteArray = ByteArray(0),
    val externalAttributes: Long = 0x81A4L shl 16,
    val declaredSize: Long? = null,
    val declaredCompressedSize: Long? = null,
    val flags: Int = 0x0800,
    val method: Int = 0,
    val nameBytes: ByteArray? = null,
) {
    constructor(name: String, text: String) : this(name, text.toByteArray())
}

object ZipFixtures {
    /** Stored-entry ZIP written byte by byte, like `makeStoredZIP` in the Swift tests. */
    fun rawZip(vararg entries: RawEntry): ByteArray {
        val locals = ByteArrayOutputStream()
        val central = ByteArrayOutputStream()
        for (entry in entries) {
            val name = entry.nameBytes ?: entry.name.toByteArray()
            val crc = CRC32().apply { update(entry.data) }.value
            val size = entry.declaredSize ?: entry.data.size.toLong()
            val compressed = entry.declaredCompressedSize ?: entry.data.size.toLong()
            val offset = locals.size()
            val local = ByteBuffer.allocate(30).order(ByteOrder.LITTLE_ENDIAN)
            local.putInt(0x04034B50).putShort(20).putShort(entry.flags.toShort()).putShort(entry.method.toShort())
            local.putShort(0).putShort(0x21).putInt(crc.toInt()).putInt(compressed.toInt()).putInt(size.toInt())
            local.putShort(name.size.toShort()).putShort(0)
            locals.write(local.array())
            locals.write(name)
            locals.write(entry.data)
            val header = ByteBuffer.allocate(46).order(ByteOrder.LITTLE_ENDIAN)
            header.putInt(0x02014B50).putShort(0x031E).putShort(20).putShort(entry.flags.toShort()).putShort(entry.method.toShort())
            header.putShort(0).putShort(0x21).putInt(crc.toInt()).putInt(compressed.toInt()).putInt(size.toInt())
            header.putShort(name.size.toShort()).putShort(0).putShort(0).putShort(0).putShort(0)
            header.putInt(entry.externalAttributes.toInt()).putInt(offset)
            central.write(header.array())
            central.write(name)
        }
        val end = ByteBuffer.allocate(22).order(ByteOrder.LITTLE_ENDIAN)
        end.putInt(0x06054B50).putShort(0).putShort(0).putShort(entries.size.toShort()).putShort(entries.size.toShort())
        end.putInt(central.size()).putInt(locals.size()).putShort(0)
        return locals.toByteArray() + central.toByteArray() + end.array()
    }

    /** Deflated ZIP produced by the platform writer. */
    fun deflatedZip(files: Map<String, ByteArray>): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            for ((name, data) in files) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(data)
                zip.closeEntry()
            }
        }
        return output.toByteArray()
    }

    /** Overwrites the uncompressed size the central directory declares for entry [index]. */
    fun forgeDeclaredSize(archive: ByteArray, index: Int, size: Int): ByteArray {
        val bytes = archive.copyOf()
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var cursor = buffer.getInt(bytes.size - 22 + 16)
        repeat(index) { cursor += 46 + buffer.getShort(cursor + 28) + buffer.getShort(cursor + 30) + buffer.getShort(cursor + 32) }
        assertEquals(0x02014B50, buffer.getInt(cursor))
        buffer.putInt(cursor + 24, size)
        return bytes
    }

    fun packageZip(root: String = "Widget", name: String = root, extra: Map<String, String> = emptyMap()): ByteArray {
        val entries = arrayListOf(RawEntry("$root/widget.json", manifest(name)), RawEntry("$root/main.jsx", "\$render(<text>hi</text>);"))
        extra.forEach { (path, text) -> entries.add(RawEntry("$root/$path", text)) }
        return rawZip(*entries.toTypedArray())
    }

    fun manifest(name: String, id: String = "com.example.widget"): String =
        """{"formatVersion":2,"id":"$id","name":"$name","version":"1.2.3","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall"],"permissions":[],"networkDomains":[]}"""

    fun assertCode(code: String, block: () -> Unit) {
        try {
            block()
        } catch (error: PackageException) {
            assertEquals(error.message, code, error.code)
            return
        }
        fail("Expected PackageException($code)")
    }

    /** Relative paths of everything below [root], directories included, for "nothing left behind" checks. */
    fun tree(root: File): List<String> =
        root.walkTopDown().filter { it != root }.map { it.relativeTo(root).path + if (it.isDirectory) "/" else "" }.sorted().toList()
}
