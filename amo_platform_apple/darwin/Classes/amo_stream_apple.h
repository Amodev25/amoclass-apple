/**
 * amo_stream_apple.h — Apple replacement for the Android JNI bridge.
 *
 * On Android the mpv protocol is registered through JNI
 * (amo_stream_jni.c). Apple needs no JNI: Objective-C and Swift can call C
 * directly, so this header exposes the same three operations as plain C.
 */

#ifndef AMO_STREAM_APPLE_H
#define AMO_STREAM_APPLE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Register the "amo://" protocol with the mpv instance behind `mpv_handle`.
 *
 * `mpv_handle` is the raw mpv_handle pointer media_kit exposes as an int.
 * mpv_stream_cb_add_ro is resolved at runtime (media_kit links libmpv as a
 * framework, so the symbol is already in the process image).
 *
 * Returns 0 on success, negative on failure.
 */
int amo_register_protocol(int64_t mpv_handle);

/** Set credentials for v2 key derivation. Call before playback. */
void amo_apple_set_credentials(const char *credential, const char *course_secret);

/** Clear credentials from native memory. Call on logout / course switch. */
void amo_apple_clear_credentials(void);

#ifdef __cplusplus
}
#endif

#endif /* AMO_STREAM_APPLE_H */
