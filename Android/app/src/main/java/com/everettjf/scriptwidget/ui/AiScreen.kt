package com.everettjf.scriptwidget.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.everettjf.scriptwidget.R
import com.everettjf.scriptwidget.ai.AiServices
import com.everettjf.scriptwidget.core.ai.AiClient
import com.everettjf.scriptwidget.core.ai.AiClientException
import com.everettjf.scriptwidget.core.ai.AiConversationLimits
import com.everettjf.scriptwidget.core.ai.AiProfile
import com.everettjf.scriptwidget.core.ai.AiProviderKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * AI provider settings: provider, base URL, model, API key and a connection test. Shown inside
 * the Settings screen. Its own texts are in `strings_ai.xml`; what the provider profile and the
 * client report (a base URL that is not https, a refused key) comes from core.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AiSettings() {
    val context = LocalContext.current
    val store = remember { AiServices.settings(context) }
    val credentials = remember { AiServices.credentials(context) }
    val scope = rememberCoroutineScope()
    var kind by remember { mutableStateOf(store.activeKind) }
    var baseUrl by remember(kind) { mutableStateOf(store.profile(kind).baseUrl) }
    var modelName by remember(kind) { mutableStateOf(store.profile(kind).model) }
    // The typed key lives only in this field until it is saved; a stored key is never read back into the UI.
    var typedKey by remember(kind) { mutableStateOf("") }
    var keyStored by remember(kind) { mutableStateOf(false) }
    var status by remember(kind) { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(kind) { keyStored = withContext(Dispatchers.IO) { credentials.has(kind.id) } }

    val draft = AiProfile(kind, baseUrl, modelName)
    val problem = draft.validationError()
    val endpointChanged = draft.normalizedBaseUrl != store.profile(kind).normalizedBaseUrl

    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.ai_settings_intro),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (option in AiProviderKind.entries) FilterChip(selected = kind == option, onClick = { kind = option; store.activeKind = option }, label = { Text(option.displayName) })
        }
        OutlinedTextField(
            baseUrl, { baseUrl = it.take(AiProfile.MAXIMUM_BASE_URL_LENGTH); status = null }, singleLine = true, label = { Text(stringResource(R.string.ai_settings_base_url)) },
            placeholder = { Text(kind.defaultBaseUrl.ifEmpty { "https://example.com" }) }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            modelName, { modelName = it.take(AiProfile.MAXIMUM_MODEL_LENGTH); status = null }, singleLine = true, label = { Text(stringResource(R.string.ai_settings_model)) },
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false), modifier = Modifier.fillMaxWidth(),
        )
        if (kind.suggestedModels.size > 1) FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (suggestion in kind.suggestedModels) AssistChip(onClick = { modelName = suggestion; status = null }, label = { Text(suggestion) })
        }
        OutlinedTextField(
            typedKey, { typedKey = it.take(4096); status = null }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
            label = { Text(stringResource(R.string.ai_settings_key)) }, placeholder = { Text(stringResource(if (keyStored && !endpointChanged) R.string.ai_settings_key_saved_placeholder else R.string.ai_settings_key_placeholder)) },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false), modifier = Modifier.fillMaxWidth(),
        )
        Text(
            stringResource(when {
                endpointChanged && keyStored && typedKey.isBlank() -> R.string.ai_settings_key_note_changed
                keyStored -> R.string.ai_settings_key_note_saved
                else -> R.string.ai_settings_key_note_new
            }),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (problem != null && (baseUrl.isNotBlank() || modelName.isNotBlank())) Text(problem, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(enabled = !busy && problem == null, onClick = {
                busy = true
                val key = typedKey
                scope.launch {
                    val stored = withContext(Dispatchers.IO) { store.save(draft, key.takeIf { it.isNotBlank() }) to credentials.has(kind.id) }
                    busy = false; typedKey = ""; keyStored = stored.second
                    status = context.getString(if (stored.first) R.string.ai_settings_saved else R.string.ai_settings_key_not_stored)
                }
            }) { Text(stringResource(R.string.ai_settings_save)) }
            OutlinedButton(enabled = !busy && problem == null && (typedKey.isNotBlank() || (keyStored && !endpointChanged)), onClick = {
                busy = true; status = context.getString(R.string.ai_settings_testing)
                val key = typedKey
                scope.launch {
                    status = withContext(Dispatchers.IO) {
                        // A saved key is only ever sent to the endpoint it was saved for.
                        val secret = key.takeIf { it.isNotBlank() } ?: credentials.get(kind.id) ?: return@withContext context.getString(R.string.ai_settings_key_not_set)
                        try {
                            val models = AiClient().listModels(draft, secret)
                            val listed = draft.model.trim() in models
                            context.getString(if (listed) R.string.ai_settings_connected_listed else R.string.ai_settings_connected_unlisted, models.size, draft.model.trim())
                        } catch (error: AiClientException) {
                            error.message ?: context.getString(R.string.ai_settings_test_failed)
                        } catch (_: Exception) {
                            context.getString(R.string.ai_settings_test_failed)
                        }
                    }
                    busy = false
                }
            }) { Text(stringResource(R.string.ai_settings_test)) }
            if (keyStored) TextButton(enabled = !busy, onClick = {
                scope.launch { withContext(Dispatchers.IO) { credentials.remove(kind.id) }; keyStored = false; typedKey = ""; status = context.getString(R.string.ai_settings_key_removed) }
            }) { Text(stringResource(R.string.ai_settings_remove_key)) }
        }
        status?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        // A conversation fixes the number of attempts of a turn; there is nothing to choose here.
        Text(stringResource(R.string.ai_settings_attempts_note, AiConversationLimits.MAX_ATTEMPTS_PER_TURN, AiConversationLimits.MAX_ATTEMPTS_PER_TURN - 1),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
