/**
 * amo_stream.c — mpv custom stream protocol for in-process AES-256-CTR decryption.
 *
 * Registers "amo://" protocol with mpv. When mpv opens amo:///path/to/file.amo,
 * this code reads the .amo header, derives the key, and decrypts video data
 * on-the-fly via read/seek/size/close callbacks.
 *
 * Uses mmap for zero-syscall reads — the kernel page cache handles I/O.
 * Decrypted bytes never leave the process — no network, no disk, no temp files.
 * Uses self-contained AES-256 and SHA-256 — no OpenSSL dependency.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <windows.h>
#include <io.h>
#define PROT_READ     0x1
#define MAP_PRIVATE   0x2
#define MAP_FAILED    ((void *)-1)
#define MADV_RANDOM   1
#define MADV_WILLNEED 3
static void madvise(void *addr, size_t length, int advice) {}
static void munlock(const void *addr, size_t len) {}
static void mlock(const void *addr, size_t len) {}

static void *mmap(void *addr, size_t length, int prot, int flags, int fd, int64_t offset) {
    HANDLE hFile = (HANDLE)_get_osfhandle(fd);
    if (hFile == INVALID_HANDLE_VALUE) return MAP_FAILED;
    HANDLE hMapping = CreateFileMappingA(hFile, NULL, PAGE_READONLY, 0, 0, NULL);
    if (!hMapping) return MAP_FAILED;
    void *map = MapViewOfFile(hMapping, FILE_MAP_READ, (DWORD)(offset >> 32), (DWORD)(offset & 0xFFFFFFFF), length);
    CloseHandle(hMapping);
    if (!map) return MAP_FAILED;
    return map;
}

static int munmap(void *addr, size_t length) {
    UnmapViewOfFile(addr);
    return 0;
}

#define TAG "AmoStream"
#define LOGI(...) do { printf("I/" TAG ": "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while(0)
#define LOGW(...) do { printf("W/" TAG ": "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while(0)
#define LOGE(...) do { printf("E/" TAG ": "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while(0)

static int win32_utf8_open(const char *utf8_path, int oflag) {
    int wchars_num = MultiByteToWideChar(CP_UTF8, 0, utf8_path, -1, NULL, 0);
    if (wchars_num <= 0) return -1;
    wchar_t *wpath = (wchar_t *)malloc(wchars_num * sizeof(wchar_t));
    if (!wpath) return -1;
    MultiByteToWideChar(CP_UTF8, 0, utf8_path, -1, wpath, wchars_num);
    int fd = _wopen(wpath, oflag);
    free(wpath);
    return fd;
}

#ifndef O_BINARY
#define O_BINARY _O_BINARY
#endif
#define open win32_utf8_open
#define close _close
#define fstat _fstat64
#define stat _stat64

#elif defined(__APPLE__)
#include <unistd.h>
#include <sys/mman.h>
#ifndef O_BINARY
#define O_BINARY 0
#endif

/* Apple is POSIX: mmap, madvise, mlock and munlock all exist natively, so
   nothing needs shimming here. The only Android-specific dependency in this
   file is <android/log.h>, so mirror the _WIN32 branch and log to stderr
   (visible in the Xcode console and Console.app). */
#define TAG "AmoStream"
#define LOGI(...) do { fprintf(stderr, "I/" TAG ": "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while(0)
#define LOGW(...) do { fprintf(stderr, "W/" TAG ": "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while(0)
#define LOGE(...) do { fprintf(stderr, "E/" TAG ": "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while(0)
#else
#include <unistd.h>
#include <sys/mman.h>
#include <android/log.h>
#ifndef O_BINARY
#define O_BINARY 0
#endif

#define TAG "AmoStream"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#endif

#include "amo_stream.h"
#include "aes256.h"
#include "sha256.h"

/* ── .amo file magic ─────────────────────────────────────────────────────── */
static const uint8_t AMO_MAGIC[8] = {0x41,0x4D,0x4F,0x45,0x4E,0x43,0x30,0x31};
#define AMO_HEADER_SIZE 128
#define AMO_KEY_SIZE    32
#define AMO_IV_SIZE     16
#define AMO_HMAC_SIZE   32
#define AMO_CHUNK_SIZE  (1024 * 1024)   /* HMAC covers thumbnail + first 1 MB of video (matches Dart verifyHmac) */

/* Defense-in-depth: verify the file HMAC inside the native decryptor before
   producing any plaintext. Mirrors DecryptionService.verifyHmac, and is now
   unconditional — the keyVersion/all-zero exemptions went away with v1 support.
   Set to 0 only to triage a device-specific decryption issue. */
#ifndef AMO_ENFORCE_NATIVE_HMAC
#define AMO_ENFORCE_NATIVE_HMAC 1
#endif

/* ── Master key parts (must match amo_core/lib/core/constants.dart) ────── */
static const uint8_t KEY_PART1[16] = {
    0x7A,0x3F,0x8B,0xC2,0x15,0xD4,0xE6,0x91,
    0x4D,0xA8,0x2C,0x67,0xF3,0x0E,0x5B,0x89
};
static const uint8_t KEY_PART2[16] = {
    0xB1,0x6D,0x23,0xF5,0x78,0x9A,0x4C,0xDE,
    0x03,0x56,0xE7,0x1B,0x8F,0xC4,0x32,0xA0
};
static const uint8_t XOR_MASK1[16] = {
    0x2E,0x71,0xD9,0x84,0x43,0x96,0xA0,0xF7,
    0x1B,0xEE,0x7A,0x21,0xA5,0x48,0x0D,0xCF
};
static const uint8_t XOR_MASK2[16] = {
    0xE3,0x2B,0x75,0xB3,0x0C,0xDC,0x1A,0x98,
    0x55,0x00,0xA1,0x4D,0xD9,0x82,0x64,0xF6
};

/* ── v2 pattern encryption ───────────────────────────────────────────────────
   Encrypt AMO_PATTERN_UNIT bytes, leave the rest of AMO_PATTERN_STRIDE in the
   clear, repeating across the whole video body — the 1:9 shape CENC's `cbcs`
   scheme uses.

   v1 encrypted the first 100 KB of every 10 MB block, which left a contiguous
   9.90 MB plaintext run per block — 98.83% of the video, carvable into a
   watchable file with no key at all, because the cleartext header gives away
   where the body starts. This build does not read v1: amo_open rejects it. */
#define AMO_FORMAT_VERSION 2
#define AMO_PATTERN_STRIDE 160
#define AMO_PATTERN_UNIT   16

/* Encrypted bytes contained in the first `length` bytes of the video body.

   THE seek formula. The CTR counter advances only over bytes that actually went
   through the cipher, so a byte at body position p is keyed to
   crypto_base_offset + pattern_encrypted_bytes(p) — never to p itself. */
static int64_t pattern_encrypted_bytes(int64_t length) {
    int64_t strides = length / AMO_PATTERN_STRIDE;
    int64_t rest    = length % AMO_PATTERN_STRIDE;
    return strides * AMO_PATTERN_UNIT +
           (rest < AMO_PATTERN_UNIT ? rest : AMO_PATTERN_UNIT);
}

/* ── Global credential storage (set from JNI before playback) ──────────── */
static char g_credential[512]    = {0};
static char g_course_secret[512] = {0};
static int  g_has_credentials    = 0;

/* ── Helpers ─────────────────────────────────────────────────────────────── */

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] <<  8) | ((uint32_t)p[3]);
}

static uint64_t read_be64(const uint8_t *p) {
    return ((uint64_t)p[0] << 56) | ((uint64_t)p[1] << 48) |
           ((uint64_t)p[2] << 40) | ((uint64_t)p[3] << 32) |
           ((uint64_t)p[4] << 24) | ((uint64_t)p[5] << 16) |
           ((uint64_t)p[6] <<  8) | ((uint64_t)p[7]);
}

static void derive_master_key(uint8_t out[AMO_KEY_SIZE]) {
    for (int i = 0; i < 16; i++) {
        out[i]      = KEY_PART1[i] ^ XOR_MASK1[i];
        out[i + 16] = KEY_PART2[i] ^ XOR_MASK2[i];
    }
}

static int derive_v2_key(uint8_t out[AMO_KEY_SIZE]) {
    if (!g_has_credentials) return 0;
    hmac_sha256((const uint8_t *)g_credential, strlen(g_credential),
                (const uint8_t *)g_course_secret, strlen(g_course_secret),
                out);
    return 1;
}

static void calculate_counter_iv(uint8_t counter_iv[AMO_IV_SIZE],
                                 const uint8_t base_iv[AMO_IV_SIZE],
                                 int64_t byte_offset) {
    memcpy(counter_iv, base_iv, AMO_IV_SIZE);
    int64_t block_index = byte_offset / 16;
    int64_t carry = block_index;
    for (int i = 15; i >= 0 && carry > 0; i--) {
        carry += counter_iv[i];
        counter_iv[i] = (uint8_t)(carry & 0xFF);
        carry >>= 8;
    }
}

/** Full cipher init (key expansion + counter). Called once at open. */
static void cipher_full_init(AmoStreamContext *ctx, int64_t crypto_offset) {
    uint8_t counter_iv[AMO_IV_SIZE];
    calculate_counter_iv(counter_iv, ctx->iv, crypto_offset);
    aes256_ctr_init(&ctx->ctr_ctx, ctx->key, counter_iv, (int)(crypto_offset % 16));
    ctx->cipher_position = crypto_offset;
}

/** Fast seek: counter reset only, no key re-expansion. */
static void cipher_seek_to(AmoStreamContext *ctx, int64_t crypto_offset) {
    uint8_t counter_iv[AMO_IV_SIZE];
    calculate_counter_iv(counter_iv, ctx->iv, crypto_offset);
    aes256_ctr_seek(&ctx->ctr_ctx, counter_iv, (int)(crypto_offset % 16));
    ctx->cipher_position = crypto_offset;
}

/* ── Simple JSON parser ──────────────────────────────────────────────────── */

static int json_get_int(const char *json, const char *key, int default_val) {
    char pattern[256];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *pos = strstr(json, pattern);
    if (!pos) return default_val;
    pos += strlen(pattern);
    while (*pos == ' ' || *pos == '\t' || *pos == '\n' || *pos == '\r' || *pos == ':') pos++;
    if (*pos < '0' || *pos > '9') return default_val;
    /* strtol with bounds — atoi has undefined behaviour on overflow and no
       way to signal a parse error. */
    char *endp = NULL;
    long val = strtol(pos, &endp, 10);
    if (endp == pos || val < 0 || val > INT_MAX) return default_val;
    return (int)val;
}

/* ── mpv stream protocol callbacks ───────────────────────────────────────── */

/**
 * Read callback — called by mpv to read decrypted video data.
 * Uses mmap: no fseeko/fread syscalls. Just memcpy from kernel page cache.
 */
static int64_t amo_read(void *cookie, char *buf, uint64_t nbytes) {
    AmoStreamContext *ctx = (AmoStreamContext *)cookie;
    if (!ctx || !ctx->mmap_base) return -1;

    /* Clamp to remaining data */
    int64_t remaining = ctx->video_data_length - ctx->position;
    if (remaining <= 0) return 0;
    if ((int64_t)nbytes > remaining) nbytes = (uint64_t)remaining;

    /* Direct memcpy from mmap'd file — zero syscalls */
    const uint8_t *src = ctx->mmap_base + ctx->video_data_offset + ctx->position;
    memcpy(buf, src, (size_t)nbytes);

    /* v2 pattern decryption.

       The encrypted units inside [start, end) are scattered through the buffer
       but CONTIGUOUS in cipher space — a unit ends exactly where the next one
       begins, because the counter skips the cleartext entirely. So gather them,
       run ONE cipher pass, scatter back. A separate cipher call per unit would
       be far slower (65,536 units per 10 MB) and, without hand-rolled counter
       bookkeeping between calls, simply wrong.

       Both loops must walk identical bounds; they are kept adjacent for that
       reason. `total` is exact, not an upper bound. */
    int64_t start = ctx->position;
    int64_t end   = start + (int64_t)nbytes;

    int64_t enc_before = pattern_encrypted_bytes(start);
    int64_t total      = pattern_encrypted_bytes(end) - enc_before;

    if (total > 0) {
        /* Typical mpv reads are 64 KB → ~6.5 KB gathered. The stack buffer
           covers reads up to ~160 KB; anything larger falls back to malloc. */
        uint8_t stackbuf[16384];
        uint8_t *gathered = (total <= (int64_t)sizeof(stackbuf))
                            ? stackbuf
                            : (uint8_t *)malloc((size_t)total);
        if (!gathered) {
            LOGE("amo_read: gather buffer allocation failed (%lld bytes)", (long long)total);
            return -1;
        }

        int64_t first_stride = (start / AMO_PATTERN_STRIDE) * AMO_PATTERN_STRIDE;
        int64_t n = 0;

        for (int64_t s = first_stride; s < end; s += AMO_PATTERN_STRIDE) {
            int64_t u0 = s, u1 = s + AMO_PATTERN_UNIT;
            if (u0 < start) u0 = start;
            if (u1 > end)   u1 = end;
            if (u1 <= u0) continue;
            memcpy(gathered + n, buf + (u0 - start), (size_t)(u1 - u0));
            n += u1 - u0;
        }

        int64_t crypto_offset = ctx->crypto_base_offset + enc_before;
        if (ctx->cipher_position != crypto_offset) {
            cipher_seek_to(ctx, crypto_offset);
        }
        aes256_ctr_xcrypt(&ctx->ctr_ctx, gathered, (size_t)n);
        ctx->cipher_position = crypto_offset + n;

        n = 0;
        for (int64_t s = first_stride; s < end; s += AMO_PATTERN_STRIDE) {
            int64_t u0 = s, u1 = s + AMO_PATTERN_UNIT;
            if (u0 < start) u0 = start;
            if (u1 > end)   u1 = end;
            if (u1 <= u0) continue;
            memcpy(buf + (u0 - start), gathered + n, (size_t)(u1 - u0));
            n += u1 - u0;
        }

        if (gathered != stackbuf) free(gathered);
    }

    ctx->position += (int64_t)nbytes;

    return (int64_t)nbytes;
}

/**
 * Seek callback — instant, just updates position + cipher counter.
 */
static int64_t amo_seek(void *cookie, int64_t offset) {
    AmoStreamContext *ctx = (AmoStreamContext *)cookie;
    if (!ctx) return MPV_ERROR_GENERIC;

    if (offset < 0) offset = 0;
    if (offset > ctx->video_data_length) offset = ctx->video_data_length;

    ctx->position = offset;

    /* Fast counter reset - set cipher_position to -1 to force resync on next read */
    ctx->cipher_position = -1;

    return offset;
}

static int64_t amo_size(void *cookie) {
    AmoStreamContext *ctx = (AmoStreamContext *)cookie;
    if (!ctx) return -1;
    return ctx->video_data_length;
}

static void amo_close(void *cookie) {
    AmoStreamContext *ctx = (AmoStreamContext *)cookie;
    if (!ctx) return;

    /* Unmap file */
    if (ctx->mmap_base && ctx->mmap_base != MAP_FAILED) {
        munmap(ctx->mmap_base, ctx->mmap_size);
    }
    if (ctx->fd >= 0) {
        close(ctx->fd);
    }

    /* Zero key material */
    munlock(ctx->key, AMO_KEY_SIZE);
    memset(ctx->key, 0, AMO_KEY_SIZE);
    memset(ctx->iv, 0, AMO_IV_SIZE);
    memset(&ctx->ctr_ctx, 0, sizeof(ctx->ctr_ctx));

    free(ctx);
    LOGI("amo_close: stream closed, keys zeroed");
}

/**
 * Open callback — called when mpv encounters "amo:///path/to/file.amo".
 * mmap's the entire file for zero-copy, zero-syscall reads during playback.
 */
int amo_open(void *user_data, char *uri, mpv_stream_cb_info *info) {
    (void)user_data;

    LOGI("amo_open: %s", uri);

    /* Parse file path from URI */
    const char *path = uri;
    if (strncmp(path, "amo://", 6) == 0) path += 6;

    /* Open file descriptor */
    int fd = open(path, O_RDONLY | O_BINARY);
    if (fd < 0) {
        LOGE("amo_open: cannot open: %s (%s)", path, strerror(errno));
        return MPV_ERROR_LOADING_FAILED;
    }

    /* Get file size */
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < AMO_HEADER_SIZE) {
        LOGE("amo_open: fstat failed or file too small");
        close(fd);
        return MPV_ERROR_LOADING_FAILED;
    }
    size_t file_size = (size_t)st.st_size;

    /* mmap the entire file — kernel page cache handles I/O */
    uint8_t *map = (uint8_t *)mmap(NULL, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) {
        LOGE("amo_open: mmap failed: %s", strerror(errno));
        close(fd);
        return MPV_ERROR_LOADING_FAILED;
    }

    /* Advise kernel: we'll access this randomly (seeking) */
    madvise(map, file_size, MADV_RANDOM);

    /* Parse header directly from mmap'd memory (zero-copy) */
    const uint8_t *hdr = map;

    if (memcmp(hdr, AMO_MAGIC, 8) != 0) {
        LOGE("amo_open: invalid magic bytes");
        munmap(map, file_size);
        close(fd);
        return MPV_ERROR_LOADING_FAILED;
    }

    uint32_t version          = read_be32(hdr + 8);
    uint32_t metadata_length  = read_be32(hdr + 12);
    uint32_t thumbnail_length = read_be32(hdr + 16);
    uint64_t video_data_length = read_be64(hdr + 20);

    uint8_t iv[AMO_IV_SIZE];
    memcpy(iv, hdr + 28, AMO_IV_SIZE);

    LOGI("amo_open: v%u meta=%u thumb=%u video=%llu",
         version, metadata_length, thumbnail_length,
         (unsigned long long)video_data_length);

    /* v2-only build. A v1 container has a completely different video layout, so
       decoding one here would not fail loudly — it would hand mpv plausible
       garbage. Refuse it. */
    if (version != AMO_FORMAT_VERSION) {
        LOGE("amo_open: unsupported container version %u (this build reads v%d only)",
             version, AMO_FORMAT_VERSION);
        munmap(map, file_size);
        close(fd);
        return MPV_ERROR_LOADING_FAILED;
    }

    /* Validate every length field against the real file size BEFORE using it as
       an offset/size. Overflow-safe form (a > limit - b) — never compute a+b
       first. file_size >= AMO_HEADER_SIZE was already checked above. A corrupt
       or hostile .amo would otherwise drive OOB reads past the mmap and an
       integer-overflowing malloc below. */
    if ((uint64_t)metadata_length > (uint64_t)file_size - AMO_HEADER_SIZE) {
        LOGE("amo_open: metadata_length out of bounds");
        munmap(map, file_size);
        close(fd);
        return MPV_ERROR_LOADING_FAILED;
    }
    uint64_t after_meta = (uint64_t)AMO_HEADER_SIZE + metadata_length;
    if ((uint64_t)thumbnail_length > (uint64_t)file_size - after_meta) {
        LOGE("amo_open: thumbnail_length out of bounds");
        munmap(map, file_size);
        close(fd);
        return MPV_ERROR_LOADING_FAILED;
    }
    uint64_t after_thumb = after_meta + thumbnail_length;
    if (video_data_length > (uint64_t)file_size - after_thumb) {
        LOGE("amo_open: video_data_length out of bounds");
        munmap(map, file_size);
        close(fd);
        return MPV_ERROR_LOADING_FAILED;
    }

    /* Decrypt metadata (copy from mmap to writable buffer).
       metadata_length is now bounded < file_size, so +1 cannot overflow. */
    uint8_t *dec_metadata = (uint8_t *)malloc((size_t)metadata_length + 1);
    if (!dec_metadata) {
        munmap(map, file_size);
        close(fd);
        return MPV_ERROR_LOADING_FAILED;
    }
    memcpy(dec_metadata, map + AMO_HEADER_SIZE, metadata_length);

    uint8_t master_key[AMO_KEY_SIZE];
    derive_master_key(master_key);

    uint8_t meta_iv[AMO_IV_SIZE];
    calculate_counter_iv(meta_iv, iv, 0);
    Aes256CtrContext meta_ctr;
    aes256_ctr_init(&meta_ctr, master_key, meta_iv, 0);
    aes256_ctr_xcrypt(&meta_ctr, dec_metadata, metadata_length);
    memset(&meta_ctr, 0, sizeof(meta_ctr));
    dec_metadata[metadata_length] = '\0';

    int key_version = json_get_int((const char *)dec_metadata, "keyVersion", 1);
    LOGI("amo_open: keyVersion=%d", key_version);
    free(dec_metadata);

    /* Derive data key. Always HMAC-SHA256(credential, courseSecret) — the v1
       master-key path is gone. That key is a constant compiled into the binary,
       so any file it could open was never really protected; it survives only to
       decrypt the metadata block above. */
    uint8_t data_key[AMO_KEY_SIZE];
    if (key_version < 2 || !derive_v2_key(data_key)) {
        LOGE("amo_open: key derivation failed (keyVersion=%d, credentials=%d)",
             key_version, g_has_credentials);
        memset(master_key, 0, AMO_KEY_SIZE);
        munmap(map, file_size);
        close(fd);
        return MPV_ERROR_LOADING_FAILED;
    }
    memset(master_key, 0, AMO_KEY_SIZE);

#if AMO_ENFORCE_NATIVE_HMAC
    /* Verify file integrity before producing any plaintext (defense-in-depth).
       Range + key match DecryptionService.verifyHmac exactly: HMAC over
       thumbnail || first min(videoDataLength, 1MB) bytes of video, starting at
       headerSize + metadataLength (= after_meta), keyed with the data key.
       Unconditional — v2 files always carry an HMAC. */
    {
        const uint8_t *stored_hmac = hdr + 44;
        int hmac_all_zero = 1;
        for (int i = 0; i < AMO_HMAC_SIZE; i++) {
            if (stored_hmac[i] != 0) { hmac_all_zero = 0; break; }
        }
        /* An all-zero HMAC used to mean "legacy file, skip verification", which
           was also a downgrade bypass: zero the field and the check skipped
           itself. Every v2 file carries one, so treat its absence as failure. */
        if (hmac_all_zero) {
            LOGE("amo_open: file carries no HMAC — refusing (v2 requires one)");
            memset(data_key, 0, AMO_KEY_SIZE);
            munmap(map, file_size);
            close(fd);
            return MPV_ERROR_LOADING_FAILED;
        }
        {
            uint64_t video_part = video_data_length > AMO_CHUNK_SIZE
                                  ? (uint64_t)AMO_CHUNK_SIZE
                                  : (uint64_t)video_data_length;
            uint64_t hmac_len = (uint64_t)thumbnail_length + video_part;
            uint8_t computed[AMO_HMAC_SIZE];
            hmac_sha256(data_key, AMO_KEY_SIZE,
                        map + after_meta, (size_t)hmac_len, computed);
            uint8_t diff = 0;
            for (int i = 0; i < AMO_HMAC_SIZE; i++) {
                diff |= (uint8_t)(computed[i] ^ stored_hmac[i]);
            }
            memset(computed, 0, sizeof(computed));
            if (diff != 0) {
                LOGE("amo_open: HMAC verification failed — wrong key or tampered file");
                memset(data_key, 0, AMO_KEY_SIZE);
                munmap(map, file_size);
                close(fd);
                return MPV_ERROR_LOADING_FAILED;
            }
        }
    }
#endif

    /* Allocate stream context */
    AmoStreamContext *ctx = (AmoStreamContext *)calloc(1, sizeof(AmoStreamContext));
    if (!ctx) {
        munmap(map, file_size);
        close(fd);
        memset(data_key, 0, AMO_KEY_SIZE);
        return MPV_ERROR_LOADING_FAILED;
    }

    ctx->mmap_base          = map;
    ctx->mmap_size          = file_size;
    ctx->fd                 = fd;
    memcpy(ctx->key, data_key, AMO_KEY_SIZE);
    memcpy(ctx->iv, iv, AMO_IV_SIZE);
    ctx->video_data_offset  = AMO_HEADER_SIZE + metadata_length + thumbnail_length;
    ctx->crypto_base_offset = metadata_length + thumbnail_length;
    ctx->video_data_length  = (int64_t)video_data_length;
    ctx->position           = 0;
    ctx->cipher_position    = -1;

    mlock(ctx->key, AMO_KEY_SIZE);
    memset(data_key, 0, AMO_KEY_SIZE);

    /* Pre-fault video data pages for faster first read */
    madvise(map + ctx->video_data_offset,
            (size_t)(video_data_length < 2*1024*1024 ? video_data_length : 2*1024*1024),
            MADV_WILLNEED);

    /* Initialize cipher (full key expansion, only happens once per file) */
    cipher_full_init(ctx, ctx->crypto_base_offset);

    info->cookie    = ctx;
    info->read_fn   = amo_read;
    info->seek_fn   = amo_seek;
    info->size_fn   = amo_size;
    info->close_fn  = amo_close;
    info->cancel_fn = NULL;

    LOGI("amo_open: success, video=%lld, offset=%lld, mmap=%zu bytes",
         (long long)ctx->video_data_length, (long long)ctx->video_data_offset, file_size);

    return 0;
}

/* ── Credential management (called from JNI) ─────────────────────────────── */

void amo_set_credentials(const char *credential, const char *course_secret) {
    if (credential && course_secret) {
        strncpy(g_credential, credential, sizeof(g_credential) - 1);
        g_credential[sizeof(g_credential) - 1] = '\0';
        strncpy(g_course_secret, course_secret, sizeof(g_course_secret) - 1);
        g_course_secret[sizeof(g_course_secret) - 1] = '\0';
        g_has_credentials = 1;
        LOGI("amo_set_credentials: credentials set");
    }
}

void amo_clear_credentials(void) {
    memset(g_credential, 0, sizeof(g_credential));
    memset(g_course_secret, 0, sizeof(g_course_secret));
    g_has_credentials = 0;
    LOGI("amo_clear_credentials: credentials cleared");
}

#ifdef _WIN32
/* ── Windows FFI Exports ─────────────────────────────────────────────────── */

__declspec(dllexport) int amo_register_protocol(int64_t mpv_handle) {
    if (mpv_handle == 0) return -1;
    
    HMODULE hMpv = GetModuleHandleA("libmpv-2.dll");
    if (!hMpv) hMpv = LoadLibraryA("libmpv-2.dll");
    if (!hMpv) hMpv = GetModuleHandleA("mpv-2.dll");
    if (!hMpv) hMpv = LoadLibraryA("mpv-2.dll");
    if (!hMpv) hMpv = GetModuleHandleA("mpv-1.dll");
    if (!hMpv) hMpv = LoadLibraryA("mpv-1.dll");

    if (!hMpv) {
        LOGE("Failed to load libmpv-2.dll or mpv-2.dll");
        return -1;
    }

    mpv_stream_cb_add_ro_fn add_ro = (mpv_stream_cb_add_ro_fn)GetProcAddress(hMpv, "mpv_stream_cb_add_ro");
    if (!add_ro) {
        LOGE("Failed to find mpv_stream_cb_add_ro in loaded mpv dll");
        return -1;
    }

    int ret = add_ro((uint64_t)mpv_handle, "amo", NULL, amo_open);
    if (ret < 0) {
        LOGE("mpv_stream_cb_add_ro failed: %d", ret);
        return -1;
    }

    LOGI("amo_register_protocol: amo:// registered successfully");
    return 0;
}

__declspec(dllexport) void amo_set_credentials_ffi(const char* cred, const char* secret) {
    amo_set_credentials(cred, secret);
}

__declspec(dllexport) void amo_clear_credentials_ffi(void) {
    amo_clear_credentials();
}
#endif
