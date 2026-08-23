/*
 * ma_bridge.cpp — JNI shim for the portable Ma core.
 *
 * All llama.cpp work lives in ma_core.{h,cpp} (nativeShared/ma/). This file
 * is purely a JNI translation layer:
 *   - jstring    ↔ const char*
 *   - jobject cb ↔ C function-pointer trampoline (jni_token_cb)
 *   - jlong      ↔ ma_handle (uint64_t)
 *
 * When iOS comes online, ma_core will be bound via Kotlin/Native cinterop
 * and this file stays Android-only. The common behaviour is already in
 * ma_core and only needs to be linked.
 *
 * MurphySig: kev+claude / confidence 0.88 / 2026-04-19
 */

#include <jni.h>
#include <android/log.h>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "ma_core.h"

#define LOG_TAG "MaBridge"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* -------------------------------------------------------------------------
 * JNI streaming callback trampoline.
 *
 * `JniCallbackCtx` captures JNIEnv + the Java callback object + its onToken
 * method ID at the point of JNI entry. `jni_token_cb` is the C function
 * pointer handed to ma_core; ma_core calls it per complete UTF-8 chunk and
 * we translate back into env->CallVoidMethod on the Java side.
 *
 * Thread safety: ma_core runs generation on the same thread that entered the
 * JNI call (no background threads), so the captured JNIEnv pointer remains
 * valid throughout the call. If we ever move generation off-thread in
 * ma_core, we'd need to AttachCurrentThread here.
 * ---------------------------------------------------------------------- */
struct JniCallbackCtx {
    JNIEnv   *env;
    jobject   callback;
    jmethodID on_token;
};

static void jni_token_cb(const char *piece, void *user_data) {
    auto *ctx = static_cast<JniCallbackCtx *>(user_data);
    if (!ctx || !ctx->env || !ctx->callback || !ctx->on_token) return;
    jstring jPiece = ctx->env->NewStringUTF(piece);
    if (jPiece) {
        ctx->env->CallVoidMethod(ctx->callback, ctx->on_token, jPiece);
        ctx->env->DeleteLocalRef(jPiece);
    }
}

/* Resolve the onToken method on a callback object. Returns NULL on failure. */
static jmethodID resolve_on_token(JNIEnv *env, jobject callback) {
    if (!callback) return nullptr;
    jclass cbClass = env->GetObjectClass(callback);
    jmethodID mid = env->GetMethodID(cbClass, "onToken", "(Ljava/lang/String;)V");
    if (!mid) {
        LOGE("resolve_on_token: MaTokenCallback.onToken(String) not found");
    }
    return mid;
}

/* ==========================================================================
 *                                    JNI
 * ========================================================================= */

extern "C" JNIEXPORT jlong JNICALL
Java_app_m1k3_ai_assistant_ai_ma_MaBridge_nativeInit(
        JNIEnv *env, jobject /*thiz*/,
        jstring  jModelPath,
        jint     nCtx,
        jint     nBatch,
        jint     nUbatch,
        jint     threadsGen,
        jint     threadsBatch,
        jboolean useFlashAttn,
        jint     kvQuantOrdinal,
        jboolean useMlock,
        jstring  jNativeLibDir,
        jstring  jPreferredCpuVariant) {

    const char *modelPath    = env->GetStringUTFChars(jModelPath, nullptr);
    const char *nativeLibDir = jNativeLibDir ? env->GetStringUTFChars(jNativeLibDir, nullptr) : nullptr;
    const char *preferredVariant =
            jPreferredCpuVariant ? env->GetStringUTFChars(jPreferredCpuVariant, nullptr) : nullptr;
    ma_init_result res = ma_core_init(
            modelPath,
            (int) nCtx,
            (int) nBatch,
            (int) nUbatch,
            (int) threadsGen,
            (int) threadsBatch,
            useFlashAttn == JNI_TRUE ? 1 : 0,
            (int) kvQuantOrdinal,
            useMlock == JNI_TRUE ? 1 : 0,
            nativeLibDir,
            preferredVariant);
    env->ReleaseStringUTFChars(jModelPath, modelPath);
    if (jNativeLibDir) env->ReleaseStringUTFChars(jNativeLibDir, nativeLibDir);
    if (jPreferredCpuVariant) env->ReleaseStringUTFChars(jPreferredCpuVariant, preferredVariant);

    if (res.handle == 0) {
        LOGE("init: ma_core_init returned 0");
    }
    return static_cast<jlong>(res.handle);
}

extern "C" JNIEXPORT jstring JNICALL
Java_app_m1k3_ai_assistant_ai_ma_MaBridge_nativeLastLoadedCpuVariant(
        JNIEnv *env, jobject /*thiz*/) {
    char *out = ma_core_last_loaded_cpu_variant();
    jstring jOut = env->NewStringUTF(out ? out : "");
    ma_core_free_string(out);
    return jOut;
}

extern "C" JNIEXPORT jstring JNICALL
Java_app_m1k3_ai_assistant_ai_ma_MaBridge_nativeGenerate(
        JNIEnv *env, jobject /*thiz*/,
        jlong   handle,
        jstring jPrompt,
        jint    maxTokens,
        jfloat  temperature,
        jfloat  topP,
        jint    topK,
        jfloat  minP,
        jfloat  repeatPenalty,
        jobject callback,
        jstring jGrammar) {

    const char *prompt_c  = env->GetStringUTFChars(jPrompt,  nullptr);
    const char *grammar_c = jGrammar ? env->GetStringUTFChars(jGrammar, nullptr) : nullptr;

    JniCallbackCtx cb_ctx = { env, callback, resolve_on_token(env, callback) };
    ma_token_cb    cb_fn  = (callback && cb_ctx.on_token) ? &jni_token_cb : nullptr;
    void          *cb_ud  = (callback && cb_ctx.on_token) ? &cb_ctx       : nullptr;

    char *out = ma_core_generate(
            static_cast<ma_handle>(handle),
            prompt_c,
            (int)   maxTokens,
            (float) temperature,
            (float) topP,
            (int)   topK,
            (float) repeatPenalty,
            (float) minP,
            cb_fn, cb_ud,
            grammar_c);

    env->ReleaseStringUTFChars(jPrompt, prompt_c);
    if (jGrammar) env->ReleaseStringUTFChars(jGrammar, grammar_c);

    jstring jOut = env->NewStringUTF(out ? out : "");
    ma_core_free_string(out);
    return jOut;
}

extern "C" JNIEXPORT jstring JNICALL
Java_app_m1k3_ai_assistant_ai_ma_MaBridge_nativeGenerateChat(
        JNIEnv *env, jobject /*thiz*/,
        jlong    handle,
        jstring  jMessagesJson,
        jstring  jToolsJson,
        jint     maxTokens,
        jfloat   temperature,
        jfloat   topP,
        jint     topK,
        jfloat   minP,
        jfloat   repeatPenalty,
        jboolean enableThinking,
        jobject  callback) {

    const char *messages_c = env->GetStringUTFChars(jMessagesJson, nullptr);
    const char *tools_c    = jToolsJson ? env->GetStringUTFChars(jToolsJson, nullptr) : "";

    JniCallbackCtx cb_ctx = { env, callback, resolve_on_token(env, callback) };
    ma_token_cb    cb_fn  = (callback && cb_ctx.on_token) ? &jni_token_cb : nullptr;
    void          *cb_ud  = (callback && cb_ctx.on_token) ? &cb_ctx       : nullptr;

    char *out = ma_core_generate_chat(
            static_cast<ma_handle>(handle),
            messages_c,
            tools_c,
            (int)   maxTokens,
            (float) temperature,
            (float) topP,
            (int)   topK,
            (float) repeatPenalty,
            (float) minP,
            enableThinking == JNI_TRUE ? 1 : 0,
            cb_fn, cb_ud);

    env->ReleaseStringUTFChars(jMessagesJson, messages_c);
    if (jToolsJson) env->ReleaseStringUTFChars(jToolsJson, tools_c);

    jstring jOut = env->NewStringUTF(out ? out : "{\"error\":\"null result\"}");
    ma_core_free_string(out);
    return jOut;
}

extern "C" JNIEXPORT jlong JNICALL
Java_app_m1k3_ai_assistant_ai_ma_MaBridge_nativeInitEmbedding(
        JNIEnv *env, jobject /*thiz*/,
        jstring jModelPath,
        jint    nCtx,
        jstring jNativeLibDir,
        jstring jPreferredCpuVariant) {

    const char *modelPath    = env->GetStringUTFChars(jModelPath, nullptr);
    const char *nativeLibDir = jNativeLibDir ? env->GetStringUTFChars(jNativeLibDir, nullptr) : nullptr;
    const char *preferredVariant =
            jPreferredCpuVariant ? env->GetStringUTFChars(jPreferredCpuVariant, nullptr) : nullptr;

    ma_handle handle = ma_core_init_embedding(
            modelPath, (int) nCtx, nativeLibDir, preferredVariant);

    env->ReleaseStringUTFChars(jModelPath, modelPath);
    if (jNativeLibDir) env->ReleaseStringUTFChars(jNativeLibDir, nativeLibDir);
    if (jPreferredCpuVariant) env->ReleaseStringUTFChars(jPreferredCpuVariant, preferredVariant);

    if (handle == 0) {
        LOGE("embed-init: ma_core_init_embedding returned 0");
    }
    return static_cast<jlong>(handle);
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_app_m1k3_ai_assistant_ai_ma_MaBridge_nativeEmbed(
        JNIEnv *env, jobject /*thiz*/,
        jlong   handle,
        jstring jText) {

    const char *text = env->GetStringUTFChars(jText, nullptr);

    // Generous upper bound on embedding width; ma_core_embed returns the real
    // n_embd (EmbeddingGemma is 768) and refuses if it would exceed this.
    static const int kMaxDim = 4096;
    std::vector<float> buf(kMaxDim);
    const int n = ma_core_embed(
            static_cast<ma_handle>(handle), text, buf.data(), kMaxDim);

    env->ReleaseStringUTFChars(jText, text);

    if (n <= 0) {
        LOGE("embed: ma_core_embed returned %d", n);
        return nullptr; // caller maps null → failure
    }

    jfloatArray out = env->NewFloatArray(n);
    if (!out) {
        LOGE("embed: NewFloatArray(%d) failed", n);
        return nullptr;
    }
    env->SetFloatArrayRegion(out, 0, n, buf.data());
    return out;
}

extern "C" JNIEXPORT void JNICALL
Java_app_m1k3_ai_assistant_ai_ma_MaBridge_release(
        JNIEnv */*env*/, jobject /*thiz*/, jlong handle) {
    ma_core_release(static_cast<ma_handle>(handle));
}
