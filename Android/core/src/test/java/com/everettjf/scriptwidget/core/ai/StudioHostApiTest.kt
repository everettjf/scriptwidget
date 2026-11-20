package com.everettjf.scriptwidget.core.ai

import com.everettjf.scriptwidget.core.api.ThemeColors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The code editor learns what only Android has from `android-bridge.js` in the app's assets:
 * the `material.<role>` colors and the attributes of `<list>`. That file is JavaScript the
 * WebView loads, so it cannot read the Kotlin lists; this keeps the two the same.
 */
class StudioHostApiTest {
    private val bridge: String = generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
        .map { File(it, "app/src/main/assets/studio/android-bridge.js") }
        .first { it.isFile }
        .readText()

    private fun strings(text: String): List<String> = Regex("\"([^\"]*)\"").findAll(text).map { it.groupValues[1] }.toList()

    @Test fun theMaterialRolesAreThoseOfThemeColorsInTheSameOrder() {
        val list = Regex("var materialRoles = \\[([^\\]]*)\\];").find(bridge)!!.groupValues[1]
        assertEquals(ThemeColors.roleNames, strings(list))
        // The names are completed as "material.<role>", the form the renderer reads.
        assertTrue(bridge.contains("colors: materialRoles.map(function (role) { return \"material.\" + role; })"))
    }

    @Test fun theListAttributesAreThoseTheCodeCheckKnows() {
        val line = AiJsxSurfaceData.TEXT.lines().single { it.startsWith("tag@android list") }
        val block = Regex("var listAttributes = \\{(.*?)\\n  \\};", RegexOption.DOT_MATCHES_ALL).find(bridge)!!.groupValues[1]
        val names = Regex("^\\s*\"([A-Za-z]+)\": \\{", RegexOption.MULTILINE).findAll(block).map { it.groupValues[1] }.toList()
        assertEquals(line.split(" ").drop(2).map { it.substringBefore("=") }, names)
        // <list> is the only tag Android adds; another one needs an entry in the bridge too.
        assertEquals(listOf("list"), AiJsxSurfaceData.TEXT.lines().filter { it.startsWith("tag@android ") }.map { it.split(" ")[1] })
        assertTrue(Regex("components: \\{\\s*list: \\{").containsMatchIn(bridge))
    }
}
