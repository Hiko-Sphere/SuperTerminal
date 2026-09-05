# Third-party components

Every dependency, why it is here, its licence, and — for anything vendored — exactly
what was changed. Versions are pinned in `Packages/SuperTerminalKit/Package.resolved`.

## Swift package dependencies

| Package | Version | Licence | Why |
| --- | --- | --- | --- |
| [swift-nio](https://github.com/apple/swift-nio) | 2.102.0 | Apache-2.0 | Channel pipeline, HTTP/1.1, WebSocket framing |
| [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) | 0.15.0 | Apache-2.0 | SSH transport, authentication and channels |
| [swift-nio-ssl](https://github.com/apple/swift-nio-ssl) | 2.37.4 | Apache-2.0 | TLS for platforms where Network.framework is not used |
| [swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services) | 1.28.0 | Apache-2.0 | Network.framework-backed channels — correct behaviour across network changes and app suspension on iOS |
| [swift-crypto](https://github.com/apple/swift-crypto) | 3.15.1 | Apache-2.0 | SHA-2, Ed25519, P-256; `_CryptoExtras` for RSA signature verification (Access JWTs) and AES-CTR/CBC (OpenSSH key files) |
| [swift-sodium](https://github.com/jedisct1/swift-sodium) | 0.11.0 | ISC | `crypto_box` — see below |
| swift-asn1, swift-atomics, swift-collections, swift-system | transitive | Apache-2.0 | Pulled in by the above |

### A note on `swift-sodium`

Cloudflare's login helper seals the Access token with NaCl `crypto_box` — X25519 key
agreement with XSalsa20-Poly1305. CryptoKit and `swift-crypto` provide X25519 but not
XSalsa20 or a raw Poly1305, so there is no way to open that box with platform APIs
alone, and writing the missing pieces by hand is exactly the kind of do-it-yourself
cryptography this project refuses.

`swift-sodium` is maintained by Frank Denis, libsodium's author. On Apple platforms it
resolves to `Clibsodium.xcframework`, a **prebuilt binary** — which is a supply-chain
consideration recorded in `SECURITY.md`, not something to wave through. The dependency
is pinned to an exact version.

## Vendored source

### OpenBSD `bcrypt_pbkdf` and Blowfish

**Location:** `Packages/SuperTerminalKit/Sources/CBcryptPBKDF/`
**Upstream:** [openssh-portable](https://github.com/openssh/openssh-portable) `openbsd-compat/`
**Files:** `bcrypt_pbkdf.c` (ISC, © 2013 Ted Unangst), `blowfish.c` and `blf.h`
(BSD-3-Clause, © 1997 Niels Provos)

**Why vendored:** `bcrypt_pbkdf` is the key-derivation function OpenSSH uses to protect
private keys in the `openssh-key-v1` container. There is no system API for it, and
libsodium does not provide it. Importing a passphrase-protected key is impossible
without it.

**Modifications** — the algorithm code is untouched; only the build glue changed:

1. `#include "includes.h"` → `#include "st_portability.h"`. Upstream's header pulls in
   the entire portable-OpenSSH configure output; the shim declares only what these two
   files need.
2. `#include "crypto_api.h"` → `#include "st_crypto_api.h"`, which maps
   `crypto_hash_sha512` onto CommonCrypto's `CC_SHA512`. Upstream satisfies it from
   OpenSSL or a bundled SUPERCOP copy, neither of which is linked here.
3. `explicit_bzero` and `freezero` are supplied by the shim. Darwin's SDK declares
   neither. `explicit_bzero` is implemented with the volatile-function-pointer technique
   OpenSSH's own `openbsd-compat/explicit_bzero.c` uses, so the optimiser cannot elide
   the wipe.
4. One explicit cast, `(const unsigned char *)pass`, to silence a real pointer-sign
   mismatch against the CommonCrypto prototype rather than suppressing the warning.

**Verification:** exercised end to end by
`Tests/STSSHTests/SSHIntegrationTests.swift` — a real `ssh-keygen`-produced encrypted
key is imported and used to authenticate against a real `sshd`. A wrong passphrase must
be rejected, which only happens if the derivation is bit-exact.

## Protocol research

Cloudflare's carrier and login behaviour was determined by reading
[cloudflared](https://github.com/cloudflare/cloudflared) (Apache-2.0) at commit
`2253eeeb25a44a713a4b60b8ba1e1b3f377d1a0f`. **No cloudflared code was copied.** The
files consulted are listed in `DECISIONS.md` (D-001) so the finding can be re-checked
against a future release.

## Trademarks

Cloudflare, Cloudflare Tunnel, Cloudflare Access and WARP are trademarks of Cloudflare,
Inc. SuperTerminal is not affiliated with, endorsed by, or sponsored by Cloudflare.
Product names such as iTerm2, Warp, Blink Shell and Termius belong to their respective
owners and are referenced only to describe categories of prior art; no code, visual
asset or protected design from any of them is used here.
