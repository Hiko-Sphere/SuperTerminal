# Cloudflare Access and Cloudflare Tunnel — internal record

**Written:** 2026-09-10 · **Status: INTERNAL.** · **Gated by:**
[`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md) and
`docs/HUMAN_ACTIONS.md` H-4

> **Nothing in this file may be used publicly until H-4 clears.** Not a sentence, not a
> phrase, not a paraphrase. Cloudflare appears in no name, subtitle, description, keyword,
> screenshot, caption, social post, website page or press note. The single exception, which
> already exists and is not to be extended, is the disclosure in the App Review notes, where
> guideline 2.3.1 requires that a working feature present in the binary be declared to the
> reviewer.
>
> This is a decision, not an oversight, and it is recorded here so that a later writer who
> finds the code does not conclude that marketing simply forgot.

The reason is one sentence: **no connection has ever been made through a live Cloudflare
account.** Everything that passes, passes against a local server this project wrote to
reproduce the edge's wire behaviour. A claim we cannot reproduce is a claim we must not make.

This file records what is implemented, what is tested and how, what has never been verified
and why that matters, exactly what would unblock it, and the wording that becomes available
on the day it does.

---

## 1 · What is implemented

`STCloudflare` is 1 769 lines, and the app surfaces on top of it are real, shipping and
reachable in the interface. Two halves, of very different maturity.

### 1.1 · The carrier — the transport half

* **A native reimplementation of the tunnel carrier protocol in Swift over SwiftNIO.**
  A WebSocket client upgrade, then raw bytes in and out, with every client frame masked per
  RFC 6455 §5.3. Fragments are forwarded without reassembly buffering.
  (`CloudflareCarrierTransport.swift:100-166`, `WebSocketByteStream.swift:17`, `:107`.)
* **The carrier vends an ordinary NIO channel**, on which the app's ordinary `SSHConnection`
  sits unchanged (`CloudflareCarrierTransport.swift:93`). Everything downstream — the
  terminal, SFTP, forwarding, tmux — is the same code as on a direct connection.
* **Headers.** `Cf-Access-Token` for a user session, `Cf-Access-Client-Id` and
  `Cf-Access-Client-Secret` for a service token, and `Cf-Access-Jump-Destination` for bastion
  mode (`:204-219`).
* **Failure classification.** Login redirect, 401/403, 404, 502/503/504 and 530 become
  distinct, actionable errors, each carrying a recovery suggestion — "the tunnel is offline,
  start the connector on the origin" rather than "connection failed"
  (`:333-378`, `AccessModels.swift:121-207`).
* **A safety property.** The test-only plaintext carrier throws before it dials if it is
  pointed at anything that is not loopback (`:126-136`), so no build can be tricked into an
  unencrypted tunnel.
* **Keepalive.** Periodic ping, pong echo per §5.5.2, teardown when a ping goes unanswered,
  and an RFC 6455 close handshake echoing the peer's status code
  (`WebSocketByteStream.swift:39-104`).

### 1.2 · Access authentication — the identity half

* **Discovery.** A HEAD probe works out whether a hostname sits behind Access and which
  application guards it, verifying the signed `cf-access-metadata` JWT, re-deriving the auth
  domain from the *verified* payload, checking the hostname match, requiring `type == "match"`
  and a non-empty audience, and enforcing the expected suffix on the auth domain. A redirect
  blocker means a 302 to the login path is *seen* rather than followed, so a hostile origin
  cannot choose the login page the user lands on (`AccessDiscovery.swift:54`, `:88`, `:141`,
  `HTTPTransport.swift:129`).
* **JWKS and signature verification.** RS256 pinned as the accepted algorithm, closing
  `alg: none` and algorithm substitution; the key id must match exactly, with no fall-back to
  trying every key; PKCS #1 v1.5 verification; a 24-hour cache with one rate-limited refresh on
  a key-id miss, a 1 MiB response cap and acceptance of 200 responses alone. Parsing is
  deliberately separated from verification (`JWKS.swift:26-171`, `JWT.swift:10`).
* **Token validation — the token-confusion defence.** Signature, then the audience must
  contain the discovered application audience, then the issuer pinned to the verified
  metadata's auth domain, then lifetime with a 30-second leeway and a not-before check. The
  validated type cannot be constructed outside the module, so the type system enforces
  "validated or not at all" (`AccessTokenValidator.swift:31-80`, `AccessModels.swift:64-80`).
* **Browser SSO and MFA sign-in.** A system web-authentication session against the CLI login
  endpoint, racing the browser against a poll of the login transfer service, with the payload
  decrypted using an ephemeral key pair — so the transfer is bound to this request and the
  app never sees the identity provider's credentials
  (`AccessLogin.swift:43-241`, `BoxCrypto.swift:32`).
* **Service tokens.** Stored per connection in the Keychain, this-device-only, excluded from
  sync, deleted with the connection (D-017).
* **Credential lifecycle.** Sign out of one Access application without losing another; the
  Delete-all-data sweep clears every stored session.

### 1.3 · Where it surfaces in the app

* `+` → **New Cloudflare Connection**, and a "Through Cloudflare Tunnel" toggle in the
  connection editor with the service-token fields beneath it.
* A **remote screen** can take a tunnel hostname as its own route, with no SSH connection in
  the way (`VNCSession.swift:213-244`).
* A **published Files location** can be backed by a tunnelled connection, where the stored
  credential is one an extension can use with nobody present
  (`DomainConnection.swift:177-219`).
* An **Access Diagnostics** screen: in the order a connection meets them — did the edge
  answer, which application guards the hostname, which team owns it, and is the stored
  credential valid, expired, missing or present-but-unusable.

### 1.4 · The architectural claim, which is genuinely true

**Nothing has to be installed on the device.** No helper binary, no VPN profile, no Network
Extension. Three independent things establish it: the protocol is reimplemented in Swift over
SwiftNIO; the app's entitlements declare no Network Extension and no VPN, with a comment
saying in as many words that the tunnel is an ordinary outbound TLS connection made
in-process; and no subprocess-spawning API appears anywhere in the app, the extension or the
shipping package sources — the matches are in test-only fixtures. The single non-Apple
dependency of this module is libsodium, for the transfer decryption.

---

## 2 · What is tested, and exactly how

Everything below passed on a local re-run on 2026-09-10.

| What was run | What it proves | Where |
| --- | --- | --- |
| A full interactive SSH session over the carrier | `SSHConnection.connect` runs over the carrier against a **real** OpenSSH `sshd`, exit status 0 and exact stdout | `CarrierIntegrationTests.swift:65` |
| A 256 KiB PTY burst in one go | Multi-frame fragment reassembly, in order, under load — over 200 000 bytes and the post-burst marker | `:94` |
| The user token reaches the edge | The test server *requires* the exact `Cf-Access-Token` value before it will upgrade, and the assertion is on the header the server recorded — a pass means the header arrived, not that the client meant to send it | `:148`, `:177`; `:181` for the non-matching case |
| Service-token headers are sent and accepted | Both header values required by the server, asserted on what the server recorded | `:217`, `:248-250` |
| The bastion destination is sent | `Cf-Access-Jump-Destination` asserted on the server's record | `:254` |
| Edge failures classify correctly | Four parameterised cases — login redirect, forbidden, origin unreachable, tunnel offline — each additionally required to carry a non-empty recovery suggestion | `:288`, `:311` |
| A plaintext carrier refuses a non-loopback host | Targets a public hostname, requires a configuration error before dialling | `:315` |
| A service token survives the real Keychain | Store, read back, delete, in the app host's own Keychain; the secret is redacted in any description | `AppTests/ServiceTokenTests.swift:26` |
| The service-token editor behaves | Save stays disabled without a token; a stored token is shown as stored and never displayed; no system "Save Password?" sheet appears | `AppUITests/ServiceTokenUITests.swift:12` |
| The diagnostics reasoning | Six tests over every state, including that an unprotected hostname is a warning rather than a pass, that a missing service token is fatal while a not-yet-signed-in session is a warning, and that an unusable stored token is reported as bad | `AppTests/AccessDiagnosticsTests.swift:13`, `:31`, `:53`, `:68` |

**And here is the thing to understand about that table.** Every row above whose counterparty
is "the edge" is in fact `WebSocketCarrierTestServer` — a NIO server written inside this
project to reproduce the edge's wire behaviour, bridged to a real local OpenSSH `sshd`. That
file says at its own top that it does not prove Access authentication. The wire protocol it
reproduces was derived by reading the connector's source at a pinned commit (D-001), which is
honest engineering and is not the same as observing the real service.

---

## 3 · What has never been verified, and why it matters

### 3.1 · No live connection, ever

`LiveCloudflareE2ETests` is the suite that would settle this. It is gated on
`ST_LIVE_CF_HOSTNAME` and skips without it. It was run on 2026-09-10 and all four cases
reported `skipped: "set ST_LIVE_CF_HOSTNAME to run"`. Its four cases are exactly the four
questions that matter:

1. the hostname is discovered as an Access application (`:69`);
2. a service token opens the carrier and reaches a real interactive PTY (`:86`);
3. a token for the wrong audience is refused (`:155`);
4. an unauthenticated connection is refused rather than silently allowed (`:180`).

The no-account workaround was tried and failed: two quick tunnels registered with the service
but every request to the edge returned an empty 404, with no request reaching the tunnel
(`TEST_REPORT.md:1033`, `PROJECT_STATUS.md:244`, B-3).

**Why it matters.** Case 4 is a security property, not a convenience one. Until it has run
against the real service, this project cannot say that an unauthenticated connection is
refused by the path a customer would take — it can say only that its own reproduction of the
edge refuses one.

### 3.2 · The authentication half carries no test at all

Of the 1 769 lines, the carrier (roughly 548) is well covered. The identity half — discovery,
JWKS and RS256 verification, token validation, the browser login and its transfer decryption,
the HTTP transport: roughly **950 lines** — has no test whatsoever.

Concretely, none of the following has ever been executed by a test:

* a forged signature being rejected;
* `alg: none` being refused;
* a rotated key id not being silently accepted;
* the key-id-must-match rule, with no fall-back to trying every key;
* the audience check that prevents a token issued for one Access application being replayed
  against another;
* the issuer pin, the expiry leeway and the not-before check;
* the transfer decryption, the ephemeral-key property that binds a login to its request, and
  the browser-closed-first race;
* the 300-second poll timeout.

**Why it matters.** These are the security-critical files in the module. The reasoning in them
reads carefully and the type system enforces the important invariant — but careful is not
verified, and the entire value of the audit this rebuild rests on is the refusal to treat the
two as the same thing.

### 3.3 · Three project documents overstate the coverage

They are recorded here so that nobody quotes them:

1. `docs/RELEASE_EVIDENCE.md:1042` says the probe "has its own tests"; `docs/CLOUDFLARE.md:293`
   repeats it. **There is no discovery test file.**
2. `AccessLogin.swift:5-6` says "tests supply a driver that performs the browser half of the
   exchange programmatically". **There is no such driver** — the single implementation of that
   protocol is the real one.
3. `CarrierIntegrationTests.swift:200-201` defers validation coverage to a suite named in the
   comment. **That suite does not exist.** The whole test target is three files totalling 545
   lines, one of which is a four-line base64 round trip.

None of the three is quotable, and the truth matrix says so.

### 3.4 · Smaller gaps, listed so they are not rediscovered as surprises

* **Keepalive never fires in any test.** The interval is set to five seconds and the longest
  case in the suite ran 2.29 seconds, so no ping is ever scheduled, and nothing asserts pong
  handling or the close handshake. Idle-timeout survival — the property that matters for a
  terminal left open on a desk — has never been observed anywhere.
* **A remote screen over the carrier has never been connected.** Only the record is tested:
  that the route is neither direct nor SSH, and that a blank port means 443. No picture has
  crossed the carrier in any test.
* **A tunnelled Files location has never been exercised.** Neither branch — service token, or
  a stored browser session — has run against a live tenant, and the extension path has its own
  separate device-level block. Note the inherent limit, which is real and permanent: an app
  extension cannot present a web view, so a browser session that has expired must send the
  person back to the app.
* **The bastion header is proven on the wire and nowhere else.** Whether the ingress routes to
  the named destination is unverified.
* **The user-token Keychain lifecycle is untested** — storing, loading and signing out. Only
  the service token's storage is covered. These are two different credentials and copy must
  not blur them.
* **The diagnostics screen is half-proven:** the pure reasoning on top is well covered; the
  probe and the validation underneath it are not called by any test. Against a hostname with
  no live tenant, that screen can show "unreachable" or "no Access application" and nothing
  else, so a screenshot of a healthy diagnosis cannot be produced today.

---

## 4 · Exactly what would unblock it

`docs/HUMAN_ACTIONS.md` **H-4 · Cloudflare Access live environment (B-2)**. It is blocked on
the owner, because it needs an account nobody on the engineering side can create on the
project's behalf, and it names what it blocks: the app's central product claim being
*verified* rather than implemented.

**What is needed.**

1. A Cloudflare account.
2. A tunnel, published to a hostname.
3. An Access application in front of that hostname.
4. An Access service token — client id and secret. The service token is what makes the run
   automatable: interactive SSO and MFA sign-in is exercised from the app by hand, not from
   the script.
5. An SSH server on the origin, and a credential for it.

**How it is run.** The variables live outside the working tree and nothing is committed:

```
ST_LIVE_CF_HOSTNAME              the hostname published by the tunnel
ST_LIVE_SSH_USER                 the SSH user name on the origin host
ST_LIVE_CF_SERVICE_TOKEN_ID      the Access service token client id
ST_LIVE_CF_SERVICE_TOKEN_SECRET  the Access service token client secret
ST_LIVE_SSH_KEY_PATH             an OpenSSH private key  (or ST_LIVE_SSH_PASSWORD)
ST_LIVE_SSH_KEY_PASSPHRASE       its passphrase, if it has one
ST_LIVE_CF_JUMP_DESTINATION      optional: host:port, when the tunnel runs in bastion mode
ST_LIVE_SSH_HOST_FINGERPRINT     optional: SHA256:… to pin instead of trusting on first use
```

Then `./scripts/live-e2e.sh`. When the environment is configured, nothing in that suite is
lenient: every step must succeed.

**What has to be true before any of it is quotable.**

* All four live cases pass, not skip — including the two refusal cases, which are the ones
  that matter.
* The run is recorded in `docs/RELEASE_EVIDENCE.md` with the date it happened, the hostname's
  shape (not the hostname), and the result of each case.
* The three overstating documents in §3.3 are corrected, so that a later reader does not find
  a document claiming coverage that still does not exist.
* Tests are written for the identity half, or the wording below is trimmed to cover the
  carrier alone. A single live run proves that the pieces and the real service agree once; it
  does not substitute for the roughly 950 untested lines, and the wording released on that day
  should reflect which of the two happened.
* The truth matrix is regenerated, the claims matrix gains its row, and the messaging system
  gains the sentence — in that order. Only then does any customer-facing document change.

---

## 5 · The wording that becomes available on the day

Held here, written, marked blocked. It is not to be used, adapted, previewed to a partner or
put in a draft that could be published by accident.

**The claim, once the live run passes and is recorded:**

> Connect to a server that has no public SSH port and no VPN. If it is published as a
> Cloudflare hostname behind Cloudflare Access, Apex Terminal reaches it directly — nothing to
> install on the device, no helper, no VPN profile.

**The short form, for a subtitle-length slot:**

> Reach a server behind Cloudflare Access, with nothing installed on the device.

**The supporting sentences, each of which needs its own evidence before use:**

* Sign in with your organisation's own identity provider, including multi-factor, in a browser
  session the app never reads. *(Needs a real sign-in, observed and recorded.)*
* Or authenticate with a service token an administrator issued, with no browser at all.
  *(Storage and the wire are already proven; the live acceptance is what H-4 adds.)*
* One published hostname can front several internal servers, and each keeps its own host-key
  record. *(Needs a live bastion run.)*
* When something is wrong, the app says which thing: the tunnel is offline, the Access session
  has expired, no application guards this hostname. *(Needs the real service's own failures
  observed, since today's classification is built against a reproduction of them.)*

**If, on that day, the live carrier run passes but the identity half is still untested**, the
available claim is narrower and should be written narrowly — the carrier and the service-token
path, without any sentence about browser sign-in, token validation or the refusal properties.

**Trademark rules, for whenever the word is used at all.**

* Permitted: "works with Cloudflare Access", "supports Cloudflare Tunnel".
* Forbidden: "official Cloudflare client", "Cloudflare-approved", and any implication of
  partnership, endorsement or authorship.
* No Cloudflare logo or wordmark in any key visual.
* The app is not affiliated with, endorsed by or connected to Cloudflare, Inc.
* Cloudflare, Cloudflare Access and Cloudflare Tunnel are trademarks of Cloudflare, Inc.

---

## 6 · The maximal honest statement today

For App Review notes and for internal use. Not for a store listing, a website, a press note or
a caption:

> The app implements Cloudflare's carrier protocol natively and runs a full interactive SSH
> session over it with no helper binary — proven against a real `sshd`, not against Cloudflare.

Everything in that sentence is load-bearing, including the last five words. A version of it
that drops them is a different claim, and it is the claim this whole file exists to prevent.

---

## 7 · What can and cannot be photographed, if the day comes

**Can be, today:** the connection editor's tunnel setup, the service-token fields showing a
token as stored without revealing it, and the diagnostics screen — which, against a hostname
with no live tenant, can show "unreachable" or "no Access application" and nothing more. All
of these are driven in the simulator by the existing service-token UI suite.

**Cannot be, today:** a working terminal session over a tunnel, and a healthy Access
diagnosis. Neither can be produced, and neither may be staged. A screenshot of something no
test has ever produced is a fabrication regardless of how it was assembled, and it would
undo the thing this rebuild was for.
