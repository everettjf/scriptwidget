package com.everettjf.scriptwidget.ui

import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Save
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.navigation.NavController
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.core.runtime.ExecutionResult
import com.everettjf.scriptwidget.core.runtime.PackageCompiler
import com.everettjf.scriptwidget.widget.WidgetScheduler

/**
 * Source editor with a live preview. The default editor is the CodeMirror
 * Studio editor shared with the Apple apps; a plain text editor remains as a
 * fallback. Saving writes the file atomically, clears the compiled cache and
 * redraws widgets that show the package.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditorScreen(navigation: NavController, name: String) {
    val context = LocalContext.current
    val installed = remember { AppServices.library.find(name) }
    if (installed == null) { Text("This widget is no longer installed.", Modifier.padding(32.dp)); return }
    val paths = remember { installed.files.paths().filter { PackageCompiler.isTextFile(it) }.sortedBy { if (it == "main.jsx") "" else it } }
    var path by remember { mutableStateOf(paths.firstOrNull() ?: "main.jsx") }
    var saved by remember { mutableStateOf(installed.files.readText(path).orEmpty()) }
    var text by remember { mutableStateOf(TextFieldValue(saved)) }
    var revision by remember { mutableIntStateOf(0) }
    var result by remember { mutableStateOf<ExecutionResult?>(null) }
    var plain by remember { mutableStateOf(false) }
    var family by remember { mutableStateOf("medium") }
    val dark = isSystemInDarkTheme()
    val dirty = plain && text.text != saved

    fun write(content: String): Boolean = runCatching {
        if (content.toByteArray().size > 512 * 1024) error("Source exceeds the 512 KiB limit")
        if (content == saved) return@runCatching
        AppServices.library.writeFile(installed.name, path, content.toByteArray())
        saved = content
        revision += 1
        WidgetScheduler.refreshPackage(context, installed.installation)
    }.onFailure { Toast.makeText(context, it.message ?: "Could not save", Toast.LENGTH_LONG).show() }.isSuccess

    val studio = remember { StudioEditor(context, onSave = { content -> write(content) }) }
    DisposableEffect(Unit) { onDispose { studio.destroy() } }
    LaunchedEffect(path, plain) { if (!plain) studio.open("${installed.installation}/$path", saved) }
    LaunchedEffect(dark) { studio.setTheme(dark) }
    LaunchedEffect(result) { studio.publishDiagnostics(result?.error?.let { "[${it.kind}] ${it.message}" }) }

    /** Saves whatever the active editor holds, then runs [then]. */
    fun saveThen(then: () -> Unit) {
        if (plain) { if (write(text.text)) then() }
        else studio.content { content -> if (content == null || write(content)) then() }
    }

    BackHandler { saveThen { navigation.popBackStack() } }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(if (dirty) "$path •" else path, maxLines = 1) },
            navigationIcon = { IconButton(onClick = { saveThen { navigation.popBackStack() } }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            actions = {
                if (!plain) IconButton(onClick = { studio.format() }) { Icon(Icons.Default.AutoFixHigh, "Format") }
                IconButton(onClick = { saveThen { plain = !plain; text = TextFieldValue(saved) } }) { Icon(Icons.Default.SwapHoriz, if (plain) "Use the Studio editor" else "Use the plain editor") }
                IconButton(onClick = { saveThen { revision += 1; Toast.makeText(context, "Saved", Toast.LENGTH_SHORT).show() } }) { Icon(Icons.Default.PlayArrow, "Save and run") }
            },
        )
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().imePadding()) {
            Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), contentAlignment = Alignment.Center) {
                WidgetPreview(installed.files, installed.installation, family, dark, Modifier.height(140.dp), buildDirectory = installed.buildDirectory, revision = revision) { result = it }
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally)) {
                for (size in listOf("small", "medium", "large")) FilterChip(selected = family == size, onClick = { family = size }, label = { Text(size.replaceFirstChar { it.uppercase() }) })
            }
            result?.error?.let { error ->
                Text("[${error.kind}] ${error.message}", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                    maxLines = 4, modifier = Modifier.padding(horizontal = 16.dp))
            }
            if (paths.size > 1) Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (candidate in paths) FilterChip(selected = candidate == path, label = { Text(candidate) }, onClick = {
                    if (candidate != path) saveThen {
                        path = candidate
                        saved = installed.files.readText(candidate).orEmpty()
                        text = TextFieldValue(saved)
                    }
                })
            }
            if (plain) BasicTextField(
                value = text, onValueChange = { text = it },
                textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp, lineHeight = 19.sp, color = MaterialTheme.colorScheme.onSurface),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = KeyboardType.Ascii),
                modifier = Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState()).padding(16.dp),
            ) else AndroidView(factory = { studio.webView }, modifier = Modifier.weight(1f).fillMaxWidth())
        }
    }
}
