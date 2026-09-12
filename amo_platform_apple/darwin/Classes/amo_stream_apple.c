/**
 * amo_stream_apple.c — Apple replacement for amo_stream_jni.c.
 *
 * Mirrors the Android bridge exactly, minus JNI. The only real difference is
 * how libmpv is located: on Android it is a plain libmpv.so loaded by
 * media_kit, while media_kit on Apple links libmpv as a framework, so the
 * symbol is normally already in the process image and RTLD_DEFAULT finds it.
 * The framework paths below are a fallback for builds that link it elsewhere.
 */

#include <stdio.h>
#include <stdint.h>
#include <dlfcn.h>

#include "amo_stream.h"
#include "amo_stream_apple.h"

#define TAG "AmoStreamApple"
#define LOGI(...) do { fprintf(stderr, "I/" TAG ": "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while(0)
#define LOGE(...) do { fprintf(stderr, "E/" TAG ": "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while(0)

/* Cached function pointer to mpv_stream_cb_add_ro */
static mpv_stream_cb_add_ro_fn fn_stream_cb_add_ro = NULL;

/* Fallbacks, tried in order, if the symbol is not already in the image. */
static const char *kMpvCandidates[] = {
    "Mpv.framework/Mpv",
    "mpv.framework/mpv",
    "libmpv.dylib",
    "libmpv.2.dylib",
};

/**
 * Resolve mpv_stream_cb_add_ro. Returns 1 on success, 0 on failure.
 */
static int ensure_mpv_symbols(void) {
    if (fn_stream_cb_add_ro) return 1;

    /* media_kit links libmpv into the app, so the symbol is usually already
       available process-wide — no dlopen needed. */
    fn_stream_cb_add_ro =
        (mpv_stream_cb_add_ro_fn)dlsym(RTLD_DEFAULT, "mpv_stream_cb_add_ro");
    if (fn_stream_cb_add_ro) {
        LOGI("mpv_stream_cb_add_ro resolved from the process image");
        return 1;
    }

    for (size_t i = 0; i < sizeof(kMpvCandidates) / sizeof(kMpvCandidates[0]); i++) {
        void *h = dlopen(kMpvCandidates[i], RTLD_NOLOAD | RTLD_NOW);
        if (!h) h = dlopen(kMpvCandidates[i], RTLD_NOW);
        if (!h) continue;

        fn_stream_cb_add_ro =
            (mpv_stream_cb_add_ro_fn)dlsym(h, "mpv_stream_cb_add_ro");
        if (fn_stream_cb_add_ro) {
            LOGI("mpv_stream_cb_add_ro resolved from %s", kMpvCandidates[i]);
            return 1;
        }
    }

    LOGE("could not resolve mpv_stream_cb_add_ro: %s", dlerror());
    return 0;
}

int amo_register_protocol(int64_t mpv_handle) {
    if (!ensure_mpv_symbols()) {
        LOGE("amo_register_protocol: failed to resolve mpv symbols");
        return -1;
    }

    if (mpv_handle == 0) {
        LOGE("amo_register_protocol: mpv_handle is null");
        return -1;
    }

    LOGI("amo_register_protocol: registering amo:// with mpv handle %lld",
         (long long)mpv_handle);

    int ret = fn_stream_cb_add_ro((uint64_t)mpv_handle, "amo", NULL, amo_open);
    if (ret != 0) {
        LOGE("mpv_stream_cb_add_ro failed: %d", ret);
        return -1;
    }

    LOGI("amo_register_protocol: amo:// protocol registered successfully");
    return 0;
}

void amo_apple_set_credentials(const char *credential, const char *course_secret) {
    if (!credential || !course_secret) return;
    amo_set_credentials(credential, course_secret);
}

void amo_apple_clear_credentials(void) {
    amo_clear_credentials();
}
