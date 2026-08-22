/*
 * ma_core.h — portable C API for the Ma inference library.
 *
 * Wraps llama.cpp's stable C API behind a plain-C facade so both Android (JNI)
 * and iOS (Kotlin/Native cinterop) can bind to the same implementation.
 *
 * No JNI types, no C++ types, no Swift types. Just uint/int/float/char*.
 * Streaming uses a C function pointer + user_data (host-side trampolines).
 *
 * Callers:
 *   - Android: ma_bridge.cpp wraps these in JNI (JNIEnv/jstring/jobject → C).
 *   - iOS    : Kotlin/Native cinterop binds this header directly.
 */

#ifndef MA_CORE_H
#define MA_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Opaque handle to a loaded model + context. Zero means invalid / failure. */
typedef uint64_t ma_handle;

/** Streaming-token callback.
 *  `piece` is a NUL-terminated UTF-8 string valid only during this call;
 *  copy it if you need to retain it. `user_data` is passed through unchanged. */
typedef void (*ma_token_cb)(const char *piece, void *user_data);

/** Result of ma_core_init. On failure, handle == 0 and the other fields
 *  describe what was attempted (used for diagnostics on the host side). */
typedef struct {
    ma_handle handle;          /* 0 = failure */
    int       fell_back;       /* 1 = retry-on-null fallback kicked in */
    int       effective_fa;    /* final flash-attn setting: 0 = off, 1 = auto */
    int       effective_kv;    /* final KV type: 0 = F16, 1 = Q8_0 */
    int       n_threads_gen;   /* final gen thread count (what llama.cpp got) */
    int       n_threads_batch; /* final prefill thread count */
} ma_init_result;

/**
 * Load a GGUF model and create an inference context.
 *
 * Tuning knobs (nCtx/nBatch/nUbatch/threads/FA/KV/mlock) come from the domain
 * `InferenceTuning.resolve` matrix on the host side; this function applies them
 * verbatim with a retry-on-null safety net: if the aggressive config fails to
 * instantiate a context (some ARM kernel variants reject FA+Q8_0), it retries
 * once with F16 + FA disabled. The caller can detect this via `fell_back`.
 *
 * On the FIRST call per process, this also loads the ggml CPU backend: when
 * built with GGML_BACKEND_DL (see androidMain/cpp/CMakeLists.txt), the CPU
 * backend ships as several `libggml-cpu-<variant>.so` runtime-dispatch
 * modules rather than being linked in directly, and nothing registers a CPU
 * device until something asks. `backend_lib_dir` is where those modules live
 * (Android: the app's `nativeLibraryDir`, beside `libma.so`); pass NULL or ""
 * to fall back to the process's default search paths (executable dir + cwd
 * — rarely useful on Android, but harmless, and a no-op on builds that don't
 * define GGML_BACKEND_DL, e.g. a future statically-linked iOS bridge).
 * Subsequent calls ignore this parameter — the backend load only ever runs
 * once, and picks the best-scoring variant for the CPU actually running it.
 *
 * `preferred_cpu_variant` (nullable/"" = no preference): a bare `.so`
 * filename (e.g. "libggml-cpu-android_armv9.0_1.so") to try loading FIRST,
 * before the built-in most-capable-first order in `kAndroidCpuBackendVariants`
 * (ma_core.cpp). Exists so `tools/eval/android` can force a specific CPU
 * variant to reproduce a variant-specific bug (the Pixel 9a SVE2
 * broken-logits case) as a fixture cell rather than a one-off log read.
 * Ignored on non-Android builds and once the backend has already loaded for
 * this process (see load_cpu_backends_once's "Idempotent" note) — the eval
 * harness relies on the Python driver launching a fresh process per variant
 * cell (`am force-stop` between cells), matching how production behaves.
 *
 * Returns 0 in handle on hard failure (model load failed, or fallback also failed).
 */
ma_init_result ma_core_init(
    const char *model_path,
    int         n_ctx,
    int         n_batch,
    int         n_ubatch,
    int         threads_gen,      /* 0 = hw-derived */
    int         threads_batch,    /* 0 = hw-derived */
    int         use_flash_attn,   /* bool-like: nonzero = on */
    int         kv_quant_ordinal, /* 0 = F16, 1 = Q8_0 */
    int         use_mlock,        /* bool-like */
    const char *backend_lib_dir,  /* nullable; see above */
    const char *preferred_cpu_variant /* nullable/""; see above */
);

/**
 * The bare `.so` filename of the CPU backend variant that actually
 * registered on the first ma_core_init call this process, or an empty
 * string if unknown (no model has loaded yet, non-Android build, or the
 * backend fell through to the default-search-path scan rather than
 * matching a known variant name). Set once, at the first successful backend
 * load — see load_cpu_backends_once's "Idempotent" note.
 *
 * Returns a heap-allocated NUL-terminated UTF-8 string. Caller MUST free it
 * via ma_core_free_string, same convention as ma_core_generate.
 */
char *ma_core_last_loaded_cpu_variant(void);

/**
 * Generate text from a pre-formatted prompt.
 *
 * Streaming: when `cb` is non-NULL, fires on every complete UTF-8 boundary.
 * Non-streaming: pass NULL for `cb`; only the full string is returned.
 *
 * `grammar` may be NULL. When non-NULL, installs a lazy grammar sampler
 * triggered by the literal `<tool_call>` pattern (matches the Kotlin-side
 * tool-call convention).
 *
 * Return value is a heap-allocated NUL-terminated UTF-8 string. Caller MUST
 * free it via ma_core_free_string. Returns an empty non-NULL string on
 * non-fatal errors (e.g. tokenize failure) so callers can always free.
 * Returns NULL only on catastrophic allocation failure.
 */
char *ma_core_generate(
    ma_handle   handle,
    const char *prompt,
    int         max_tokens,
    float       temperature,
    float       top_p,
    int         top_k,
    float       repeat_penalty,
    float       min_p,
    ma_token_cb cb,
    void       *cb_user_data,
    const char *grammar
);

/**
 * Generate via the model's own chat template (common_chat_templates_apply).
 *
 * `messages_json` : OpenAI-style messages JSON array.
 * `tools_json`    : OpenAI-style tools JSON array ("" or "[]" = no tools).
 *
 * Returns a JSON string of shape:
 *   {"content":"...","reasoning_content":"...",
 *    "tool_calls":[{"name":"...","arguments":"...","id":"..."}],
 *    "raw":"..."}
 * or
 *   {"error":"..."}
 * on failure. Caller MUST free via ma_core_free_string.
 */
char *ma_core_generate_chat(
    ma_handle   handle,
    const char *messages_json,
    const char *tools_json,
    int         max_tokens,
    float       temperature,
    float       top_p,
    int         top_k,
    float       repeat_penalty,
    float       min_p,
    int         enable_thinking, /* bool-like */
    ma_token_cb cb,
    void       *cb_user_data
);

/** Free a string returned by ma_core_generate / ma_core_generate_chat. */
void ma_core_free_string(char *s);

/** Release a context. After this call the handle is invalid. */
void ma_core_release(ma_handle handle);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* MA_CORE_H */
