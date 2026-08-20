# M1K3 ProGuard Rules - PHASE1.5 APK Optimization
#
# Enables code shrinking and obfuscation while preserving critical runtime reflection.
# Target: Reduce APK size by ~20-30 MB while maintaining 100% functionality.

# ============================================================
# ONNX Runtime - Critical for AI inference
# ============================================================

# Keep all ONNX Runtime classes (native JNI bindings)
-keep class ai.onnxruntime.** { *; }
-keep interface ai.onnxruntime.** { *; }

# Keep native methods (called from C++)
-keepclasseswithmembernames class * {
    native <methods>;
}

# ============================================================
# SQLDelight - Type-safe database access
# ============================================================

# Keep all generated SQLDelight code
-keep class app.m1k3.ai.assistant.database.** { *; }
-keep interface app.m1k3.ai.assistant.database.** { *; }

# Keep query implementations
-keep class **Queries { *; }
-keep class **Impl { *; }

# ============================================================
# Jetpack Compose - Modern UI framework
# ============================================================

# Keep Compose runtime
-keep class androidx.compose.** { *; }
-keep class androidx.compose.runtime.** { *; }
-keep class androidx.compose.ui.** { *; }

# Keep Material3 components
-keep class androidx.compose.material3.** { *; }

# Keep Composable functions (reflection used)
-keep @androidx.compose.runtime.Composable class * { *; }

# ============================================================
# Kotlin Coroutines - Async programming
# ============================================================

# Keep coroutine dispatchers
-keep class kotlinx.coroutines.** { *; }
-keep interface kotlinx.coroutines.** { *; }

# Keep coroutine debug info for crash reports
-keepattributes *Annotation*
-keepattributes SourceFile
-keepattributes LineNumberTable

# ============================================================
# Kotlin Serialization - JSON parsing
# ============================================================

# Keep serializers
-keep class kotlinx.serialization.** { *; }
-keep interface kotlinx.serialization.** { *; }

# Keep @Serializable classes
-keepclassmembers @kotlinx.serialization.Serializable class * {
    *;
}

# Keep serializer methods
-keepclassmembers class * {
    *** serializer(...);
}

# ============================================================
# M1K3 AI Core - Application logic
# ============================================================

# Keep AI engine interfaces
-keep class app.m1k3.ai.assistant.ai.** { *; }
-keep interface app.m1k3.ai.assistant.ai.** { *; }

# Keep embedding engine interfaces
-keep class app.m1k3.ai.assistant.embedding.** { *; }
-keep interface app.m1k3.ai.assistant.embedding.** { *; }

# Handle duplicate WhenMappings from Kotlin sealed classes (dynamic feature modules)
# R8 complains about duplicates between base and feature modules - this is expected
-dontwarn app.m1k3.ai.assistant.embedding.GemmaEmbeddingEngine$WhenMappings

# Keep knowledge retrieval (reflection for RAG)
-keep class app.m1k3.ai.assistant.knowledge.** { *; }

# Keep memory system
-keep class app.m1k3.ai.assistant.memory.** { *; }

# Keep avatar engine
-keep class app.m1k3.ai.assistant.avatar.** { *; }

# ============================================================
# Android Framework Components
# ============================================================

# Keep Activities, Services, Receivers, Providers
-keep public class * extends android.app.Activity
-keep public class * extends android.app.Service
-keep public class * extends android.content.BroadcastReceiver
-keep public class * extends android.content.ContentProvider

# Keep Application class
-keep public class * extends android.app.Application

# Keep View constructors (required for XML inflation)
-keepclasseswithmembers class * {
    public <init>(android.content.Context, android.util.AttributeSet);
}
-keepclasseswithmembers class * {
    public <init>(android.content.Context, android.util.AttributeSet, int);
}

# ============================================================
# General Optimizations
# ============================================================

# Remove logging (except errors)
-assumenosideeffects class android.util.Log {
    public static *** d(...);
    public static *** v(...);
    public static *** i(...);
    public static *** w(...);
}

# Optimize string operations
-optimizations !code/simplification/string

# Preserve annotations for debugging
-keepattributes RuntimeVisibleAnnotations
-keepattributes RuntimeInvisibleAnnotations
-keepattributes RuntimeVisibleParameterAnnotations
-keepattributes RuntimeInvisibleParameterAnnotations

# ============================================================
# Crash Reporting & Debugging
# ============================================================

# Keep stack traces readable
-keepattributes SourceFile,LineNumberTable

# Rename source file attribute to hide real file names
-renamesourcefileattribute SourceFile

# Keep exception classes
-keep public class * extends java.lang.Exception

# ============================================================
# Privacy & Security
# ============================================================

# Remove BuildConfig fields except VERSION info
-assumenosideeffects class app.m1k3.ai.assistant.BuildConfig {
    public static final boolean DEBUG;
}

# Keep version info for crash reports
-keep class app.m1k3.ai.assistant.BuildConfig {
    public static final java.lang.String VERSION_NAME;
    public static final int VERSION_CODE;
}
