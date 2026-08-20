import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.androidLibrary)
}

kotlin {
    androidTarget {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_11)
        }
    }

    iosArm64()
    iosSimulatorArm64()

    // JVM target for desktop testing (optional)
    jvm()

    // Note: JS and WASM targets removed - not needed for mobile app
    // and incompatible with some dependencies

    sourceSets {
        all {
            languageSettings {
                // Enable experimental datetime APIs to suppress warnings
                optIn("kotlin.time.ExperimentalTime")
                optIn("kotlinx.datetime.ExperimentalDateTimeApi")
            }
        }

        commonMain.dependencies {
            // Kotlin Coroutines for Flow support
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
            // DateTime for domain layer timestamp handling
            implementation(libs.kotlinx.datetime)
        }
        commonTest.dependencies {
            implementation(libs.kotlin.test)
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
        }
    }
}

android {
    namespace = "app.m1k3.shared"
    compileSdk =
        libs.versions.android.compileSdk
            .get()
            .toInt()
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    defaultConfig {
        minSdk =
            libs.versions.android.minSdk
                .get()
                .toInt()
    }
}
