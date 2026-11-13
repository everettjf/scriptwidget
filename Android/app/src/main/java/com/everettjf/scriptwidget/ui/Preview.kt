package com.everettjf.scriptwidget.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.core.RunRequest
import com.everettjf.scriptwidget.core.runtime.ExecutionResult
import com.everettjf.scriptwidget.core.runtime.PackageFiles
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** Widget sizes in dp used for in-app previews; a placed widget uses the launcher's size. */
val previewSizes = mapOf("small" to (160f to 160f), "medium" to (330f to 160f), "large" to (330f to 330f), "extraLarge" to (680f to 330f))

class PreviewState(val bitmap: Bitmap?, val result: ExecutionResult?)

/** Runs a package and draws it, off the main thread. [revision] forces a rerun. */
suspend fun renderPreview(files: PackageFiles, packageID: String, family: String, dark: Boolean, parameter: String, buildDirectory: File?, density: Float): PreviewState =
    withContext(Dispatchers.Default) {
        val runtime = AppServices.runtime
        val (width, height) = previewSizes[family] ?: previewSizes.getValue("medium")
        val request = RunRequest(files, packageID, family, parameter, dark, buildDirectory = buildDirectory)
        runCatching {
            val result = runtime.run(request)
            PreviewState(runtime.render(request, result, width, height, density).bitmap, result.execution)
        }.getOrElse { PreviewState(null, null) }
    }

@Composable
fun WidgetPreview(
    files: PackageFiles, packageID: String, family: String, dark: Boolean, modifier: Modifier = Modifier, parameter: String = "",
    buildDirectory: File? = null, revision: Int = 0, onResult: (ExecutionResult?) -> Unit = {},
) {
    val density = LocalDensity.current.density
    val state by produceState<PreviewState?>(initialValue = null, packageID, family, dark, parameter, revision) {
        value = renderPreview(files, packageID, family, dark, parameter, buildDirectory, minOf(density, 3f))
        onResult(value?.result)
    }
    val (width, height) = previewSizes[family] ?: previewSizes.getValue("medium")
    Box(
        modifier.widthIn(max = width.dp).fillMaxWidth().aspectRatio(width / height).clip(RoundedCornerShape(22.dp)).background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        val bitmap = state?.bitmap
        if (bitmap != null) Image(bitmap.asImageBitmap(), contentDescription = "Widget preview", contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxWidth().aspectRatio(width / height))
        else if (state == null) CircularProgressIndicator()
    }
}
