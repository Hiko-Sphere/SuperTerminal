# Export compliance — the cryptography this app actually contains

Written because `docs/RELEASE.md` claimed the app "implements none of its own" algorithms
while the repository contained a hand-written DES and a hand-written big-integer modular
exponentiation. One of those is now gone; the other is here with its reason. This file is
the inventory that statement should always have been checked against.

Every row was established by reading the source, not by reading the previous document.

## What performs cryptography

| Algorithm | What it is for | Where it comes from | Licence |
| --- | --- | --- | --- |
| SSH transport: curve25519-sha256, ecdh-sha2-nistp256/384/521, AES-CTR, chacha20-poly1305, hmac-sha2-256/512-ETM | The SSH connection itself | `swift-nio-ssh`, vendored as `swift-nio-ssh-rsa` (D-007) | Apache-2.0 |
| ML-KEM-768 (FIPS 203), combined with X25519 as `mlkem768x25519-sha256` | Post-quantum SSH key exchange, preferred where the system provides it (D-048) | **CryptoKit `MLKEM768` (Apple)**, iOS 26 / macOS 26 and later; the SSH plumbing around it is in `Sources/NIOSSH/Key Exchange/MLKEMHybridKeyExchange.swift` | Apple platform |
| Ed25519, ECDSA P-256/384/521, RSA signing and verification | SSH host keys and user keys | same, over `swift-crypto` | Apache-2.0 |
| TLS 1.2/1.3 | HTTPS to the Cloudflare edge, and the WebSocket carrier | `swift-nio-ssl` → BoringSSL | Apache-2.0 (BoringSSL: ISC/OpenSSL) |
| SHA-256, SHA-512, HMAC, P-256, Curve25519 | SSH key exchange, JWT signature validation for Access | `swift-crypto` | Apache-2.0 |
| `crypto_box` (X25519 + XSalsa20-Poly1305) | Sealing credentials to Cloudflare's login helper (D-001) | `swift-sodium` → libsodium | ISC |
| bcrypt_pbkdf (Blowfish) | Decrypting a passphrase-protected OpenSSH private key on import (D-004) | Vendored OpenBSD C, `Sources/CBcryptPBKDF` | ISC / public domain |
| PBKDF2-HMAC-SHA256 | Deriving the App Lock passcode record (D-023) | CommonCrypto (Apple) | Apple platform |
| AES-128-ECB | Sealing the credentials block in macOS Screen Sharing authentication, RFB security type 30 (D-031) | CommonCrypto (Apple) | Apple platform |
| DES-ECB | The challenge response in classic VNC Authentication, RFB security type 2 | CommonCrypto (Apple) — **was hand-written until D-038** | Apple platform |
| MD5 | Deriving the AES key from the Diffie-Hellman shared secret, as RFB security type 30 mandates | CryptoKit `Insecure.MD5` (Apple) | Apple platform |
| SHA-1 | Deriving a name-based UUID (version 5) for screen migration ids — an identifier, not a security decision (D-027) | CryptoKit `Insecure.SHA1` (Apple) | Apple platform |
| Modular exponentiation over the server's Diffie-Hellman group | Key agreement for RFB security type 30 | **`Packages/ApexTerminalKit/Sources/STVNC/VNCBigInteger.swift` — this repository** | — |

## A note on the post-quantum exchange

The ML-KEM implementation is Apple's, reached through `CryptoKit.MLKEM768`. What this
repository contains is the SSH-side plumbing: how the two public values are concatenated,
how the two shared secrets are combined (`SHA-256(K_PQ ‖ K_X25519)`), and how the result is
encoded into the exchange hash and the key derivation. No primitive is implemented here.

For the encryption questionnaire this is the same answer as the rest of the SSH transport —
standard, published key agreement used to secure the app's own connections — with the note
that ML-KEM is a FIPS 203 algorithm supplied by the operating system, not by this app.

## The one thing this app still implements itself, and why

`VNCBigInteger` performs `a^b mod m` over a group the *server* chooses at connection time
(macOS Screen Sharing sends the generator, the prime and its public key). Apple publishes
no API that does this:

* CryptoKit exposes key agreement only over its own named curves (`Curve25519.KeyAgreement`,
  `P256.KeyAgreement`); there is no primitive taking an arbitrary modulus.
* Security's `SecKey` handles RSA and EC keys as whole objects. It has no modular
  exponentiation entry point.
* CommonCrypto has ciphers, digests and PBKDF2. It has no big-integer arithmetic.
* BoringSSL ships inside `swift-crypto` and `swift-nio-ssl`, but as `CCryptoBoringSSL` —
  a private target neither package vends as a product, so depending on it would mean
  vendoring a C library to reach one function.

So the choice is between this and dropping account-based login to macOS Screen Sharing.
It is kept, and bounded:

* It is used **only** for RFB security type 30 key agreement — never for SSH, TLS, key
  storage, or anything protecting data at rest.
* The private exponent is generated per connection and discarded with it.
* It is **not constant-time.** Reading it is a documented risk rather than an oversight:
  an attacker would need to observe timing on the device itself, and the value recovered
  would be an exponent already thrown away. If Apple ever exposes a modexp primitive, this
  file should go.
* Its arithmetic is checked against exchanges computed by Python's arbitrary-precision
  integers at 512 and 1024 bits, not against itself (D-031).

## What was removed

`VNCDES.swift` carried a full DES — S-boxes, permutation tables, key schedule — under a
comment claiming no dependency exposed "this exact form" (D-038). That was wrong. VNC's
quirk is that the *key* has the bits of each byte reversed; the cipher underneath is
ordinary DES, and `kCCAlgorithmDES` is exactly that. The file now prepares the key and
calls CommonCrypto, and carries FIPS 46-3 known-answer vectors — which the previous tests
did not, since they only checked that the output was deterministic and key-dependent,
something any wrong permutation also satisfies.

## For the App Store Connect encryption questions

Answer from this table, not from memory. The facts to answer with:

* The app **does** contain encryption: SSH, TLS, and the primitives above.
* All of it is used for authentication and for securing the user's own connections. There
  is no digital-rights management and no proprietary algorithm.
* Everything except `VNCBigInteger` comes from Apple's platform or from published,
  standard, open-source implementations.
* `ITSAppUsesNonExemptEncryption` is **deliberately not set in this repository.** Whether
  the app qualifies for the exemption, and whether a CCATS or a self-classification report
  is required, depends on where it is distributed and is a decision for the owner with
  advice — not something a build setting should assert on their behalf. See
  `docs/HUMAN_ACTIONS.md`.
