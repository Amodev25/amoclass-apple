/**
 * amo_stream.h — mpv custom stream protocol for .amo file decryption.
 */

#ifndef AMO_STREAM_H
#define AMO_STREAM_H

#include <stdio.h>
#include <stdint.h>
#include "aes256.h"

/* ── mpv error codes (from mpv/client.h) ─────────────────────────────────── */
#ifndef MPV_ERROR_GENERIC
#define MPV_ERROR_GENERIC        (-1)
#endif
#ifndef MPV_ERROR_LOADING_FAILED
#define MPV_ERROR_LOADING_FAILED (-12)
#endif

/* ── mpv stream callback types (from mpv/stream_cb.h) ────────────────────── */

typedef int64_t (*mpv_stream_cb_read_fn)(void *cookie, char *buf, uint64_t nbytes);
typedef int64_t (*mpv_stream_cb_seek_fn)(void *cookie, int64_t offset);
typedef int64_t (*mpv_stream_cb_size_fn)(void *cookie);
typedef void    (*mpv_stream_cb_close_fn)(void *cookie);
typedef void    (*mpv_stream_cb_cancel_fn)(void *cookie);

typedef struct mpv_stream_cb_info {
    void *cookie;
    mpv_stream_cb_read_fn   read_fn;
    mpv_stream_cb_seek_fn   seek_fn;
    mpv_stream_cb_size_fn   size_fn;
    mpv_stream_cb_close_fn  close_fn;
    mpv_stream_cb_cancel_fn cancel_fn;   /* since API 1.106, can be NULL */
} mpv_stream_cb_info;

typedef int (*mpv_stream_cb_open_fn)(void *user_data, char *uri,
                                     mpv_stream_cb_info *info);

/* mpv_stream_cb_add_ro — declared as function pointer type, loaded at runtime */
typedef int (*mpv_stream_cb_add_ro_fn)(uint64_t ctx, const char *protocol,
                                       void *user_data,
                                       mpv_stream_cb_open_fn open_fn);

/* ── Stream context (per-file state) ─────────────────────────────────────── */

typedef struct {
    uint8_t *mmap_base;            /* mmap'd file base pointer */
    size_t   mmap_size;            /* total mmap'd size */
    int      fd;                   /* file descriptor (kept for munmap) */
    uint8_t  key[32];              /* AES-256 data key (zeroed on close) */
    uint8_t  iv[16];               /* original IV from header */
    int64_t  video_data_offset;    /* byte offset where video data starts */
    int64_t  crypto_base_offset;   /* metadataLength + thumbnailLength */
    int64_t  video_data_length;    /* total video data size */
    int64_t  position;             /* current read position within video data */
    Aes256CtrContext ctr_ctx;      /* AES-256-CTR cipher context */
    int64_t  cipher_position;      /* crypto offset the cipher is synced to */
} AmoStreamContext;

/* ── Public API ──────────────────────────────────────────────────────────── */

/**
 * mpv open callback — called when mpv opens "amo:///path/to/file.amo".
 */
int amo_open(void *user_data, char *uri, mpv_stream_cb_info *info);

/**
 * Set the course content key: exactly 64 hex digits (the 32-byte key the
 * server computed). Call before playback.
 *
 * Returns 1 when the key was stored, 0 when `hex` is malformed — in which case
 * any previously set key is cleared too.
 */
int amo_set_content_key(const char *hex);

/**
 * Clear the content key from native memory. Call on logout/course switch.
 */
void amo_clear_content_key(void);

#endif /* AMO_STREAM_H */
