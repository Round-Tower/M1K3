cmake_minimum_required(VERSION 3.22.1)
project(ma VERSION 1.0 LANGUAGES C CXX)

# ============================================================================
# llama.cpp - CPU inference for GGUF models
# ============================================================================
# Setup (one-time):
#   cd app/composeApp/src/androidMain/cpp
#   git submodule add https://github.com/ggerganov/llama.cpp.git llama.cpp
#   cd llama.cpp && git checkout <b8637+ commit hash>
#
# Pinned at b8637+ for Gemma 4 support (Llamatik was stuck at b7815, Jan 2025)
# ============================================================================

set(LLAMA_DIR   ${CMAKE_SOURCE_DIR}/llama.cpp)
set(MA_CORE_DIR ${CMAKE_SOURCE_DIR}/../../nativeShared/ma)

# Android-optimised llama.cpp build (CPU only, no GPU, no tools)
set(LLAMA_BUILD_TESTS     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES  OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS     OFF CACHE BOOL "" FORCE)
# Build common/ so we can use native chat templates (common_chat_templates_apply)
# and the per-model tool-call parser (common_chat_parse). This lets any GGUF with
# a chat template — Qwen3/3.5, Llama 3.x, Mistral, Phi, DeepSeek — render its
# tools and parse its tool-call output in the format the model was trained on.
# cpp-httplib comes along for the ride but we never invoke it.
set(LLAMA_BUILD_COMMON    ON  CACHE BOOL "" FORCE)
set(LLAMA_CURL            OFF CACHE BOOL "" FORCE)
set(GGML_METAL            OFF CACHE BOOL "" FORCE)
set(GGML_CUDA             OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN           OFF CACHE BOOL "" FORCE)
set(LLAMA_ANDROID         ON  CACHE BOOL "" FORCE)

# ARM64 optimizations: enable dotprod + i8mm for Cortex-A720/X4 (Tensor G4+)
# armv8.2-a+dotprod+i8mm enables SDOT/UDOT and MMLA instructions for
# 4-8x faster int8/int4 matmul vs baseline NEON.
set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+i8mm" CACHE STRING "" FORCE)

add_subdirectory(${LLAMA_DIR} llama_build)

# ============================================================================
# ma_core - portable llama.cpp wrapper (no JNI, no Swift)
# ============================================================================
# Lives in composeApp/src/nativeShared/ma/ so a future Kotlin/Native cinterop
# consumer can bind to the same implementation via ma_core.h. Built as a
# STATIC library on Android; linked into libma.so below. This app's own
# iOS target is unbuilt (the real Apple mobile/spatial surface is the
# SwiftUI shell under ../../macos/M1K3iOSApp/ — see ../../macos/docs/
# IOS_VISIONOS_PORT.md and Kev's 2026-07-06 ruling in that doc).

add_library(ma_core STATIC
    ${MA_CORE_DIR}/ma_core.cpp
)

target_include_directories(ma_core PUBLIC
    ${MA_CORE_DIR}
    ${LLAMA_DIR}
    ${LLAMA_DIR}/include
    ${LLAMA_DIR}/ggml/include
    ${LLAMA_DIR}/common
    ${LLAMA_DIR}/common/vendor
)

target_link_libraries(ma_core PUBLIC
    common
    llama
)

target_compile_features(ma_core PRIVATE cxx_std_17)

# Match libma's Release-only flags on the static lib too. Same skip list
# (no -ffast-math, no -flto) for the same reasons documented below.
target_compile_options(ma_core PRIVATE
    $<$<CONFIG:Release>:-O3 -fno-math-errno -fvisibility=hidden>
)

# ============================================================================
# Ma JNI bridge — the only file that knows about JNIEnv
# ============================================================================

add_library(ma SHARED ma_bridge.cpp)

target_include_directories(ma PRIVATE
    ${MA_CORE_DIR}
)

target_link_libraries(ma
    ma_core
    android
    log
)

target_compile_features(ma PRIVATE cxx_std_17)

# Release-only compiler flags (bridge only — llama.cpp submodule has its own):
#   -O3                : aggressive optimization. AGP defaults to -O2 for Release.
#   -fno-math-errno    : don't set errno from libm — inference never reads it.
#   -fvisibility=hidden: non-exported symbols get internal linkage, shrinks .so
#                        and lets the linker inline more aggressively.
# Skipped on purpose:
#   -ffast-math : breaks grammar/penalty NaN handling in the sampler chain.
#   -flto       : build-time cost vs unclear runtime win at this size.
target_compile_options(ma PRIVATE
    $<$<CONFIG:Release>:-O3 -fno-math-errno -fvisibility=hidden>
)

# Android 15+ requires 16KB page-aligned libraries.
# Without this the system shows PageSizeMismatchDialog on first launch.
target_link_options(ma PRIVATE "-Wl,-z,max-page-size=16384")

# Reduce .so size: strip debug symbols in release builds
if (CMAKE_BUILD_TYPE STREQUAL "Release")
    set_target_properties(ma PROPERTIES LINK_FLAGS "-Wl,--strip-all")
endif ()
