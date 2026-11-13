package com.everettjf.scriptwidget.core.ai

import com.everettjf.scriptwidget.core.PlatformSupport
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Profile validation (`AISettings.swift`), prompts (`PromptBuilder.swift`) and output extraction. */
class AiProfileAndPromptTest {
    private fun custom(url: String, model: String = "m") = AiProfile(AiProviderKind.OPENAI_COMPATIBLE, url, model)

    @Test
    fun providerDefaults() {
        assertEquals("claude-fable-5-2", AiProviderKind.ANTHROPIC.defaultModel)
        assertEquals(listOf("claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"), AiProviderKind.ANTHROPIC.suggestedModels)
        assertEquals("https://api.anthropic.com", AiProviderKind.ANTHROPIC.defaultBaseUrl)
        assertEquals("https://api.openai.com", AiProviderKind.OPENAI.defaultBaseUrl)
        assertEquals("gpt-4o-mini", AiProviderKind.OPENAI.defaultModel)
        assertEquals(20, AiSettings.DEFAULT_MAX_ITERATIONS)
        assertEquals(0.7, AiSettings.DEFAULT_TEMPERATURE, 0.0)
        assertNull(AiProviderKind.fromId("oauth"))
        assertEquals(AiProviderKind.OPENAI_COMPATIBLE, AiProviderKind.fromId("custom"))
        for (kind in listOf(AiProviderKind.ANTHROPIC, AiProviderKind.OPENAI)) assertTrue(AiProfile.defaults(kind).isConfigured)
        assertFalse(AiProfile.defaults(AiProviderKind.OPENAI_COMPATIBLE).isConfigured)
    }

    @Test
    fun baseUrlIsNormalizedLikeSwift() {
        assertEquals("https://api.example.com", custom("  https://api.example.com/v1/  ").normalizedBaseUrl)
        assertEquals("https://api.example.com/proxy", custom("https://api.example.com/proxy///").normalizedBaseUrl)
        assertEquals("https://api.openai.com", AiProfile(AiProviderKind.OPENAI, "   ", "m").normalizedBaseUrl)
        assertEquals("", custom("").normalizedBaseUrl)
    }

    @Test
    fun onlyHttpsBaseUrlsAreAccepted() {
        val valid = listOf("https://api.example.com", "https://api.example.com:8443/openai/v1", "HTTPS://Example.com/", "https://192.0.2.10/v1", "https://[2001:db8::1]:8443")
        for (url in valid) assertNull(url, custom(url).validationError())
        val invalid = listOf(
            "", "   ", "http://api.example.com", "http://localhost:11434", "ftp://example.com", "api.example.com", "//example.com", "https://",
            "https:///path", "https://user:pass@example.com", "https://key@example.com", "https://example.com?key=1", "https://example.com/#frag",
            "https://example.com/v1/chat/completions", "https://example.com/v1/messages", "https://exa mple.com", "https://example.com/a/../b",
            "javascript:alert(1)", "file:///etc/passwd", "https://example.com\\@evil.com", "https://example.com\n.evil.com",
        )
        for (url in invalid) assertNotNull(url, custom(url).validationError())
        assertTrue(custom("http://example.com").validationError()!!.contains("https://"))
    }

    @Test
    fun modelIsRequired() {
        assertNotNull(custom("https://example.com", "").validationError())
        assertNotNull(custom("https://example.com", "  \t").validationError())
        assertNotNull(custom("https://example.com", "a\nb").validationError())
        assertNotNull(custom("https://example.com", "x".repeat(201)).validationError())
    }

    @Test
    fun systemPromptContainsRulesLimitsUnsupportedListAndReference() {
        val reference = AiReference.build(mapOf("text" to "<text>hi</text>"), mapOf("fetch" to "await fetch(url)"))
        val prompt = PromptBuilder.systemPrompt(reference)
        assertTrue(prompt.contains("Call \$render(<...>) exactly once"))
        assertTrue(prompt.contains("ScriptWidget for Android"))
        // Runtime limits.
        assertTrue(prompt.contains("RUNTIME LIMITS"))
        assertTrue(prompt.contains("within 5 seconds"))
        assertTrue(prompt.contains("64 MiB"))
        assertTrue(prompt.contains("at most 32 requests per run"))
        assertTrue(prompt.contains("2 MiB"))
        assertTrue(prompt.contains("1024 keys"))
        assertTrue(prompt.contains("512 KiB"))
        // Android unsupported list: every stub global and every PlatformSupport reason.
        assertTrue(prompt.contains("NOT SUPPORTED ON ANDROID"))
        for (global in AndroidPromptNotes.UNSUPPORTED_GLOBALS) assertTrue(global, prompt.contains(global))
        for (reason in PlatformSupport.unsupportedPermissions.values) assertTrue(reason, prompt.contains(reason))
        for (name in listOf("\$health", "\$location", "\$calendar", "\$icloud", "accessoryCircular", "\$dynamic_island", "backgroundMaterial", "Control Widgets")) assertTrue(name, prompt.contains(name))
        // Network declaration contract and the reference.
        assertTrue(prompt.contains("\"networkDomains\""))
        assertTrue(prompt.contains("=== COMPONENTS (JSX tags) ===\n// === text ===\n<text>hi</text>"))
        assertTrue(prompt.contains("=== APIs (globals) ===\n// === fetch ===\nawait fetch(url)"))
        // The prompt never tells the model to use what Android lacks.
        assertFalse(prompt.contains("requires permission `icloud`"))
    }

    @Test
    fun referenceIsSortedCappedAndSkipsAndroidUnsupportedExamples() {
        val long = (1..60).joinToString("\n") { "line $it" }
        val reference = AiReference.build(
            mapOf("zstack" to "z", "hstack" to long, "live-activity" to "LIVE"),
            mapOf("health" to "HEALTH", "location" to "LOCATION", "calendar" to "CALENDAR", "storage" to "s", "fetch" to "f"),
        )
        assertTrue(reference.componentsBlock.startsWith("// === hstack ===\nline 1\n"))
        assertTrue(reference.componentsBlock.contains("line 40\n// ...\n\n// === zstack ===\nz"))
        assertFalse(reference.componentsBlock.contains("line 41"))
        assertFalse(reference.combined.contains("LIVE"))
        for (excluded in listOf("HEALTH", "LOCATION", "CALENDAR")) assertFalse(reference.combined.contains(excluded))
        assertEquals("// === fetch ===\nf\n\n// === storage ===\ns", reference.apisBlock)
        assertEquals("", AiReference.EMPTY.combined)
    }

    @Test
    fun referenceFallsBackToPriorityApisWhenOverBudget() {
        val big = "x".repeat(AiReference.SOFT_CHARACTER_BUDGET)
        val reference = AiReference.build(mapOf("text" to big), mapOf("fetch" to "f", "usage-map" to "MAP", "animation" to "ANIM"))
        assertEquals("// === fetch ===\nf", reference.apisBlock)
    }

    @Test
    fun userPromptsCarryTheRequestSizeAndFailure() {
        val first = PromptBuilder.userPromptFirst("a clock", AiWidgetSize.SMALL)
        assertTrue(first.startsWith("Widget size: small\nSize hint: Square"))
        assertTrue(first.contains("User description:\na clock"))
        val fix = PromptBuilder.userPromptFix("CODE", "scriptError: x is not defined", (1..12).map { "[log] $it" })
        assertTrue(fix.contains("```jsx\nCODE\n```"))
        assertTrue(fix.contains("Runtime feedback:\nscriptError: x is not defined"))
        assertFalse(fix.contains("[log] 2\n"))
        assertTrue(fix.contains("[log] 3\n"))
        assertTrue(fix.contains("[log] 12"))
        assertTrue(PromptBuilder.userPromptFix("CODE", "e", emptyList()).contains("(no console output)"))
        val refine = PromptBuilder.userPromptRefine("OLD", "make it blue", """{"permissions":["network"],"networkDomains":["a.example.com"]}""", "scriptError: boom")
        assertTrue(refine.contains("```jsx\nOLD\n```"))
        assertTrue(refine.contains("a.example.com"))
        assertTrue(refine.contains("scriptError: boom"))
        assertTrue(refine.contains("Apply this change request from the user:\nmake it blue"))
        assertFalse(PromptBuilder.userPromptRefine("OLD", "x").contains("package declaration is"))
    }

    @Test
    fun skillsAreAppendedOnlyWhenPresent() {
        assertEquals("p", PromptBuilder.augmentWithSkills("p", null))
        assertEquals("p", PromptBuilder.augmentWithSkills("p", "  \n"))
        assertEquals("p\n\nApply these ScriptWidget skills:\n- Layout v1:\n  be tidy", PromptBuilder.augmentWithSkills("p", "- Layout v1:\n  be tidy\n"))
        assertTrue(PromptBuilder.augmentWithSkills("p", "s".repeat(200_000)).length < 70_000)
    }

    @Test
    fun examplePromptsAvoidUnsupportedApis() {
        assertTrue(AiExamplePrompts.all.size >= 5)
        for (example in AiExamplePrompts.all) for (global in AndroidPromptNotes.UNSUPPORTED_GLOBALS) assertFalse(example.title, example.prompt.contains(global))
        assertFalse(AiExamplePrompts.all.any { it.prompt.contains("device location") })
    }

    // MARK: - Extraction

    @Test
    fun stripCodeFencesMatchesSwift() {
        assertEquals("\$render(<vstack/>)", AiOutput.stripCodeFences("  \$render(<vstack/>)\n"))
        assertEquals("\$render(<vstack/>)", AiOutput.stripCodeFences("```jsx\n\$render(<vstack/>)\n```"))
        assertEquals("\$render(<vstack/>)", AiOutput.stripCodeFences("Here you go:\n```javascript\n\$render(<vstack/>)\n```\nEnjoy!"))
        assertEquals("first", AiOutput.stripCodeFences("```\nfirst\n```\n```\nsecond\n```"))
        // An unterminated fence: markers are dropped, content kept.
        assertEquals("\$render(<vstack/>)", AiOutput.stripCodeFences("```jsx\n\$render(<vstack/>)"))
        assertEquals("", AiOutput.stripCodeFences("   "))
    }

    @Test
    fun extractSeparatesCodeFromTheDeclaration() {
        val declaration = """{"permissions": ["network"], "networkDomains": ["api.example.com"]}"""
        val bare = AiOutput.extract("const a = await fetch(u);\n\$render(<vstack/>)\n\n```json\n$declaration\n```")
        assertEquals("const a = await fetch(u);\n\$render(<vstack/>)", bare.source)
        assertEquals(declaration, bare.manifestJson)
        val fenced = AiOutput.extract("```jsx\n\$render(<vstack/>)\n```\n\n```json\n$declaration\n```\n")
        assertEquals("\$render(<vstack/>)", fenced.source)
        assertEquals(declaration, fenced.manifestJson)
        val tagged = AiOutput.extract("```jsx\ncode\n```\n```widget.json\n$declaration\n```")
        assertEquals(declaration, tagged.manifestJson)
        val none = AiOutput.extract("```jsx\n\$render(<vstack/>)\n```")
        assertEquals("\$render(<vstack/>)", none.source)
        assertNull(none.manifestJson)
    }

    @Test
    fun extractDoesNotMistakeCodeForADeclaration() {
        // A jsx block is never a declaration, and neither is a fenced block that is not a JSON object.
        val objectLiteral = AiOutput.extract("```jsx\n{\"a\": 1}\n```")
        assertNull(objectLiteral.manifestJson)
        assertEquals("{\"a\": 1}", objectLiteral.source)
        val notJson = AiOutput.extract("```jsx\ncode\n```\n```json\nnot json\n```")
        assertNull(notJson.manifestJson)
        assertEquals("code", notJson.source)
        assertEquals("", AiOutput.extract("").source)
    }

    @Test
    fun candidateRoundTripsThroughTheAssistantMessage() {
        val candidate = AiCandidate("code", """{"permissions":["network"],"networkDomains":["a.example.com"]}""")
        val again = AiOutput.extract(candidate.asAssistantMessage())
        assertEquals(candidate.source, again.source)
        assertEquals(candidate.manifestJson, again.manifestJson)
        assertEquals("code", AiCandidate("code", null).asAssistantMessage())
    }

    @Test
    fun declarationAcceptsOnlyNetworkAndPublicHosts() {
        val parsed = AiManifestDeclaration.parse("""{"permissions":["network","network"],"networkDomains":["API.Example.com","*.example.org"]}""")
        assertEquals(listOf("network"), parsed.permissions)
        assertEquals(listOf("api.example.com", "*.example.org"), parsed.networkDomains)
        assertEquals("""{"permissions":["network"],"networkDomains":["api.example.com","*.example.org"]}""", parsed.toJson())
        val empty = AiManifestDeclaration.parse("{}")
        assertTrue(empty.permissions.isEmpty() && empty.networkDomains.isEmpty())

        val rejected = listOf(
            """[]""", """not json""",
            """{"permissions":["location"]}""", """{"permissions":["network","health"],"networkDomains":["a.example.com"]}""",
            """{"permissions":"network","networkDomains":["a.example.com"]}""", """{"permissions":[1],"networkDomains":["a.example.com"]}""",
            """{"permissions":["network"]}""", """{"permissions":["network"],"networkDomains":[]}""", """{"networkDomains":["a.example.com"]}""",
            """{"permissions":["network"],"networkDomains":["https://a.example.com"]}""", """{"permissions":["network"],"networkDomains":["a.example.com/path"]}""",
            """{"permissions":["network"],"networkDomains":["localhost"]}""", """{"permissions":["network"],"networkDomains":["127.0.0.1"]}""",
            """{"permissions":["network"],"networkDomains":["192.168.1.1"]}""", """{"permissions":["network"],"networkDomains":["printer.local"]}""",
            """{"permissions":["network"],"networkDomains":["*"]}""", """{"permissions":["network"],"networkDomains":["*.com"]}""".replace("*.com", "*."),
            """{"permissions":["network"],"networkDomains":["a.example.com"],"id":"evil"}""", """{"permissions":["network"],"networkDomains":["a.example.com"],"entry":"x.jsx"}""",
            """{"permissions":["network"],"networkDomains":[${(1..17).joinToString(",") { "\"h$it.example.com\"" }}]}""",
        )
        for (json in rejected) {
            try { AiManifestDeclaration.parse(json); fail("accepted $json") } catch (expected: IllegalArgumentException) { assertFalse(expected.message.isNullOrEmpty()) }
        }
    }

    @Test
    fun declarationOnlyChangesNetworkFieldsOfAManifest() {
        val base = JSONObject("""{"formatVersion":2,"id":"local.x","name":"N","entry":"main.jsx","permissions":["network","storage"],"networkDomains":["old.example.com"]}""")
        val applied = AiManifestDeclaration.parse("""{"permissions":["network"],"networkDomains":["new.example.com"]}""").applyTo(base)
        assertEquals("local.x", applied.getString("id"))
        assertEquals("main.jsx", applied.getString("entry"))
        assertEquals("""["storage","network"]""", applied.getJSONArray("permissions").toString())
        assertEquals("""["new.example.com"]""", applied.getJSONArray("networkDomains").toString())
        // Removing network keeps other permissions and leaves the base untouched.
        val removed = AiManifestDeclaration.parse("{}").applyTo(base)
        assertEquals("""["storage"]""", removed.getJSONArray("permissions").toString())
        assertEquals("""[]""", removed.getJSONArray("networkDomains").toString())
        assertEquals("""["old.example.com"]""", base.getJSONArray("networkDomains").toString())

        assertNull(AiManifestDeclaration.fromManifest(null))
        assertNull(AiManifestDeclaration.fromManifest(JSONObject("""{"permissions":["storage"]}""")))
        assertEquals(listOf("old.example.com"), AiManifestDeclaration.fromManifest(base)!!.networkDomains)
    }

    @Test
    fun candidateManifestGrantsNothingByDefault() {
        val fresh = JSONObject(AiManifests.text(null, null, "My Widget"))
        assertEquals("My Widget", fresh.getString("name"))
        assertEquals(2, fresh.getInt("formatVersion"))
        assertEquals("main.jsx", AiManifests.entry(fresh))
        assertEquals(0, fresh.getJSONArray("permissions").length())
        assertEquals(0, fresh.getJSONArray("networkDomains").length())
        val network = JSONObject(AiManifests.text(null, """{"permissions":["network"],"networkDomains":["a.example.com"]}""", "W"))
        assertEquals("""["network"]""", network.getJSONArray("permissions").toString())
        assertEquals("""["a.example.com"]""", network.getJSONArray("networkDomains").toString())
        // An invalid declaration never widens a manifest.
        val invalid = JSONObject(AiManifests.text(null, """{"permissions":["network","health"],"networkDomains":["a.example.com"]}""", "W"))
        assertEquals(0, invalid.getJSONArray("permissions").length())
        // Improving keeps the installed manifest, including its entry and identity.
        val base = JSONObject("""{"formatVersion":2,"id":"local.keep","name":"Old","entry":"src/app.jsx","permissions":[],"networkDomains":[]}""")
        val kept = JSONObject(AiManifests.text(base, null, "ignored"))
        assertEquals("local.keep", kept.getString("id"))
        assertEquals("src/app.jsx", AiManifests.entry(kept))
        assertEquals("main.jsx", AiManifests.entry(null))
        assertEquals("main.jsx", AiManifests.entry(JSONObject("""{"entry":5}""")))
        assertNull(AiManifests.parse("[]"))
    }

    @Test
    fun executionResultsAreJudgedLikeSwift() {
        val tree = """{"${'$'}element":"vstack","props":{},"children":[{"${'$'}element":"text","children":["hi"]}]}"""
        assertTrue(ValidationResult.fromExecution(tree, null, null, listOf("[log] ok")).ok)
        val error = ValidationResult.fromExecution(null, "scriptError", "x is not defined", listOf("[log] a"))
        assertFalse(error.ok)
        assertEquals("scriptError: x is not defined", error.errorSummary)
        assertEquals(listOf("[log] a"), error.logs)
        assertEquals("Runtime returned no element.", ValidationResult.fromExecution(null, null, null, emptyList()).errorSummary)
        assertEquals("Runtime returned no element.", ValidationResult.fromExecution("not json", null, null, emptyList()).errorSummary)
        val sentinel = """{"${'$'}element":"text","children":["#UI Not Found#"]}"""
        assertTrue(ValidationResult.fromExecution(sentinel, null, null, emptyList()).errorSummary!!.contains("fallback/placeholder"))
        assertFalse(ValidationResult.fromExecution(tree, null, null, listOf("[error] fetch failed")).ok)
        assertFalse(ValidationResult.fromExecution(tree, null, null, listOf("[log] Uncaught TypeError")).ok)
    }
}
