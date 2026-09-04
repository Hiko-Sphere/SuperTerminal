# Architecture

SuperTerminal is an iOS/iPadOS SSH client whose distinguishing capability is
connecting to SSH servers published through Cloudflare Tunnel and protected by
Cloudflare Access — without any helper binary on the device.

## The organising idea

> Once a reliable, ordered byte stream to the SSH server exists, **nothing above it
> needs to know how that stream was obtained.**

Both transports vend a SwiftNIO `Channel` whose pipeline tail speaks `ByteBuffer` in
both directions. `NIOSSHHandler` is then installed on top. So there is exactly one
implementation of key exchange, host-key verification, user authentication, PTY
handling and window resize — and a Cloudflare session exercises the same code as a
plain one.

```
                 ┌──────────────────────────────────────────────┐
                 │                  App / UI                    │
                 │        SwiftUI · scenes · design system      │
                 └───────────────────────┬──────────────────────┘
                                         │
         ┌───────────────────────────────┴───────────────────────────────┐
         │                      Session management                       │
         │       connection lifecycle · reconnection · multiplexing      │
         └───────────┬───────────────────────────────────┬───────────────┘
                     │                                   │
      ┌──────────────┴─────────────┐        ┌────────────┴──────────────┐
      │       STTerminal           │        │          STSSH            │
      │  VT parser · screen model  │◀──────▶│  NIOSSH · host keys ·     │
      │  scrollback · rendering    │ bytes  │  credentials · PTY        │
      └────────────────────────────┘        └────────────┬──────────────┘
                                                         │  ByteStreamTransport
                                         ┌───────────────┴───────────────┐
                                         │                               │
                         ┌───────────────┴──────────┐   ┌────────────────┴─────────────┐
                         │   DirectTCPTransport     │   │  CloudflareCarrierTransport  │
                         │   Network.framework TCP  │   │  TLS → HTTP/1.1 upgrade →    │
                         │                          │   │  WebSocket → byte stream     │
                         └──────────────────────────┘   └────────────────┬─────────────┘
                                                                         │
                                                        ┌────────────────┴─────────────┐
                                                        │        STCloudflare          │
                                                        │  Access discovery · JWKS ·   │
                                                        │  token validation · login    │
                                                        └──────────────────────────────┘

      ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
      │  STSecureStore   │  │  STPersistence   │  │      STCore      │
      │  Keychain · LA   │  │  hosts · config  │  │ errors · logging │
      └──────────────────┘  └──────────────────┘  └──────────────────┘
```

## Modules

Everything except the SwiftUI app lives in a Swift package, `Packages/SuperTerminalKit`.
That is a testing decision as much as a structural one: the package builds and tests on
macOS with `swift test`, so the SSH stack can be exercised against a real `sshd` in
seconds, with no simulator in the loop.

| Module | Responsibility | Notable types |
| --- | --- | --- |
| `STCore` | Vocabulary shared by everything: the transport protocol, the error taxonomy, redaction-aware logging | `ByteStreamTransport`, `STError`, `Redacted`, `STLogger` |
| `STSecureStore` | Keychain access with explicit protection classes and biometric gating | `SecureStore`, `KeychainSecureStore` |
| `STCloudflare` | The whole Access story: app discovery, JWKS verification, token validation, interactive login, and the WebSocket carrier | `AccessDiscovery`, `JWKSProvider`, `AccessTokenValidator`, `AccessLoginService`, `CloudflareCarrierTransport` |
| `STSSH` | SSH client: transports, host-key policy, credentials, key parsing, sessions | `SSHConnection`, `SSHShellSession`, `HostKeyVerifier`, `OpenSSHPrivateKeyParser`, `DirectTCPTransport` |
| `CBcryptPBKDF` | Vendored OpenBSD `bcrypt_pbkdf` + Blowfish, needed to open passphrase-protected OpenSSH keys | — |
| `STTerminal` | VT/ANSI emulation and the screen model | *in progress* |
| `STPersistence` | Hosts, folders, snippets, settings | *in progress* |
| `STTestSupport` | Real test infrastructure: an actual `sshd`, and a WebSocket carrier server that reproduces the edge's protocol and failure modes | `OpenSSHTestServer`, `WebSocketCarrierTestServer` |

## The Cloudflare path, end to end

```
 1. User connects to ssh.example.com
        │
 2. AccessDiscovery.probe()
        │   HEAD https://ssh.example.com/    cf-access-metadata-request: true
        │   ◀── cf-access-metadata: <JWT>
        │
 3. JWKSProvider.verify()
        │   GET https://team.cloudflareaccess.com/cdn-cgi/access/certs
        │   RS256 signature check · auth_domain must end .cloudflareaccess.com
        │   claims.hostname must equal the host we asked for
        │   ⇒ AccessAppInfo { authDomain, appAUD, appHostname }
        │
 4. Stored token?  ── yes ──▶ AccessTokenValidator (aud · iss · exp · nbf) ──┐
        │ no                                                                 │
        ▼                                                                    │
 5. AccessLoginService.login()                                               │
        │   generate ephemeral X25519 key pair (never persisted)             │
        │   ASWebAuthenticationSession →                                     │
        │     https://ssh.example.com/cdn-cgi/access/cli                     │
        │       ?aud=…&token=<pubkey>&edge_token_transfer=true               │
        │       &send_org_token=true&close_interstitial=true                 │
        │   … user completes SSO / MFA in the system browser …               │
        │   poll https://login.cloudflareaccess.org/transfer/<pubkey>        │
        │   ◀── base64( nonce ‖ crypto_box ), service-public-key header      │
        │   crypto_box_open  ⇒  { app_token, org_token }                     │
        │   validate the app token exactly as in step 4                      │
        ▼                                                                    │
 6. CloudflareCarrierTransport.connect()  ◀───────────────────────────────────┘
        │   TLS (system validation) → HTTP/1.1 GET / with
        │     Upgrade: websocket, Cf-Access-Token: <app token>
        │     [Cf-Access-Jump-Destination: <host:port>]   (bastion mode)
        │   ◀── 101 Switching Protocols
        │   ⇒ a Channel whose binary frames are raw TCP bytes
        │
 7. SSHConnection.connect(transport:)
        │   NIOSSHHandler on the same pipeline
        │   host key verification · user authentication
        │
 8. openShell() ⇒ pty-req + shell ⇒ interactive session
```

Steps 7 and 8 are byte-for-byte the same code the plain-TCP path runs.

### Why the credential arrives by polling, not by callback

`ASWebAuthenticationSession` gives the app a callback URL and nothing else — no cookie
jar, no access to the session's storage. A design that assumed it could read
`CF_Authorization` out of the authentication browser would be built on something the
platform does not permit.

Cloudflare's CLI login flow does not need it. The client generates an ephemeral
Curve25519 key pair and passes the public half in the login URL; after the identity
round-trip the edge seals the tokens to that key and posts them to the login-helper
transfer service, where the client collects and opens them. The public key is
simultaneously the lookup handle and the encryption target, so only the login attempt
that created it can retrieve *and* read the result.

That property is also the CSRF defence: an attacker who induces a login cannot read the
outcome, and cannot substitute one, because the returned token is still signature-,
audience-, issuer- and lifetime-checked against the verified `AccessAppInfo` before it
is attached to anything.

## Concurrency

* Actors own mutable session state (`SSHConnection`, `SSHShellSession`, `JWKSProvider`,
  the known-hosts stores).
* NIO handlers stay event-loop confined. Where a handler must be referenced from
  outside, it goes through `EventLoopIsolated`, whose accessor asserts it is running on
  the owning loop — the invariant is checked, not just asserted in a comment.
* Remote output reaches the terminal as an `AsyncStream<SSHChannelEvent>`.
* The package builds under Swift 6 language mode with strict concurrency and no
  warnings.

## Testing strategy

| Layer | How it is tested | What a pass proves |
| --- | --- | --- |
| Pure logic (JWT, wire codec, key parsing, host-key policy) | Unit tests | The logic is right |
| SSH client | Against a **real `sshd`** started by the test | The client interoperates with OpenSSH, not with a stub |
| Cloudflare carrier protocol | Against a local WebSocket server reproducing the edge's upgrade, framing and failure responses | The wire format and error classification are right |
| Cloudflare Access | **Only** a live account, tunnel and identity provider | Nothing local can prove this; see `TEST_REPORT.md` |

The last row is the important one. The local carrier server deliberately does not
pretend to be Access: it cannot authenticate anyone. Claims about Access rest on the
live end-to-end run and on nothing else.
