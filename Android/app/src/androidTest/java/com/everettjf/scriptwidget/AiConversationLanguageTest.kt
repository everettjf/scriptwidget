package com.everettjf.scriptwidget

import android.content.res.Configuration
import android.os.LocaleList
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Locale

/**
 * The texts of the AI conversation follow the system language when it is English or
 * Simplified Chinese, and are English for every other language. Texts with a count are
 * not Android plurals, which would follow the system language's rules and make the
 * English fallback read "1 versions" on a Japanese phone.
 */
@RunWith(AndroidJUnit4::class)
class AiConversationLanguageTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun resources(vararg tags: String) = context.createConfigurationContext(
        Configuration(context.resources.configuration).apply { setLocales(LocaleList(*tags.map { Locale.forLanguageTag(it) }.toTypedArray())) },
    ).resources

    @Test fun simplifiedChineseIsUsedForChineseInTheSimplifiedScript() {
        for (tag in listOf("zh-CN", "zh-Hans-CN", "zh-Hans-SG", "zh-SG")) {
            val resources = resources(tag)
            assertEquals(tag, "保存小组件", resources.getString(R.string.ai_save_widget))
            assertEquals(tag, "版本 3 的改动", resources.getString(R.string.ai_changes_title, 3))
            assertEquals(tag, "1 个版本", resources.getString(R.string.ai_versions_one, 1))
            assertEquals(tag, "已自动修复 2 次", resources.getString(R.string.ai_fixed_other, 2))
        }
    }

    @Test fun everyOtherLanguageGetsEnglish() {
        for (tag in listOf("en-US", "en-GB", "fr-FR", "ja-JP", "zh-TW", "zh-Hant-HK")) {
            val resources = resources(tag)
            assertEquals(tag, "Save widget", resources.getString(R.string.ai_save_widget))
            assertEquals(tag, "Changes in version 3", resources.getString(R.string.ai_changes_title, 3))
            assertEquals(tag, "1 version", resources.getString(R.string.ai_versions_one, 1))
            assertEquals(tag, "Fixed automatically 2 times", resources.getString(R.string.ai_fixed_other, 2))
        }
    }
}
