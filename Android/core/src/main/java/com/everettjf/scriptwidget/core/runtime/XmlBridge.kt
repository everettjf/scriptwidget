package com.everettjf.scriptwidget.core.runtime

import org.json.JSONArray
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.StringReader

/**
 * Bounded XML parser behind `$xml.parse`, with the limits and output shape of
 * ScriptWidgetXMLParser: {name, attributes, text, children}. DTDs and entity
 * declarations are rejected and external entities are never resolved.
 */
object XmlBridge {
    private const val MAXIMUM_BYTES = 256 * 1024
    private const val MAXIMUM_ELEMENTS = 2048
    private const val MAXIMUM_DEPTH = 32

    private class Node(val name: String, val attributes: JSONObject) {
        val text = StringBuilder()
        val children = JSONArray()
        fun json(): JSONObject = JSONObject().put("name", name).put("attributes", attributes).put("text", text.toString()).put("children", children)
    }

    fun parse(source: String): String = try {
        JSONObject().put("ok", true).put("value", parseDocument(source)).toString()
    } catch (error: Exception) {
        JSONObject().put("ok", false).put("error", error.message ?: "Invalid XML").toString()
    }

    private fun parseDocument(source: String): JSONObject {
        if (source.toByteArray().size > MAXIMUM_BYTES) throw IllegalArgumentException("XML exceeds the $MAXIMUM_BYTES-byte limit")
        if (Regex("<!\\s*(DOCTYPE|ENTITY)", RegexOption.IGNORE_CASE).containsMatchIn(source)) {
            throw IllegalArgumentException("XML document type and entity declarations are not allowed")
        }
        val parser = XmlPullParserFactory.newInstance().apply { isNamespaceAware = false }.newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
        parser.setInput(StringReader(source))
        val stack = ArrayDeque<Node>()
        var root: Node? = null
        var elements = 0
        var textBytes = 0
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> {
                    elements += 1
                    if (elements > MAXIMUM_ELEMENTS) throw IllegalArgumentException("XML exceeds the $MAXIMUM_ELEMENTS-element limit")
                    if (stack.size >= MAXIMUM_DEPTH) throw IllegalArgumentException("XML exceeds the $MAXIMUM_DEPTH-level depth limit")
                    val attributes = JSONObject()
                    for (index in 0 until parser.attributeCount) attributes.put(parser.getAttributeName(index), parser.getAttributeValue(index))
                    val node = Node(parser.name, attributes)
                    if (stack.isEmpty()) {
                        if (root != null) throw IllegalArgumentException("XML has more than one root element")
                        root = node
                    }
                    stack.addLast(node)
                }
                XmlPullParser.TEXT, XmlPullParser.CDSECT -> {
                    val text = parser.text.orEmpty()
                    textBytes += text.toByteArray().size
                    if (textBytes > MAXIMUM_BYTES) throw IllegalArgumentException("XML text exceeds the $MAXIMUM_BYTES-byte limit")
                    stack.lastOrNull()?.text?.append(text)
                }
                XmlPullParser.ENTITY_REF -> throw IllegalArgumentException("XML entity references are not allowed")
                XmlPullParser.DOCDECL -> throw IllegalArgumentException("XML document type declarations are not allowed")
                XmlPullParser.END_TAG -> {
                    val node = stack.removeLast()
                    stack.lastOrNull()?.children?.put(node.json())
                }
            }
            event = parser.nextToken()
        }
        return (root ?: throw IllegalArgumentException("XML has no root element")).json()
    }
}
