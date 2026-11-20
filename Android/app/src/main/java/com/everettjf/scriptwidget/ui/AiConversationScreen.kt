package com.everettjf.scriptwidget.ui

import android.content.Context
import android.net.Uri
import android.text.format.DateUtils
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.height
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import com.everettjf.scriptwidget.R
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
import com.everettjf.scriptwidget.core.ai.AiConversation
import com.everettjf.scriptwidget.core.ai.AiConversationLimits
import com.everettjf.scriptwidget.core.ai.AiConversationSummary
import com.everettjf.scriptwidget.core.ai.AiConversationTurn
import com.everettjf.scriptwidget.core.ai.AiSourceDiff
import com.everettjf.scriptwidget.core.ai.AiConversationTurns
import com.everettjf.scriptwidget.core.ai.AiConversationVersion
import com.everettjf.scriptwidget.core.ai.AiConversationUsageAdvice
import com.everettjf.scriptwidget.core.ai.AiExamplePrompts
import com.everettjf.scriptwidget.core.ai.AiManifestDeclaration
import com.everettjf.scriptwidget.core.ai.AiManifests
import com.everettjf.scriptwidget.core.ai.AiProfile
import com.everettjf.scriptwidget.core.ai.AiTokenUsage
import com.everettjf.scriptwidget.core.ai.AiWidgetSize
import com.everettjf.scriptwidget.core.ai.PromptBuilder
import com.everettjf.scriptwidget.core.ai.ValidationResult
import com.everettjf.scriptwidget.core.pkg.PackageLimits
import com.everettjf.scriptwidget.core.runtime.ExecutionResult
import com.everettjf.scriptwidget.core.skills.Skill
import com.everettjf.scriptwidget.core.runtime.MemoryPackageFiles
import com.everettjf.scriptwidget.core.runtime.PackageFiles
import com.everettjf.scriptwidget.widget.WidgetScheduler
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URI

private const val PREVIEW_PACKAGE_ID = "ai-preview"

/** A package's files with some text files replaced in memory; nothing is written to disk. */
private class OverlayPackageFiles(private val base: PackageFiles, private val overrides: Map<String, String>) : PackageFiles {
    override fun paths(): List<String> = (base.paths() + overrides.keys).distinct().sorted()
    override fun exists(path: String): Boolean = overrides.containsKey(path) || base.exists(path)
    override fun readText(path: String): String? = overrides[path] ?: base.readText(path)
    override fun readBytes(path: String): ByteArray? = overrides[path]?.toByteArray() ?: base.readBytes(path)
}

/**
 * How a version of a conversation becomes a package: in memory for the preview, and on disk
 * when it is saved or applied. The model only ever influences the network declaration.
 */
internal object AiCandidates {
    /** Entry file of an installed package: the manifest's `entry`, or `main.jsx` for a legacy package. */
    fun entryOf(installed: InstalledPackage): String = AiManifests.entry(installed.manifest)

    /** Hosts an installed widget may already contact. */
    fun allowedHosts(installed: InstalledPackage?): List<String> = AiManifestDeclaration.fromManifest(installed?.manifest)?.networkDomains.orEmpty()

    /**
     * The declaration a version runs and is saved with. A new widget gets exactly what the
     * version declares. An installed widget keeps the hosts it already has and gains the
     * declared ones: a conversation never takes a permission away from a widget.
     */
    fun declaration(installed: InstalledPackage?, domains: List<String>): String? {
        val hosts = (allowedHosts(installed) + domains).distinct()
        return if (hosts.isEmpty()) null else AiManifestDeclaration(listOf("network"), hosts).toJson()
    }

    /** Declared hosts the installed widget may not contact yet; the user is asked before they are added. */
    fun newHosts(installed: InstalledPackage?, domains: List<String>): List<String> = domains.filter { it !in allowedHosts(installed) }

    /** The manifest text of a version, or null for a legacy package that has no `widget.json`. */
    fun manifestText(installed: InstalledPackage?, domains: List<String>, newName: String): String? {
        if (installed != null && installed.manifest == null) return null
        return AiManifests.text(installed?.manifest, declaration(installed, domains), newName)
    }

    /** In-memory package of a version: a fresh one, or the installed package with its entry replaced. */
    fun files(installed: InstalledPackage?, source: String, domains: List<String>, newName: String = "AI Widget"): PackageFiles {
        val manifest = manifestText(installed, domains, newName)
        if (installed == null) return MemoryPackageFiles(mapOf(AiManifests.DEFAULT_ENTRY to source, AiManifests.FILE_NAME to manifest!!))
        val overrides = LinkedHashMap<String, String>()
        overrides[entryOf(installed)] = source
        if (manifest != null) overrides[AiManifests.FILE_NAME] = manifest
        return OverlayPackageFiles(installed.files, overrides)
    }

    /** Compiles and executes a candidate in memory, exactly as the preview will. Blocking. */
    fun validate(installed: InstalledPackage?, source: String, declarationJson: String?, family: String, baseline: Set<String>): ValidationResult {
        if (source.toByteArray().size > PackageLimits.MAX_SCRIPT_BYTES) return ValidationResult.failure("resourceLimit: main.jsx exceeds ${PackageLimits.MAX_SCRIPT_BYTES / 1024} KiB.")
        val domains = declarationJson?.let { runCatching { AiManifestDeclaration.parse(it).networkDomains }.getOrNull() }.orEmpty()
        val files = files(installed, source, domains)
        val runtime = AppServices.runtime
        val execution = runtime.run(RunRequest(files, PREVIEW_PACKAGE_ID, family, darkMode = runtime.isDarkMode())).execution
        val logs = execution.logs.map { "[${it.level}] ${it.message}" }
        val result = ValidationResult.fromExecution(execution.tree, execution.error?.kind, execution.error?.message, logs)
        if (!result.ok) return result
        val unsupported = PlatformSupport.unsupported(AiManifests.parse(files.readText(AiManifests.FILE_NAME)), files).filter { it !in baseline }
        if (unsupported.isNotEmpty()) return ValidationResult.failure("The widget uses features that are not supported on Android: ${unsupported.joinToString(" ")}", logs)
        return result
    }
}

/**
 * The conversation on screen. It owns the conversation object: every change
 * happens on the main thread and is followed by [changed], which redraws and
 * saves. The model call and the trial run happen off the main thread.
 */
class AiConversationViewModel : ViewModel() {
    /** Read in a composable to be redrawn when the conversation changes. */
    var revision by mutableIntStateOf(0); private set
    var conversation by mutableStateOf(AiConversation()); private set
    /** The installed widget the conversation is about; null for a new widget. */
    var installed by mutableStateOf<InstalledPackage?>(null); private set
    /** What the installed widget's entry file holds, to tell whether the version on screen is applied. */
    var installedSource by mutableStateOf<String?>(null); private set
    var isLoading by mutableStateOf(true); private set
    var isMissing by mutableStateOf(false); private set
    /** The widget has a `widget.json` that can not be read: the conversation is refused, never run as a legacy widget. */
    var isManifestUnreadable by mutableStateOf(false); private set
    /** What the preview reported when it last ran a version; null until it has. */
    var previewRun by mutableStateOf<PreviewRun?>(null); private set
    /** What is happening in the running turn, in words. */
    var activity by mutableStateOf<String?>(null); private set
    /** The end of the code being written, while a reply arrives; empty otherwise. */
    var liveText by mutableStateOf(""); private set
    var drafts by mutableStateOf<List<AiConversationSummary>>(emptyList()); private set

    /** One run of a version in the preview: why it failed, if it did, and what it printed. */
    class PreviewRun(val versionId: String, val error: String?, val logs: List<String>)

    private var cancellation: AiCancellation? = null
    private var generation = 0
    /** How many attempts the running turn may make; the progress line counts against it. */
    private var attemptLimit = AiConversationLimits.MAX_ATTEMPTS_PER_TURN
    private var opened = false
    /** The application, for the texts of [activity]; set when a turn starts. */
    private var strings: Context? = null

    val isRunning: Boolean get() = conversation.isRunning

    /** Opens the conversation of the installed widget [name], or an empty one for a new widget. */
    fun open(context: Context, name: String?) {
        if (opened) return
        opened = true
        val application = context.applicationContext
        viewModelScope.launch {
            val store = AiServices.conversations(application)
            val loaded = withContext(Dispatchers.IO) {
                val target = name?.let { AppServices.library.find(it) }
                val source = target?.let { it.files.readText(AiCandidates.entryOf(it)) }
                val existing = target?.let { store.latest(it.installation) }
                Triple(target, source, existing) to store.summaries(draftsOnly = true)
            }
            val (target, source, existing) = loaded.first
            drafts = loaded.second
            if (name != null && (target == null || source == null)) { isMissing = true; isLoading = false; return@launch }
            // A manifest that is there and can not be read is not a missing one: nothing is run, sent or written.
            if (target?.manifestUnreadable == true) { isManifestUnreadable = true; isLoading = false; return@launch }
            installed = target
            installedSource = source
            if (target != null && source != null) {
                val bound = existing ?: AiConversation(packageId = target.installation, title = target.displayName)
                // Code the conversation has not seen (the editor, a Gallery update) becomes a version of its own.
                val adopted = bound.adoptExternalSource(source, AiCandidates.allowedHosts(target))
                conversation = bound
                if (adopted && existing != null) changed(application)
            }
            isLoading = false
            revision += 1
        }
    }

    /** Continues a draft. */
    fun openDraft(context: Context, id: String) {
        if (isRunning) return
        val application = context.applicationContext
        viewModelScope.launch {
            val draft = withContext(Dispatchers.IO) { AiServices.conversations(application).load(id) } ?: return@launch
            conversation = draft
            revision += 1
        }
    }

    /** Leaves the conversation on screen as it is saved and starts an empty one. */
    fun startNew(context: Context) {
        if (isRunning) return
        conversation = AiConversation(packageId = installed?.installation, title = installed?.displayName.orEmpty()).also { fresh ->
            val source = installedSource
            if (installed != null && source != null) fresh.adoptExternalSource(source, AiCandidates.allowedHosts(installed))
        }
        revision += 1
        refreshDrafts(context)
    }

    /** Opens a conversation that starts from the version on screen, with no earlier turn to send. */
    fun continueFromHere(context: Context) {
        if (isRunning) return
        conversation = conversation.continuedFromCurrentVersion() ?: return
        revision += 1
        refreshDrafts(context)
    }

    fun deleteDraft(context: Context, id: String) {
        val application = context.applicationContext
        viewModelScope.launch {
            withContext(Dispatchers.IO) { AiServices.conversations(application).delete(id) }
            if (conversation.id == id) startNew(application) else refreshDrafts(application)
        }
    }

    private fun refreshDrafts(context: Context) {
        val application = context.applicationContext
        viewModelScope.launch { drafts = withContext(Dispatchers.IO) { AiServices.conversations(application).summaries(draftsOnly = true) } }
    }

    fun setSize(context: Context, size: AiWidgetSize) {
        if (conversation.size == size) return
        conversation.size = size
        changed(context)
    }

    fun selectVersion(context: Context, id: String) {
        if (isRunning) return
        if (conversation.selectVersion(id)) changed(context)
    }

    /** Records what the preview's run of the version [versionId] reported. */
    fun previewRan(versionId: String, result: ExecutionResult?) {
        val logs = result?.logs.orEmpty().map { "[${it.level}] ${it.message}" }
        // Judged as the loop judges an attempt, so "it runs" means the same in both places.
        val judged = if (result == null) ValidationResult.failure("internalError: the widget could not be run.")
        else ValidationResult.fromExecution(result.tree, result.error?.kind, result.error?.message, logs)
        previewRun = PreviewRun(versionId, if (judged.ok) null else judged.errorSummary ?: "Runtime returned no element.", logs)
    }

    /** The failure of the version on screen, if its last run in the preview failed. */
    val runtimeFailure: PreviewRun? get() = previewRun?.takeIf { it.versionId == conversation.currentVersionId && it.error != null }

    /** Chooses the Skills that apply to every turn of this conversation. */
    fun chooseSkills(context: Context, ids: Collection<String>) {
        conversation.chooseSkills(ids)
        changed(context)
    }

    /** Sends [request] as the next turn. */
    fun send(context: Context, request: String) = start(context) { AiConversationTurns.begin(conversation, request, "", null) }

    /**
     * Asks the AI to repair the version on screen, which failed when the preview ran it, and
     * tells it what the run reported. [typed] is what the user wrote, if anything; without it
     * the request is the fixed sentence of the Apple apps.
     */
    fun fixRuntimeError(context: Context, typed: String) {
        val failure = runtimeFailure ?: return
        val request = typed.trim().ifEmpty { context.getString(R.string.ai_fix_runtime_request) }
        val diagnostic = PromptBuilder.runtimeDiagnostic(failure.error.orEmpty(), failure.logs)
        start(context) { AiConversationTurns.begin(conversation, request, "", null, diagnostic) }
    }

    /** Sends a turn that did not succeed again. */
    fun retry(context: Context, turnId: String) = start(context) { AiConversationTurns.retry(conversation, turnId, "", null) }

    private fun start(context: Context, begin: () -> AiConversationTurns.Started?) {
        val application = context.applicationContext
        if (isRunning) return
        val started = begin() ?: return
        val turnId = started.turn.id
        val token = AiCancellation()
        cancellation = token
        val run = ++generation
        strings = application
        activity = application.getString(R.string.ai_activity_preparing)
        liveText = ""
        changed(application)
        val target = installed
        val family = conversation.size.family
        val mode = started.loopRequest.mode as AgentLoopRequest.Mode.Turn
        attemptLimit = AgentLoop.iterationLimit(started.loopRequest.maxIterations)
        // Null until the user chose Skills for this conversation: then the ones enabled in the app apply.
        val skillIds = conversation.skillIds

        viewModelScope.launch {
            val outcome: AgentLoopOutcome? = withContext(Dispatchers.IO) {
                try {
                    val settings = AiServices.settings(application).load()
                    settings.profile.validationError()?.let { return@withContext AgentLoopOutcome.Failed(it, AiTokenUsage.ZERO) }
                    val key = AiServices.credentials(application).get(settings.profile.kind.id)
                        ?: return@withContext AgentLoopOutcome.Failed(application.getString(R.string.ai_no_key), AiTokenUsage.ZERO)
                    val baseline = target?.let { PlatformSupport.unsupported(it.manifest, it.files).toSet() } ?: emptySet()
                    // The text of the Skills is read when the turn is sent: the conversation keeps their ids only.
                    val context = mode.context
                    val withSkills = com.everettjf.scriptwidget.core.ai.AiTurnContext(
                        context.history, context.currentCode, context.previousCode, context.request, AppServices.skillsPrompt(skillIds),
                        context.size, context.currentDeclaration, context.runtimeDiagnostic,
                    )
                    val request = AgentLoopRequest(AgentLoopRequest.Mode.Turn(withSkills), context.size, PromptBuilder.systemPrompt(AiServices.reference(application)), started.loopRequest.maxIterations)
                    AgentLoop(chatFactory(settings, key)).run(
                        request,
                        validate = { source, declaration -> AiCandidates.validate(target, source, declaration, family, baseline) },
                        cancellation = token,
                        onEvent = { event -> viewModelScope.launch { if (run == generation) apply(turnId, event) } },
                    )
                } catch (_: Exception) {
                    // Nothing here may surface exception text: it could describe the request.
                    null
                }
            }
            if (run != generation) return@launch
            AiConversationTurns.applyOutcome(conversation, turnId, outcome)
            cancellation = null
            activity = null
            liveText = ""
            changed(application)
        }
    }

    private fun apply(turnId: String, event: AgentLoopEvent) {
        AiConversationTurns.applyEvent(conversation, turnId, event)
        when (event) {
            is AgentLoopEvent.Thinking -> { liveText = ""; activity = if (event.iteration == 1) strings?.getString(R.string.ai_activity_writing) else strings?.getString(R.string.ai_activity_fixing, event.iteration, attemptLimit) }
            is AgentLoopEvent.Running -> { activity = strings?.getString(R.string.ai_activity_checking); liveText = "" }
            // Only the last lines are kept: that is all the screen shows.
            is AgentLoopEvent.Partial -> liveText = PromptBuilder.previewOfPartialReply(event.text).trimEnd().lines().takeLast(LIVE_LINES).joinToString("\n")
            else -> Unit
        }
        revision += 1
    }

    /** Stops the running turn at once; the widget stays as it was. */
    fun stop(context: Context) {
        val running = conversation.turns.firstOrNull { it.status == AiConversationTurn.Status.RUNNING } ?: return
        generation += 1
        cancellation?.cancel()
        cancellation = null
        AiConversationTurns.applyOutcome(conversation, running.id, AgentLoopOutcome.Cancelled(running.usage))
        activity = null
        liveText = ""
        changed(context)
    }

    /** The conversation now belongs to the widget it was saved as or applied to. */
    fun bind(context: Context, saved: InstalledPackage, source: String) {
        installed = saved
        installedSource = source
        conversation.packageId = saved.installation
        changed(context)
    }

    override fun onCleared() { cancellation?.cancel() }

    companion object {
        /** How many lines of the code being written are shown. */
        const val LIVE_LINES = 8
        /** The model a turn talks to. Tests put a scripted one here; nothing else changes it. */
        @Volatile internal var chatFactory: (com.everettjf.scriptwidget.core.ai.AiSettings, String) -> com.everettjf.scriptwidget.core.ai.AiChat =
            { settings, key -> AiClient().bind(settings, key) }
    }

    /** Redraws and saves. A conversation nobody has written to is not saved. */
    private fun changed(context: Context) {
        revision += 1
        if (conversation.turns.isEmpty()) return
        val application = context.applicationContext
        val text = conversation
        viewModelScope.launch(Dispatchers.Main.immediate) {
            // Encoded on the main thread, where the conversation is owned; written off it.
            val snapshot = AiConversation.fromJson(text.toJson()) ?: return@launch
            // A running turn is read back as interrupted, which is what a closed app leaves behind.
            withContext(Dispatchers.IO) { AiServices.conversations(application).save(snapshot) }
        }
    }
}

/**
 * The AI conversation about one widget: the preview on top, the turns below,
 * the request field at the bottom. [name] is the installed widget to work on,
 * or null to make a new one.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun AiConversationScreen(navigation: NavController, name: String?) {
    val context = LocalContext.current
    val model: AiConversationViewModel = viewModel()
    LaunchedEffect(name) { model.open(context, name) }

    var settingsRevision by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { settingsRevision += 1 }
    // The profile is not secret; whether a key exists is read off the main thread.
    var profile by remember { mutableStateOf<AiProfile?>(null) }
    var hasKey by remember { mutableStateOf(true) }
    LaunchedEffect(settingsRevision) {
        val loaded = withContext(Dispatchers.IO) { AiServices.settings(context).load().profile.let { it to AiServices.credentials(context).has(it.kind.id) } }
        profile = loaded.first; hasKey = loaded.second
    }
    val ready = profile?.isConfigured == true && hasKey

    var draft by rememberSaveable { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    var showDrafts by remember { mutableStateOf(false) }
    var shownCode by remember { mutableStateOf<Pair<String, String>?>(null) }
    var shownChanges by remember { mutableStateOf<String?>(null) }
    var askName by remember { mutableStateOf(false) }
    var confirmNetwork by remember { mutableStateOf<String?>(null) }
    var confirmApply by remember { mutableStateOf(false) }
    var showLogs by remember { mutableStateOf(false) }
    var showSkills by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val dark = isSystemInDarkTheme()

    @Suppress("UNUSED_VARIABLE") val redraw = model.revision
    val conversation = model.conversation
    val installed = model.installed
    val current = conversation.currentVersion
    val running = model.isRunning

    if (model.isMissing) { Refusal(stringResource(R.string.ai_missing)) { navigation.popBackStack() }; return }
    if (model.isManifestUnreadable) { Refusal(stringResource(R.string.ai_manifest_unreadable)) { navigation.popBackStack() }; return }

    fun leave() { model.stop(context); navigation.popBackStack() }

    fun send() {
        val text = draft.trim()
        if (text.isEmpty() || running || !ready) return
        draft = ""
        model.send(context, text)
    }

    fun finishSave(result: Result<InstalledPackage>, source: String, open: Boolean) {
        result.onSuccess { saved ->
            model.bind(context, saved, source)
            WidgetScheduler.refreshPackage(context, saved.installation)
            if (open) navigation.navigate("package/${Uri.encode(saved.name)}") { popUpTo("home") }
            else Toast.makeText(context, context.getString(R.string.ai_applied_to, saved.displayName), Toast.LENGTH_SHORT).show()
        }.onFailure { Toast.makeText(context, it.message ?: context.getString(R.string.ai_save_failed), Toast.LENGTH_LONG).show() }
    }

    fun saveNew(newName: String, version: AiConversationVersion) {
        scope.launch {
            finishSave(withContext(Dispatchers.IO) { runCatching {
                val library = AppServices.library
                val unique = library.store.uniqueName(newName)
                library.create(unique, version.source, AiCandidates.manifestText(null, version.networkDomains, unique))
            } }, version.source, open = true)
        }
    }

    fun apply(target: InstalledPackage, version: AiConversationVersion) {
        scope.launch {
            finishSave(withContext(Dispatchers.IO) { runCatching {
                val library = AppServices.library
                library.writeFile(target.name, AiCandidates.entryOf(target), version.source.toByteArray(Charsets.UTF_8))
                val manifest = AiCandidates.manifestText(target, version.networkDomains, target.name)
                if (manifest != null && AiCandidates.newHosts(target, version.networkDomains).isNotEmpty()) library.writeFile(target.name, AiManifests.FILE_NAME, manifest.toByteArray(Charsets.UTF_8))
                library.find(target.name) ?: target
            } }, version.source, open = false)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    @Suppress("UNUSED_VARIABLE") val redrawTitle = model.revision
                    Column {
                        Text(if (installed != null) installed.displayName else conversation.title.ifEmpty { stringResource(R.string.ai_title_new) }, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(
                            if (installed != null) stringResource(R.string.ai_subtitle_installed) else if (conversation.turns.isEmpty()) stringResource(R.string.ai_subtitle_empty) else stringResource(R.string.ai_subtitle_draft),
                            style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
                        )
                    }
                },
                navigationIcon = { IconButton(onClick = { leave() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.ai_back)) } },
                actions = {
                    @Suppress("UNUSED_VARIABLE") val redrawActions = model.revision
                    if (installed == null && model.drafts.isNotEmpty()) IconButton(enabled = !running, onClick = { showDrafts = true }) { Icon(Icons.Default.History, stringResource(R.string.ai_drafts)) }
                    IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, stringResource(R.string.ai_more)) }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text(stringResource(R.string.ai_menu_new)) }, enabled = !running && conversation.turns.isNotEmpty(), onClick = { menu = false; draft = ""; model.startNew(context) })
                        if (installed == null) DropdownMenuItem(text = { Text(stringResource(R.string.ai_menu_delete_draft)) }, enabled = !running && conversation.turns.isNotEmpty(), onClick = { menu = false; model.deleteDraft(context, conversation.id) })
                        DropdownMenuItem(text = { Text(stringResource(R.string.ai_menu_skills)) }, enabled = !running, onClick = { menu = false; showSkills = true })
                        DropdownMenuItem(text = { Text(stringResource(R.string.ai_menu_logs)) }, enabled = current != null && model.previewRun?.versionId == current.id, onClick = { menu = false; showLogs = true })
                        DropdownMenuItem(text = { Text(stringResource(R.string.ai_menu_settings)) }, onClick = { menu = false; navigation.navigate("settings") })
                    }
                },
            )
        },
        bottomBar = {
          Column {
            @Suppress("UNUSED_VARIABLE") val redrawNotice = model.revision
            conversation.usageAdvice?.let { advice ->
                Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer).padding(start = 16.dp, end = 8.dp, top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(usageAdviceText(advice), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
                    if (current != null) TextButton(enabled = !running, onClick = { draft = ""; model.continueFromHere(context) }) { Text(stringResource(R.string.ai_start_new_from_here)) }
                }
            }
            Composer(
                text = draft, onText = { draft = it.take(AiConversationLimits.MAX_REQUEST_CHARACTERS) }, running = running, enabled = ready && !model.isLoading,
                placeholder = if (current == null) stringResource(R.string.ai_placeholder_new) else stringResource(R.string.ai_placeholder_change),
                onSend = { send() }, onStop = { model.stop(context) },
            )
          }
        },
    ) { padding ->
        // Read here as well: this block is its own scope, and the conversation changes in place.
        @Suppress("UNUSED_VARIABLE") val redrawContent = model.revision
        Column(Modifier.padding(padding).fillMaxSize()) {
            if (!ready && profile != null) Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer), modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(stringResource(R.string.ai_setup_title), style = MaterialTheme.typography.titleSmall)
                    Text(stringResource(R.string.ai_setup_text), style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = { navigation.navigate("settings") }) { Text(stringResource(R.string.ai_open_settings)) }
                }
            }

            if (current != null) {
                val ordered = conversation.versions.sortedBy { it.number }
                val index = ordered.indexOfFirst { it.id == current.id }
                PreviewPanel(
                    size = conversation.size, version = current, position = index + 1, count = ordered.size,
                    previousId = ordered.getOrNull(index - 1)?.id, nextId = if (index >= 0) ordered.getOrNull(index + 1)?.id else null,
                    installed = installed, dark = dark, running = running,
                    applied = installed != null && model.installedSource == current.source,
                    failure = model.runtimeFailure?.error, canFix = ready && !running,
                    onRan = { result -> model.previewRan(current.id, result) },
                    onFix = { val typed = draft; draft = ""; model.fixRuntimeError(context, typed) },
                    onSize = { model.setSize(context, it) }, onVersion = { model.selectVersion(context, it) },
                    onCode = { shownCode = context.getString(R.string.ai_version, current.number) to current.source },
                    onSave = { if (installed == null) askName = true else confirmApply = true },
                )
            }

            if (conversation.turns.none { !it.isManualEdit }) {
                EmptyState(
                    installed = installed, profile = profile, drafts = if (installed == null) model.drafts else emptyList(), enabled = ready,
                    onExample = { example -> draft = example.prompt; model.setSize(context, example.size) },
                    onDraft = { model.openDraft(context, it) }, onAllDrafts = { showDrafts = true },
                    modifier = Modifier.weight(1f),
                )
            } else {
                TurnList(
                    turns = conversation.turns.map { TurnUi.of(conversation, it) }, totalTokens = conversation.totalUsage.totalTokens,
                    activity = model.activity, live = model.liveText, running = running,
                    onVersion = { model.selectVersion(context, it) }, onRetry = { model.retry(context, it) },
                    onFailedCode = { id -> conversation.turn(id)?.failedSource?.let { shownCode = context.getString(R.string.ai_failed_attempt_title) to it } },
                    onChanges = { shownChanges = it },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }

    shownChanges?.let { versionId ->
        val version = conversation.version(versionId)
        val parent = conversation.version(version?.parentId)
        if (version == null || parent == null) shownChanges = null else {
            val lines = remember(versionId) { AiSourceDiff.lines(parent.source, version.source) }
            AlertDialog(
                onDismissRequest = { shownChanges = null }, title = { Text(stringResource(R.string.ai_changes_title, version.number)) },
                text = {
                    if (lines == null) Text(stringResource(R.string.ai_changes_too_long))
                    else LazyColumn(Modifier.heightIn(max = 420.dp).horizontalScroll(rememberScrollState())) {
                        items(lines) { line -> DiffLine(line) }
                    }
                },
                confirmButton = { TextButton(onClick = { shownChanges = null }) { Text(stringResource(R.string.ai_close)) } },
            )
        }
    }

    shownCode?.let { (title, code) ->
        AlertDialog(
            onDismissRequest = { shownCode = null }, title = { Text(title) },
            text = {
                Text(code, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                    modifier = Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState()))
            },
            confirmButton = { TextButton(onClick = { shownCode = null }) { Text(stringResource(R.string.ai_close)) } },
        )
    }

    if (askName && current != null) NameDialog(stringResource(R.string.ai_save_as_title), suggestedName(conversation.title, stringResource(R.string.ai_default_name)), onDismiss = { askName = false }) { newName ->
        askName = false
        if (current.networkDomains.isEmpty()) saveNew(newName, current) else confirmNetwork = newName
    }
    confirmNetwork?.let { newName ->
        if (current != null) AlertDialog(
            onDismissRequest = { confirmNetwork = null }, title = { Text(stringResource(R.string.ai_network_title)) },
            text = { Text(stringResource(R.string.ai_network_text, current.networkDomains.joinToString(", "))) },
            confirmButton = { TextButton(onClick = { confirmNetwork = null; saveNew(newName, current) }) { Text(stringResource(R.string.ai_save_and_allow)) } },
            dismissButton = { TextButton(onClick = { confirmNetwork = null }) { Text(stringResource(R.string.ai_cancel)) } },
        )
    }
    if (confirmApply && current != null && installed != null) {
        val added = AiCandidates.newHosts(installed, current.networkDomains)
        AlertDialog(
            onDismissRequest = { confirmApply = false }, title = { Text(stringResource(R.string.ai_apply_title, current.number, installed.displayName)) },
            text = {
                Text(
                    stringResource(R.string.ai_apply_text, AiCandidates.entryOf(installed)) +
                        if (added.isEmpty()) "" else "\n\n" + stringResource(R.string.ai_apply_text_hosts, added.joinToString(", ")),
                )
            },
            confirmButton = { TextButton(onClick = { confirmApply = false; apply(installed, current) }) { Text(if (added.isEmpty()) stringResource(R.string.ai_apply) else stringResource(R.string.ai_allow_and_apply)) } },
            dismissButton = { TextButton(onClick = { confirmApply = false }) { Text(stringResource(R.string.ai_cancel)) } },
        )
    }
    if (showLogs) {
        val run = model.previewRun?.takeIf { it.versionId == current?.id }
        if (run == null) showLogs = false else AlertDialog(
            onDismissRequest = { showLogs = false }, title = { Text(stringResource(R.string.ai_logs_title)) },
            text = {
                Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(run.error ?: stringResource(R.string.ai_logs_ran), style = MaterialTheme.typography.bodyMedium, color = if (run.error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                    if (run.logs.isEmpty()) Text(stringResource(R.string.ai_logs_empty), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    for (line in run.logs.takeLast(MAXIMUM_LOG_LINES_SHOWN)) Text(line, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                }
            },
            confirmButton = { TextButton(onClick = { showLogs = false }) { Text(stringResource(R.string.ai_close)) } },
        )
    }
    if (showSkills) SkillsDialog(chosen = conversation.skillIds, onDismiss = { showSkills = false }) { ids -> showSkills = false; model.chooseSkills(context, ids) }
    if (showDrafts) ModalBottomSheet(onDismissRequest = { showDrafts = false }) {
        Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            Text(stringResource(R.string.ai_drafts), style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
            Text(stringResource(R.string.ai_drafts_text), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 20.dp))
            LazyColumn(Modifier.heightIn(max = 420.dp).padding(top = 8.dp)) {
                items(model.drafts, key = { it.id }) { item ->
                    DraftRow(item, onOpen = { showDrafts = false; model.openDraft(context, item.id) }, onDelete = { model.deleteDraft(context, item.id) })
                }
            }
        }
    }
}

/** Why there is no conversation about this widget, with the way back. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Refusal(text: String, onBack: () -> Unit) {
    Scaffold(topBar = {
        TopAppBar(title = { Text(stringResource(R.string.ai_subtitle_installed)) }, navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.ai_back)) } })
    }) { padding -> Text(text, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(padding).padding(24.dp)) }
}

/** How many console lines the Logs dialog shows: the last ones. */
private const val MAXIMUM_LOG_LINES_SHOWN = 200

/**
 * Chooses the Skills of a conversation. [chosen] is what the conversation holds; null means it
 * has no choice of its own yet, and the Skills enabled in the app are shown ticked, because
 * those are the ones that apply until a choice is made here.
 */
@Composable
private fun SkillsDialog(chosen: List<String>?, onDismiss: () -> Unit, onChoose: (List<String>) -> Unit) {
    val context = LocalContext.current
    var skills by remember { mutableStateOf<List<Skill>?>(null) }
    var ticked by remember { mutableStateOf<Set<String>>(emptySet()) }
    LaunchedEffect(Unit) {
        val loaded = withContext(Dispatchers.IO) {
            runCatching { com.everettjf.scriptwidget.GalleryServices.get(context).skills.let { it.list() to it.enabledIds() } }.getOrDefault(emptyList<Skill>() to emptySet())
        }
        ticked = (chosen?.toSet() ?: loaded.second) intersect loaded.first.map { it.id }.toSet()
        skills = loaded.first
    }
    AlertDialog(
        onDismissRequest = onDismiss, title = { Text(stringResource(R.string.ai_skills_title)) },
        text = {
            Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                Text(stringResource(R.string.ai_skills_text), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 8.dp))
                val all = skills
                if (all == null) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                else if (all.isEmpty()) Text(stringResource(R.string.ai_skills_none), style = MaterialTheme.typography.bodyMedium)
                else for (skill in all) {
                    val on = skill.id in ticked
                    Row(
                        Modifier.fillMaxWidth().selectable(selected = on, role = Role.Checkbox, onClick = { ticked = if (on) ticked - skill.id else ticked + skill.id }).padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(checked = on, onCheckedChange = null)
                        Column(Modifier.padding(start = 12.dp)) {
                            Text(skill.title, style = MaterialTheme.typography.bodyLarge)
                            if (skill.summary.isNotBlank()) Text(skill.summary, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(enabled = skills != null, onClick = { onChoose(ticked.toList()) }) { Text(stringResource(R.string.ai_skills_done)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.ai_cancel)) } },
    )
}

@Composable
private fun DraftRow(item: AiConversationSummary, onOpen: () -> Unit, onDelete: (() -> Unit)?) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(start = 20.dp, end = 8.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(item.title.ifEmpty { stringResource(R.string.ai_untitled) }, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
            Text(
                (if (item.versionCount == 0) stringResource(R.string.ai_no_version) else counted(item.versionCount, R.string.ai_versions_one, R.string.ai_versions_other)) + " · " +
                    (if (System.currentTimeMillis() - item.updatedAt < DateUtils.MINUTE_IN_MILLIS) stringResource(R.string.ai_just_now) else DateUtils.getRelativeTimeSpanString(item.updatedAt, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (onDelete != null) IconButton(onClick = onDelete) { Icon(Icons.Default.DeleteOutline, stringResource(R.string.ai_delete_draft, item.title)) }
    }
}

/** A short name for a new widget from what the user first asked: its first phrase, a few words long. */
internal fun suggestedName(title: String, fallback: String = "AI Widget"): String {
    val phrase = title.trim().split('.', ',', ':', ';', '!', '?', '。', '，', '\n').firstOrNull { it.isNotBlank() }?.trim().orEmpty().removeSuffix("…")
    val words = phrase.split(' ').filter { it.isNotBlank() }
    var name = ""
    for (word in words) { if ((name + " " + word).trim().length > 28) break; name = (name + " " + word).trim() }
    if (name.isEmpty()) name = phrase.take(28)
    return name.replace(Regex("[/\\\\:*?\"<>|]"), " ").trim().ifBlank { fallback }.replaceFirstChar { it.uppercase() }
}

/** The text of an example's chip; an example without a text here keeps its title. */
internal fun exampleTitleResource(title: String): Int? = when (title) {
    "Weather" -> R.string.ai_example_weather
    "Clock" -> R.string.ai_example_clock
    "Countdown" -> R.string.ai_example_countdown
    "Crypto Price" -> R.string.ai_example_crypto_price
    "Battery Ring" -> R.string.ai_example_battery_ring
    "Quote" -> R.string.ai_example_quote
    "Steps" -> R.string.ai_example_steps
    "Habit Grid" -> R.string.ai_example_habit_grid
    else -> null
}

@Composable
private fun exampleTitle(example: com.everettjf.scriptwidget.core.ai.AiExamplePrompt): String =
    exampleTitleResource(example.title)?.let { stringResource(it) } ?: example.title

/** [AiConversationUsageAdvice.message] from the string resources. */
internal fun usageAdviceText(resources: android.content.res.Resources, advice: AiConversationUsageAdvice): String = when (advice.reason) {
    AiConversationUsageAdvice.Reason.HEAVY_REQUESTS -> resources.getString(R.string.ai_advice_heavy_requests, "%,d".format(advice.tokens))
    AiConversationUsageAdvice.Reason.HEAVY_TOTAL -> resources.getString(R.string.ai_advice_heavy_total, "%,d".format(advice.tokens))
    AiConversationUsageAdvice.Reason.VERSIONS_FULL -> resources.getString(R.string.ai_advice_versions_full, AiConversationLimits.MAX_VERSIONS)
    AiConversationUsageAdvice.Reason.HISTORY_FULL -> resources.getString(R.string.ai_advice_history_full, AiConversationLimits.HISTORY_TURNS)
}

@Composable
private fun usageAdviceText(advice: AiConversationUsageAdvice): String = usageAdviceText(LocalContext.current.resources, advice)

/** A text with a count in it: the singular for 1. */
@Composable
private fun counted(count: Int, one: Int, other: Int): String = stringResource(if (count == 1) one else other, count)

/** The name of a size. */
private fun sizeName(size: AiWidgetSize): Int = when (size) {
    AiWidgetSize.SMALL -> R.string.ai_size_small
    AiWidgetSize.MEDIUM -> R.string.ai_size_medium
    AiWidgetSize.LARGE -> R.string.ai_size_large
}

/** One size of the widget, drawn small, with its name. Running it costs nothing but time on the device. */
@Composable
private fun SizeThumbnail(option: AiWidgetSize, selected: Boolean, files: com.everettjf.scriptwidget.core.runtime.PackageFiles, revision: Int, dark: Boolean, onClick: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier.clip(RoundedCornerShape(10.dp)).selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .background(if (selected) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent).padding(horizontal = 6.dp, vertical = 4.dp),
    ) {
        Box(Modifier.height(36.dp), contentAlignment = Alignment.Center) {
            WidgetPreview(files = files, packageID = PREVIEW_PACKAGE_ID, family = option.family, dark = dark, revision = revision, maxHeight = if (option == AiWidgetSize.LARGE) 36f else 26f)
        }
        Text(stringResource(sizeName(option)), style = MaterialTheme.typography.labelSmall, color = if (selected) MaterialTheme.colorScheme.onSecondaryContainer else MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** The widget as it is now, its size, its versions and the button that keeps it. */
@Composable
private fun PreviewPanel(
    size: AiWidgetSize, version: AiConversationVersion, position: Int, count: Int, previousId: String?, nextId: String?,
    installed: InstalledPackage?, dark: Boolean, running: Boolean, applied: Boolean,
    /** Why the version failed when the preview last ran it; null when it ran. */
    failure: String?, canFix: Boolean, onRan: (ExecutionResult?) -> Unit, onFix: () -> Unit,
    onSize: (AiWidgetSize) -> Unit, onVersion: (String) -> Unit, onCode: () -> Unit, onSave: () -> Unit,
) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainerLow, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            // The version runs from memory with exactly the manifest it would be saved with.
            val files = remember(version.id, installed?.installation) { AiCandidates.files(installed, version.source, version.networkDomains) }
            Box(contentAlignment = Alignment.TopEnd) {
                WidgetPreview(files = files, packageID = PREVIEW_PACKAGE_ID, family = size.family, dark = dark, revision = version.number, maxHeight = 190f, onResult = onRan)
                if (running) Surface(shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f), modifier = Modifier.padding(8.dp)) {
                    Text(stringResource(R.string.ai_version_while_working, version.number), style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp))
                }
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                // The widget at every size, side by side; a tap shows that size above.
                for (option in AiWidgetSize.entries) SizeThumbnail(option, selected = size == option, files = files, revision = version.number, dark = dark) { onSize(option) }
                Spacer(Modifier.weight(1f))
                IconButton(enabled = !running && previousId != null, onClick = { previousId?.let(onVersion) }) { Icon(Icons.Default.ChevronLeft, stringResource(R.string.ai_previous_version)) }
                // Position among the versions that are kept, which is what the arrows move through.
                val positionDescription = stringResource(R.string.ai_position_description, version.number, position, count)
                Text(stringResource(R.string.ai_position, position, count), style = MaterialTheme.typography.labelLarge, maxLines = 1, modifier = Modifier.semantics { contentDescription = positionDescription })
                IconButton(enabled = !running && nextId != null, onClick = { nextId?.let(onVersion) }) { Icon(Icons.Default.ChevronRight, stringResource(R.string.ai_next_version)) }
            }
            if (version.networkDomains.isNotEmpty()) Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Language, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(stringResource(R.string.ai_may_contact, version.networkDomains.joinToString(", ")), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 6.dp))
            }
            // A version that ran when it was made can fail later (the network is gone), and code taken over from the editor may never have run.
            if (failure != null) Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.ErrorOutline, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.error)
                Text(
                    failure.lineSequence().firstOrNull { it.isNotBlank() }?.trim().orEmpty(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
                    maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).padding(start = 6.dp),
                )
                TextButton(enabled = canFix, onClick = onFix) { Text(stringResource(R.string.ai_fix_runtime_error)) }
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onCode) { Icon(Icons.Default.Code, null, Modifier.size(18.dp)); Text(stringResource(R.string.ai_code), Modifier.padding(start = 6.dp)) }
                Spacer(Modifier.weight(1f))
                if (installed != null && applied) Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.CheckCircle, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
                    Text(stringResource(R.string.ai_in_widget), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 6.dp, end = 8.dp))
                } else Button(enabled = !running, onClick = onSave) { Text(if (installed == null) stringResource(R.string.ai_save_widget) else stringResource(R.string.ai_apply_to_widget)) }
            }
        }
    }
    HorizontalDivider()
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun EmptyState(
    installed: InstalledPackage?, profile: AiProfile?, drafts: List<AiConversationSummary>, enabled: Boolean,
    onExample: (com.everettjf.scriptwidget.core.ai.AiExamplePrompt) -> Unit, onDraft: (String) -> Unit, onAllDrafts: () -> Unit, modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (installed == null) {
            Text(stringResource(R.string.ai_empty_title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.ai_empty_text), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(stringResource(R.string.ai_try_example), style = MaterialTheme.typography.labelLarge)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (example in AiExamplePrompts.all) AssistChip(enabled = enabled, onClick = { onExample(example) }, label = { Text(exampleTitle(example)) })
            }
            if (drafts.isNotEmpty()) {
                Text(stringResource(R.string.ai_continue_draft), style = MaterialTheme.typography.labelLarge)
                Card(Modifier.fillMaxWidth()) {
                    Column {
                        for (item in drafts.take(3)) DraftRow(item, onOpen = { onDraft(item.id) }, onDelete = null)
                        if (drafts.size > 3) TextButton(onClick = onAllDrafts, modifier = Modifier.padding(horizontal = 12.dp)) { Text(stringResource(R.string.ai_all_drafts, drafts.size)) }
                    }
                }
            }
        } else {
            Text(stringResource(R.string.ai_change_title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.ai_change_text, installed.displayName), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        profile?.let { active ->
            val host = runCatching { URI(active.normalizedBaseUrl).host }.getOrNull().orEmpty()
            Text(
                stringResource(R.string.ai_provider_note, active.kind.displayName, active.model.ifBlank { stringResource(R.string.ai_no_model) }, host.ifEmpty { stringResource(R.string.ai_configured_server) }),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** One line of a comparison. The sign is drawn as well as the color, so that the color is not the only cue. */
@Composable
private fun DiffLine(line: AiSourceDiff.Line) {
    if (line.kind == AiSourceDiff.Kind.SKIPPED) {
        Text(counted(line.skipped, R.string.ai_unchanged_lines_one, R.string.ai_unchanged_lines_other), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 4.dp))
        return
    }
    val (sign, tint, label) = when (line.kind) {
        AiSourceDiff.Kind.ADDED -> Triple("+", Color(0xFF2E7D32).copy(alpha = 0.20f), stringResource(R.string.ai_diff_added))
        AiSourceDiff.Kind.REMOVED -> Triple("−", Color(0xFFC62828).copy(alpha = 0.18f), stringResource(R.string.ai_diff_removed))
        else -> Triple(" ", Color.Transparent, stringResource(R.string.ai_diff_unchanged))
    }
    val description = stringResource(R.string.ai_diff_line_description, label, line.text)
    Text(
        "$sign ${line.text}", style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace, softWrap = false,
        modifier = Modifier.background(tint).padding(horizontal = 4.dp, vertical = 1.dp).semantics { contentDescription = description },
    )
}

/**
 * One turn as the list draws it. The conversation changes in place, which Compose can not
 * see, so the screen makes these values anew whenever it changes and the rows compare them.
 */
private data class TurnUi(
    val id: String, val request: String, val status: AiConversationTurn.Status, val note: String?, val error: String?, val repairs: Int, val tokens: Int,
    val abandoned: Boolean, val manual: Boolean, val versionId: String?, val versionNumber: Int?, val isCurrent: Boolean, val hasFailedSource: Boolean,
    /** Lines the version added and removed against the one it was made from; null when there is nothing to compare. */
    val added: Int? = null, val removed: Int? = null,
) {
    companion object {
        fun of(conversation: AiConversation, turn: AiConversationTurn): TurnUi {
            val version = conversation.version(turn.versionId)
            val changes = conversation.version(version?.parentId)?.let { parent -> AiSourceDiff.summary(parent.source, version!!.source) }?.takeIf { !it.isEmpty }
            return TurnUi(
                turn.id, turn.request, turn.status, turn.note,
                // The first line says what went wrong; the rest is the runtime's view of the source.
                turn.errorSummary?.lineSequence()?.firstOrNull { it.isNotBlank() }?.trim(),
                turn.repairs, turn.usage.totalTokens, turn.isAbandoned, turn.isManualEdit, version?.id, version?.number,
                version != null && version.id == conversation.currentVersionId, turn.failedSource != null,
                changes?.added, changes?.removed,
            )
        }
    }
}

@Composable
private fun TurnList(
    turns: List<TurnUi>, totalTokens: Int, activity: String?, live: String, running: Boolean,
    onVersion: (String) -> Unit, onRetry: (String) -> Unit, onFailedCode: (String) -> Unit, onChanges: (String) -> Unit, modifier: Modifier = Modifier,
) {
    val state = rememberLazyListState()
    // The newest turn stays in view while it changes.
    LaunchedEffect(turns.size, turns.lastOrNull(), activity, live.isEmpty()) { if (turns.isNotEmpty()) state.animateScrollToItem(turns.size) }
    LazyColumn(modifier.fillMaxWidth(), state = state, contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        items(turns, key = { it.id }) { turn -> TurnRow(turn, activity, live, running, onVersion, onRetry, onFailedCode, onChanges) }
        item(key = "total") {
            if (totalTokens > 0) Text(stringResource(R.string.ai_total_tokens, totalTokens), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.fillMaxWidth().padding(top = 2.dp))
            else Spacer(Modifier.size(1.dp))
        }
    }
}

@Composable
private fun VersionLine(turn: TurnUi, running: Boolean, onVersion: (String) -> Unit, onChanges: (String) -> Unit) {
    val versionId = turn.versionId ?: return
    val changesDescription = if (turn.added != null && turn.removed != null) stringResource(R.string.ai_changes_description, turn.added, turn.removed) else ""
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Default.CheckCircle, null, Modifier.size(16.dp), tint = if (turn.isCurrent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
        Text(stringResource(R.string.ai_version, turn.versionNumber ?: 0), style = MaterialTheme.typography.labelLarge, color = if (turn.isCurrent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 6.dp))
        if (turn.isCurrent) Text(stringResource(R.string.ai_shown_above), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 8.dp))
        else TextButton(enabled = !running, onClick = { onVersion(versionId) }, contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp)) { Text(stringResource(R.string.ai_show_this_version)) }
        if (turn.added != null && turn.removed != null) TextButton(
            onClick = { onChanges(versionId) }, contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp),
            modifier = Modifier.semantics { contentDescription = changesDescription },
        ) { Text("+${turn.added} −${turn.removed}", fontFamily = FontFamily.Monospace) }
        if (turn.abandoned) Text(stringResource(R.string.ai_left_behind), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 4.dp))
    }
}

@Composable
private fun TurnRow(turn: TurnUi, activity: String?, live: String, running: Boolean, onVersion: (String) -> Unit, onRetry: (String) -> Unit, onFailedCode: (String) -> Unit, onChanges: (String) -> Unit) {
    val faded = if (turn.abandoned) 0.55f else 1f
    if (turn.manual) {
        Column(Modifier.fillMaxWidth().alpha(faded), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Edit, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(stringResource(R.string.ai_installed_code), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 6.dp))
            }
            VersionLine(turn, running, onVersion, onChanges)
        }
        return
    }
    Column(Modifier.fillMaxWidth().alpha(faded), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            Text(
                turn.request, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.widthIn(max = 300.dp).clip(RoundedCornerShape(18.dp, 18.dp, 4.dp, 18.dp)).background(MaterialTheme.colorScheme.primaryContainer).padding(horizontal = 14.dp, vertical = 10.dp),
            )
        }
        when (turn.status) {
            AiConversationTurn.Status.RUNNING -> {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    Text(activity ?: stringResource(R.string.ai_working), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 10.dp))
                }
                // The code as it arrives. A model that does not stream shows nothing here.
                val liveDescription = stringResource(R.string.ai_code_being_written)
                if (live.isNotEmpty()) Text(
                    live, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    softWrap = false, overflow = TextOverflow.Clip, minLines = AiConversationViewModel.LIVE_LINES, maxLines = AiConversationViewModel.LIVE_LINES,
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.surfaceContainerHighest).padding(8.dp)
                        .semantics { contentDescription = liveDescription },
                )
            }
            AiConversationTurn.Status.SUCCEEDED -> {
                Text(turn.note ?: stringResource(R.string.ai_done), style = MaterialTheme.typography.bodyLarge)
                if (turn.repairs > 0) Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.AutoFixHigh, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(counted(turn.repairs, R.string.ai_fixed_one, R.string.ai_fixed_other), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 6.dp))
                }
                VersionLine(turn, running, onVersion, onChanges)
            }
            AiConversationTurn.Status.UNCONVERGED -> {
                Text(stringResource(R.string.ai_did_not_run), style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.error)
                turn.error?.let { Text(it, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 3, overflow = TextOverflow.Ellipsis) }
                Row {
                    TextButton(enabled = !running, onClick = { onRetry(turn.id) }) { Text(stringResource(R.string.ai_try_again)) }
                    if (turn.hasFailedSource) TextButton(onClick = { onFailedCode(turn.id) }) { Text(stringResource(R.string.ai_show_its_code)) }
                }
            }
            AiConversationTurn.Status.FAILED -> {
                Text(turn.error ?: stringResource(R.string.ai_request_failed), style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.error)
                TextButton(enabled = !running, onClick = { onRetry(turn.id) }) { Text(stringResource(R.string.ai_retry)) }
            }
            AiConversationTurn.Status.CANCELLED -> {
                Text(stringResource(R.string.ai_stopped), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(enabled = !running, onClick = { onRetry(turn.id) }) { Text(stringResource(R.string.ai_send_again)) }
            }
            AiConversationTurn.Status.INTERRUPTED -> {
                Text(stringResource(R.string.ai_interrupted), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(enabled = !running, onClick = { onRetry(turn.id) }) { Text(stringResource(R.string.ai_send_again)) }
            }
        }
        if (turn.tokens > 0 && turn.status != AiConversationTurn.Status.RUNNING) Text(stringResource(R.string.ai_tokens, turn.tokens), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** The request field. It stays above the keyboard. */
@Composable
private fun Composer(text: String, onText: (String) -> Unit, running: Boolean, enabled: Boolean, placeholder: String, onSend: () -> Unit, onStop: () -> Unit) {
    Surface(tonalElevation = 3.dp) {
        Row(Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.Bottom) {
            OutlinedTextField(
                text, onText, enabled = enabled && !running, maxLines = 5, placeholder = { Text(placeholder) }, shape = RoundedCornerShape(24.dp),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences), modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            if (running) FilledTonalIconButton(onClick = onStop, modifier = Modifier.padding(bottom = 4.dp)) { Icon(Icons.Default.Stop, stringResource(R.string.ai_stop)) }
            else FilledIconButton(enabled = enabled && text.isNotBlank(), onClick = onSend, modifier = Modifier.padding(bottom = 4.dp)) { Icon(Icons.AutoMirrored.Filled.Send, stringResource(R.string.ai_send)) }
        }
    }
}
