/*
 * Portability shim for the vendored OpenBSD blowfish / bcrypt_pbkdf sources.
 *
 * The upstream files include OpenSSH's build-system "includes.h", which pulls in the
 * whole portable-OpenSSH configuration. SuperTerminal vendors only the two algorithm
 * files, so this header supplies exactly the declarations they need on Apple
 * platforms and nothing more. See THIRD_PARTY_NOTICES.md for provenance.
 */
#ifndef ST_PORTABILITY_H
#define ST_PORTABILITY_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/types.h>

#include "blf.h"

/* Provided by st_explicit_bzero.c; Darwin's SDK does not declare explicit_bzero. */
void st_explicit_bzero(void *p, size_t n);
#define explicit_bzero(p, n) st_explicit_bzero((p), (n))

/*
 * OpenBSD's freezero(): wipe then free. Darwin has no equivalent, so it is expressed
 * here in terms of explicit_bzero (available on Apple platforms since macOS 10.15 /
 * iOS 13) rather than a plain memset, which the optimiser is allowed to elide.
 */
static inline void
st_freezero(void *ptr, size_t len)
{
	if (ptr == NULL)
		return;
	explicit_bzero(ptr, len);
	free(ptr);
}
#define freezero(p, n) st_freezero((p), (n))

#endif /* ST_PORTABILITY_H */
