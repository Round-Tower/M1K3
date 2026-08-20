package app.m1k3.ai.assistant.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.ai.ondevice.OnDeviceAi
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography
import app.m1k3.ai.assistant.platform.PreferenceKeys
import app.m1k3.ai.assistant.platform.PreferencesStoreInterface
import app.m1k3.ai.assistant.settings.collectAsState
import app.m1k3.ai.assistant.settings.rememberSettingsViewModel
import app.m1k3.ai.assistant.ui.components.*
import app.m1k3.ai.domain.ai.AiCoreModelPreference
import app.m1k3.ai.domain.rag.Intent
import org.jetbrains.compose.ui.tooling.preview.Preview
import org.koin.compose.koinInject

/**
 * SettingsScreen — full app configuration.
 *
 * Sections (top → bottom, logical priority):
 * 1. Personal     — name
 * 2. Voice        — auto reply, STT, haptics
 * 3. AI           — model, ML Kit, AICore, RAG
 * 4. Data         — export, import, clear
 * 5. About        — version, privacy, licenses
 */
@Composable
fun SettingsScreen(
    onNavigateToLicenses: (() -> Unit)? = null,
    onNavigateToDocuments: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalHapticFeedback.current
    val onDeviceAi: OnDeviceAi = koinInject()
    val prefs: PreferencesStoreInterface = koinInject()
    val viewModel = rememberSettingsViewModel(onDeviceAi)
    val state by viewModel.collectAsState()

    LaunchedEffect(Unit) { viewModel.checkMlKitAvailability() }

    LazyColumn(
        modifier =
            modifier
                .fillMaxSize()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base),
        verticalArrangement = Arrangement.spacedBy(MaSpacing.base),
    ) {
        // ── 1. Personal ───────────────────────────────────────
        item {
            PersonalSection(
                prefs = prefs,
                haptics = haptics,
            )
        }

        // ── 2. Voice ─────────────────────────────────────────
        item {
            VoiceSection(prefs = prefs, haptics = haptics)
        }

        // ── 3. AI Model ───────────────────────────────────────
        item {
            ModelSection(modelInfo = state.modelInfo)
        }

        item {
            SettingsSection(title = "ML Kit GenAI", icon = Icons.Default.AutoAwesome) {
                MlKitStatusSection(
                    status = state.mlKitStatus,
                    testResult = state.testResult,
                    isTestRunning = state.isTestRunning,
                    onTestClick = { viewModel.runTestGeneration() },
                )
            }
        }

        item {
            AiCoreSection(
                currentPreference = state.aiCorePreference,
                onPreferenceChange = { viewModel.switchAiCorePreference(it) },
            )
        }

        item {
            KnowledgeSection(
                ragEnabled = state.ragEnabled,
                onRagEnabledChange = { viewModel.setRagEnabled(it) },
                onKnowledgeBaseClick = { onNavigateToDocuments?.invoke() },
                onIntentClick = {},
            )
        }

        // ── 4. Data ───────────────────────────────────────────
        item {
            DataSection(onExportClick = {}, onImportClick = {}, onClearClick = {})
        }

        // ── 5. About ──────────────────────────────────────────
        item {
            PrivacySection(
                onPrivacyDashboardClick = {},
                onEncryptionClick = {},
            )
        }

        item {
            AboutSection(
                onVersionClick = {},
                onLicensesClick = { onNavigateToLicenses?.invoke() },
                onPrivacyPolicyClick = {},
            )
        }

        item { Spacer(Modifier.height(48.dp)) }
    }
}

// ─────────────────────────────────────────────────────────────
// 1. Personal
// ─────────────────────────────────────────────────────────────

@Composable
private fun PersonalSection(
    prefs: PreferencesStoreInterface,
    haptics: androidx.compose.ui.hapticfeedback.HapticFeedback,
) {
    var name by remember { mutableStateOf(prefs.getString(PreferenceKeys.USER_NAME, "") ?: "") }
    var isEditing by remember { mutableStateOf(false) }

    SettingsSection(title = "Personal", icon = Icons.Default.Person) {
        if (isEditing) {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Your first name") },
                singleLine = true,
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = MaSpacing.base, vertical = MaSpacing.sm),
                trailingIcon = {
                    IconButton(onClick = {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        prefs.setString(PreferenceKeys.USER_NAME, name.trim())
                        isEditing = false
                    }) {
                        Icon(Icons.Default.Check, contentDescription = "Save", tint = MaColors.Orange)
                    }
                },
                colors =
                    OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = MaColors.Orange,
                        focusedLabelColor = MaColors.Orange,
                        cursorColor = MaColors.Orange,
                    ),
            )
        } else {
            SettingsItem(
                title = "Your name",
                subtitle = name.ifBlank { "Tap to set — used in your greeting" },
                icon = Icons.Default.Person,
                onClick = {
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    isEditing = true
                },
            )
        }
    }
}

// ─────────────────────────────────────────────────────────────
// 2. Voice
// ─────────────────────────────────────────────────────────────

@Composable
private fun VoiceSection(
    prefs: PreferencesStoreInterface,
    haptics: androidx.compose.ui.hapticfeedback.HapticFeedback,
) {
    var autoVoiceReply by remember {
        mutableStateOf(prefs.getBoolean(PreferenceKeys.VOICE_AUTO_REPLY, false))
    }
    var hapticsEnabled by remember {
        mutableStateOf(prefs.getBoolean(PreferenceKeys.HAPTICS_ENABLED, true))
    }

    SettingsSection(title = "Voice & Feedback", icon = Icons.Default.RecordVoiceOver) {
        SettingsToggleItem(
            title = "Auto voice reply",
            subtitle = "M1K3 speaks responses aloud automatically",
            icon = Icons.Default.VolumeUp,
            checked = autoVoiceReply,
            onCheckedChange = { checked ->
                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                autoVoiceReply = checked
                prefs.setBoolean(PreferenceKeys.VOICE_AUTO_REPLY, checked)
            },
        )

        HorizontalDivider(modifier = Modifier.padding(horizontal = MaSpacing.base), color = MaColors.BorderLight)

        SettingsToggleItem(
            title = "Haptic feedback",
            subtitle = "Tactile response for interactions",
            icon = Icons.Default.Vibration,
            checked = hapticsEnabled,
            onCheckedChange = { checked ->
                hapticsEnabled = checked
                prefs.setBoolean(PreferenceKeys.HAPTICS_ENABLED, checked)
                if (checked) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            },
        )

        HorizontalDivider(modifier = Modifier.padding(horizontal = MaSpacing.base), color = MaColors.BorderLight)

        // Voice picker — Daniel, Bella, Emma
        var selectedVoiceId by remember {
            mutableStateOf(
                prefs.getString(PreferenceKeys.SELECTED_VOICE, app.m1k3.ai.domain.tts.Voice.default.id)
                    ?: app.m1k3.ai.domain.tts.Voice.default.id,
            )
        }
        val voices =
            app.m1k3.ai.domain.tts.Voice
                .all()

        SettingsItem(
            title = "Voice",
            subtitle = voices.find { it.id == selectedVoiceId }?.displayName ?: "Daniel",
            icon = Icons.Default.RecordVoiceOver,
            onClick = {},
        )
        androidx.compose.foundation.layout.Row(
            modifier =
                androidx.compose.ui.Modifier
                    .fillMaxWidth()
                    .padding(horizontal = MaSpacing.base, vertical = MaSpacing.sm),
            horizontalArrangement =
                androidx.compose.foundation.layout.Arrangement
                    .spacedBy(MaSpacing.sm),
        ) {
            voices.forEach { voice ->
                val isSelected = voice.id == selectedVoiceId
                androidx.compose.material3.FilterChip(
                    selected = isSelected,
                    onClick = {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        selectedVoiceId = voice.id
                        prefs.setString(PreferenceKeys.SELECTED_VOICE, voice.id)
                    },
                    label = { androidx.compose.material3.Text(voice.displayName) },
                )
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// 3. AI Model (existing, unchanged)
// ─────────────────────────────────────────────────────────────

@Composable
private fun ModelSection(modelInfo: String) {
    SettingsSection(title = "AI Model", icon = Icons.Default.Memory) {
        SettingsItem(
            title = "Current Model",
            subtitle = modelInfo,
            icon = Icons.Default.ModelTraining,
            onClick = {},
        )
    }
}

@Composable
private fun KnowledgeSection(
    ragEnabled: Boolean,
    onRagEnabledChange: (Boolean) -> Unit,
    onKnowledgeBaseClick: () -> Unit,
    onIntentClick: () -> Unit,
) {
    SettingsSection(title = "Personal Knowledge", icon = Icons.Default.MenuBook) {
        SettingsToggleItem(
            title = "Use personal knowledge",
            subtitle = "Ground replies in your imported notes and docs",
            icon = Icons.Default.AutoAwesome,
            checked = ragEnabled,
            onCheckedChange = onRagEnabledChange,
        )
        HorizontalDivider(modifier = Modifier.padding(horizontal = MaSpacing.base), color = MaColors.BorderLight)
        SettingsItem(
            title = "Documents",
            subtitle = "None imported yet",
            icon = Icons.Default.Book,
            onClick = onKnowledgeBaseClick,
        )
        SettingsItem(
            title = "Intent Classification",
            subtitle = "${Intent.entries.size} query types · Adaptive retrieval",
            icon = Icons.Default.Category,
            onClick = onIntentClick,
        )
    }
}

@Composable
private fun AiCoreSection(
    currentPreference: AiCoreModelPreference,
    onPreferenceChange: (AiCoreModelPreference) -> Unit,
) {
    SettingsSection(title = "AICore Model", icon = Icons.Default.AutoAwesome) {
        AiCoreModelPreference.entries.forEachIndexed { index, preference ->
            val isSelected = preference == currentPreference
            SettingsItem(
                title = preference.displayName,
                subtitle =
                    when (preference) {
                        AiCoreModelPreference.STABLE -> "Production model — stable, optimized"
                        AiCoreModelPreference.PREVIEW_SPEED -> "Gemma 4 E2B — 3x faster (Preview)"
                        AiCoreModelPreference.PREVIEW_FULL -> "Gemma 4 E4B — highest quality (Preview)"
                    },
                icon = if (isSelected) Icons.Default.RadioButtonChecked else Icons.Default.RadioButtonUnchecked,
                iconTint = if (isSelected) MaColors.Orange else MaColors.textMuted(),
                onClick = { onPreferenceChange(preference) },
            )
            if (index < AiCoreModelPreference.entries.lastIndex) {
                HorizontalDivider(modifier = Modifier.padding(horizontal = MaSpacing.base), color = MaColors.BorderLight)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// 4. Data
// ─────────────────────────────────────────────────────────────

@Composable
private fun DataSection(
    onExportClick: () -> Unit,
    onImportClick: () -> Unit,
    onClearClick: () -> Unit,
) {
    SettingsSection(title = "Data", icon = Icons.Default.Storage) {
        SettingsItem(
            title = "Export conversations",
            subtitle = "Backup to JSON",
            icon = Icons.Default.Upload,
            onClick = onExportClick,
        )
        SettingsItem(
            title = "Import conversations",
            subtitle = "Restore from backup",
            icon = Icons.Default.Download,
            onClick = onImportClick,
        )
        SettingsItem(
            title = "Clear all data",
            subtitle = "Reset app to defaults",
            icon = Icons.Default.DeleteForever,
            onClick = onClearClick,
            isDestructive = true,
        )
    }
}

// ─────────────────────────────────────────────────────────────
// 5. About / Privacy
// ─────────────────────────────────────────────────────────────

@Composable
private fun PrivacySection(
    onPrivacyDashboardClick: () -> Unit,
    onEncryptionClick: () -> Unit,
) {
    SettingsSection(title = "Privacy", icon = Icons.Default.Lock) {
        SettingsItem(
            title = "Privacy dashboard",
            subtitle = "Chat on-device · network only when you ask",
            icon = Icons.Default.Security,
            onClick = onPrivacyDashboardClick,
        )
        SettingsItem(
            title = "Data encryption",
            subtitle = "AES-256 via SQLCipher",
            icon = Icons.Default.Shield,
            onClick = onEncryptionClick,
        )
    }
}

@Composable
private fun AboutSection(
    onVersionClick: () -> Unit,
    onLicensesClick: () -> Unit,
    onPrivacyPolicyClick: () -> Unit,
) {
    SettingsSection(title = "About", icon = Icons.Default.Info) {
        SettingsItem(
            title = "Version",
            subtitle = "0.1.0 — Phase 2",
            icon = Icons.Default.AppShortcut,
            onClick = onVersionClick,
        )
        SettingsItem(
            title = "Open source licenses",
            subtitle = "Apache 2.0 · MIT",
            icon = Icons.Default.Code,
            onClick = onLicensesClick,
        )
        SettingsItem(
            title = "Privacy policy",
            subtitle = "No analytics · no telemetry · no tracking",
            icon = Icons.Default.PrivacyTip,
            onClick = onPrivacyPolicyClick,
        )
    }
}

// ─────────────────────────────────────────────────────────────
// Preview
// ─────────────────────────────────────────────────────────────

@Preview(showBackground = true)
@Composable
private fun SettingsScreenPreview() {
    MaTheme {
        SettingsScreen()
    }
}
