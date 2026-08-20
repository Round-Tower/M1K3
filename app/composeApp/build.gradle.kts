import com.android.build.api.artifact.SingleArtifact
import org.jetbrains.compose.desktop.application.dsl.TargetFormat
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.ZipEntry
import java.util.zip.ZipFile

plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.androidApplication)
    alias(libs.plugins.composeMultiplatform)
    alias(libs.plugins.composeCompiler)
    alias(libs.plugins.composeHotReload)
    alias(libs.plugins.sqldelight)
    alias(libs.plugins.kotlinSerialization)
}

kotlin {
    androidTarget {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_11)
        }
    }

    listOf(
        iosArm64(),
        iosSimulatorArm64(),
    ).forEach { iosTarget ->
        iosTarget.binaries.framework {
            baseName = "M1K3"
            isStatic = true
        }
    }

    // JVM target for desktop testing (optional)
    jvm()

    // Note: JS and WASM targets removed - not needed for mobile app

    sourceSets {
        all {
            languageSettings {
                // Enable experimental datetime APIs to suppress warnings
                optIn("kotlin.time.ExperimentalTime")
                optIn("kotlinx.datetime.ExperimentalDateTimeApi")
            }
        }

        androidMain.dependencies {
            implementation(compose.preview)
            implementation(libs.androidx.activity.compose)

            // M1K3 AI - Android-specific dependencies
            implementation(libs.sqldelight.driver.android)
            // SQLCipher for encrypted DB-at-rest. Passphrase is a 256-bit random
            // value stored in EncryptedSharedPreferences (Keystore-backed master
            // key) — see AndroidDatabaseFactory. Wired via SupportOpenHelperFactory
            // in PlatformModule.android.kt.
            implementation(libs.sqlcipher)
            implementation(libs.androidx.security.crypto)

            // ONNX Runtime — used by MiniLmEmbeddingEngine, GemmaEmbeddingEngine,
            // and KokoroTtsEngine. Not used for LLM inference (that's Ma/llama.cpp).
            implementation(libs.onnxruntime.android)

            // Google Fonts for custom typography
            implementation(libs.compose.ui.text.googlefonts)

            // WorkManager — background downloads survive screen lock
            implementation(libs.androidx.work.runtime)

            // Koin Android
            implementation(libs.koin.android)
            implementation(libs.koin.androidx.compose)

            // JVector HNSW graph, used by VectorSearchManager for memory
            // semantic search (falls back to linear-scan when the graph is
            // empty/stale). Personal-knowledge passage search is a separate
            // path and uses LinearScanVectorIndex, not this dependency.
            implementation(libs.jvector)
        }
        commonMain.dependencies {
            implementation(compose.runtime)
            implementation(compose.foundation)
            implementation(compose.material3)
            implementation(compose.materialIconsExtended)
            implementation(compose.ui)
            implementation(compose.components.resources)
            implementation(compose.components.uiToolingPreview)
            implementation(libs.androidx.lifecycle.viewmodelCompose)
            implementation(libs.androidx.lifecycle.runtimeCompose)
            implementation(libs.androidx.navigation.compose)
            implementation(projects.shared)

            // Common dependencies
            implementation(libs.sqldelight.coroutines)
            implementation(libs.kotlinx.serialization.json)
            implementation(libs.kotlinx.datetime)

            // Ma - our own JNI bridge to llama.cpp (replaces Llamatik)
            // Built via NDK/CMake, no Gradle dependency needed (libma.so is compiled locally)

            // Kermit - Multiplatform logging
            implementation(libs.kermit)

            // Koin - Dependency injection
            implementation(libs.koin.core)
            implementation(libs.koin.compose)
        }
        commonTest.dependencies {
            implementation(libs.kotlin.test)
            implementation(libs.kotlinx.coroutinesTest)
        }
        androidInstrumentedTest.dependencies {
            implementation(libs.androidx.testExt.junit)
            implementation(libs.androidx.espresso.core)
            implementation(libs.koin.test)
            implementation(libs.kotlin.test)
            implementation(libs.kotlin.test)
            @OptIn(org.jetbrains.compose.ExperimentalComposeLibrary::class)
            implementation(compose.uiTest)
        }
        jvmTest.dependencies {
            // JDBC SQLite driver for JVM unit tests only (in-memory database)
            implementation(libs.sqldelight.driver.jdbc)
        }
        iosMain.dependencies {
            // 間 AI - iOS-specific dependencies
            implementation(libs.sqldelight.driver.native)
        }
        jvmMain.dependencies {
            implementation(compose.desktop.currentOs)
            implementation(libs.kotlinx.coroutinesSwing)

            // 間 AI - JVM/Desktop dependencies
            implementation(libs.sqldelight.driver.sqlite)
        }
    }
}

android {
    namespace = "app.m1k3.ai.assistant"
    compileSdk =
        libs.versions.android.compileSdk
            .get()
            .toInt()

    // Pin NDK to keep llama.cpp submodule build reproducible across machines.
    ndkVersion = libs.versions.ndk.get()

    defaultConfig {
        applicationId = "app.m1k3"
        minSdk =
            libs.versions.android.minSdk
                .get()
                .toInt()
        targetSdk =
            libs.versions.android.targetSdk
                .get()
                .toInt()
        versionCode = 1
        versionName = "0.1.0"

        // Instrumented test runner
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // Ma native library - llama.cpp JNI bridge
        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                arguments +=
                    listOf(
                        "-DLLAMA_ANDROID=ON",
                        "-DLLAMA_NATIVE=OFF", // no host-optimized SIMD (cross-compile)
                        "-DCMAKE_BUILD_TYPE=Release",
                    )
            }
        }
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    // Ma CMake build
    externalNativeBuild {
        cmake {
            path = file("src/androidMain/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // Disable unused AGP build features. buildConfig stays on — Logger.kt reads
    // BuildConfig.DEBUG to set log severity.
    buildFeatures {
        aidl = false
        renderScript = false
        shaders = false
        mlModelBinding = false
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
    buildTypes {
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // App Bundle configuration for optimized distribution
    bundle {
        language {
            // Disable language splits to include all languages in base
            // (Can enable later for further size optimization)
            enableSplit = false
        }
        density {
            // Enable density splits for screen-specific resources
            enableSplit = true
        }
        abi {
            // Enable ABI splits for architecture-specific native libraries
            enableSplit = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

dependencies {
    // The vision-internal-vkp 16KB-alignment pin (transitive through
    // image-labeling) went with ML Kit Vision/GenAI + CameraX, cut 2026-08 as
    // unreferenced dead weight — nothing left pulls that artifact in.
    // Verify16KbAlignmentTask stays: it still guards sqlcipher/onnx/llama.

    debugImplementation(compose.uiTooling)

    // LeakCanary for memory leak detection (debug only)
    debugImplementation("com.squareup.leakcanary:leakcanary-android:2.14")

    // Testing dependencies
    testImplementation(libs.junit)
    testImplementation(libs.kotlin.test)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.sqldelight.driver.jdbc) // JDBC driver for unit tests (JVM)
}

compose.desktop {
    application {
        mainClass = "app.m1k3.ai.assistant.MainKt"

        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "app.m1k3.ai.assistant"
            packageVersion = "1.0.0"
        }
    }
}

// SQLDelight Configuration
sqldelight {
    databases {
        create("MaDatabase") {
            packageName.set("app.m1k3.ai.assistant.database")
            // Schema will be defined in src/commonMain/sqldelight
            schemaOutputDirectory.set(file("build/dbs"))
            dialect("app.cash.sqldelight:sqlite-3-38-dialect:2.0.2")
        }
    }
}

// ============================================================================
// Web Avatar - committed assets only (pipeline retired 2026-08-13)
// ============================================================================
// The THREE.js web-avatar SOURCE lived in attic/src/web-avatar and was cleared
// from the working tree with the rest of the attic — git history before
// 7545b4a4 keeps it, along with the npm-install/Vite-build/copy task chain
// that used to run here (installWebAvatarDeps → buildWebAvatar →
// copyWebAvatarToAndroid, wired into preBuild). The BUILT bundle the app
// actually ships is committed at src/androidMain/assets/web-avatar/ and needs
// no build step. To change the avatar: resurrect the source from history,
// rebuild, and re-commit the dist output.

// ============================================================================
// 16KB Page-Size Alignment Guard (Android 15+)
// ============================================================================
// Google Play requires all apps targeting API 35+ to support 16KB memory pages.
// Every native library must have 16KB-aligned ELF LOAD segments AND its zip
// entry in the APK must be aligned to a 16KB boundary (because AGP 8.3+ ships
// with extractNativeLibs=false — libs are mmap'd straight from the APK).
//
// zipalign -c -P 16 verifies both properties in one shot. This task wires the
// check into every assemble{Debug,Release}, so a dependency that sneaks in a
// 4KB-aligned .so fails the build instead of the install dialog.

abstract class Verify16KbAlignmentTask : DefaultTask() {
    @get:InputDirectory
    abstract val apkDirectory: DirectoryProperty

    init {
        group = "verification"
        description = "Fail the build if any native library is not 16KB-aligned (Android 15+ compliance)"
    }

    @TaskAction
    fun verify() {
        val apks =
            apkDirectory
                .get()
                .asFile
                .walkTopDown()
                .filter { it.isFile && it.extension == "apk" }
                .toList()

        if (apks.isEmpty()) {
            logger.lifecycle("No APKs in ${apkDirectory.get().asFile} — skipping 16KB check")
            return
        }

        val failures = mutableListOf<String>()

        apks.forEach { apk ->
            logger.lifecycle("🔎 16KB alignment check: ${apk.name}")
            ZipFile(apk).use { zip ->
                val enumeration = zip.entries()
                while (enumeration.hasMoreElements()) {
                    val entry: ZipEntry = enumeration.nextElement()
                    if (entry.isDirectory) continue
                    if (!entry.name.startsWith("lib/") || !entry.name.endsWith(".so")) continue
                    val align = readMaxLoadAlignment(zip, entry) ?: continue
                    val hex = "0x" + align.toString(16)
                    if (align < 0x4000L) {
                        failures += "${entry.name} → $hex (need ≥ 0x4000)"
                    } else {
                        logger.info("   ok  ${entry.name} @ $hex")
                    }
                }
            }
        }

        if (failures.isNotEmpty()) {
            throw GradleException(
                buildString {
                    appendLine()
                    appendLine("❌ 16KB page-alignment check FAILED — Android 15+ will refuse to install:")
                    failures.forEach { appendLine("   • $it") }
                    appendLine()
                    appendLine("Fix options:")
                    appendLine("  1. Upgrade the offending dependency to a 16KB-safe release.")
                    appendLine("  2. Add a dependency constraint forcing the 16KB-aligned transitive")
                    appendLine("     version (see mlkit-vision-internal-vkp in composeApp/build.gradle.kts).")
                    appendLine("  3. If you own the native code, link with -Wl,-z,max-page-size=16384")
                    appendLine("     (see androidMain/cpp/CMakeLists.txt:64).")
                },
            )
        }
    }

    /**
     * Parse the ELF program headers of a 64-bit little-endian ELF and return the max
     * p_align across all PT_LOAD segments. Returns null if the entry isn't a 64-bit LE
     * ELF (e.g. 32-bit — which we don't ship — or malformed).
     */
    private fun readMaxLoadAlignment(
        zip: ZipFile,
        entry: ZipEntry,
    ): Long? {
        val bytes =
            zip.getInputStream(entry).use { input ->
                // Program headers live near the start of the ELF; 8KB covers every
                // realistic library (phoff is typically 64, phentsize=56, phnum<30).
                val sz = minOf(entry.size, 8192L).toInt()
                input.readNBytes(sz)
            }
        if (bytes.size < 64) return null
        if (bytes[0] != 0x7F.toByte() ||
            bytes[1] != 'E'.code.toByte() ||
            bytes[2] != 'L'.code.toByte() ||
            bytes[3] != 'F'.code.toByte()
        ) {
            return null
        }
        if (bytes[4].toInt() != 2) return null // 32-bit — unsupported (we ship 64-bit only)
        if (bytes[5].toInt() != 1) return null // big-endian — not our target

        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val phoff = buf.getLong(32)
        val phentsize = buf.getShort(54).toInt() and 0xFFFF
        val phnum = buf.getShort(56).toInt() and 0xFFFF

        val headersEnd = phoff + phentsize.toLong() * phnum
        if (headersEnd > bytes.size.toLong()) {
            logger.warn("Program headers of ${entry.name} exceed 8KB buffer — skipping")
            return null
        }

        var maxLoadAlign = 0L
        for (i in 0 until phnum) {
            val off = (phoff + i.toLong() * phentsize).toInt()
            val pType = buf.getInt(off)
            if (pType == 1) { // PT_LOAD
                val pAlign = buf.getLong(off + 48)
                if (pAlign > maxLoadAlign) maxLoadAlign = pAlign
            }
        }
        return maxLoadAlign.takeIf { it > 0 }
    }
}

androidComponents {
    onVariants { variant ->
        val capName = variant.name.replaceFirstChar { it.uppercase() }
        val verifyTask =
            tasks.register<Verify16KbAlignmentTask>("verify16KbAlignment$capName") {
                apkDirectory.set(variant.artifacts.get(SingleArtifact.APK))
            }
        // AGP registers assemble<Variant> after onVariants fires — wire lazily.
        afterEvaluate {
            tasks.named("assemble$capName") {
                dependsOn(verifyTask)
            }
        }
    }
}
