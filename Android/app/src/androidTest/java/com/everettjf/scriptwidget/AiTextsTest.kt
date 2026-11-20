package com.everettjf.scriptwidget

import android.content.res.Configuration
import android.os.LocaleList
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.core.ai.AiConversationLimits
import com.everettjf.scriptwidget.core.ai.AiConversationUsageAdvice
import com.everettjf.scriptwidget.core.ai.AiExamplePrompts
import com.everettjf.scriptwidget.ui.exampleTitleResource
import com.everettjf.scriptwidget.ui.suggestedName
import com.everettjf.scriptwidget.ui.usageAdviceText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Locale

/**
 * The texts of the AI screens are string resources in English, the app's only language: they
 * read the same whatever the system language is, and the ones that used to be written in the
 * code read as they did there.
 */
@RunWith(AndroidJUnit4::class)
class AiTextsTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun resources(tag: String) = context.createConfigurationContext(
        Configuration(context.resources.configuration).apply { setLocales(LocaleList(Locale.forLanguageTag(tag))) },
    ).resources

    private val english = resources("en-US")

    @Test fun everyTextIsTheSameInEverySystemLanguage() {
        val names = R.string::class.java.fields.map { it.name }.filter { it.startsWith("ai_") || it.startsWith("name_dialog_") }
        assertTrue("${names.size} texts", names.size > 100)
        for (tag in listOf("en-GB", "zh-CN", "zh-Hans-SG", "zh-TW", "ja-JP", "fr-FR")) {
            val other = resources(tag)
            for (name in names) {
                val id = R.string::class.java.getField(name).getInt(null)
                assertEquals("$name on a $tag system", english.getString(id), other.getString(id))
            }
        }
    }

    @Test fun textsWithACountHaveASingular() {
        assertEquals("1 version", english.getString(R.string.ai_versions_one, 1))
        assertEquals("3 versions", english.getString(R.string.ai_versions_other, 3))
        assertEquals("Fixed automatically 1 time", english.getString(R.string.ai_fixed_one, 1))
        assertEquals("Fixed automatically 2 times", english.getString(R.string.ai_fixed_other, 2))
        assertEquals("Changes in version 3", english.getString(R.string.ai_changes_title, 3))
    }

    /** The AI settings, "Improve with AI" and the titles of the name dialog were literals in the code. */
    @Test fun theTextsMovedOutOfTheCodeReadAsTheyDidThere() {
        val unchanged = mapOf(
            R.string.ai_improve to "Improve with AI", R.string.name_dialog_new_widget to "New widget", R.string.name_dialog_rename to "Rename",
            R.string.name_dialog_label to "Name", R.string.name_dialog_ok to "OK", R.string.name_dialog_cancel to "Cancel",
            R.string.ai_settings_intro to "Widgets can be drafted by a model you choose. The Android app supports API-key providers only; signing in with an OpenAI account (OAuth) is not available.",
            R.string.ai_settings_base_url to "API base URL (https)", R.string.ai_settings_model to "Model", R.string.ai_settings_key to "API key",
            R.string.ai_settings_key_saved_placeholder to "Saved. Enter a new key to replace it", R.string.ai_settings_key_placeholder to "Paste the API key",
            R.string.ai_settings_key_note_changed to "The saved key belongs to the previous base URL and is removed when you save. Enter the key for this endpoint.",
            R.string.ai_settings_key_note_saved to "A key is saved, encrypted with the Android Keystore. It is never shown again, backed up, or added to widgets and prompts.",
            R.string.ai_settings_key_note_new to "The key is stored encrypted with the Android Keystore and only sent to the base URL above.",
            R.string.ai_settings_save to "Save", R.string.ai_settings_saved to "Saved.", R.string.ai_settings_key_not_stored to "The key could not be stored securely on this device.",
            R.string.ai_settings_test to "Test connection", R.string.ai_settings_testing to "Testing…", R.string.ai_settings_key_not_set to "API key is not set.",
            R.string.ai_settings_test_failed to "The connection test failed.", R.string.ai_settings_remove_key to "Remove key", R.string.ai_settings_key_removed to "Key removed.",
        )
        for ((id, text) in unchanged) assertEquals(text, english.getString(id))
        assertEquals("Connected. 12 models available; m is one of them.", english.getString(R.string.ai_settings_connected_listed, 12, "m"))
        assertEquals("Connected. 12 models available; m is not in the list, check the model name.", english.getString(R.string.ai_settings_connected_unlisted, 12, "m"))
        // The note says how many attempts a turn makes, from the limit itself; nothing in the settings changes it.
        val limit = AiConversationLimits.MAX_ATTEMPTS_PER_TURN
        assertTrue(english.getString(R.string.ai_settings_attempts_note, limit, limit - 1).startsWith("A request is tried at most 4 times: once, and up to 3 repairs"))
        assertEquals("It did not run. Fixing it, attempt 2 of 4…", english.getString(R.string.ai_activity_fixing, 2, limit))
    }

    /** The example chips, the notice above the request field and the offered name match what core says. */
    @Test fun textsThatMirrorCoreAreTheSameAsThere() {
        for (example in AiExamplePrompts.all) {
            val id = exampleTitleResource(example.title)
            assertNotNull("no text for the example ${example.title}", id)
            assertEquals(example.title, english.getString(id!!))
        }
        for (advice in listOf(
            AiConversationUsageAdvice(AiConversationUsageAdvice.Reason.HEAVY_REQUESTS, 31_250),
            AiConversationUsageAdvice(AiConversationUsageAdvice.Reason.HEAVY_TOTAL, 300_001),
            AiConversationUsageAdvice(AiConversationUsageAdvice.Reason.VERSIONS_FULL),
            AiConversationUsageAdvice(AiConversationUsageAdvice.Reason.HISTORY_FULL),
        )) assertEquals(advice.message, usageAdviceText(english, advice))
        assertEquals("AI Widget", suggestedName("", english.getString(R.string.ai_default_name)))
        assertEquals("AI Widget", suggestedName("?"))
        assertEquals("A red clock", suggestedName("a red clock. Make it big"))
    }
}
