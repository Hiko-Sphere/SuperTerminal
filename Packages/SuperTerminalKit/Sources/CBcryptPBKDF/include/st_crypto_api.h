/*
 * SHA-512 shim for the vendored bcrypt_pbkdf source.
 *
 * Upstream OpenSSH satisfies `crypto_hash_sha512` from either OpenSSL or a bundled
 * SUPERCOP implementation. SuperTerminal links neither, so this maps the one function
 * bcrypt_pbkdf needs onto CommonCrypto, which is part of the platform and is the same
 * FIPS-validated implementation CryptoKit uses. No hashing code is implemented here.
 */
#ifndef ST_CRYPTO_API_H
#define ST_CRYPTO_API_H

#include <stddef.h>
#include <CommonCrypto/CommonDigest.h>

#define crypto_hash_sha512_BYTES 64U

static inline int
crypto_hash_sha512(unsigned char *out, const unsigned char *in,
    unsigned long long inlen)
{
	CC_SHA512(in, (CC_LONG)inlen, out);
	return 0;
}

#endif /* ST_CRYPTO_API_H */
