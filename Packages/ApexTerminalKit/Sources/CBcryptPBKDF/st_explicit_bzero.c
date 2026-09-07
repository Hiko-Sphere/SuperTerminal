/*
 * explicit_bzero() for Apple platforms.
 *
 * Darwin's SDK does not declare explicit_bzero, and a plain memset() on memory that
 * is about to go out of scope is a dead store the optimiser may remove — which would
 * leave passphrase-derived key material in freed memory. The volatile function
 * pointer below is the same technique OpenSSH's own portability layer uses
 * (openbsd-compat/explicit_bzero.c): the indirection through a volatile pointer means
 * the compiler cannot prove the call has no effect, so it cannot elide it.
 */
#include "st_portability.h"

static void *(*volatile st_memset_fn)(void *, int, size_t) = memset;

void
st_explicit_bzero(void *p, size_t n)
{
	if (p == NULL || n == 0)
		return;
	(void)st_memset_fn(p, 0, n);
}
