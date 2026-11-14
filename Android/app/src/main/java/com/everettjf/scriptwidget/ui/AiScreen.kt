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

private const val PREVIEW_PACKAGE_ID = "ai-preview"
private const val MAXIMUM_PROMPT_CHARACTERS = 4000

/** Where the generate screen is in a run. Port of `AIGenerateSession.Phase`. */
internal sealed class AiPhase {
    data object Idle : AiPhase()
    class Preparing : AiPhase()
    class Thinking(val iteration: Int) : AiPhase()
    class Running(val iteration: Int) : AiPhase()
    class Fixing(val iteration: Int, val errorSummary: String) : AiPhase()
    data object Done : AiPhase()
    class Exhausted(val lastError: String?) : AiPhase()
    class Failed(val message: String) : AiPhase()
    data object Cancelled : AiPhase()
}

/** One finished iteration; [errorSummary] is null when it rendered. */
internal class AiIteration(val iteration: Int, val errorSummary: String?)

/** A package's files with some text files replaced in memory; nothing is written to disk. */
private class OverlayPackageFiles(private val base: PackageFiles, private val overrides: Map<String, String>) : PackageFiles {
    override fun paths(): List<String> = (base.paths() + overrides.keys).distinct().sorted()
    override fun exists(path: String): Boolean = overrides.containsKey(path) || base.exists(path)
    override fun readText(path: String): String? = overrides[path] ?: base.readText(path)
    override fun readBytes(path: String): ByteArray? = overrides[path]?.toByteArray() ?: base.readBytes(path)
}

/**
 * Text of the enabled Skills for the prompt, or null. Skills only add
 * instructions to the request; wire the Skill store in here when it exists.
 */
private fun enabledSkillsPrompt(): String? = com.everettjf.scriptwidget.AppServices.skillsPrompt()

/**
 * Drives the agent loop off the main thread and exposes its progress as
 * Compose state. Port of `AIGenerateSession`.
 */
class AiGenerateViewModel : ViewModel() {
    private var phaseState by mutableStateOf<AiPhase>(AiPhase.Idle)
    private val historyState = mutableStateListOf<AiIteration>()
    private val main = Handler(Looper.getMainLooper())
    private var cancellation: AiCancellation? = null
    private var generation = 0

    internal val phase: AiPhase get() = phaseState
    internal val history: List<AiIteration> get() = historyState
    var usage by mutableStateOf(AiTokenUsage.ZERO); private set
    var maxIterations by mutableIntStateOf(AiSettings.DEFAULT_MAX_ITERATIONS); private set
    /** Latest candidate source, or null before the model has produced one. */
    var source by mutableStateOf<String?>(null); private set
    /** Canonical network declaration of the latest candidate. */
    var declaration by mutableStateOf<String?>(null); private set
    /** Bumped whenever the candidate changes so the preview reruns. */
    var revision by mutableIntStateOf(0); private set
    var isRunning by mutableStateOf(false); private set
    /** The installed package being improved, resolved when a run starts. */
    private var target: InstalledPackage? = null

    /** Starts a run. [name] is the installed package to improve, or null for a new widget. */
    fun start(context: Context, description: String, family: String, name: String?) {
        val application = context.applicationContext
        val prompt = description.trim()
        if (prompt.isEmpty() || isRunning) return
        cancellation?.cancel()
        val token = AiCancellation()
        cancellation = token
        val run = ++generation
        historyState.clear()
        usage = AiTokenUsage.ZERO
        source = null
        declaration = null
        isRunning = true
        phaseState = AiPhase.Preparing()

        viewModelScope.launch(Dispatchers.IO) {
            val outcome: AgentLoopOutcome? = try {
                val store = AiServices.settings(application)
                val settings = store.load()
                settings.profile.validationError()?.let { return@launch finish(run, AiPhase.Failed(it)) }
                val key = AiServices.credentials(application).get(settings.profile.kind.id)
                    ?: return@launch finish(run, AiPhase.Failed("API key is not set. Open Settings → AI to configure it."))
                val installed = name?.let { AppServices.library.find(it) ?: return@launch finish(run, AiPhase.Failed("This widget is no longer installed.")) }
                target = installed
                val mode = if (installed == null) AgentLoopRequest.Mode.Fresh(prompt) else {
                    val current = installed.files.readText(entryOf(installed)) ?: return@launch finish(run, AiPhase.Failed("The widget's ${entryOf(installed)} could not be read."))
                    AgentLoopRequest.Mode.Refine(current, prompt, AiManifestDeclaration.fromManifest(installed.manifest)?.toJson())
                }
                val baseline = installed?.let { PlatformSupport.unsupported(it.manifest, it.files).toSet() } ?: emptySet()
                val request = AgentLoopRequest(mode, AiWidgetSize.fromFamily(family), PromptBuilder.systemPrompt(AiServices.reference(application)), settings.maxIterations, enabledSkillsPrompt())
                post(run) { maxIterations = AgentLoop.iterationLimit(settings.maxIterations) }
                AgentLoop(AiClient().bind(settings, key)).run(
                    request,
                    validate = { candidate, candidateDeclaration -> validate(installed, candidate, candidateDeclaration, family, baseline) },
                    cancellation = token,
                    onEvent = { event -> post(run) { apply(event) } },
                )
            } catch (_: Exception) {
                // Nothing here may surface exception text: it could describe the request.
                null
            }
            post(run) { apply(outcome) }
        }
    }

    /** Stops the current run; the in-flight request is aborted. */
    fun cancel() {
        generation += 1
        cancellation?.cancel()
        cancellation = null
        if (isRunning) phaseState = AiPhase.Cancelled
        isRunning = false
    }

    override fun onCleared() { cancellation?.cancel() }

    private fun finish(run: Int, phase: AiPhase) = post(run) { isRunning = false; phaseState = phase }

    /** Applies a state change on the main thread, unless the run was cancelled or replaced. */
    private fun post(run: Int, change: () -> Unit) { main.post { if (run == generation) change() } }

    private fun apply(event: AgentLoopEvent) {
        when (event) {
            is AgentLoopEvent.Thinking -> phaseState = AiPhase.Thinking(event.iteration)
            is AgentLoopEvent.Produced -> { source = event.source; declaration = event.manifestJson }
            is AgentLoopEvent.Running -> phaseState = AiPhase.Running(event.iteration)
            is AgentLoopEvent.RanFailed -> {
                phaseState = AiPhase.Fixing(event.iteration, event.errorSummary)
                historyState += AiIteration(event.iteration, event.errorSummary)
                revision += 1
            }
            is AgentLoopEvent.RanSucceeded -> { historyState += AiIteration(event.iteration, null); revision += 1 }
            is AgentLoopEvent.TokensUsed -> usage = event.usage
        }
    }

    private fun apply(outcome: AgentLoopOutcome?) {
        isRunning = false
        cancellation = null
        if (outcome != null) usage = outcome.usage
        phaseState = when (outcome) {
            is AgentLoopOutcome.Succeeded -> { source = outcome.source; declaration = outcome.manifestJson; AiPhase.Done }
            is AgentLoopOutcome.Exhausted -> { source = outcome.lastSource ?: source; declaration = outcome.lastManifestJson; AiPhase.Exhausted(outcome.lastError) }
            is AgentLoopOutcome.Cancelled -> AiPhase.Cancelled
            is AgentLoopOutcome.Failed -> AiPhase.Failed(outcome.message)
            null -> AiPhase.Failed("Generation could not be completed.")
        }
        revision += 1
    }

    /** Compiles and executes a candidate in memory, exactly as the preview will. Runs on the loop's thread. */
    private fun validate(installed: InstalledPackage?, candidate: String, candidateDeclaration: String?, family: String, baseline: Set<String>): ValidationResult {
        if (candidate.toByteArray().size > PackageLimits.MAX_SCRIPT_BYTES) return ValidationResult.failure("resourceLimit: main.jsx exceeds ${PackageLimits.MAX_SCRIPT_BYTES / 1024} KiB.")
        val files = candidateFiles(installed, candidate, candidateDeclaration, "AI Widget")
        val runtime = AppServices.runtime
        val execution = runtime.run(RunRequest(files, PREVIEW_PACKAGE_ID, family, darkMode = runtime.isDarkMode())).execution
        val logs = execution.logs.map { "[${it.level}] ${it.message}" }
        val result = ValidationResult.fromExecution(execution.tree, execution.error?.kind, execution.error?.message, logs)
        if (!result.ok) return result
        val manifest = AiManifests.parse(files.readText(AiManifests.FILE_NAME))
        val unsupported = PlatformSupport.unsupported(manifest, files).filter { it !in baseline }
        if (unsupported.isNotEmpty()) return ValidationResult.failure("The widget uses features that are not supported on Android: ${unsupported.joinToString(" ")}", logs)
        return result
    }

    companion object {
        /** Entry file of an installed package: the manifest's `entry`, or `main.jsx` for a legacy package. */
        fun entryOf(installed: InstalledPackage): String = AiManifests.entry(installed.manifest)

        /**
         * The manifest text a candidate would be saved with, or null for a legacy package that has
         * no `widget.json`. Only `network` and `networkDomains` come from the model's declaration.
         * When improving a widget, a reply without a declaration keeps the manifest unchanged.
         */
        fun manifestText(installed: InstalledPackage?, declaration: String?, newName: String): String? {
            if (installed != null && installed.manifest == null) return null
            return AiManifests.text(installed?.manifest, declaration, newName)
        }

        /** In-memory package for a candidate: a fresh one, or the installed package with its entry replaced. */
        fun candidateFiles(installed: InstalledPackage?, source: String, declaration: String?, newName: String): PackageFiles {
            val manifest = manifestText(installed, declaration, newName)
            if (installed == null) return MemoryPackageFiles(mapOf(AiManifests.DEFAULT_ENTRY to source, AiManifests.FILE_NAME to manifest!!))
            val overrides = LinkedHashMap<String, String>()
            overrides[entryOf(installed)] = source
            if (manifest != null) overrides[AiManifests.FILE_NAME] = manifest
            return OverlayPackageFiles(installed.files, overrides)
        }
    }
}

/**
 * Generates a new widget from a description ([name] is null) or improves the
 * installed package [name], whose current entry source is sent to the model.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun AiScreen(navigation: NavController, name: String?) {
    val context = LocalContext.current
    val model: AiGenerateViewModel = viewModel()
    val installed = remember(name) { name?.let { AppServices.library.find(it) } }
    if (name != null && installed == null) { Text("This widget is no longer installed.", Modifier.padding(32.dp)); return }

    var prompt by rememberSaveable { mutableStateOf("") }
    var family by rememberSaveable { mutableStateOf("medium") }
    var showCode by rememberSaveable { mutableStateOf(false) }
    var askName by remember { mutableStateOf(false) }
    var confirmReplace by remember { mutableStateOf(false) }
    var settingsRevision by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { settingsRevision += 1 }
    // Provider summary: the profile is not secret; whether a key exists is read off the main thread.
    var profile by remember { mutableStateOf<AiProfile?>(null) }
    var hasKey by remember { mutableStateOf(true) }
    LaunchedEffect(settingsRevision) {
        val loaded = withContext(Dispatchers.IO) { AiServices.settings(context).load().profile.let { it to AiServices.credentials(context).has(it.kind.id) } }
        profile = loaded.first; hasKey = loaded.second
    }
    val dark = isSystemInDarkTheme()
    val scope = rememberCoroutineScope()
    val phase = model.phase
    val candidate = model.source
    val ready = profile?.isConfigured == true && hasKey

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(if (installed == null) "Generate with AI" else "Improve ${installed.displayName}", maxLines = 1) },
            navigationIcon = { IconButton(onClick = { model.cancel(); navigation.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
        )
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            if (!ready && profile != null) Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer), modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Set up an AI provider", style = MaterialTheme.typography.titleSmall)
                    Text("Choose a provider and enter its API key in Settings → AI. The key is stored encrypted on this device.", style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = { navigation.navigate("settings") }) { Text("Open Settings") }
                }
            }
            OutlinedTextField(
                prompt, { prompt = it.take(MAXIMUM_PROMPT_CHARACTERS) }, enabled = !model.isRunning, minLines = 3, maxLines = 8,
                label = { Text(if (installed == null) "Describe the widget" else "Describe the change") }, modifier = Modifier.fillMaxWidth(),
            )
            if (installed == null) FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (example in AiExamplePrompts.all) AssistChip(enabled = !model.isRunning, onClick = { prompt = example.prompt; family = example.size.family }, label = { Text(example.title) })
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (size in AiWidgetSize.entries) FilterChip(selected = family == size.family, enabled = !model.isRunning, onClick = { family = size.family }, label = { Text(size.displayName) })
            }
            profile?.let { active ->
                val host = runCatching { URI(active.normalizedBaseUrl).host }.getOrNull().orEmpty()
                Text(
                    "${active.kind.displayName} · ${active.model.ifBlank { "no model" }}. Your description" + (if (installed == null) " is" else " and this widget's ${AiGenerateViewModel.entryOf(installed)} are") +
                        " sent to ${host.ifEmpty { "the configured server" }}. Each attempt is a separate request, so cost grows with iterations.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.fillMaxWidth(),
                )
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(enabled = ready && !model.isRunning && prompt.isNotBlank(), onClick = { model.start(context, prompt, family, name) }, modifier = Modifier.weight(1f)) {
                    Text(if (candidate == null) (if (installed == null) "Generate" else "Improve") else "Try again")
                }
                OutlinedButton(enabled = model.isRunning, onClick = { model.cancel() }, modifier = Modifier.weight(1f)) { Text("Cancel") }
            }

            AiProgress(phase, model.history, model.usage, model.maxIterations)

            if (candidate != null) {
                // The candidate runs from memory with exactly the manifest it would be saved with.
                val files = remember(candidate, model.declaration, installed) { AiGenerateViewModel.candidateFiles(installed, candidate, model.declaration, "AI Widget") }
                WidgetPreview(files = files, packageID = PREVIEW_PACKAGE_ID, family = family, dark = dark, revision = model.revision)
                val domains = remember(model.declaration) { model.declaration?.let { runCatching { AiManifestDeclaration.parse(it).networkDomains }.getOrNull() }.orEmpty() }
                if (domains.isNotEmpty()) Text("Network access requested: ${domains.joinToString(", ")}", style = MaterialTheme.typography.bodySmall, modifier = Modifier.fillMaxWidth())
                TextButton(onClick = { showCode = !showCode }) { Text(if (showCode) "Hide code" else "Show code") }
                if (showCode) Card(Modifier.fillMaxWidth()) {
                    Text(candidate, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                        modifier = Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState()).padding(12.dp))
                }
                val finished = !model.isRunning && (phase is AiPhase.Done || phase is AiPhase.Exhausted || phase is AiPhase.Cancelled || phase is AiPhase.Failed)
                if (finished) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (installed != null) Button(onClick = { confirmReplace = true }, modifier = Modifier.weight(1f)) { Text("Replace") }
                    val saveNew: @Composable () -> Unit = { Text("Save as new widget") }
                    if (installed == null) Button(onClick = { askName = true }, modifier = Modifier.weight(1f), content = { saveNew() })
                    else OutlinedButton(onClick = { askName = true }, modifier = Modifier.weight(1f), content = { saveNew() })
                }
            }
        }
    }

    fun saved(result: Result<InstalledPackage>) {
        result.onSuccess { saved ->
            WidgetScheduler.refreshPackage(context, saved.installation)
            navigation.navigate("package/${Uri.encode(saved.name)}") { popUpTo("home") }
        }.onFailure { Toast.makeText(context, it.message ?: "Could not save the widget", Toast.LENGTH_LONG).show() }
    }

    if (askName && candidate != null) NameDialog("Save as new widget", installed?.let { "${it.name} AI" } ?: "AI Widget", onDismiss = { askName = false }) { newName ->
        askName = false
        val declaration = model.declaration
        scope.launch { saved(withContext(Dispatchers.IO) { runCatching { saveAsNew(installed, newName, candidate, declaration) } }) }
    }
    if (confirmReplace && candidate != null && installed != null) AlertDialog(
        onDismissRequest = { confirmReplace = false }, title = { Text("Replace ${installed.displayName}?") },
        text = { Text("${AiGenerateViewModel.entryOf(installed)} is overwritten with the generated code. Widgets on the home screen showing it are redrawn.") },
        confirmButton = { TextButton(onClick = {
            confirmReplace = false
            val declaration = model.declaration
            scope.launch { saved(withContext(Dispatchers.IO) { runCatching { replace(installed, candidate, declaration) } }) }
        }) { Text("Replace") } },
        dismissButton = { TextButton(onClick = { confirmReplace = false }) { Text("Cancel") } },
    )
}

/** Creates a new package from a candidate; when improving, the original's other files are copied first. */
private fun saveAsNew(installed: InstalledPackage?, requestedName: String, source: String, declaration: String?): InstalledPackage {
    val library = AppServices.library
    if (installed == null) {
        val name = library.store.uniqueName(requestedName)
        return library.create(name, source, AiGenerateViewModel.manifestText(null, declaration, name))
    }
    val duplicate = library.duplicate(installed.name)
    return try {
        replace(library.rename(duplicate.name, library.store.uniqueName(requestedName)), source, declaration)
    } catch (error: Exception) {
        // Do not leave a half-made copy behind.
        runCatching { library.delete(duplicate.name) }
        throw error
    }
}

/** Writes a candidate over an installed package's entry and, when its network declaration changed, its manifest. */
private fun replace(installed: InstalledPackage, source: String, declaration: String?): InstalledPackage {
    val library = AppServices.library
    library.writeFile(installed.name, AiGenerateViewModel.entryOf(installed), source.toByteArray(Charsets.UTF_8))
    val manifest = AiGenerateViewModel.manifestText(installed, declaration, installed.name)
    if (manifest != null && declaration != null) library.writeFile(installed.name, AiManifests.FILE_NAME, manifest.toByteArray(Charsets.UTF_8))
    return library.find(installed.name) ?: installed
}

@Composable
private fun AiProgress(phase: AiPhase, history: List<AiIteration>, usage: AiTokenUsage, maxIterations: Int) {
    if (phase is AiPhase.Idle) return
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            val iteration = when (phase) { is AiPhase.Thinking -> phase.iteration; is AiPhase.Running -> phase.iteration; is AiPhase.Fixing -> phase.iteration; else -> 0 }
            val status = when (phase) {
                is AiPhase.Preparing -> "Preparing the request…"
                is AiPhase.Thinking -> "Iteration ${phase.iteration} / $maxIterations: waiting for the model…"
                is AiPhase.Running -> "Iteration ${phase.iteration} / $maxIterations: running the code…"
                is AiPhase.Fixing -> "Iteration ${phase.iteration} / $maxIterations: the code failed, asking for a fix…"
                is AiPhase.Done -> "Done. The widget rendered without errors."
                is AiPhase.Exhausted -> "Did not converge, showing the last attempt."
                is AiPhase.Failed -> phase.message
                is AiPhase.Cancelled -> "Cancelled."
                is AiPhase.Idle -> ""
            }
            Text(status, style = MaterialTheme.typography.titleSmall, color = if (phase is AiPhase.Failed || phase is AiPhase.Exhausted) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
            if (iteration > 0) LinearProgressIndicator(progress = { (iteration.toFloat() / maxIterations.coerceAtLeast(1)).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
            else if (phase is AiPhase.Preparing) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (phase is AiPhase.Exhausted && phase.lastError != null) Text(phase.lastError.take(600), style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
            for (record in history.takeLast(8)) Text(
                if (record.errorSummary == null) "✓ Attempt ${record.iteration} rendered" else "✗ Attempt ${record.iteration}: ${record.errorSummary.take(300)}",
                style = MaterialTheme.typography.bodySmall,
                color = if (record.errorSummary == null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (usage.totalTokens > 0) Text("Tokens used: ${usage.totalTokens} (${usage.promptTokens} in, ${usage.completionTokens} out)", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

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
