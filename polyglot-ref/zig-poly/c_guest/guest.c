/*
 * guest.c - C guest for the FANO polyglot runtime.
 *
 * Compiled into the Zig host. All functions use the canonical FANO i256
 * C ABI: 32-byte little-endian two's-complement integers carrying
 * Q128.128 fixed-point values (128.128, scaled by 2^-128).
 */

#include <stdint.h>

typedef unsigned __int128 u128;

/* Load a 32-byte LE two's-complement value into 4 u64 limbs. */
static void load_limb256(const uint8_t *p, uint64_t limbs[4]) {
    for (int i = 0; i < 4; i++) {
        uint64_t v = 0;
        for (int k = 0; k < 8; k++) {
            v |= (uint64_t)p[i * 8 + k] << (8 * k);
        }
        limbs[i] = v;
    }
}

/* Store 4 u64 limbs little-endian into 32 bytes. */
static void store_limb256(uint8_t *p, const uint64_t limbs[4]) {
    for (int i = 0; i < 4; i++) {
        for (int k = 0; k < 8; k++) {
            p[i * 8 + k] = (uint8_t)(limbs[i] >> (8 * k));
        }
    }
}

/* Two's-complement negate across n 64-bit limbs. */
static void negate(uint64_t *limbs, int n) {
    uint64_t carry = 1;
    for (int i = 0; i < n; i++) {
        uint64_t inv = ~limbs[i];
        uint64_t sum = inv + carry;
        carry = (sum < inv) ? 1 : 0;
        limbs[i] = sum;
    }
}

/* 4x4 -> 8 limb schoolbook multiply (unsigned magnitudes). */
static void mul_limbs(const uint64_t a[4], const uint64_t b[4], uint64_t out[8]) {
    for (int i = 0; i < 8; i++) out[i] = 0;
    for (int i = 0; i < 4; i++) {
        u128 carry = 0;
        for (int j = 0; j < 4; j++) {
            u128 cur = (u128)out[i + j] + (u128)a[i] * b[j] + carry;
            out[i + j] = (uint64_t)cur;
            carry = cur >> 64;
        }
        int k = i + 4;
        while (carry > 0) {
            u128 cur = (u128)out[k] + carry;
            out[k] = (uint64_t)cur;
            carry = cur >> 64;
            k++;
        }
    }
}

/* Crate ABI version. */
uint32_t poly_c_version(void) {
    return 1;
}

/* Identity probe: copies 32 bytes, used by link/ABI smoke tests. */
void poly_c_echo(const uint8_t *v, uint8_t *out) {
    for (int i = 0; i < 32; i++) out[i] = v[i];
}

/* Q128.128 fixed-point add: plain 256-bit two's-complement addition. */
void poly_c_add128(const uint8_t *a, const uint8_t *b, uint8_t *out) {
    uint64_t x[4], y[4];
    load_limb256(a, x);
    load_limb256(b, y);
    uint64_t carry = 0;
    for (int i = 0; i < 4; i++) {
        u128 s = (u128)x[i] + y[i] + carry;
        x[i] = (uint64_t)s;
        carry = (uint64_t)(s >> 64);
    }
    store_limb256(out, x);
}

/* 256x256 -> 512-bit signed product, two's complement, 8 limbs. */
static void mul_widen(const uint64_t a[4], const uint64_t b[4], uint64_t p[8]) {
    int an = a[3] >> 63, bn = b[3] >> 63;
    uint64_t ma[4], mb[4];
    for (int i = 0; i < 4; i++) { ma[i] = a[i]; mb[i] = b[i]; }
    if (an) negate(ma, 4);
    if (bn) negate(mb, 4);
    mul_limbs(ma, mb, p);
    if (an != bn) negate(p, 8);
}

/* Raw 256-bit two's-complement multiply (low 256 bits of the product). */
void poly_c_mulraw(const uint8_t *a, const uint8_t *b, uint8_t *out) {
    uint64_t wa[4], wb[4], p[8];
    load_limb256(a, wa);
    load_limb256(b, wb);
    mul_widen(wa, wb, p);
    store_limb256(out, p);
}

/* Q128.128 fixed-point multiply: (a * b) >> 128, round-to-nearest-even. */
void poly_c_mul128(const uint8_t *a, const uint8_t *b, uint8_t *out) {
    uint64_t wa[4], wb[4], p[8];
    load_limb256(a, wa);
    load_limb256(b, wb);
    mul_widen(wa, wb, p);
    /* q = P >> 128 (arithmetic): limbs 2..5 of the product. */
    uint64_t q[4] = { p[2], p[3], p[4], p[5] };
    /* Round-to-nearest-even on the dropped 128 bits. */
    int round = (int)(p[1] >> 63);
    int sticky = (p[0] & ~(1ULL << 63)) != 0;
    if (round && (sticky || (q[0] & 1))) {
        uint64_t carry = 1;
        for (int i = 0; i < 4; i++) {
            u128 s = (u128)q[i] + carry;
            q[i] = (uint64_t)s;
            carry = (uint64_t)(s >> 64);
        }
    }
    store_limb256(out, q);
}
