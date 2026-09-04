/*
 * Public interface for the vendored OpenBSD bcrypt_pbkdf implementation.
 *
 * bcrypt_pbkdf is the key-derivation function OpenSSH uses to protect private keys
 * written in the `openssh-key-v1` container. SuperTerminal needs it to import a
 * passphrase-protected key, and there is no system API that provides it.
 */
#ifndef ST_BCRYPT_PBKDF_H
#define ST_BCRYPT_PBKDF_H

#include <stddef.h>
#include <stdint.h>

int bcrypt_pbkdf(const char *pass, size_t passlen, const uint8_t *salt,
    size_t saltlen, uint8_t *key, size_t keylen, unsigned int rounds);

#endif /* ST_BCRYPT_PBKDF_H */
