/**
 * sha256.h — Minimal SHA-256 and HMAC-SHA256 implementation.
 *
 * Self-contained, no external dependencies.
 * Based on FIPS 180-4.
 */

#ifndef SHA256_H
#define SHA256_H

#include <stdint.h>
#include <stddef.h>

#define SHA256_BLOCK_SIZE  64
#define SHA256_DIGEST_SIZE 32

typedef struct {
    uint32_t state[8];
    uint64_t count;
    uint8_t  buffer[SHA256_BLOCK_SIZE];
} Sha256Context;

void sha256_init(Sha256Context *ctx);
void sha256_update(Sha256Context *ctx, const uint8_t *data, size_t len);
void sha256_final(Sha256Context *ctx, uint8_t digest[SHA256_DIGEST_SIZE]);

/**
 * Compute HMAC-SHA256.
 * @param key      HMAC key
 * @param key_len  Key length in bytes
 * @param msg      Message data
 * @param msg_len  Message length in bytes
 * @param out      Output buffer (32 bytes)
 */
void hmac_sha256(const uint8_t *key, size_t key_len,
                 const uint8_t *msg, size_t msg_len,
                 uint8_t out[SHA256_DIGEST_SIZE]);

#endif /* SHA256_H */
