/**
 * aes256.h — Minimal AES-256 ECB + CTR mode implementation.
 *
 * Self-contained, no external dependencies.
 * Based on the AES (Rijndael) specification, FIPS 197.
 */

#ifndef AES256_H
#define AES256_H

#include <stdint.h>
#include <stddef.h>

#define AES256_KEY_SIZE  32
#define AES256_BLOCK_SIZE 16
#define AES256_ROUNDS    14

typedef struct {
    uint32_t round_key[60];  /* Expanded key schedule (4 * (Nk + 7)) */
} Aes256Context;

/**
 * Initialize AES-256 context with the given key (32 bytes).
 */
void aes256_init(Aes256Context *ctx, const uint8_t key[AES256_KEY_SIZE]);

/**
 * Encrypt a single 16-byte block in-place (ECB mode).
 */
void aes256_ecb_encrypt(const Aes256Context *ctx, uint8_t block[AES256_BLOCK_SIZE]);

/* ── CTR mode ──────────────────────────────────────────────────────────── */

typedef struct {
    Aes256Context aes;
    uint8_t counter[AES256_BLOCK_SIZE];  /* Current counter value */
    uint8_t keystream[AES256_BLOCK_SIZE]; /* Cached keystream block */
    int keystream_pos;                    /* Position within current keystream block */
} Aes256CtrContext;

/**
 * Initialize AES-256-CTR context (full key expansion + counter set).
 * Call once when the key is first known.
 * @param key  32-byte AES key
 * @param iv   16-byte counter/IV value for this position
 * @param partial_offset  Byte offset within the current block (0-15).
 */
void aes256_ctr_init(Aes256CtrContext *ctx, const uint8_t key[AES256_KEY_SIZE],
                     const uint8_t iv[AES256_BLOCK_SIZE], int partial_offset);

/**
 * Reset CTR counter WITHOUT re-expanding the key (fast seek).
 * Reuses the existing key schedule — only updates the counter and partial offset.
 * ~100x faster than aes256_ctr_init for seeks within the same file.
 */
void aes256_ctr_seek(Aes256CtrContext *ctx, const uint8_t iv[AES256_BLOCK_SIZE],
                     int partial_offset);

/**
 * Encrypt/decrypt data using AES-256-CTR (XOR with keystream).
 * Processes len bytes in-place.
 */
void aes256_ctr_xcrypt(Aes256CtrContext *ctx, uint8_t *data, size_t len);

#endif /* AES256_H */
