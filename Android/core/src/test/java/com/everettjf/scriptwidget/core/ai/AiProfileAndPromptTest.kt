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
        // Android unsupported list: every PlatformSupport reason, and the names a candidate is searched for.
        assertTrue(prompt.contains("NOT SUPPORTED ON ANDROID"))
        for (reason in PlatformSupport.unsupportedGlobals.values) assertTrue(reason, prompt.contains(reason))
        for (reason in PlatformSupport.unsupportedPermissions.values) assertTrue(reason, prompt.contains(reason))
        for (reason in PlatformSupport.unsupportedSourceMarkers.values) assertTrue(reason, prompt.contains(reason))
        for (name in PlatformSupport.unsupportedSourceMarkers.keys + PlatformSupport.unsupportedFamilies + PlatformSupport.unsupportedGlobals.keys) assertTrue(name, unsupportedSection(prompt).contains(name))
        // Network declaration contract and the reference.
        assertTrue(prompt.contains("\"networkDomains\""))
        assertTrue(prompt.contains("=== COMPONENTS (JSX tags) ===\n// === text ===\n<text>hi</text>"))
        assertTrue(prompt.contains("=== APIs (globals) ===\n// === fetch ===\nawait fetch(url)"))
        // The prompt never tells the model to use what Android lacks.
        assertFalse(prompt.contains("requires permission `icloud`"))
    }

    /** The part of the prompt that says what Android cannot do. */
    private fun unsupportedSection(prompt: String): String {
        val start = prompt.indexOf("NOT SUPPORTED ON ANDROID")
        val end = prompt.indexOf("SYSTEM DATA ON ANDROID")
        assertTrue(start in 0 until end)
        return prompt.substring(start, end)
    }

    /** The globals of the shared contract that may be missing on a platform: the names in the stub table of android-apis.js. */
    private fun contractGlobals(): Set<String> {
        val source = java.io.File("src/main/js/android-apis.js").readText()
        val table = source.substring(source.indexOf("const groups = {"), source.indexOf("for (const name of Object.keys(groups))"))
        return Regex("""^\s{4}(\$[A-Za-z_]+): \{""", RegexOption.MULTILINE).findAll(table).map { it.groupValues[1] }.toSet()
    }

    /**
     * The globals a native module implements (`override val apis` of the modules in `core/system`
     * and `core/plugin`). `AiLoopOnDeviceTest.thePromptOnTheDeviceNamesNoRegisteredModuleAsUnsupported`
     * checks the modules the app really registers on a device.
     */
    private val implemented = setOf(
        "\$health", "\$music", "\$photos", "\$calendar", "\$location", "\$services", "\$icloud", "\$notifications",
        "\$alarms", "\$documents", "\$contacts", "\$maps", "\$weather", "\$dataSource",
    )

    /** [global] named as a whole, not as the owner of one method: `$maps` but not `$maps.snapshot`. */
    private fun names(text: String, global: String) = Regex(Regex.escape(global) + """(?![A-Za-z0-9_.])""").containsMatchIn(text)

    @Test
    fun thePromptNeverNamesASupportedApiAsUnsupported() {
        // Every global of the contract is either implemented or in PlatformSupport, never both and never neither.
        assertEquals(contractGlobals(), implemented + PlatformSupport.unsupportedGlobals.keys)
        assertTrue((implemented intersect PlatformSupport.unsupportedGlobals.keys).isEmpty())

        val section = unsupportedSection(PromptBuilder.systemPrompt(AiReference.EMPTY))
        for (global in implemented) {
            assertFalse("$global is implemented and must not be listed as unsupported", names(section, global))
            for (line in AndroidPromptNotes.unsupportedLines()) assertFalse("$global in: $line", names(line, global))
        }
        // The one method that is missing is named with its method.
        assertTrue(section.contains("\$maps.snapshot"))
        // The words that used to say it: no sentence anywhere tells the model that a supported global fails.
        val prompt = PromptBuilder.systemPrompt(AiReference.EMPTY)
        assertFalse(prompt.contains("not implemented and every call fails"))
        for (reason in PlatformSupport.unsupportedGlobals.values) assertTrue(reason, section.contains(reason))
    }

    @Test
    fun thePromptSaysWhatDiffersForTheSystemDataThatWorks() {
        val prompt = PromptBuilder.systemPrompt(AiReference.EMPTY)
        val start = prompt.indexOf("SYSTEM DATA ON ANDROID")
        val section = prompt.substring(start, prompt.indexOf("ONLY ON ANDROID"))
        // Every implemented global is named where the model is told it works.
        for (global in implemented) assertTrue(global, section.contains(global))
        // The differences docs/android/README.md states under "System data", where a model needs them.
        for (words in listOf("only photos the user picked", "no albums", "GitHub token", "no sign-in", "Health Connect", "calendars the user selected", "saved position", "androidMediaSession", "not business categories", "sync folder", "about ten minutes late")) {
            assertTrue(words, section.contains(words))
        }
        // The calls the capped examples of the reference do not reach.
        assertTrue(section.contains("\$health.stepCountToday()") && section.contains("\$location.current("))
        // A conversation cannot declare these permissions, so the model must write the setup state.
        assertTrue(section.contains("you cannot declare"))
        assertTrue(section.contains("try/catch"))
        assertFalse(names(section, "\$reminders") || names(section, "\$home"))
        // Rule 7 lets the model use what this section names.
        assertTrue(prompt.contains("section or under SYSTEM DATA below"))
        // The prompt is already long: this section stays about 400 tokens.
        assertTrue("${section.length} characters", section.length < 1_800)
    }

    @Test
    fun aRepairSendsOnlyTheStartOfEachOfTheLastTenConsoleLines() {
        val long = "[log] " + "x".repeat(400)
        val fix = PromptBuilder.userPromptFix("CODE", "scriptError: boom", (1..11).map { "[log] line $it" } + long)
        assertFalse(fix.contains("[log] line 2\n"))
        assertTrue(fix.contains("[log] line 3\n"))
        // 300 characters of the line, then the mark that it was cut, as PromptBuilder.swift does.
        assertTrue(fix.contains("\n" + long.take(PromptBuilder.MAXIMUM_LOG_LINE_CHARACTERS) + "…\n"))
        assertFalse(fix.contains("x".repeat(PromptBuilder.MAXIMUM_LOG_LINE_CHARACTERS)))
        assertEquals(300, PromptBuilder.MAXIMUM_LOG_LINE_CHARACTERS)
        // A line of exactly 300 characters is sent whole.
        val exact = "y".repeat(300)
        assertTrue(PromptBuilder.userPromptFix("CODE", "e", listOf(exact)).contains("\n$exact\n"))
    }

    @Test
    fun aRuntimeDiagnosticCarriesTheErrorAndTheEndsOfTheLastConsoleLines() {
        assertEquals("scriptError: boom", PromptBuilder.runtimeDiagnostic("scriptError: boom", emptyList()))
        val long = "[log] " + "z".repeat(400)
        val text = PromptBuilder.runtimeDiagnostic("scriptError: boom", (1..11).map { "[log] line $it" } + long)
        assertTrue(text.startsWith("scriptError: boom\nLast console output:\n[log] line 3\n"))
        assertFalse(text.contains("[log] line 2\n"))
        assertTrue(text.endsWith(long.take(300) + "…"))
        // It reaches the model inside the turn, cut to 2,000 characters.
        val turn = PromptBuilder.userPromptTurn(AiTurnContext(emptyList(), "CODE", null, "fix it", null, AiWidgetSize.SMALL, runtimeDiagnostic = PromptBuilder.runtimeDiagnostic("e".repeat(3_000), listOf("[log] tail"))))
        assertTrue(turn.contains("The latest local ScriptWidget runtime diagnostic is:\n" + "e".repeat(2_000) + "…"))
        assertFalse(turn.contains("[log] tail"))
    }

    @Test
    fun systemPromptDescribesTheListAndTheWallpaperColorsBriefly() {
        val prompt = PromptBuilder.systemPrompt(AiReference.EMPTY)
        val start = prompt.indexOf("ONLY ON ANDROID")
        assertTrue(start > prompt.indexOf("NOT SUPPORTED ON ANDROID"))
        val section = prompt.substring(start)
        assertTrue(section.contains("<list spacing=\"4\">"))
        assertTrue(section.contains("at most 100 rows"))
        assertTrue(section.contains("\"material.<role>\""))
        assertTrue(section.contains("background=\"material.surfaceContainer\" with color=\"material.onSurface\""))
        // What the section shows is what the code check accepts on Android.
        assertEquals(emptyList<String>(), AiJsxCheck.problems("\$render(<vstack background=\"material.surfaceContainer\"><list spacing=\"4\"><text color=\"material.onSurface\">a</text></list></vstack>)", AiJsxCheck.ANDROID))
        // Every role is either named or covered by one of the two short forms.
        val named = setOf("primary", "onPrimary", "primaryContainer", "onPrimaryContainer", "background", "onBackground", "surface", "onSurface", "surfaceVariant", "onSurfaceVariant", "surfaceContainer", "outline", "outlineVariant")
        for (role in named) assertTrue(role, Regex("\\b$role\\b").containsMatchIn(section))
        val expanded = named + listOf("secondary", "tertiary").flatMap { family ->
            val capital = family.replaceFirstChar { it.uppercase() }
            listOf(family, "on$capital", "${family}Container", "on${capital}Container")
        } +
            listOf("Lowest", "Low", "High", "Highest").map { "surfaceContainer$it" }
        assertEquals(com.everettjf.scriptwidget.core.api.ThemeColors.roleNames.toSet(), expanded.toSet())
        // The prompt is already long; this section must stay small (about 250 tokens).
        assertTrue("${section.length} characters", section.length < 1_100)
    }

    @Test
    fun referenceIsSortedCappedAndSkipsAndroidUnsupportedExamples() {
        val long = (1..60).joinToString("\n") { "line $it" }
        val reference = AiReference.build(
            mapOf("zstack" to "z", "hstack" to long, "live-activity" to "LIVE"),
            mapOf("reminders" to "REMINDERS", "home" to "HOME", "storage" to "s", "fetch" to "f"),
        )
        assertTrue(reference.componentsBlock.startsWith("// === hstack ===\nline 1\n"))
        assertTrue(reference.componentsBlock.contains("line 40\n// ...\n\n// === zstack ===\nz"))
        assertFalse(reference.componentsBlock.contains("line 41"))
        assertFalse(reference.combined.contains("LIVE"))
        for (excluded in listOf("REMINDERS", "HOME")) assertFalse(reference.combined.contains(excluded))
        assertEquals("// === fetch ===\nf\n\n// === storage ===\ns", reference.apisBlock)
        assertEquals("", AiReference.EMPTY.combined)
        // Only what PlatformSupport lists is left out.
        assertEquals(setOf("reminders", "home"), AiReference.ANDROID_EXCLUDED_APIS)
    }

    @Test
    fun referenceShowsTheExamplesOfTheSystemDataAndroidImplements() {
        val reference = AiReference.build(emptyMap(), mapOf("health" to "HEALTH", "location" to "LOCATION", "calendar" to "CALENDAR", "fetch" to "f"))
        assertEquals("// === calendar ===\nCALENDAR\n\n// === fetch ===\nf\n\n// === health ===\nHEALTH\n\n// === location ===\nLOCATION", reference.apisBlock)
        // They are also the ones kept when the reference is over its budget.
        val big = AiReference.build(mapOf("text" to "x".repeat(AiReference.SOFT_CHARACTER_BUDGET)), mapOf("health" to "HEALTH", "location" to "LOCATION", "calendar" to "CALENDAR", "usage-map" to "MAP"))
        assertEquals("// === calendar ===\nCALENDAR\n\n// === health ===\nHEALTH\n\n// === location ===\nLOCATION", big.apisBlock)
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
        for (example in AiExamplePrompts.all) for (global in PlatformSupport.unsupportedGlobals.keys) assertFalse(example.title, example.prompt.contains(global))
        assertFalse(AiExamplePrompts.all.any { it.prompt.contains("device location") })
        // The Steps example of the Apple apps is back: $health is implemented through Health Connect.
        val steps = AiExamplePrompts.all.single { it.title == "Steps" }
        assertEquals(AiWidgetSize.SMALL, steps.size)
        assertTrue(steps.prompt.contains("step count from \$health"))
        assertEquals(listOf("Weather", "Clock", "Countdown", "Crypto Price", "Battery Ring", "Quote", "Steps", "Habit Grid"), AiExamplePrompts.all.map { it.title })
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
            """{"permissions":["network"],"networkDomains":[${(1..9).joinToString(",") { "\"h$it.example.com\"" }}]}""",
        )
        for (json in rejected) {
            try { AiManifestDeclaration.parse(json); fail("accepted $json") } catch (expected: IllegalArgumentException) { assertFalse(expected.message.isNullOrEmpty()) }
        }
    }

    @Test
    fun declarationLimitsAndFailureTextsAreTheOnesOfTheAppleApps() {
        fun hosts(count: Int) = """{"permissions":["network"],"networkDomains":[${(1..count).joinToString(",") { "\"h$it.example.com\"" }}]}"""
        fun refusal(json: String): String = try { AiManifestDeclaration.parse(json); fail("accepted $json"); "" } catch (expected: IllegalArgumentException) { AiManifestDeclaration.failureText(expected.message!!) }

        // AINetworkDeclaration.maximumDomains: 8 hosts pass, 9 do not.
        assertEquals(8, AiManifestDeclaration.MAXIMUM_DOMAINS)
        assertEquals(8, AiManifestDeclaration.parse(hosts(8)).networkDomains.size)
        assertEquals("The network declaration block is not valid: \"networkDomains\" must list 1 to 8 hosts.", refusal(hosts(9)))
        assertEquals("The network declaration block is not valid: \"networkDomains\" must list 1 to 8 hosts.", refusal("""{"permissions":["network"],"networkDomains":[]}"""))

        // 4,096 bytes of UTF-8 pass, one more does not; Swift calls both that and unreadable text "not a JSON object".
        assertEquals(4_096, AiManifestDeclaration.MAXIMUM_BYTES)
        val small = """{"permissions":["network"],"networkDomains":["a.example.com"]}"""
        val atLimit = small + " ".repeat(4_096 - small.length)
        assertEquals(4_096, atLimit.toByteArray().size)
        assertEquals(listOf("a.example.com"), AiManifestDeclaration.parse(atLimit).networkDomains)
        assertEquals("The network declaration block is not valid: it is not a JSON object.", refusal("$atLimit "))
        assertEquals("The network declaration block is not valid: it is not a JSON object.", refusal("not json"))
        // Bytes, not characters: 2,000 characters of two and three bytes are over the limit.
        assertEquals("The network declaration block is not valid: it is not a JSON object.", refusal("""{"permissions":["network"],"networkDomains":["a.example.com"],"x":"${"é€".repeat(1_000)}"}"""))

        assertEquals("The network declaration block is not valid: only \"permissions\" and \"networkDomains\" may appear.", refusal("""{"permissions":["network"],"networkDomains":["a.example.com"],"id":"evil"}"""))
        val onlyNetwork = "The network declaration block is not valid: \"permissions\" must be exactly [\"network\"]; no other permission can be declared."
        assertEquals(onlyNetwork, refusal("""{"permissions":["location"]}"""))
        assertEquals(onlyNetwork, refusal("""{"networkDomains":["a.example.com"]}"""))
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
