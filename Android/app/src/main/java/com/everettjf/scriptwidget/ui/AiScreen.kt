package com.everettjf.scriptwidget.ui

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.InstalledPackage
import com.everettjf.scriptwidget.ai.AiServices
import com.everettjf.scriptwidget.core.PlatformSupport
import com.everettjf.scriptwidget.core.RunRequest
import com.everettjf.scriptwidget.core.ai.AgentLoop
import com.everettjf.scriptwidget.core.ai.AgentLoopEvent
import com.everettjf.scriptwidget.core.ai.AgentLoopOutcome
import com.everettjf.scriptwidget.core.ai.AgentLoopRequest
import com.everettjf.scriptwidget.core.ai.AiCancellation
import com.everettjf.scriptwidget.core.ai.AiClient
import com.everettjf.scriptwidget.core.ai.AiClientException
import com.everettjf.scriptwidget.core.ai.AiExamplePrompts
import com.everettjf.scriptwidget.core.ai.AiManifestDeclaration
import com.everettjf.scriptwidget.core.ai.AiProfile
import com.everettjf.scriptwidget.core.ai.AiProviderKind
import com.everettjf.scriptwidget.core.ai.AiSettings
import com.everettjf.scriptwidget.core.ai.AiTokenUsage
import com.everettjf.scriptwidget.core.ai.AiWidgetSize
import com.everettjf.scriptwidget.core.ai.PromptBuilder
import com.everettjf.scriptwidget.core.ai.ValidationResult
import com.everettjf.scriptwidget.core.pkg.PackageLimits
import com.everettjf.scriptwidget.core.ai.AiManifests
import com.everettjf.scriptwidget.core.runtime.MemoryPackageFiles
import com.everettjf.scriptwidget.core.runtime.PackageFiles
import com.everettjf.scriptwidget.widget.WidgetScheduler
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.URI

/** AI provider settings: provider, base URL, model, API key and a connection test. Shown inside the Settings screen. */
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
    var iterations by remember { mutableIntStateOf(store.maxIterations) }
    LaunchedEffect(kind) { keyStored = withContext(Dispatchers.IO) { credentials.has(kind.id) } }

    val draft = AiProfile(kind, baseUrl, modelName)
    val problem = draft.validationError()
    val endpointChanged = draft.normalizedBaseUrl != store.profile(kind).normalizedBaseUrl

    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Widgets can be drafted by a model you choose. The Android app supports API-key providers only; signing in with an OpenAI account (OAuth) is not available.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (option in AiProviderKind.entries) FilterChip(selected = kind == option, onClick = { kind = option; store.activeKind = option }, label = { Text(option.displayName) })
        }
        OutlinedTextField(
            baseUrl, { baseUrl = it.take(AiProfile.MAXIMUM_BASE_URL_LENGTH); status = null }, singleLine = true, label = { Text("API base URL (https)") },
            placeholder = { Text(kind.defaultBaseUrl.ifEmpty { "https://example.com" }) }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            modelName, { modelName = it.take(AiProfile.MAXIMUM_MODEL_LENGTH); status = null }, singleLine = true, label = { Text("Model") },
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false), modifier = Modifier.fillMaxWidth(),
        )
        if (kind.suggestedModels.size > 1) FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (suggestion in kind.suggestedModels) AssistChip(onClick = { modelName = suggestion; status = null }, label = { Text(suggestion) })
        }
        OutlinedTextField(
            typedKey, { typedKey = it.take(4096); status = null }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
            label = { Text("API key") }, placeholder = { Text(if (keyStored && !endpointChanged) "Saved. Enter a new key to replace it" else "Paste the API key") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false), modifier = Modifier.fillMaxWidth(),
        )
        Text(
            when {
                endpointChanged && keyStored && typedKey.isBlank() -> "The saved key belongs to the previous base URL and is removed when you save. Enter the key for this endpoint."
                keyStored -> "A key is saved, encrypted with the Android Keystore. It is never shown again, backed up, or added to widgets and prompts."
                else -> "The key is stored encrypted with the Android Keystore and only sent to the base URL above."
            },
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
                    status = if (stored.first) "Saved." else "The key could not be stored securely on this device."
                }
            }) { Text("Save") }
            OutlinedButton(enabled = !busy && problem == null && (typedKey.isNotBlank() || (keyStored && !endpointChanged)), onClick = {
                busy = true; status = "Testing…"
                val key = typedKey
                scope.launch {
                    status = withContext(Dispatchers.IO) {
                        // A saved key is only ever sent to the endpoint it was saved for.
                        val secret = key.takeIf { it.isNotBlank() } ?: credentials.get(kind.id) ?: return@withContext "API key is not set."
                        try {
                            val models = AiClient().listModels(draft, secret)
                            val listed = draft.model.trim() in models
                            "Connected. ${models.size} models available" + if (listed) "; ${draft.model.trim()} is one of them." else "; ${draft.model.trim()} is not in the list, check the model name."
                        } catch (error: AiClientException) {
                            error.message ?: "The connection test failed."
                        } catch (_: Exception) {
                            "The connection test failed."
                        }
                    }
                    busy = false
                }
            }) { Text("Test connection") }
            if (keyStored) TextButton(enabled = !busy, onClick = {
                scope.launch { withContext(Dispatchers.IO) { credentials.remove(kind.id) }; keyStored = false; typedKey = ""; status = "Key removed." }
            }) { Text("Remove key") }
        }
        status?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        Text("Maximum attempts per widget", style = MaterialTheme.typography.bodyMedium)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (option in listOf(5, 10, 20, 40)) FilterChip(selected = iterations == option, onClick = { iterations = option; store.maxIterations = option }, label = { Text("$option") })
        }
        Text("Each attempt sends a request to the provider and is billed by it. Generated widgets run under the same limits as any other widget.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
