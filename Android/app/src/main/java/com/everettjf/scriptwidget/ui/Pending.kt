package com.everettjf.scriptwidget.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ListItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController

// Placeholders replaced by GalleryScreen.kt and AiScreen.kt.
@Composable fun GalleryScreen(navigation: NavController) { Text("Gallery", Modifier.padding(32.dp)) }
@Composable fun AiScreen(navigation: NavController, name: String?) { Text("AI", Modifier.padding(32.dp)) }
@Composable fun AiSettings() { ListItem(headlineContent = { Text("AI provider") }) }
