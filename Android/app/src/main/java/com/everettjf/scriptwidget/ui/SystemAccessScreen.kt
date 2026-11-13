package com.everettjf.scriptwidget.ui

import android.Manifest
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.navigation.NavController
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.SystemModules
import com.everettjf.scriptwidget.core.system.AndroidHealthPlatform
import com.everettjf.scriptwidget.core.system.CalendarModule
import com.everettjf.scriptwidget.core.system.CalendarSelection
import com.everettjf.scriptwidget.core.system.CalendarSource
import com.everettjf.scriptwidget.core.system.HealthModule
import com.everettjf.scriptwidget.core.system.LocationGrant
import com.everettjf.scriptwidget.core.system.LocationModule
import com.everettjf.scriptwidget.core.system.NotificationsModule
import com.everettjf.scriptwidget.core.system.PhotoEntry
import com.everettjf.scriptwidget.core.system.PhotoLimits
import com.everettjf.scriptwidget.core.system.SystemLog
import com.everettjf.scriptwidget.core.system.SystemReject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Where the user gives widgets access to system data. Widgets run in the
 * background and can never prompt, so every permission request, source
 * selection and account connection happens here.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SystemAccessScreen(navigation: NavController) {
    val context = LocalContext.current
    val stores = remember { SystemModules.stores(context) }
    val scope = rememberCoroutineScope()
    // Bumped after every change, and when returning from system settings, to re-read state.
    var revision by remember { mutableIntStateOf(0) }
    var message by remember { mutableStateOf("") }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) { stores.location.recheck(); revision += 1 } }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    fun openAppSettings() = context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    val locationRequest = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        stores.prompts.markAsked(LocationModule.PROMPT)
        SystemLog.call("access.location.request", "granted=${result.values.any { it }}")
        revision += 1
    }
    val calendarRequest = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        stores.prompts.markAsked(CalendarModule.PROMPT)
        SystemLog.call("access.calendar.request", "granted=${result.values.all { it }}")
        revision += 1
    }
    val notificationRequest = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        stores.prompts.markAsked(NotificationsModule.PROMPT)
        SystemLog.call("access.notifications.request", "granted=$granted")
        revision += 1
    }
    // The outcome is not inspected: finishing the review says nothing about which types were shared.
    val healthRequest = rememberLauncherForActivityResult(PermissionController.createRequestPermissionResultContract()) { _ ->
        stores.prompts.markAsked(HealthModule.PROMPT)
        SystemLog.call("access.health.request", "reviewed")
        revision += 1
    }
    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(PhotoLimits.MAXIMUM_SELECTED)) { uris ->
        if (uris.isNotEmpty()) scope.launch {
            val added = withContext(Dispatchers.IO) { stores.photoImporter.import(uris) }
            message = if (added == uris.size) "Added $added photo${if (added == 1) "" else "s"}." else "Added $added of ${uris.size}. At most ${PhotoLimits.MAXIMUM_SELECTED} photos can be selected; some images could not be read."
            revision += 1
        }
    }

    Scaffold(topBar = {
        TopAppBar(title = { Text("System Access") }, navigationIcon = { IconButton(onClick = { navigation.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState())) {
            ListItem(headlineContent = { Text("Widgets cannot ask for access") },
                supportingContent = { Text("Widgets run in the background. Allow access, choose sources and connect accounts here; a widget only sees what you allow, and only if its package declares the capability.") })
            if (message.isNotEmpty()) ListItem(headlineContent = { Text(message, color = MaterialTheme.colorScheme.primary) })

            // MARK: Location
            AccessSection("Location")
            val grant = remember(revision) { stores.locationPlatform.grant() }
            val servicesOn = remember(revision) { stores.locationPlatform.servicesEnabled() }
            val age = remember(revision) { stores.location.snapshotAgeSeconds() }
            ListItem(headlineContent = { Text(when (grant) { LocationGrant.PRECISE -> "Precise location allowed"; LocationGrant.APPROXIMATE -> "Approximate location allowed"; LocationGrant.NONE -> "Location not allowed" }) },
                supportingContent = { Text((if (servicesOn) "" else "Location is turned off for this device. ") +
                    (if (age == null) "No saved position. " else "Saved position is ${formatAge(age)} old. ") +
                    "ScriptWidget reads your position only while the app is open and never in the background. Widgets show the saved position with its age; it is discarded after 24 hours or when access changes.") })
            Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { locationRequest.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)) }) { Text(if (grant == LocationGrant.NONE) "Allow location" else "Change precision") }
                OutlinedButton(enabled = grant != LocationGrant.NONE && servicesOn, onClick = {
                    message = "Finding your position…"
                    stores.location.refreshFromApp { stored -> scope.launch { message = if (stored) "Position saved for widgets." else "No position was available. Try again outdoors or with Wi-Fi on."; revision += 1 } }
                }) { Text("Refresh position") }
            }
            TextButton(modifier = Modifier.padding(horizontal = 8.dp), onClick = { openAppSettings() }) { Text("Open Android app settings") }

            // MARK: Calendar
            AccessSection("Calendar")
            val calendarStatus = remember(revision) { stores.calendar.systemStatus() }
            val canWrite = remember(revision) { stores.calendarPlatform.canWrite() }
            val selection = remember(revision) { runCatching { stores.calendarSelection.load() }.getOrNull() }
            val calendars by produceState(emptyList<CalendarSource>(), revision) {
                value = withContext(Dispatchers.IO) { if (calendarStatus == "authorized") runCatching { stores.calendarPlatform.sources() }.getOrDefault(emptyList()) else emptyList() }
            }
            ListItem(headlineContent = { Text(when (calendarStatus) { "authorized" -> if (canWrite) "Calendar access allowed" else "Calendar read access allowed"; "writeOnly" -> "Only adding events is allowed"; "denied" -> "Calendar access denied"; else -> "Calendar access not requested" }) },
                supportingContent = { Text("Widgets read titles and times of events in the calendars you select below. Notes, guests and locations are never shared. A widget can only change events it created itself.") })
            OutlinedButton(modifier = Modifier.padding(horizontal = 16.dp), onClick = {
                if (calendarStatus == "denied") openAppSettings() else calendarRequest.launch(arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR))
            }) { Text(if (calendarStatus == "authorized" && canWrite) "Review calendar permission" else "Allow calendar access") }
            if (calendarStatus == "authorized") {
                if (selection == null) ListItem(headlineContent = { Text("Calendar selection could not be read") },
                    supportingContent = { Text("Widgets cannot read events until you choose calendars again.") },
                    trailingContent = { TextButton(onClick = { stores.calendarSelection.save(CalendarSelection.NONE); revision += 1 }) { Text("Reset") } })
                ListItem(headlineContent = { Text("All calendars, including new ones") },
                    trailingContent = { Switch(selection?.calendarIDs == null && selection != null, onCheckedChange = { all ->
                        stores.calendarSelection.save(if (all) CalendarSelection.ALL else CalendarSelection.NONE)
                        SystemLog.call("access.calendar.selection", if (all) "all" else "selected count=0")
                        revision += 1
                    }) })
                val chosen = selection?.calendarIDs
                if (chosen != null) {
                    if (chosen.isEmpty()) ListItem(headlineContent = { Text("No calendars selected") }, supportingContent = { Text("Widgets show a setup message until you select at least one calendar.") })
                    for (calendar in calendars.take(64)) ListItem(
                        headlineContent = { Text(calendar.title.ifEmpty { "Untitled calendar" }) },
                        supportingContent = { if (!calendar.writable) Text("Read only") },
                        trailingContent = { Checkbox(calendar.id in chosen, onCheckedChange = { checked ->
                            val next = if (checked) (chosen + calendar.id).distinct().take(64) else chosen - calendar.id
                            stores.calendarSelection.save(CalendarSelection(next))
                            SystemLog.call("access.calendar.selection", "selected count=${next.size}")
                            revision += 1
                        }) },
                    )
                    val missing = chosen.count { id -> calendars.none { it.id == id } }
                    if (missing > 0 && calendars.isNotEmpty()) ListItem(headlineContent = { Text("$missing selected calendar${if (missing == 1) " is" else "s are"} no longer available") },
                        trailingContent = { TextButton(onClick = { stores.calendarSelection.save(CalendarSelection(chosen.filter { id -> calendars.any { it.id == id } })); revision += 1 }) { Text("Remove") } })
                }
            }

            // MARK: Photos
            AccessSection("Photos")
            val photos = remember(revision) { runCatching { stores.photoLibrary.list() }.getOrNull() }
            ListItem(headlineContent = { Text(if (photos == null) "Selected photos could not be read" else "${photos.size} of ${PhotoLimits.MAXIMUM_SELECTED} photos selected") },
                supportingContent = { Text("Photos you choose are copied into ScriptWidget as small thumbnails (at most 768 px) without location or camera details. Widgets never see your library, and no storage permission is used.") })
            Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(enabled = photos != null && photos.size < PhotoLimits.MAXIMUM_SELECTED, onClick = {
                    photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }) { Text("Choose photos") }
                OutlinedButton(enabled = photos == null || photos.isNotEmpty(), onClick = { stores.photoLibrary.clear(); SystemLog.call("access.photos.clear", "ok"); revision += 1 }) { Text("Remove all") }
            }
            if (!photos.isNullOrEmpty()) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (photo in photos) PhotoTile(photo, load = { stores.photoLibrary.read(photo) }, remove = { stores.photoLibrary.remove(photo.id); SystemLog.call("access.photos.remove", "ok"); revision += 1 })
            }

            // MARK: Notifications
            AccessSection("Notifications")
            val notificationStatus = remember(revision) { stores.notifications.authorization() }
            val pendingCount = remember(revision) { runCatching { stores.notificationStore.all().size }.getOrDefault(0) }
            ListItem(headlineContent = { Text(when (notificationStatus) { "authorized" -> "Notifications allowed"; "denied" -> "Notifications denied"; else -> "Notifications not requested" }) },
                supportingContent = { Text("$pendingCount reminder${if (pendingCount == 1) "" else "s"} scheduled by widgets. Reminders arrive within about ten minutes of their time; Android may delay them further to save battery.") })
            OutlinedButton(modifier = Modifier.padding(horizontal = 16.dp), onClick = {
                if (notificationStatus == "denied") openAppSettings() else notificationRequest.launch(Manifest.permission.POST_NOTIFICATIONS)
            }) { Text(if (notificationStatus == "authorized") "Review notification permission" else "Allow notifications") }

            // MARK: Health
            AccessSection("Health")
            val healthStatus = remember(revision) { stores.healthPlatform.sdkStatus() }
            val healthReviewed = remember(revision) { stores.prompts.asked(HealthModule.PROMPT) }
            // Permission state only; no health record is read to draw this section.
            val healthGranted by produceState<Set<String>?>(null, revision) {
                value = withContext(Dispatchers.IO) { if (healthStatus == HealthConnectClient.SDK_AVAILABLE) stores.healthPlatform.grantedPermissions() else emptySet() }
            }
            if (healthStatus != HealthConnectClient.SDK_AVAILABLE) {
                ListItem(headlineContent = { Text(if (healthStatus == HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED) "Health Connect needs an update" else "Health Connect is not available on this device") },
                    supportingContent = { Text("Widgets that use health data show their unavailable state until Health Connect can be used.") })
            } else {
                val granted = healthGranted
                val shared = granted?.count { it in AndroidHealthPlatform.READ_PERMISSIONS } ?: 0
                val background = granted?.contains(AndroidHealthPlatform.BACKGROUND_PERMISSION) == true
                ListItem(headlineContent = { Text(if (healthReviewed) "Health access reviewed" else "Health access not reviewed") },
                    supportingContent = { Text((if (granted == null) "" else "$shared of ${AndroidHealthPlatform.READ_PERMISSIONS.size} data types shared. " +
                        (if (shared > 0 && !background) "Reading in the background is off, so home screen widgets show no data unless the app is open. " else "")) +
                        "ScriptWidget only reads steps, active energy, heart rate, sleep, exercise, distance, hydration and weight, and never writes. " +
                        "Readings are not stored or logged. Widgets are not told which types you shared: a type you keep private looks like a type with no data.") })
                OutlinedButton(modifier = Modifier.padding(horizontal = 16.dp), onClick = {
                    runCatching { healthRequest.launch(stores.healthPlatform.requestPermissions()) }.onFailure { message = "Health Connect could not be opened." }
                }) { Text(if (healthReviewed) "Review Health access" else "Allow Health access") }
                TextButton(modifier = Modifier.padding(horizontal = 8.dp), onClick = {
                    runCatching { context.startActivity(Intent(HealthConnectClient.ACTION_HEALTH_CONNECT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.onFailure { message = "Health Connect could not be opened." }
                }) { Text("Open Health Connect") }
            }

            // MARK: GitHub
            AccessSection("GitHub")
            var token by remember { mutableStateOf("") }
            var connecting by remember { mutableStateOf(false) }
            val accountResult = remember(revision) { runCatching { stores.serviceConnections.summary() } }
            val account = accountResult.getOrNull()
            val vaultError = if (accountResult.isFailure) "unreadable" else ""
            if (account != null) {
                ListItem(headlineContent = { Text("Connected as ${account.username}") },
                    supportingContent = { Text("The token is encrypted with a key in the Android Keystore. Widgets can only read your public profile numbers after you allow them below; they never receive the token.") },
                    trailingContent = { TextButton(onClick = { runCatching { stores.serviceConnections.disconnect() }; revision += 1 }) { Text("Disconnect") } })
            } else {
                ListItem(headlineContent = { Text(if (vaultError.isEmpty()) "Not connected" else "Stored account could not be read") },
                    supportingContent = { Text("Paste a fine-grained personal access token (github.com → Settings → Developer settings → Fine-grained tokens). No repository permission is needed for the profile. Signing in through the browser (OAuth device flow) is not included in Android 1.0.") })
                OutlinedTextField(token, onValueChange = { token = it.trim().take(255) }, label = { Text("github_pat_…") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
                Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(enabled = token.isNotEmpty() && !connecting, onClick = {
                        connecting = true
                        val entered = token
                        scope.launch {
                            val result = withContext(Dispatchers.IO) { runCatching { stores.serviceConnections.connect(entered) } }
                            connecting = false
                            token = ""
                            message = result.fold({ "GitHub connected as $it. Allow widgets below." }, { serviceMessage((it as? SystemReject)?.message) })
                            revision += 1
                        }
                    }) { Text(if (connecting) "Checking…" else "Connect") }
                    if (vaultError.isNotEmpty()) OutlinedButton(onClick = { runCatching { stores.serviceConnections.disconnect() }; revision += 1 }) { Text("Remove stored account") }
                }
            }

            // MARK: Per-widget access
            AccessSection("Widgets")
            val packages = remember(revision) { AppServices.library.list().filter { item -> item.permissions.any { it in setOf("notifications", "calendarWrite", "services") } } }
            if (packages.isEmpty()) ListItem(headlineContent = { Text("No installed widget asks for notifications, calendar changes or GitHub") })
            for (item in packages) {
                val granted = stores.grants.capabilities(item.installation)
                ListItem(headlineContent = { Text(item.displayName) }, supportingContent = { Text("Access you give here stays on this device and is not copied when the widget is exported or duplicated.") })
                if ("notifications" in item.permissions) GrantRow("Schedule reminders", "notifications" in granted) { stores.grants.set(item.installation, "notifications", it); SystemLog.call("access.grant.notifications", "granted=$it"); revision += 1 }
                if ("calendarWrite" in item.permissions) GrantRow("Add and update its own calendar events", "calendarWrite" in granted) { stores.grants.set(item.installation, "calendarWrite", it); SystemLog.call("access.grant.calendarWrite", "granted=$it"); revision += 1 }
                if ("services" in item.permissions) GrantRow(if (account == null) "Read GitHub profile (connect GitHub first)" else "Read GitHub profile", account?.grants?.contains(item.installation) == true, enabled = account != null) {
                    runCatching { stores.serviceConnections.setGrant(item.installation, it) }; SystemLog.call("access.grant.services", "granted=$it"); revision += 1
                }
            }
        }
    }
}

@Composable
private fun AccessSection(title: String) {
    HorizontalDivider(Modifier.padding(top = 8.dp))
    Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp))
}

@Composable
private fun GrantRow(title: String, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    ListItem(headlineContent = { Text(title, style = MaterialTheme.typography.bodyMedium) }, trailingContent = { Switch(checked, onCheckedChange = onChange, enabled = enabled) }, modifier = Modifier.padding(start = 16.dp))
}

@Composable
private fun PhotoTile(photo: PhotoEntry, load: () -> ByteArray?, remove: () -> Unit) {
    val image by produceState<androidx.compose.ui.graphics.ImageBitmap?>(null, photo.id) {
        value = withContext(Dispatchers.IO) { load()?.let { bytes -> runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap() }.getOrNull() } }
    }
    Column {
        val bitmap = image
        if (bitmap != null) Image(bitmap, contentDescription = "Selected photo, ${photo.width} by ${photo.height} pixels", modifier = Modifier.size(88.dp), contentScale = ContentScale.Crop)
        else Text("Unavailable", modifier = Modifier.size(88.dp), style = MaterialTheme.typography.labelSmall)
        TextButton(onClick = remove) { Text("Remove") }
    }
}

private fun formatAge(seconds: Double): String = when {
    seconds < 90 -> "${seconds.toInt()} seconds"
    seconds < 5400 -> "${(seconds / 60).toInt()} minutes"
    else -> "${(seconds / 3600).toInt()} hours"
}

/** A sentence for a `service_*` rejection. The token is never part of any message. */
private fun serviceMessage(rejection: String?): String = when (SystemLog.code(rejection.orEmpty())) {
    "service_credential" -> "That is not a fine-grained personal access token (it starts with github_pat_)."
    "service_expired" -> "GitHub did not accept the token. It may be expired or revoked."
    "service_rate_limit" -> "GitHub is rate limiting requests. Try again later."
    "service_permission" -> "GitHub refused the token for the profile request."
    "service_storage" -> "The token could not be stored securely on this device."
    else -> "GitHub could not be reached. Check the connection and try again."
}
