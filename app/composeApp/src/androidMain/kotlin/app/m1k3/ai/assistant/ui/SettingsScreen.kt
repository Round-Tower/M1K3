package app.m1k3.ai.assistant.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.platform.PreferenceKeys
import app.m1k3.ai.assistant.platform.PreferencesStoreInterface
import app.m1k3.ai.domain.ai.LlmModel
import app.m1k3.ai.domain.ai.M1K3Tier
import app.m1k3.ai.domain.ai.ModelDownloadManager
import app.m1k3.ai.domain.platform.DeviceInfoProviderInterface
import app.m1k3.ai.domain.platform.DeviceTier
import app.m1k3.ai.domain.tts.Voice
import org.koin.compose.koinInject

/**
 * SettingsScreen — the M1K3 shape: Workspace, Brain, Grounding, Voice, You,
 * Data, About. Pushed from Chat's own top bar (chat is the app; this is a
 * workspace room, not a destination in its own right).
 *
 * Uses plain Material 3 (ListItem/Switch/Card) throughout — the container is
 * the platform's, M1K3's layer is the pixel face + orange + the copy, and
 * neither of those belongs on a settings form (macos/docs/DESIGN_DOCTRINE.md).
 *
 * No "ML Kit GenAI" / "AICore Model" rows: that engine path
 * (OnDeviceAi/MlKitGenAiEngine) was never wired into the real chat flow —
 * ChatScreenViewModel talks to [app.m1k3.ai.assistant.ai.BaseLlmEngine]
 * directly — and was cut entirely 2026-08 (see project memory for the trace).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    currentModel: LlmModel,
    onSelectBrain: (LlmModel) -> Unit,
    onNavigateToMemories: () -> Unit = {},
    onNavigateToDocuments: () -> Unit = {},
    onNavigateToConversations: () -> Unit = {},
    onNavigateToLicenses: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val prefs: PreferencesStoreInterface = koinInject()
    val deviceInfo: DeviceInfoProviderInterface = koinInject()
    val modelDownloadManager: ModelDownloadManager = koinInject()

    Column(modifier = modifier.fillMaxWidth()) {
        TopAppBar(
            title = { Text("Settings") },
            colors = TopAppBarDefaults.topAppBarColors(),
        )
        LazyColumn(
            modifier = Modifier.fillMaxWidth(),
            contentPadding =
                androidx.compose.foundation.layout
                    .PaddingValues(bottom = 48.dp),
        ) {
            item {
                WorkspaceSection(
                    onNavigateToMemories = onNavigateToMemories,
                    onNavigateToDocuments = onNavigateToDocuments,
                    onNavigateToConversations = onNavigateToConversations,
                )
            }
            item {
                BrainSection(
                    currentModel = currentModel,
                    onSelectBrain = onSelectBrain,
                    deviceInfo = deviceInfo,
                    modelDownloadManager = modelDownloadManager,
                )
            }
            item { GroundingSection(prefs = prefs) }
            item { VoiceSection(prefs = prefs) }
            item { YouSection(prefs = prefs) }
            item { AboutSection(onNavigateToLicenses = onNavigateToLicenses) }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// Section header
// ─────────────────────────────────────────────────────────────

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title.uppercase(),
        style = androidx.compose.material3.MaterialTheme.typography.labelMedium,
        color = androidx.compose.material3.MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 4.dp),
    )
}

@Composable
private fun SectionFooter(text: String) {
    Text(
        text = text,
        style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
        color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 4.dp),
    )
}

// ─────────────────────────────────────────────────────────────
// Workspace
// ─────────────────────────────────────────────────────────────

@Composable
private fun WorkspaceSection(
    onNavigateToMemories: () -> Unit,
    onNavigateToDocuments: () -> Unit,
    onNavigateToConversations: () -> Unit,
) {
    Column {
        SectionHeader("Workspace")
        ListItem(
            headlineContent = { Text("Memories") },
            leadingContent = { Icon(Icons.Default.Psychology, contentDescription = null) },
            trailingContent = { Icon(Icons.Default.ChevronRight, contentDescription = null) },
            modifier = Modifier.clickable(onClick = onNavigateToMemories),
        )
        ListItem(
            headlineContent = { Text("Documents") },
            leadingContent = { Icon(Icons.Default.Book, contentDescription = null) },
            trailingContent = { Icon(Icons.Default.ChevronRight, contentDescription = null) },
            modifier = Modifier.clickable(onClick = onNavigateToDocuments),
        )
        ListItem(
            headlineContent = { Text("Conversations") },
            leadingContent = { Icon(Icons.Default.History, contentDescription = null) },
            trailingContent = { Icon(Icons.Default.ChevronRight, contentDescription = null) },
            modifier = Modifier.clickable(onClick = onNavigateToConversations),
        )
    }
}

// ─────────────────────────────────────────────────────────────
// Brain
// ─────────────────────────────────────────────────────────────

@Composable
private fun BrainSection(
    currentModel: LlmModel,
    onSelectBrain: (LlmModel) -> Unit,
    deviceInfo: DeviceInfoProviderInterface,
    modelDownloadManager: ModelDownloadManager,
) {
    val recommended = M1K3Tier.forDevice(DeviceTier.fromRamGB(deviceInfo.getDeviceRamGB()))

    Column {
        SectionHeader("Brain")
        M1K3Tier.all().forEach { tier ->
            BrainCard(
                tier = tier,
                isSelected = tier.model == currentModel,
                isRecommended = tier == recommended,
                isDownloaded = modelDownloadManager.isModelAvailable(tier.model.id),
                onClick = { onSelectBrain(tier.model) },
            )
        }
    }
}

@Composable
private fun BrainCard(
    tier: M1K3Tier,
    isSelected: Boolean,
    isRecommended: Boolean,
    isDownloaded: Boolean,
    onClick: () -> Unit,
) {
    Card(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        colors =
            CardDefaults.cardColors(
                containerColor =
                    if (isSelected) {
                        androidx.compose.material3.MaterialTheme.colorScheme.primaryContainer
                    } else {
                        androidx.compose.material3.MaterialTheme.colorScheme.surfaceVariant
                    },
            ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Text(
                        text = tier.displayName.removeSuffix(" M1K3"),
                        style = androidx.compose.material3.MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    if (isRecommended) {
                        Spacer(modifier = Modifier.padding(start = 4.dp))
                        Text(
                            text = "Recommended",
                            style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
                            color = androidx.compose.material3.MaterialTheme.colorScheme.primary,
                            modifier = Modifier.padding(start = 8.dp),
                        )
                    }
                }
                Text(
                    text = tier.tagline,
                    style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                    color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = if (isDownloaded) "Downloaded" else "~${tier.downloadSizeMb} MB download on first use",
                    style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
                    color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (isSelected) {
                Icon(
                    imageVector = Icons.Default.CheckCircle,
                    contentDescription = "Selected",
                    tint = androidx.compose.material3.MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// Grounding
// ─────────────────────────────────────────────────────────────

@Composable
private fun GroundingSection(prefs: PreferencesStoreInterface) {
    var webSearchEnabled by remember {
        mutableStateOf(prefs.getBoolean(PreferenceKeys.WEB_SEARCH_ENABLED, true))
    }
    var ragEnabled by remember {
        mutableStateOf(prefs.getBoolean(PreferenceKeys.RAG_ENABLED, true))
    }

    Column {
        SectionHeader("Grounding")
        ListItem(
            headlineContent = { Text("Web search in chat") },
            trailingContent = {
                Switch(
                    checked = webSearchEnabled,
                    onCheckedChange = {
                        webSearchEnabled = it
                        prefs.setBoolean(PreferenceKeys.WEB_SEARCH_ENABLED, it)
                    },
                )
            },
        )
        SectionFooter(
            "When on, M1K3 can search the web to answer. The only capability " +
                "that sends chat-derived queries off this device.",
        )
        ListItem(
            headlineContent = { Text("Ground replies in your documents") },
            trailingContent = {
                Switch(
                    checked = ragEnabled,
                    onCheckedChange = {
                        ragEnabled = it
                        prefs.setBoolean(PreferenceKeys.RAG_ENABLED, it)
                    },
                )
            },
        )
        SectionFooter(
            "On by default — M1K3 answers from the notes and documents you add. " +
                "Runs entirely on this device; nothing is sent anywhere.",
        )
    }
}

// ─────────────────────────────────────────────────────────────
// Voice
// ─────────────────────────────────────────────────────────────

@Composable
private fun VoiceSection(prefs: PreferencesStoreInterface) {
    var selectedVoiceId by remember {
        mutableStateOf(prefs.getString(PreferenceKeys.SELECTED_VOICE, Voice.default.id) ?: Voice.default.id)
    }
    var speakRepliesAloud by remember {
        mutableStateOf(prefs.getBoolean(PreferenceKeys.VOICE_AUTO_REPLY, false))
    }

    Column {
        SectionHeader("Voice")
        ListItem(
            headlineContent = { Text("Voice") },
            supportingContent = {
                Text(Voice.all().find { it.id == selectedVoiceId }?.displayName ?: Voice.default.displayName)
            },
        )
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Voice.all().forEach { voice ->
                FilterChip(
                    selected = voice.id == selectedVoiceId,
                    onClick = {
                        selectedVoiceId = voice.id
                        prefs.setString(PreferenceKeys.SELECTED_VOICE, voice.id)
                    },
                    label = { Text(voice.displayName) },
                )
            }
        }
        ListItem(
            headlineContent = { Text("Speak replies aloud") },
            trailingContent = {
                Switch(
                    checked = speakRepliesAloud,
                    onCheckedChange = {
                        speakRepliesAloud = it
                        prefs.setBoolean(PreferenceKeys.VOICE_AUTO_REPLY, it)
                    },
                )
            },
        )
    }
}

// ─────────────────────────────────────────────────────────────
// You
// ─────────────────────────────────────────────────────────────

@Composable
private fun YouSection(prefs: PreferencesStoreInterface) {
    var name by remember { mutableStateOf(prefs.getString(PreferenceKeys.USER_NAME, "") ?: "") }

    Column {
        SectionHeader("You")
        OutlinedTextField(
            value = name,
            onValueChange = {
                name = it
                prefs.setString(PreferenceKeys.USER_NAME, it.trim())
            },
            label = { Text("Your name") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        )
    }
}

// The old "Data" section (Export/Import/Clear all data) was three no-ops —
// tapping any row did nothing. Cut rather than wired: a real "clear all
// data" needs to reach across conversations, memories, and documents in
// one irreversible action, which deserves its own confirmation-gated pass,
// not a Settings-polish edit. A dishonest-but-present row is worse than no
// row (doctrine principle 7 — an instrument gets a hidden door, not a fake
// one on the main road).

// ─────────────────────────────────────────────────────────────
// About
// ─────────────────────────────────────────────────────────────

@Composable
private fun AboutSection(onNavigateToLicenses: () -> Unit) {
    val context = LocalContext.current
    val version =
        try {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "1.0"
        } catch (_: Exception) {
            "1.0"
        }

    Column {
        SectionHeader("About")
        ListItem(
            headlineContent = { Text("Version") },
            trailingContent = { Text(version) },
        )
        ListItem(
            headlineContent = { Text("m1k3.app") },
            trailingContent = { Icon(Icons.Default.ChevronRight, contentDescription = null) },
            modifier =
                Modifier.clickable {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://m1k3.app")))
                },
        )
        ListItem(
            headlineContent = { Text("Licenses") },
            trailingContent = { Icon(Icons.Default.ChevronRight, contentDescription = null) },
            modifier = Modifier.clickable(onClick = onNavigateToLicenses),
        )
        SectionFooter("M1K3 — a local, private AI companion. Everything runs on your device.")
    }
}
