package app.m1k3.ai.assistant.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaRadius
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography

/**
 * LicensesScreen — Full attribution for all open source libraries and assets.
 *
 * Every project we ship stands on the shoulders of open source work.
 * This screen gives credit where credit is due.
 *
 * The rest of the old "Meta Screens" (About/Help/Feedback/Privacy/Export) were
 * retired in the chat-is-the-app reduction pass — their content either duplicated
 * Settings → About, or was a TODO stub with no real behaviour to preserve.
 *
 * — MurphySig (https://murphysig.dev) | confidence: high | context: pure Compose, no deps
 */
@Composable
fun LicensesScreen(onBack: () -> Unit = {}) {
    Column(
        modifier =
            Modifier
                .fillMaxSize()
                .background(MaColors.bgPrimary())
                .verticalScroll(rememberScrollState())
                .padding(horizontal = MaSpacing.base),
    ) {
        Spacer(modifier = Modifier.windowInsetsTopHeight(WindowInsets.statusBars))
        Spacer(modifier = Modifier.height(MaSpacing.lg))

        IconButton(onClick = onBack) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = MaColors.textPrimary(),
            )
        }
        Spacer(modifier = Modifier.height(MaSpacing.xs))

        // Header
        Text(
            text = "Open Source",
            style = MaTypography.displayMedium,
            fontWeight = FontWeight.Bold,
            color = MaColors.Orange,
        )
        Spacer(modifier = Modifier.height(MaSpacing.xs))
        Text(
            text = "Built on the shoulders of giants.",
            style = MaTypography.bodyMedium,
            color = MaColors.textSecondary(),
        )

        Spacer(modifier = Modifier.height(MaSpacing.xl))

        // 3D Assets
        LicenseSection(
            title = "3D Assets",
            entries =
                listOf(
                    LicenseEntry(
                        name = "Omabuarts Quirky Series",
                        license = "CC0 1.0",
                        licenseType = LicenseType.CC0,
                        author = "omabuarts.com",
                        description = "Colobus, Sparrow, Gecko, Herring, Muskrat, Pudu, Taipan, Inkfish",
                    ),
                    LicenseEntry(
                        name = "Quaternius Animal/Dino/Fish Packs",
                        license = "CC0 1.0",
                        licenseType = LicenseType.CC0,
                        author = "poly.pizza/u/Quaternius",
                        description = "28 models: dinosaurs, animals, fish",
                    ),
                    LicenseEntry(
                        name = "Khronos glTF Sample Models",
                        license = "CC0 1.0",
                        licenseType = LicenseType.CC0,
                        author = "github.com/KhronosGroup/glTF-Sample-Models",
                        description = "Fox, CesiumMan, BrainStem",
                    ),
                    LicenseEntry(
                        name = "Mask (IzLoM39)",
                        license = "CC-BY 4.0",
                        licenseType = LicenseType.CCBY,
                        author = "sketchfab.com",
                        description = "Mask avatar model",
                    ),
                ),
        )

        Spacer(modifier = Modifier.height(MaSpacing.base))

        // Apache 2.0
        LicenseSection(
            title = "Apache License 2.0",
            entries =
                listOf(
                    LicenseEntry("Kotlin & KMP", "Apache 2.0", LicenseType.APACHE, "JetBrains", version = "2.2.20"),
                    LicenseEntry("Compose Multiplatform", "Apache 2.0", LicenseType.APACHE, "JetBrains", version = "1.9.2"),
                    LicenseEntry(
                        "Compose Google Fonts",
                        "Apache 2.0",
                        LicenseType.APACHE,
                        "Google / JetBrains",
                        version = "1.9.1",
                        description = "Google Fonts integration for Compose",
                    ),
                    LicenseEntry("AndroidX Core", "Apache 2.0", LicenseType.APACHE, "Google", version = "1.17.0"),
                    LicenseEntry("AndroidX Lifecycle", "Apache 2.0", LicenseType.APACHE, "Google", version = "2.9.5"),
                    LicenseEntry("AndroidX Navigation", "Apache 2.0", LicenseType.APACHE, "Google", version = "2.9.1"),
                    LicenseEntry("AndroidX WorkManager", "Apache 2.0", LicenseType.APACHE, "Google", version = "2.10.1"),
                    LicenseEntry("AndroidX CameraX", "Apache 2.0", LicenseType.APACHE, "Google", version = "1.4.0"),
                    LicenseEntry("AndroidX Security", "Apache 2.0", LicenseType.APACHE, "Google", version = "1.1.0-alpha06"),
                    LicenseEntry("Koin", "Apache 2.0", LicenseType.APACHE, "Insert-Koin.io", version = "4.1.0"),
                    LicenseEntry("SQLDelight", "Apache 2.0", LicenseType.APACHE, "CashApp", version = "2.0.2"),
                    LicenseEntry("ONNX Runtime", "Apache 2.0", LicenseType.APACHE, "Microsoft", version = "1.23.2"),
                    LicenseEntry("Ktor", "Apache 2.0", LicenseType.APACHE, "JetBrains", version = "3.3.1"),
                    LicenseEntry("kotlinx-serialization", "Apache 2.0", LicenseType.APACHE, "JetBrains", version = "1.7.3"),
                    LicenseEntry("kotlinx-coroutines", "Apache 2.0", LicenseType.APACHE, "JetBrains", version = "1.10.2"),
                    LicenseEntry("kotlinx-datetime", "Apache 2.0", LicenseType.APACHE, "JetBrains", version = "0.6.2"),
                    LicenseEntry("Logback Classic", "Apache 2.0", LicenseType.APACHE, "QOS.ch", version = "1.5.20"),
                    LicenseEntry("ML Kit Vision", "Apache 2.0", LicenseType.APACHE, "Google", version = "17.0.2"),
                    LicenseEntry("ML Kit Text Recognition", "Apache 2.0", LicenseType.APACHE, "Google", version = "19.0.0"),
                    LicenseEntry("Play Services Location", "Apache 2.0", LicenseType.APACHE, "Google", version = "21.3.0"),
                    LicenseEntry(
                        "Health Connect",
                        "Apache 2.0",
                        LicenseType.APACHE,
                        "Google",
                        version = "1.1.0-rc01",
                        description = "Health data access API",
                    ),
                    LicenseEntry(
                        "SceneView",
                        "Apache 2.0",
                        LicenseType.APACHE,
                        "SceneView Community",
                        version = "2.3.0",
                        description = "3D/AR scene rendering for Android",
                    ),
                ),
        )

        Spacer(modifier = Modifier.height(MaSpacing.base))

        // MIT
        LicenseSection(
            title = "MIT License",
            entries =
                listOf(
                    LicenseEntry("Kermit Logging", "MIT", LicenseType.MIT, "Touchlab", version = "2.0.4"),
                    LicenseEntry("Three.js", "MIT", LicenseType.MIT, "three.js.org", description = "3D WebGL renderer for web avatar"),
                ),
        )

        Spacer(modifier = Modifier.height(MaSpacing.base))

        // BSD
        LicenseSection(
            title = "BSD License",
            entries =
                listOf(
                    LicenseEntry(
                        name = "SQLCipher",
                        license = "BSD",
                        licenseType = LicenseType.BSD,
                        author = "Zetetic LLC",
                        version = "4.5.4",
                        description = "Encrypted SQLite for Android",
                    ),
                ),
        )

        Spacer(modifier = Modifier.height(48.dp))
    }
}

// ─────────────────────────────────────────────────────────────
// License data model
// ─────────────────────────────────────────────────────────────

private enum class LicenseType { CC0, CCBY, APACHE, MIT, BSD }

private data class LicenseEntry(
    val name: String,
    val license: String,
    val licenseType: LicenseType,
    val author: String,
    val version: String? = null,
    val description: String? = null,
)

// ─────────────────────────────────────────────────────────────
// License composables
// ─────────────────────────────────────────────────────────────

@Composable
private fun LicenseSection(
    title: String,
    entries: List<LicenseEntry>,
) {
    val sectionShape = RoundedCornerShape(MaRadius.md)

    Column(verticalArrangement = Arrangement.spacedBy(MaSpacing.sm)) {
        // Section label — small ALL-CAPS
        Text(
            text = title.uppercase(),
            style = MaTypography.labelSmall,
            color = MaColors.Orange,
            modifier = Modifier.padding(start = MaSpacing.xs, bottom = MaSpacing.xs),
        )

        Column(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .clip(sectionShape)
                    .background(MaColors.bgElevated())
                    .border(1.dp, MaColors.borderSubtle(), sectionShape),
        ) {
            entries.forEachIndexed { index, entry ->
                LicenseEntryRow(entry = entry)
                if (index < entries.lastIndex) {
                    HorizontalDivider(
                        modifier = Modifier.padding(horizontal = MaSpacing.md),
                        color = MaColors.borderSubtle(),
                    )
                }
            }
        }
    }
}

@Composable
private fun LicenseEntryRow(entry: LicenseEntry) {
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(MaSpacing.md),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.Top,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = entry.name,
                style = MaTypography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaColors.textPrimary(),
            )
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text =
                    buildString {
                        append(entry.author)
                        entry.version?.let { append(" · $it") }
                    },
                style = MaTypography.labelSmall,
                color = MaColors.textMuted(),
            )
            entry.description?.let { desc ->
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = desc,
                    style = MaTypography.labelSmall,
                    color = MaColors.textMuted(),
                )
            }
        }

        Spacer(modifier = Modifier.width(MaSpacing.sm))
        LicenseBadge(entry.license, entry.licenseType)
    }
}

@Composable
private fun LicenseBadge(
    label: String,
    type: LicenseType,
) {
    val (bgColor, textColor) =
        when (type) {
            LicenseType.CC0, LicenseType.MIT -> MaColors.Success.copy(alpha = 0.12f) to MaColors.Success
            LicenseType.APACHE -> MaColors.Info.copy(alpha = 0.12f) to MaColors.Info
            LicenseType.CCBY -> MaColors.Orange.copy(alpha = 0.12f) to MaColors.Orange
            LicenseType.BSD -> MaColors.TextMuted.copy(alpha = 0.12f) to MaColors.TextMuted
        }

    Box(
        modifier =
            Modifier
                .clip(RoundedCornerShape(MaRadius.sm))
                .background(bgColor)
                .padding(horizontal = 6.dp, vertical = 3.dp),
    ) {
        Text(
            text = label,
            style = MaTypography.labelSmall,
            color = textColor,
            fontWeight = FontWeight.Medium,
        )
    }
}
