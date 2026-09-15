/**
 * aes256.c — Minimal AES-256 ECB + CTR mode implementation.
 *
 * Self-contained AES-256 based on FIPS 197 (Rijndael).
 * No external dependencies — suitable for Android NDK without OpenSSL.
 */

#include "aes256.h"
#include <string.h>

/* ── AES S-box and inverse ───────────────────────────────────────────────── */

static const uint8_t sbox[256] = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
};

/* Round constants */
static const uint8_t rcon[11] = {
    0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36
};

/* ── GF(2^8) multiplication lookup tables for MixColumns ─────────────────── */

static uint8_t xtime(uint8_t x) {
    return (uint8_t)((x << 1) ^ (((x >> 7) & 1) * 0x1b));
}

/* ── Key Expansion ───────────────────────────────────────────────────────── */

void aes256_init(Aes256Context *ctx, const uint8_t key[AES256_KEY_SIZE]) {
    uint32_t *rk = ctx->round_key;
    int i;

    /* Copy key into first 8 round key words */
    for (i = 0; i < 8; i++) {
        rk[i] = ((uint32_t)key[4*i] << 24) | ((uint32_t)key[4*i+1] << 16) |
                ((uint32_t)key[4*i+2] << 8) | (uint32_t)key[4*i+3];
    }

    /* Expand key */
    for (i = 8; i < 60; i++) {
        uint32_t temp = rk[i - 1];
        if (i % 8 == 0) {
            /* RotWord + SubWord + Rcon */
            temp = ((uint32_t)sbox[(temp >> 16) & 0xff] << 24) |
                   ((uint32_t)sbox[(temp >>  8) & 0xff] << 16) |
                   ((uint32_t)sbox[(temp      ) & 0xff] <<  8) |
                   ((uint32_t)sbox[(temp >> 24) & 0xff]);
            temp ^= (uint32_t)rcon[i / 8] << 24;
        } else if (i % 8 == 4) {
            /* SubWord only */
            temp = ((uint32_t)sbox[(temp >> 24) & 0xff] << 24) |
                   ((uint32_t)sbox[(temp >> 16) & 0xff] << 16) |
                   ((uint32_t)sbox[(temp >>  8) & 0xff] <<  8) |
                   ((uint32_t)sbox[(temp      ) & 0xff]);
        }
        rk[i] = rk[i - 8] ^ temp;
    }
}

/* ── AES-256 ECB Encrypt ─────────────────────────────────────────────────── */

/* State is a 4x4 column-major matrix of bytes, stored as uint8_t[16] */

static void sub_bytes(uint8_t state[16]) {
    for (int i = 0; i < 16; i++)
        state[i] = sbox[state[i]];
}

static void shift_rows(uint8_t state[16]) {
    uint8_t t;
    /* Row 1: shift left 1 */
    t = state[1]; state[1] = state[5]; state[5] = state[9]; state[9] = state[13]; state[13] = t;
    /* Row 2: shift left 2 */
    t = state[2]; state[2] = state[10]; state[10] = t;
    t = state[6]; state[6] = state[14]; state[14] = t;
    /* Row 3: shift left 3 */
    t = state[15]; state[15] = state[11]; state[11] = state[7]; state[7] = state[3]; state[3] = t;
}

static void mix_columns(uint8_t state[16]) {
    for (int i = 0; i < 4; i++) {
        int c = i * 4;
        uint8_t a0 = state[c], a1 = state[c+1], a2 = state[c+2], a3 = state[c+3];
        uint8_t t = a0 ^ a1 ^ a2 ^ a3;
        state[c]   = a0 ^ xtime(a0 ^ a1) ^ t;
        state[c+1] = a1 ^ xtime(a1 ^ a2) ^ t;
        state[c+2] = a2 ^ xtime(a2 ^ a3) ^ t;
        state[c+3] = a3 ^ xtime(a3 ^ a0) ^ t;
    }
}

static void add_round_key(uint8_t state[16], const uint32_t *rk, int round) {
    const uint32_t *w = &rk[round * 4];
    for (int i = 0; i < 4; i++) {
        state[i*4]   ^= (uint8_t)(w[i] >> 24);
        state[i*4+1] ^= (uint8_t)(w[i] >> 16);
        state[i*4+2] ^= (uint8_t)(w[i] >>  8);
        state[i*4+3] ^= (uint8_t)(w[i]);
    }
}

void aes256_ecb_encrypt(const Aes256Context *ctx, uint8_t block[AES256_BLOCK_SIZE]) {
    add_round_key(block, ctx->round_key, 0);

    for (int round = 1; round < AES256_ROUNDS; round++) {
        sub_bytes(block);
        shift_rows(block);
        mix_columns(block);
        add_round_key(block, ctx->round_key, round);
    }

    /* Last round (no MixColumns) */
    sub_bytes(block);
    shift_rows(block);
    add_round_key(block, ctx->round_key, AES256_ROUNDS);
}

/* ── CTR Mode ────────────────────────────────────────────────────────────── */

static void increment_counter(uint8_t counter[AES256_BLOCK_SIZE]) {
    /* Big-endian increment (matches Dart's _addToCounter with value=1) */
    for (int i = AES256_BLOCK_SIZE - 1; i >= 0; i--) {
        if (++counter[i] != 0) break;
    }
}

void aes256_ctr_init(Aes256CtrContext *ctx, const uint8_t key[AES256_KEY_SIZE],
                     const uint8_t iv[AES256_BLOCK_SIZE], int partial_offset) {
    aes256_init(&ctx->aes, key);
    aes256_ctr_seek(ctx, iv, partial_offset);
}

void aes256_ctr_seek(Aes256CtrContext *ctx, const uint8_t iv[AES256_BLOCK_SIZE],
                     int partial_offset) {
    /* Only update counter — reuse existing key schedule (skip key expansion) */
    memcpy(ctx->counter, iv, AES256_BLOCK_SIZE);

    if (partial_offset > 0 && partial_offset < AES256_BLOCK_SIZE) {
        /* Generate keystream for the current block and advance past partial */
        memcpy(ctx->keystream, ctx->counter, AES256_BLOCK_SIZE);
        aes256_ecb_encrypt(&ctx->aes, ctx->keystream);
        increment_counter(ctx->counter);
        ctx->keystream_pos = partial_offset;
    } else {
        ctx->keystream_pos = AES256_BLOCK_SIZE; /* Force new block on first use */
    }
}

void aes256_ctr_xcrypt(Aes256CtrContext *ctx, uint8_t *data, size_t len) {
    size_t i = 0;

    /* Process remaining bytes from a partially-used keystream block */
    while (i < len && ctx->keystream_pos < AES256_BLOCK_SIZE) {
        data[i++] ^= ctx->keystream[ctx->keystream_pos++];
    }

    /* Process full 16-byte blocks (fast path — bulk of the work) */
    while (i + AES256_BLOCK_SIZE <= len) {
        /* Generate keystream block */
        uint8_t ks[AES256_BLOCK_SIZE];
        memcpy(ks, ctx->counter, AES256_BLOCK_SIZE);
        aes256_ecb_encrypt(&ctx->aes, ks);
        increment_counter(ctx->counter);

        /* XOR 16 bytes at once */
        for (int j = 0; j < AES256_BLOCK_SIZE; j++) {
            data[i + j] ^= ks[j];
        }
        i += AES256_BLOCK_SIZE;
    }

    /* Process remaining tail bytes (< 16) */
    if (i < len) {
        memcpy(ctx->keystream, ctx->counter, AES256_BLOCK_SIZE);
        aes256_ecb_encrypt(&ctx->aes, ctx->keystream);
        increment_counter(ctx->counter);
        ctx->keystream_pos = 0;

        while (i < len) {
            data[i++] ^= ctx->keystream[ctx->keystream_pos++];
        }
    }
    /* No else. Reaching here with i == len means one of:
         - the cached block was exhausted by the first loop  -> pos already 16
         - the full-block loop ran and ended exactly on len   -> pos already 16
         - this call was served ENTIRELY from the cached block without
           exhausting it                                      -> pos is 11-ish
       The third case is the live one, and it used to be overwritten with
       AES256_BLOCK_SIZE ("fully consumed"). That threw away the unconsumed tail
       of the cached keystream, so the NEXT call generated a fresh block and
       every byte after it decrypted against the wrong keystream.

       It stayed hidden because it only fires when a call's length lands inside
       the cached block: reads that are multiples of 16 never trigger it, and v1
       decrypted contiguous 100 KB runs in 16-aligned chunks. v2 gathers a
       variable, rarely-16-aligned number of bytes per read, so it fires
       constantly. Caught by scratchpad/test_amo_read.c at read sizes 1/15/17. */
}
