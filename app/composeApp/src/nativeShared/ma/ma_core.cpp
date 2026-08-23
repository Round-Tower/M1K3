/*
 * ma_core.cpp — portable implementation behind ma_core.h.
 *
 * All llama.cpp interaction lives here. No JNI, no Swift, no platform headers
 * other than a log macro that conditionally uses Android's logcat when
 * __ANDROID__ is defined and stderr otherwise.
 *
 * Ported from the original JNI-coupled ma_bridge.cpp as part of the
 * ma_core / ma_bridge split (2026-04-19). JNI-only logic (env/jstring/jobject)
 * moved to ma_bridge.cpp; everything else is here.
 *
 * MurphySig: kev+claude / confidence 0.88 / 2026-04-19
 *
 * Review 2026-08-22 (kev+claude-fable-5, confidence 0.85): ma_core_init
 * gained a backend_lib_dir param + load_cpu_backends_once(), the runtime
 * side of the GGML_BACKEND_DL / GGML_CPU_ALL_VARIANTS switch in
 * androidMain/cpp/CMakeLists.txt (kills a fixed armv8.2-a+dotprod+i8mm
 * -march flag that SIGILLs on any arm64 core without i8mm — plausibly the
 * source of the 2026-04-19 "libggml-cpu.so SIGSEGV/ANR" note in
 * app/.claude/project-memory.md, though that was never confirmed as the
 * same crash). Pattern started from llama.cpp's own
 * examples/llama.android/lib/src/main/cpp/ai_chat.cpp
 * (ggml_backend_load_all_from_path → llama_backend_init, once, before any
 * model load), then diverged: that upstream directory-scan finds NOTHING
 * on this app's packaging (confirmed on-device — the app's nativeLibraryDir
 * exists but is empty under AGP's default extractNativeLibs=false), so
 * load_cpu_backends_once tries known Android variant module names BARE
 * first (see its own header + kAndroidCpuBackendVariants, both above),
 * falling back to the upstream directory scan only if none of those match.
 *
 * VERIFIED ON-DEVICE (Android Studio arm64-v8a emulator on Apple Silicon,
 * the exact CPU this fix targets — its virtual core reports `asimddp`
 * [dotprod] but no `i8mm` in /proc/cpuinfo, the precise gap the old fixed
 * -march flag didn't allow for): logcat shows `load_backends: loaded CPU
 * backend variant libggml-cpu-android_armv8.2_2.so` (the highest tier that
 * doesn't require i8mm) followed by a clean `init: success`, and a real
 * chat turn streamed to completion (63 tokens, 279 chars, ~3.2 tok/s) with
 * no SIGILL and no crash. Not verified: a REAL (non-emulator) i8mm-capable
 * device picking one of the higher armv8.6+/armv9.x tiers — Kev's to
 * confirm on a Pixel; x86_64 is deliberately unchanged by this commit (see
 * CMakeLists.txt) so it carries no new risk either way.
 */

#include "ma_core.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <exception>
#include <string>
#include <thread>
#include <vector>

#include "llama.h"
#include "chat.h"                 // common/chat.h — native chat-template rendering + tool-call parsing
#include "nlohmann/json.hpp"      // vendored in llama.cpp/vendor (moved from common/vendor upstream)

#ifdef __ANDROID__
#include <android/log.h>
#define LOG_TAG "MaCore"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#else
#define LOGI(fmt, ...) fprintf(stderr, "[MaCore I] " fmt "\n", ##__VA_ARGS__)
#define LOGE(fmt, ...) fprintf(stderr, "[MaCore E] " fmt "\n", ##__VA_ARGS__)
#define LOGD(fmt, ...) fprintf(stderr, "[MaCore D] " fmt "\n", ##__VA_ARGS__)
#endif

namespace {

/* -------------------------------------------------------------------------
 * Internal context type — mirrors the MaContext struct that used to live in
 * ma_bridge.cpp. Stays C++ because it holds C++-typed fields (common_chat_templates_ptr).
 * ---------------------------------------------------------------------- */
struct MaContext {
    llama_model               *model = nullptr;
    llama_context             *ctx   = nullptr;
    common_chat_templates_ptr  tmpls; /* null if templates_init failed */
    /* Cooperative stop: the UI's "stop" button sets this via
     * ma_core_request_stop; the generation loops check it each iteration and
     * break, returning whatever was produced so far (like ChatGPT's stop). */
    std::atomic<bool>          stop_requested{false};
};

MaContext *handle_to_ctx(ma_handle handle) {
    return reinterpret_cast<MaContext *>(static_cast<uintptr_t>(handle));
}

ma_handle ctx_to_handle(MaContext *ma) {
    return static_cast<ma_handle>(reinterpret_cast<uintptr_t>(ma));
}

/* -------------------------------------------------------------------------
 * UTF-8 boundary check. Returns true if [data, data+len) ends on a complete
 * UTF-8 sequence. Used to hold back partial multi-byte pieces until the
 * sequence completes so streaming callbacks never emit invalid UTF-8.
 * ---------------------------------------------------------------------- */
bool is_complete_utf8(const char *data, size_t len) {
    if (len == 0) return true;
    const unsigned char *p = reinterpret_cast<const unsigned char *>(data);
    size_t i = 0;
    while (i < len) {
        unsigned char c = p[i];
        int seq_len;
        if      (c < 0x80)               seq_len = 1;
        else if ((c & 0xE0) == 0xC0)     seq_len = 2;
        else if ((c & 0xF0) == 0xE0)     seq_len = 3;
        else if ((c & 0xF8) == 0xF0)     seq_len = 4;
        else return false;                /* invalid lead byte */
        if (i + seq_len > len) return false; /* truncated sequence */
        i += seq_len;
    }
    return true;
}

/* -------------------------------------------------------------------------
 * Install a lazy grammar sampler derived from common_chat_params' triggers.
 * Returns true if installed OR if there's nothing to install (success).
 * Returns false only when a grammar was supplied but compilation failed.
 * Identical to the version that used to live in ma_bridge.cpp.
 * ---------------------------------------------------------------------- */
bool install_chat_grammar_sampler(
        llama_sampler            *smpl,
        const llama_vocab        *vocab,
        const common_chat_params &params) {
    if (params.grammar.empty()) return true;

    std::vector<std::string> trigger_patterns;
    std::vector<llama_token> trigger_tokens;
    for (const auto &trigger : params.grammar_triggers) {
        switch (trigger.type) {
            case COMMON_GRAMMAR_TRIGGER_TYPE_WORD: {
                /* Minimal regex escape for the characters that appear in real
                 * trigger words the chat templates emit. Mirrors the upstream
                 * regex_escape which is internal to common/sampling.cpp. */
                std::string escaped;
                escaped.reserve(trigger.value.size() * 2);
                for (char c : trigger.value) {
                    if (strchr(R"([]{}|().+*?^$\)", c)) escaped.push_back('\\');
                    escaped.push_back(c);
                }
                trigger_patterns.push_back(std::move(escaped));
                break;
            }
            case COMMON_GRAMMAR_TRIGGER_TYPE_PATTERN:
                trigger_patterns.push_back(trigger.value);
                break;
            case COMMON_GRAMMAR_TRIGGER_TYPE_PATTERN_FULL: {
                const auto &pattern = trigger.value;
                std::string anchored = "^$";
                if (!pattern.empty()) {
                    anchored = (pattern.front() != '^' ? "^" : "") + pattern +
                               (pattern.back()  != '$' ? "$" : "");
                }
                trigger_patterns.push_back(std::move(anchored));
                break;
            }
            case COMMON_GRAMMAR_TRIGGER_TYPE_TOKEN:
                trigger_tokens.push_back(trigger.token);
                break;
        }
    }

    std::vector<const char *> trigger_patterns_c;
    trigger_patterns_c.reserve(trigger_patterns.size());
    for (const auto &p : trigger_patterns) trigger_patterns_c.push_back(p.c_str());

    llama_sampler *grammar_smpl = nullptr;
    if (params.grammar_lazy) {
        grammar_smpl = llama_sampler_init_grammar_lazy_patterns(
                vocab, params.grammar.c_str(), "root",
                trigger_patterns_c.data(), trigger_patterns_c.size(),
                trigger_tokens.data(), trigger_tokens.size());
    } else {
        grammar_smpl = llama_sampler_init_grammar(vocab, params.grammar.c_str(), "root");
    }

    if (!grammar_smpl) {
        LOGE("install_chat_grammar_sampler: grammar compilation failed");
        return false;
    }
    llama_sampler_chain_add(smpl, grammar_smpl);
    LOGI("install_chat_grammar_sampler: installed (%s, %zu patterns, %zu tokens)",
         params.grammar_lazy ? "lazy" : "strict",
         trigger_patterns.size(), trigger_tokens.size());
    return true;
}

/* -------------------------------------------------------------------------
 * strdup the contents of a std::string to a caller-owned heap buffer.
 * Returns NULL only on malloc failure.
 * ---------------------------------------------------------------------- */
char *heap_cstr(const std::string &s) {
    const size_t n = s.size();
    char *out = static_cast<char *>(std::malloc(n + 1));
    if (!out) return nullptr;
    std::memcpy(out, s.data(), n);
    out[n] = '\0';
    return out;
}

/* Convenience for returning static-literal error JSON (caller frees via
 * ma_core_free_string, same as any other returned string). */
char *heap_cstr(const char *literal) {
    return heap_cstr(std::string(literal));
}

#ifdef __ANDROID__
/* Android CPU-variant module names, most-capable first. Mirrors the
 * `ggml_add_cpu_backend_variant(android_*...)` calls in
 * llama.cpp/ggml/src/CMakeLists.txt at our pinned submodule commit — see
 * load_cpu_backends_once's header for why bare names, and why order here
 * only has to be "at least as capable first", not a perfect total order:
 * armv9.2_2 is a strict superset of every other tier's features, so trying
 * it first and stopping at the first successful load is always correct
 * when it works; when it doesn't, armv9.0_1 and armv9.2_1 have disjoint
 * feature sets (SVE2-no-SVE/SME vs SVE+SME-no-SVE2) so at most one of them
 * can ever load on a given device — their relative order doesn't matter. */
/* The SVE/SVE2/SME variants (armv9.x) are tried AFTER armv8.6_1 — for
 * LATENCY, not correctness. On a Pixel 9a (Tensor G4, llama.cpp e85caa81e)
 * armv8.6_1 is both faster and slightly higher-scoring than armv9.0_1 in
 * the eval matrix (5017ms vs 5912ms median, 19/22 vs 17/22, 2026-08-22
 * F1/F2 re-baseline), and i8mm is the real win on phones.
 *
 * ⚠️ CORRECTION (2026-08-22): the earlier claim here — that armv9.0_1
 * "produces broken logits" because Qwen3.5-0.8B answered every prompt with
 * an empty think block + end-of-generation at ~6 tokens — DID NOT
 * reproduce once F1 (PEG parser), F2 (reasoning_format=AUTO) and the
 * per-call KV-cache clear landed (68712e0f) and thinking was disabled for
 * the small tiers (ThinkingPolicy). On the clean re-baseline armv9.0_1
 * generates real answers (17/22: correct "Canberra", a working time tool,
 * a proper photosynthesis explanation). The empty-think+EOG shape was the
 * thinking-on / dirty-KV / unparsed bugs, not the CPU kernel. So armv9 is
 * NOT broken — keep armv8.6_1 first on latency, but do not treat armv9 as
 * unusable. Single-run scores are noisy; re-confirm on the next device
 * session and on every llama.cpp bump. */
static const char *kAndroidCpuBackendVariants[] = {
    "libggml-cpu-android_armv8.6_1.so",
    "libggml-cpu-android_armv9.2_2.so",
    "libggml-cpu-android_armv9.2_1.so",
    "libggml-cpu-android_armv9.0_1.so",
    "libggml-cpu-android_armv8.2_2.so",
    "libggml-cpu-android_armv8.2_1.so",
    "libggml-cpu-android_armv8.0_1.so",
};
#endif

/* -------------------------------------------------------------------------
 * Load the ggml CPU backend once per process.
 *
 * When built with GGML_BACKEND_DL (see androidMain/cpp/CMakeLists.txt), the
 * CPU backend ships as several `libggml-cpu-<variant>.so` runtime-dispatch
 * modules — one per ARM feature tier — rather than being linked directly
 * into libma.so. Nothing registers a CPU device until something calls
 * ggml_backend_load_all()/ggml_backend_load_all_from_path()/ggml_backend_load():
 * the registry's static-init auto-registration path only fires for the OLD
 * single-variant (non-DL) build (guarded by #ifdef GGML_USE_CPU upstream,
 * which is never defined in DL mode). Skipping this call is silent —
 * llama_model_load_from_file still "succeeds" at parsing the GGUF, then
 * fails to find any device to run on, deep inside the loader.
 *
 * On Android, `ggml_backend_load_all_from_path(lib_dir)` — upstream's own
 * discovery mechanism, a plain `fs::directory_iterator` scan — finds
 * NOTHING even when `lib_dir` is the app's real `nativeLibraryDir`: modern
 * AGP (extractNativeLibs=false, our default — see composeApp/build.gradle.kts's
 * 16KB-alignment comment) never copies JNI libs out to a real directory on
 * disk; they're mmap'd straight from the APK's own lib/<abi>/ zip entries.
 * Confirmed on-device: that directory exists but is empty. So instead we
 * try loading each known Android CPU-variant module by its BARE filename
 * (kAndroidCpuBackendVariants below, most-capable first) — bionic's dynamic
 * linker resolves a bare name (no path separators) against the app's own
 * process-wide linker namespace, which the OS populates from the APK's
 * embedded native libs at process start. That's the exact mechanism that
 * already makes plain `System.loadLibrary("ma")` work despite that same
 * empty directory. ggml_backend_load() already gates each candidate
 * through its own ggml_backend_score() (0 = "not supported on this
 * device", silently rejected, not registered) — we just stop at the first
 * one that actually registers.
 *
 * `lib_dir` (Android: the app's `nativeLibraryDir`, see ma_core_init) is
 * kept as a fallback for anything the bare-name loop doesn't handle: a
 * non-Android build, an Android build where none of the known variant
 * names matched (a stale list after a submodule bump — see the variant
 * list's own comment), or a future host where extraction genuinely does
 * populate a real directory. Empty/NULL there falls back further to the
 * process's default search paths (executable dir + cwd) via
 * ggml_backend_load_all(). This whole function is a harmless no-op on any
 * build that doesn't define GGML_BACKEND_DL (no libggml-cpu-*.so exists to
 * find by any method, and the static-registration path already ran).
 *
 * Idempotent: only the first call does anything, subsequent calls return
 * immediately, so switching between model tiers (Mini/Lil/Big) within one
 * app process never re-scans anything or re-dlopens anything.
 * ---------------------------------------------------------------------- */
/* Set once, at the first successful backend load — see this function's own
 * "Idempotent" note. Read back via ma_core_last_loaded_cpu_variant(). */
std::string g_last_loaded_cpu_variant;

void load_cpu_backends_once(const char *lib_dir, const char *preferred_variant) {
    static bool loaded = false;
    if (loaded) return;
    loaded = true;

    bool got_cpu_backend = false;

#ifdef __ANDROID__
    /* Eval-harness override (CpuVariantOverride, Kotlin side): try this exact
     * variant name FIRST, before the built-in most-capable-first order. See
     * ma_core_init's header for why this only ever fires from the eval
     * harness — production always passes "". */
    if (preferred_variant && *preferred_variant) {
        if (ggml_backend_load(preferred_variant)) {
            LOGI("load_backends: loaded PREFERRED CPU backend variant %s", preferred_variant);
            g_last_loaded_cpu_variant = preferred_variant;
            got_cpu_backend = true;
        } else {
            LOGI("load_backends: preferred variant %s did not load on this device, "
                 "falling back to the default order", preferred_variant);
        }
    }

    if (!got_cpu_backend) {
        for (const char *name : kAndroidCpuBackendVariants) {
            /* Preferred variant already tried above; skip re-trying it. */
            if (preferred_variant && *preferred_variant && std::strcmp(name, preferred_variant) == 0) {
                continue;
            }
            if (ggml_backend_load(name)) {
                LOGI("load_backends: loaded CPU backend variant %s", name);
                g_last_loaded_cpu_variant = name;
                got_cpu_backend = true;
                break;
            }
        }
    }
#endif

    if (!got_cpu_backend) {
        if (lib_dir && *lib_dir) {
            LOGI("load_backends: scanning %s for ggml backend variants", lib_dir);
            ggml_backend_load_all_from_path(lib_dir);
        } else {
            LOGI("load_backends: no lib dir given, using default search paths");
            ggml_backend_load_all();
        }
    }

    /* Cheap + idempotent: inits ggml's F16 lookup tables. Safe to call even
     * if backend loading above found nothing (matches llama.cpp's own
     * reference Android app — examples/llama.android/lib/src/main/cpp). */
    llama_backend_init();

    const size_t n_devices = ggml_backend_dev_count();
    if (n_devices == 0) {
        LOGE("load_backends: zero backend devices registered — model load will fail");
        return;
    }
    for (size_t i = 0; i < n_devices; i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        ggml_backend_reg_t reg = ggml_backend_dev_backend_reg(dev);
        LOGI("load_backends: device[%zu] %s (%s) via %s",
             i,
             ggml_backend_dev_name(dev),
             ggml_backend_dev_description(dev),
             reg ? ggml_backend_reg_name(reg) : "?");
    }
}

} /* namespace */

/* ==========================================================================
 *                                Public API
 * ========================================================================= */

extern "C" {

ma_init_result ma_core_init(
        const char *model_path,
        int         n_ctx,
        int         n_batch,
        int         n_ubatch,
        int         threads_gen,
        int         threads_batch,
        int         use_flash_attn,
        int         kv_quant_ordinal,
        int         use_mlock,
        const char *backend_lib_dir,
        const char *preferred_cpu_variant) {

    ma_init_result result = { 0, 0, 0, 0, 0, 0 };

    /* Must happen before the first llama_model_load_from_file — the CPU
     * backend has to be registered (loaded + scored) before anything asks
     * for a device to run on. See load_cpu_backends_once's header. */
    load_cpu_backends_once(backend_lib_dir, preferred_cpu_variant);

    // Route llama.cpp's own log into ours — a "failed to load model" without the
    // loader's reason ("unknown tensor", "missing key", mmap failure) is
    // undebuggable from logcat (bit us 2026-08-21 on the Pixel). Warnings and
    // errors only; the per-tensor INFO stream is noise at runtime.
    static bool log_hooked = false;
    if (!log_hooked) {
        llama_log_set([](ggml_log_level level, const char *text, void *) {
            if (!text || !*text) return;
            std::string line(text);
            while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();
            if (line.empty()) return;
            if (level == GGML_LOG_LEVEL_ERROR) {
                LOGE("llama: %s", line.c_str());
            } else if (level == GGML_LOG_LEVEL_WARN) {
                LOGI("llama: %s", line.c_str());
            }
        }, nullptr);
        log_hooked = true;
    }

    LOGI("init: loading %s", model_path ? model_path : "(null)");
    if (!model_path) {
        LOGE("init: null model_path");
        return result;
    }

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0; /* CPU-only on mobile for now */
    // use_mmap/use_mlock were consolidated into a single load_mode enum
    // upstream. Preserve prior behaviour exactly: mmap always on, mlock
    // toggled by the caller (was the implicit default before this merge —
    // we never touched use_mmap, so it stayed true).
    mparams.load_mode = (use_mlock != 0) ? LLAMA_LOAD_MODE_MMAP_MLOCK : LLAMA_LOAD_MODE_MMAP;

    llama_model *model = llama_model_load_from_file(model_path, mparams);
    if (!model) {
        LOGE("init: failed to load model");
        return result;
    }

    const int hw_threads = (int) std::thread::hardware_concurrency();
    const int n_threads       = (threads_gen   > 0) ? threads_gen   : std::min(4, hw_threads);
    const int n_threads_batch = (threads_batch > 0) ? threads_batch : std::min(hw_threads, 6);

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx            = (uint32_t)(n_ctx   > 0 ? n_ctx   : 2048);
    cparams.n_batch          = (uint32_t)(n_batch > 0 ? n_batch : 512);
    cparams.n_ubatch         = (uint32_t)(n_ubatch > 0 ? n_ubatch : 128);
    cparams.n_threads        = n_threads;
    cparams.n_threads_batch  = n_threads_batch;

    const bool wantFA  = use_flash_attn != 0;
    const bool wantQ8  = kv_quant_ordinal == 1 && wantFA;

    cparams.flash_attn_type = wantFA
                                  ? LLAMA_FLASH_ATTN_TYPE_AUTO
                                  : LLAMA_FLASH_ATTN_TYPE_DISABLED;
    if (wantQ8) {
        cparams.type_k = GGML_TYPE_Q8_0;
        cparams.type_v = GGML_TYPE_Q8_0;
    }

    /* Retry-on-null safety net: if the aggressive config (FA / Q8_0) fails on
     * this device's kernel variant, reset to F16 + FA disabled and retry once.
     * Init never fails over a tuning choice. */
    llama_context *ctx = llama_init_from_model(model, cparams);
    bool fellBack = false;
    if (!ctx && (wantFA || wantQ8)) {
        LOGE("init: aggressive context (fa=%d kv=%d) failed; retrying with F16 + FA disabled",
             wantFA ? 1 : 0, wantQ8 ? 1 : 0);
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;
        cparams.type_k = GGML_TYPE_F16;
        cparams.type_v = GGML_TYPE_F16;
        ctx = llama_init_from_model(model, cparams);
        fellBack = true;
    }
    if (!ctx) {
        LOGE("init: failed to create context");
        llama_model_free(model);
        return result;
    }

    auto *ma = new MaContext();
    ma->model = model;
    ma->ctx   = ctx;

    try {
        ma->tmpls = common_chat_templates_init(model, "");
        LOGI("init: chat templates loaded");
    } catch (const std::exception &e) {
        LOGE("init: common_chat_templates_init threw: %s — native chat path disabled", e.what());
    }

    const int effectiveFa = (cparams.flash_attn_type == LLAMA_FLASH_ATTN_TYPE_AUTO) ? 1 : 0;
    const int effectiveKv = (cparams.type_k == GGML_TYPE_Q8_0) ? 1 : 0;
    LOGI("init: success (handle=%p, n_ctx=%d, n_batch=%d, n_ubatch=%d, threads=%d/%d, fa=%d, kv=%d, mlock=%d%s)",
         ma, cparams.n_ctx, cparams.n_batch, cparams.n_ubatch,
         n_threads, n_threads_batch,
         effectiveFa, effectiveKv,
         use_mlock != 0 ? 1 : 0,
         fellBack ? " FALLBACK" : "");

    result.handle          = ctx_to_handle(ma);
    result.fell_back       = fellBack ? 1 : 0;
    result.effective_fa    = effectiveFa;
    result.effective_kv    = effectiveKv;
    result.n_threads_gen   = n_threads;
    result.n_threads_batch = n_threads_batch;
    return result;
}

/* ---------------------------------------------------------------------- */

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
        const char *grammar) {

    MaContext *ma = handle_to_ctx(handle);
    if (!ma || !ma->model || !ma->ctx) {
        LOGE("generate: invalid handle");
        return heap_cstr("");
    }
    ma->stop_requested.store(false, std::memory_order_relaxed);
    if (!prompt) {
        LOGE("generate: null prompt");
        return heap_cstr("");
    }

    const llama_vocab *vocab = llama_model_get_vocab(ma->model);

    /* --- Tokenize prompt --- */
    const int n_ctx        = (int) llama_n_ctx(ma->ctx);
    const int n_prompt_max = n_ctx - max_tokens - 10;

    std::vector<llama_token> prompt_tokens(n_ctx);
    int n_prompt = llama_tokenize(
            vocab,
            prompt, (int32_t) std::strlen(prompt),
            prompt_tokens.data(), (int32_t) prompt_tokens.size(),
            /*add_special=*/true, /*parse_special=*/true);

    if (n_prompt < 0) {
        LOGE("generate: tokenization failed (n=%d)", n_prompt);
        return heap_cstr("");
    }
    if (n_prompt > n_prompt_max && n_prompt_max > 0) {
        LOGI("generate: truncating prompt %d → %d tokens", n_prompt, n_prompt_max);
        n_prompt = n_prompt_max;
    }
    prompt_tokens.resize(n_prompt);

    LOGD("generate: %d prompt tokens, maxTokens=%d", n_prompt, max_tokens);

    /* Every call is a fresh, self-contained prompt (the Kotlin side renders
     * the whole conversation each turn). Without this the KV cache was never
     * cleared and llama_batch_get_one APPENDED each turn after the last: the
     * context filled across turns until n_ctx, then every decode failed and
     * every answer came back empty until the process restarted — the eval
     * harness's "native context may have been lost" cascade (2026-08-22).
     * Prefix reuse across turns is a deliberate later step (see the Mac's
     * ConversationTailCache); correctness first. */
    llama_memory_clear(llama_get_memory(ma->ctx), /*data=*/true);


    /* --- Decode prompt tokens in n_batch-sized chunks ---
     * Upstream asserts n_tokens_all <= cparams.n_batch per decode call
     * (llama-context.cpp:1595). Callers must split prompts themselves;
     * the library does NOT auto-split across physical batches. */
    const int n_batch = (int) llama_n_batch(ma->ctx);
    for (int offset = 0; offset < n_prompt; offset += n_batch) {
        const int chunk = std::min(n_batch, n_prompt - offset);
        llama_batch batch = llama_batch_get_one(prompt_tokens.data() + offset, chunk);
        if (llama_decode(ma->ctx, batch) != 0) {
            LOGE("generate: prompt decode failed at offset=%d chunk=%d", offset, chunk);
            return heap_cstr("");
        }
    }

    /* --- Sampler chain --- */
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    llama_sampler *smpl = llama_sampler_chain_init(sparams);

    /* Grammar sampler first so invalid tokens are masked before other filters. */
    if (grammar) {
        static const char *trigger_patterns[] = { "<tool_call>" };
        llama_sampler *grammar_smpl = llama_sampler_init_grammar_lazy_patterns(
                vocab, grammar, /*grammar_root=*/"root",
                trigger_patterns, /*num_trigger_patterns=*/1,
                /*trigger_tokens=*/nullptr, /*num_trigger_tokens=*/0);
        if (grammar_smpl) {
            llama_sampler_chain_add(smpl, grammar_smpl);
            LOGI("generate: lazy grammar sampler installed (trigger=<tool_call>)");
        } else {
            LOGE("generate: grammar compilation failed; continuing unconstrained");
        }
    }

    llama_sampler_chain_add(smpl, llama_sampler_init_top_k(top_k));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(top_p, /*min_keep=*/1));
    if (min_p > 0.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_min_p(min_p, /*min_keep=*/1));
    }
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(smpl, llama_sampler_init_penalties(
            /*n_vocab=*/llama_vocab_n_tokens(vocab),
            /*penalty_last_n=*/64,
            /*penalty_repeat=*/repeat_penalty,
            /*penalty_freq=*/0.0f,
            /*penalty_present=*/0.0f));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    /* --- Generation loop --- */
    std::string accumulated;
    std::string utf8_buf;
    char piece_buf[256];

    const int n_max = std::min(max_tokens, n_ctx - n_prompt - 4);

    for (int i = 0; i < n_max; ++i) {
        if (ma->stop_requested.load(std::memory_order_relaxed)) {
            LOGD("generate: stop requested at position %d", i);
            break;
        }
        llama_token token = llama_sampler_sample(smpl, ma->ctx, -1);

        if (llama_vocab_is_eog(vocab, token)) {
            LOGD("generate: EOG at position %d", i);
            break;
        }

        int n_piece = llama_token_to_piece(
                vocab, token,
                piece_buf, (int32_t) sizeof(piece_buf) - 1,
                /*lstrip=*/0, /*special=*/true);

        if (n_piece <= 0) {
            llama_batch next = llama_batch_get_one(&token, 1);
            llama_decode(ma->ctx, next);
            continue;
        }
        piece_buf[n_piece] = '\0';

        accumulated += piece_buf;
        utf8_buf    += piece_buf;

        if (cb && is_complete_utf8(utf8_buf.c_str(), utf8_buf.size())) {
            cb(utf8_buf.c_str(), cb_user_data);
            utf8_buf.clear();
        }

        llama_batch next = llama_batch_get_one(&token, 1);
        if (llama_decode(ma->ctx, next) != 0) {
            LOGE("generate: decode failed at position %d", i);
            break;
        }
    }

    /* Flush any residual buffered bytes */
    if (cb && !utf8_buf.empty()) {
        cb(utf8_buf.c_str(), cb_user_data);
    }

    llama_sampler_free(smpl);

    LOGD("generate: done, %zu chars", accumulated.size());
    return heap_cstr(accumulated);
}

/* ---------------------------------------------------------------------- */

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
        int         enable_thinking,
        ma_token_cb cb,
        void       *cb_user_data) {

    MaContext *ma = handle_to_ctx(handle);
    if (!ma || !ma->model || !ma->ctx) {
        LOGE("generate_chat: invalid handle");
        return heap_cstr("{\"error\":\"invalid handle\"}");
    }
    ma->stop_requested.store(false, std::memory_order_relaxed);
    if (!ma->tmpls) {
        LOGE("generate_chat: no chat templates available");
        return heap_cstr("{\"error\":\"no chat templates\"}");
    }
    if (!messages_json) {
        LOGE("generate_chat: null messages_json");
        return heap_cstr("{\"error\":\"null messages\"}");
    }

    const llama_vocab *vocab = llama_model_get_vocab(ma->model);

    /* --- Parse inputs --- */
    common_chat_templates_inputs inputs;
    inputs.add_generation_prompt = true;
    inputs.use_jinja             = true;
    inputs.enable_thinking       = enable_thinking != 0;

    try {
        auto messages_parsed = nlohmann::ordered_json::parse(messages_json);
        inputs.messages = common_chat_msgs_parse_oaicompat(messages_parsed);

        if (tools_json && *tools_json) {
            auto tools_parsed = nlohmann::ordered_json::parse(tools_json);
            inputs.tools = common_chat_tools_parse_oaicompat(tools_parsed);
        }
    } catch (const std::exception &e) {
        LOGE("generate_chat: JSON parse failed: %s", e.what());
        return heap_cstr("{\"error\":\"json parse failed\"}");
    }

    /* --- Apply template --- */
    common_chat_params params;
    try {
        params = common_chat_templates_apply(ma->tmpls.get(), inputs);
    } catch (const std::exception &e) {
        LOGE("generate_chat: templates_apply failed: %s", e.what());
        return heap_cstr("{\"error\":\"template apply failed\"}");
    }

    LOGI("generate_chat: format=%s, prompt=%zu bytes, grammar=%zu bytes, triggers=%zu",
         common_chat_format_name(params.format),
         params.prompt.size(),
         params.grammar.size(),
         params.grammar_triggers.size());

    /* Dump first chunk of the generated PEG parser to verify markers match model output. */
    try {
        common_peg_arena arena;
        arena.load(params.parser);
        std::string dump = arena.dump(arena.root());
        LOGI("generate_chat: parser head: <<%.*s>>",
             (int) std::min<size_t>(dump.size(), 600), dump.data());
    } catch (const std::exception & e) {
        LOGE("generate_chat: parser dump failed: %s", e.what());
    }

    /* --- Tokenize rendered prompt --- */
    const int n_ctx        = (int) llama_n_ctx(ma->ctx);
    const int n_prompt_max = n_ctx - max_tokens - 10;

    std::vector<llama_token> prompt_tokens(n_ctx);
    int n_prompt = llama_tokenize(
            vocab,
            params.prompt.c_str(), (int32_t) params.prompt.size(),
            prompt_tokens.data(), (int32_t) prompt_tokens.size(),
            /*add_special=*/false, /*parse_special=*/true);

    if (n_prompt < 0) {
        LOGE("generate_chat: tokenization failed (n=%d)", n_prompt);
        return heap_cstr("{\"error\":\"tokenize failed\"}");
    }
    if (n_prompt > n_prompt_max && n_prompt_max > 0) {
        LOGI("generate_chat: truncating prompt %d → %d tokens", n_prompt, n_prompt_max);
        n_prompt = n_prompt_max;
    }
    prompt_tokens.resize(n_prompt);

    LOGD("generate_chat: %d prompt tokens, maxTokens=%d", n_prompt, max_tokens);

    /* Every call is a fresh, self-contained prompt (the Kotlin side renders
     * the whole conversation each turn). Without this the KV cache was never
     * cleared and llama_batch_get_one APPENDED each turn after the last: the
     * context filled across turns until n_ctx, then every decode failed and
     * every answer came back empty until the process restarted — the eval
     * harness's "native context may have been lost" cascade (2026-08-22).
     * Prefix reuse across turns is a deliberate later step (see the Mac's
     * ConversationTailCache); correctness first. */
    llama_memory_clear(llama_get_memory(ma->ctx), /*data=*/true);


    /* --- Decode prompt tokens in n_batch-sized chunks ---
     * See ma_core_generate for the rationale — upstream asserts
     * n_tokens_all <= cparams.n_batch per llama_decode call. */
    const int n_batch = (int) llama_n_batch(ma->ctx);
    for (int offset = 0; offset < n_prompt; offset += n_batch) {
        const int chunk = std::min(n_batch, n_prompt - offset);
        llama_batch batch = llama_batch_get_one(prompt_tokens.data() + offset, chunk);
        if (llama_decode(ma->ctx, batch) != 0) {
            LOGE("generate_chat: prompt decode failed at offset=%d chunk=%d", offset, chunk);
            return heap_cstr("{\"error\":\"decode failed\"}");
        }
    }

    /* --- Sampler chain --- */
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    llama_sampler *smpl = llama_sampler_chain_init(sparams);
    install_chat_grammar_sampler(smpl, vocab, params); /* non-fatal on failure */

    llama_sampler_chain_add(smpl, llama_sampler_init_top_k(top_k));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(top_p, /*min_keep=*/1));
    if (min_p > 0.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_min_p(min_p, /*min_keep=*/1));
    }
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(smpl, llama_sampler_init_penalties(
            /*n_vocab=*/llama_vocab_n_tokens(vocab),
            /*penalty_last_n=*/64,
            /*penalty_repeat=*/repeat_penalty,
            /*penalty_freq=*/0.0f,
            /*penalty_present=*/0.0f));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    /* --- Generation loop (mirrors ma_core_generate) --- */
    std::string accumulated;
    std::string utf8_buf;
    char piece_buf[256];
    const int n_max = std::min(max_tokens, n_ctx - n_prompt - 4);

    for (int i = 0; i < n_max; ++i) {
        if (ma->stop_requested.load(std::memory_order_relaxed)) {
            LOGD("generate_chat: stop requested at position %d", i);
            break;
        }
        llama_token token = llama_sampler_sample(smpl, ma->ctx, -1);

        if (llama_vocab_is_eog(vocab, token)) {
            LOGD("generate_chat: EOG at position %d", i);
            break;
        }

        int n_piece = llama_token_to_piece(
                vocab, token,
                piece_buf, (int32_t) sizeof(piece_buf) - 1,
                /*lstrip=*/0, /*special=*/true);

        if (n_piece <= 0) {
            llama_batch next = llama_batch_get_one(&token, 1);
            llama_decode(ma->ctx, next);
            continue;
        }
        piece_buf[n_piece] = '\0';

        accumulated += piece_buf;
        utf8_buf    += piece_buf;

        if (cb && is_complete_utf8(utf8_buf.c_str(), utf8_buf.size())) {
            cb(utf8_buf.c_str(), cb_user_data);
            utf8_buf.clear();
        }

        llama_batch next = llama_batch_get_one(&token, 1);
        if (llama_decode(ma->ctx, next) != 0) {
            LOGE("generate_chat: decode failed at position %d", i);
            break;
        }
    }

    if (cb && !utf8_buf.empty()) {
        cb(utf8_buf.c_str(), cb_user_data);
    }

    llama_sampler_free(smpl);

    /* --- Parse output via common_chat_parse --- */
    nlohmann::ordered_json result;
    result["raw"] = accumulated;

    /* Diagnostic: head/tail of accumulated + prompt tail to debug parser misses. */
    {
        const size_t head_n   = std::min<size_t>(accumulated.size(), 200);
        const size_t tail_n   = accumulated.size() > 300 ? 300 : accumulated.size();
        const size_t tail_off = accumulated.size() > tail_n ? accumulated.size() - tail_n : 0;
        LOGI("generate_chat: format=%s", common_chat_format_name(params.format));
        LOGI("generate_chat: accumulated head: <<%.*s>>",
             (int) head_n, accumulated.data());
        LOGI("generate_chat: accumulated tail: <<%.*s>>",
             (int) (accumulated.size() - tail_off),
             accumulated.data() + tail_off);
        const size_t ptail_n   = std::min<size_t>(params.prompt.size(), 200);
        const size_t ptail_off = params.prompt.size() - ptail_n;
        LOGI("generate_chat: prompt tail: <<%.*s>>",
             (int) ptail_n, params.prompt.data() + ptail_off);
    }

    try {
        common_chat_parser_params pparams(params);
        pparams.parse_tool_calls = true;
        /* F1 (docs/MODEL_CONTRACTS.md): the converting ctor above copies only
         * `format` + `generation_prompt` — NOT the PEG parser the template
         * produced. With an empty arena common_chat_parse silently falls back
         * to a content-only parser: tool_calls always empty, reasoning never
         * split out, content returned with the generation prompt prepended
         * (the April "exactly 30c of <|im_start|>assistant\n<think>" mystery).
         * We were building this arena above only to dump it to logcat. */
        pparams.parser.load(params.parser);
        /* F2: reasoning_format defaults NONE, so <think> blocks were never
         * extracted natively; AUTO matches llama-server's behaviour. */
        pparams.reasoning_format = COMMON_REASONING_FORMAT_AUTO;
        common_chat_msg msg = common_chat_parse(accumulated, /*is_partial=*/false, pparams);

        LOGI("generate_chat: parsed content (%zu c): <<%.*s>>",
             msg.content.size(),
             (int) std::min<size_t>(msg.content.size(), 300),
             msg.content.data());
        LOGI("generate_chat: parsed reasoning (%zu c), tool_calls=%zu",
             msg.reasoning_content.size(), msg.tool_calls.size());
        for (size_t i = 0; i < msg.tool_calls.size(); ++i) {
            const auto & tc = msg.tool_calls[i];
            LOGI("generate_chat: tc[%zu] name=%s args=<<%.*s>>",
                 i, tc.name.c_str(),
                 (int) std::min<size_t>(tc.arguments.size(), 200),
                 tc.arguments.data());
        }

        result["content"]           = msg.content;
        result["reasoning_content"] = msg.reasoning_content;

        auto tool_calls = nlohmann::ordered_json::array();
        for (const auto &tc : msg.tool_calls) {
            tool_calls.push_back({
                {"name",      tc.name},
                {"arguments", tc.arguments},
                {"id",        tc.id},
            });
        }
        result["tool_calls"] = tool_calls;
    } catch (const std::exception &e) {
        LOGE("generate_chat: parse failed: %s", e.what());
        result["content"]    = accumulated;
        result["tool_calls"] = nlohmann::ordered_json::array();
    }

    LOGD("generate_chat: done, %zu chars, %zu tool_calls",
         accumulated.size(),
         result.contains("tool_calls") ? result["tool_calls"].size() : 0);

    return heap_cstr(result.dump());
}

/* ---------------------------------------------------------------------- */

char *ma_core_last_loaded_cpu_variant(void) {
    return heap_cstr(g_last_loaded_cpu_variant);
}

/* ---------------------------------------------------------------------- */

void ma_core_free_string(char *s) {
    if (s) std::free(s);
}

void ma_core_request_stop(ma_handle handle) {
    MaContext *ma = handle_to_ctx(handle);
    if (ma) ma->stop_requested.store(true, std::memory_order_relaxed);
}

/* ---------------------------------------------------------------------- */

ma_handle ma_core_init_embedding(
        const char *model_path,
        int         n_ctx,
        const char *backend_lib_dir,
        const char *preferred_cpu_variant) {

    /* Same once-per-process backend registration as ma_core_init — harmless if
     * a generation model already loaded it (idempotent). */
    load_cpu_backends_once(backend_lib_dir, preferred_cpu_variant);

    LOGI("embed-init: loading %s", model_path ? model_path : "(null)");
    if (!model_path) {
        LOGE("embed-init: null model_path");
        return 0;
    }

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0; /* CPU-only on mobile, same as generation */
    mparams.load_mode    = LLAMA_LOAD_MODE_MMAP;

    llama_model *model = llama_model_load_from_file(model_path, mparams);
    if (!model) {
        LOGE("embed-init: failed to load model");
        return 0;
    }

    const int hw_threads = (int) std::thread::hardware_concurrency();
    const uint32_t ctxLen = (uint32_t)(n_ctx > 0 ? n_ctx : 2048);

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx           = ctxLen;
    /* An embedding pass decodes the whole sequence in one batch (no
     * autoregression), so the logical batch must be able to hold it. */
    cparams.n_batch         = ctxLen;
    cparams.n_ubatch        = ctxLen;
    cparams.n_threads       = std::min(4, hw_threads);
    cparams.n_threads_batch = std::min(hw_threads, 6);
    cparams.embeddings      = true;
    cparams.pooling_type    = LLAMA_POOLING_TYPE_MEAN; /* EmbeddingGemma pools by mean */
    cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;

    llama_context *ctx = llama_init_from_model(model, cparams);
    if (!ctx) {
        LOGE("embed-init: failed to create context");
        llama_model_free(model);
        return 0;
    }

    auto *ma = new MaContext();
    ma->model = model;
    ma->ctx   = ctx;
    /* No chat templates — an embedding context never generates. */

    LOGI("embed-init: success (handle=%p, n_ctx=%u, n_embd=%d, pooling=mean)",
         ma, ctxLen, llama_model_n_embd(model));
    return ctx_to_handle(ma);
}

int ma_core_embed(
        ma_handle   handle,
        const char *text,
        float      *out,
        int         out_capacity) {

    MaContext *ma = handle_to_ctx(handle);
    if (!ma || !ma->ctx || !ma->model) {
        LOGE("embed: invalid handle");
        return -1;
    }
    if (!text || !out) {
        LOGE("embed: null text/out");
        return -1;
    }

    const int n_embd = llama_model_n_embd(ma->model);
    if (n_embd <= 0) {
        LOGE("embed: model reports n_embd=%d", n_embd);
        return -1;
    }
    if (n_embd > out_capacity) {
        LOGE("embed: n_embd %d exceeds out_capacity %d", n_embd, out_capacity);
        return -1;
    }

    const llama_vocab *vocab = llama_model_get_vocab(ma->model);
    const int n_ctx = (int) llama_n_ctx(ma->ctx);

    /* Tokenize with the model's own tokenizer (Gemma SentencePiece), adding the
     * special BOS the embedding model expects. A negative return is
     * "buffer too small": clamp to the context and truncate the tail. */
    std::vector<llama_token> tokens(n_ctx);
    int n_tok = llama_tokenize(
            vocab, text, (int32_t) std::strlen(text),
            tokens.data(), (int32_t) tokens.size(),
            /*add_special=*/true, /*parse_special=*/true);
    if (n_tok < 0) {
        LOGI("embed: input longer than n_ctx (%d), truncating", n_ctx);
        n_tok = n_ctx;
    }
    if (n_tok == 0) {
        LOGE("embed: empty tokenization");
        return -1;
    }
    tokens.resize(n_tok);

    /* Fresh sequence: an embedding context keeps no cross-call state. */
    llama_memory_clear(llama_get_memory(ma->ctx), true);

    /* Build a batch with output enabled on EVERY token — mean pooling
     * aggregates over all of them, unlike generation which only needs the
     * last. (llama_batch_get_one leaves per-token logits unset.) */
    llama_batch batch = llama_batch_init(n_tok, 0, 1);
    for (int i = 0; i < n_tok; i++) {
        batch.token[i]      = tokens[i];
        batch.pos[i]        = i;
        batch.n_seq_id[i]   = 1;
        batch.seq_id[i][0]  = 0;
        batch.logits[i]     = 1;
    }
    batch.n_tokens = n_tok;

    const bool has_encoder = llama_model_has_encoder(ma->model);
    const int rc = has_encoder ? llama_encode(ma->ctx, batch)
                               : llama_decode(ma->ctx, batch);
    llama_batch_free(batch);
    if (rc != 0) {
        LOGE("embed: %s failed rc=%d", has_encoder ? "encode" : "decode", rc);
        return -1;
    }

    /* Pooled sequence embedding; fall back to the last token if a model ever
     * reports NONE pooling despite our request. */
    float *emb = llama_get_embeddings_seq(ma->ctx, 0);
    if (!emb) emb = llama_get_embeddings_ith(ma->ctx, -1);
    if (!emb) {
        LOGE("embed: no embeddings returned");
        return -1;
    }

    /* L2-normalize into the caller's buffer (cosine-ready). */
    double norm = 0.0;
    for (int i = 0; i < n_embd; i++) norm += (double) emb[i] * (double) emb[i];
    norm = std::sqrt(norm);
    const float inv = (norm > 0.0) ? (float)(1.0 / norm) : 0.0f;
    for (int i = 0; i < n_embd; i++) out[i] = emb[i] * inv;

    return n_embd;
}

/* ---------------------------------------------------------------------- */

void ma_core_release(ma_handle handle) {
    MaContext *ma = handle_to_ctx(handle);
    if (!ma) return;

    LOGI("release: freeing context (handle=%p)", ma);
    if (ma->ctx)   llama_free(ma->ctx);
    if (ma->model) llama_model_free(ma->model);
    delete ma;
}

} /* extern "C" */
