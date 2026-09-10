# Positioning — Apex Terminal

**Written:** 2026-09-10 · **Gated by:** [`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md)

Every sentence a customer will read has to survive the matrix. This document decides what
the product *is* before anyone writes a headline, so that the headlines are consequences
rather than inventions.

---

## 1 · The product name

**Apex Terminal.** Confirmed from configuration, not from documents:

| Source | Value |
| --- | --- |
| `INFOPLIST_KEY_CFBundleDisplayName` | `Apex Terminal` |
| The name drawn at the top of the app's own list | `Apex Terminal` (`App/Sources/Views/HostListView.swift:189`) |
| Bundle identifier | `dev.apexterminal.app` |
| Version audited | `0.1.0 (1)` |

Written as **two words** everywhere a person reads it. The one-word `ApexTerminal` is an
identifier — the Xcode scheme, the project file, the package directory, the `User-Agent` —
and stays one word there. `SuperTerminal` is the retired name and appears nowhere in
shipped code or resources; a grep across `App/`, `Packages/…/Sources`, `Config/` and
`FileProvider/` returns nothing. `Hiko` is the GitHub organisation, not a brand, and is
used in no customer-facing text.

## 2 · The one-sentence position

> **Apex Terminal is a full SSH workstation for iPhone and iPad: one connection carries your
> shell, your files, your remote desktop and your tunnels — and your keys never leave the
> device.**

## 3 · What actually makes it different

The previous marketing led with Cloudflare. That was wrong twice over: it is not
verifiable (§6), and it was never the strongest thing here. The audit surfaced a better
answer, and it is one competitors would find hard to copy because it is architectural.

### 3.1 · One connection, not four

Opening a shell, a file browser, a remote desktop and a port forward on the same server
costs **one** TCP connection, **one** key exchange, **one** authentication and **one**
biometric prompt. They are SSH channels on a pooled transport, not four separate logins.

*Why it matters to a person:* on cellular, four handshakes is four chances to fail and
four Face ID prompts. On a hardware key it is four touches. Here it is one.

*Evidence:* `SSHConnectionPool` — "Open four things on the same server and you pay for one
handshake, one authentication and one Face ID prompt". Verified, including the adversarial
properties: the pool never returns a connection belonging to another account and never
returns a dead one.

### 3.2 · A key that physically cannot leave the phone

An SSH key generated in the Secure Enclave has no private half outside the chip. It cannot
be exported, backed up, synced or stolen from a file — and it logs in to an **unmodified**
OpenSSH server.

*Why it matters:* every other "your keys are safe" claim in this category is really "the
key file is encrypted". This one is "there is no key file".

*Evidence:* the test puts only the public half in a real `sshd`'s `authorized_keys` and
asserts `sshd`'s own log line `Accepted publickey … ECDSA <fingerprint>`. A control case
proves the same key is refused where it was not authorised. The backup exporter names
enclave keys as unexportable rather than silently dropping them.

### 3.3 · The terminal is the product, not a text view

Sixel pictures, 24-bit colour, the alternate screen, OSC 7/52/133, DECRQM, mouse reporting
in three modes, correct CJK and emoji cell widths, reflow, block selection, scrollback
search, any monospaced font on the device — and a fuzz suite that was shown to catch a
deliberately broken invariant rather than merely passing.

*Why it matters:* this is the difference between "I can check a log" and "I can actually
work here".

### 3.4 · tmux as a protocol, not as scraped text

The app speaks tmux's own control protocol (`-C`). It draws tmux's arrangement — including
layouts the app's own splitter cannot express — and detach/reattach finds the panes with
their output still on screen.

*Why it matters:* this is what makes a phone a usable second seat at a long-running job.

### 3.5 · Nothing to sign up for, nothing measured

No account. No back end operated by this project. No analytics, no telemetry, no crash
reporter, no third-party SDK of that kind. No StoreKit, no in-app purchase, no
subscription. Each of these is Verified by grep as an *absence*, which is the only way an
absence can be proven.

## 4 · What we are not

* **Not a web terminal.** Real SSH, real PTY, in-process.
* **Not a VPN.** No Network Extension, no VPN profile, no system-wide traffic capture.
* **Not a service.** There is no Apex Terminal account and no Apex Terminal server.
* **Not a Cloudflare product.** Not affiliated with, endorsed by or connected to
  Cloudflare, Inc.

## 5 · Audience, in priority order

The full matrix is [`AUDIENCE_MATRIX.md`](AUDIENCE_MATRIX.md). In one line each:

1. **Engineers who work from an iPad** — the split panes, hardware keyboard and tmux story.
2. **DevOps / SRE on call** — reach a box from a phone at 3 a.m. without a laptop.
3. **VPS and cloud-server owners** — one app instead of a terminal plus an SFTP client.
4. **Home-lab owners** — terminal plus remote desktop plus file access to the same NAS.
5. **People inside a bastion** — ProxyJump, certificates, agent forwarding.
6. **Teams with SSH certificate authorities** — trust the CA once, no fingerprints to eyeball.
7. **Anyone who wants their keys off other people's computers** — Secure Enclave, no account.

## 6 · The Cloudflare decision — and it is a decision

**Cloudflare appears in no public claim: not in the name, the subtitle, the description,
the keywords, any screenshot, any caption, any social post or the press kit.**

Not because it is absent from the app — it is implemented, and carefully — but because it
is not verifiable today, and a claim we cannot reproduce is a claim we must not make.

What the audit established, by running the tests rather than reading about them:

* **No connection has ever been made through a live Cloudflare account.** Every passing
  Cloudflare test runs against `WebSocketCarrierTestServer`, a local server written in this
  project to reproduce the edge's wire behaviour. `LiveCloudflareE2ETests` is gated on
  `ST_LIVE_CF_HOSTNAME` and skipped when run on 2026-09-10.
* **The entire authentication half is untested.** Of 1 769 lines in `STCloudflare`, the
  carrier (~548 lines) is well covered; `AccessDiscovery`, JWKS/RS256 verification, token
  audience validation, the login transfer decryption — ~950 lines — have no test at all.
* **Three of the project's own documents overstate this.** They refer to test suites that
  do not exist. They are not quotable, and the matrix says so.

`docs/HUMAN_ACTIONS.md` H-4 names exactly what would unblock it. Until then the honest
maximal statement — *"the app implements Cloudflare's carrier protocol natively and runs a
full interactive SSH session over it with no helper binary, proven against a real `sshd`,
not against Cloudflare"* — is a sentence for App Review notes and for
[`../feature-catalog/CLOUDFLARE_OVERVIEW.md`](../feature-catalog/CLOUDFLARE_OVERVIEW.md),
not for a store listing.

When H-4 clears, the claim that becomes available is the one worth having: **connect to a
Cloudflare Access–protected host with nothing installed on the device.** It is written and
waiting in the catalogue, marked blocked.

### Trademark rules, for whenever Cloudflare is mentioned at all

* Permitted: "works with Cloudflare Access", "supports Cloudflare Tunnel".
* Forbidden: "official Cloudflare client", "Cloudflare-approved", any implication of
  partnership, endorsement or authorship.
* No Cloudflare logo or wordmark in any key visual.
* Cloudflare, Cloudflare Access and Cloudflare Tunnel are trademarks of Cloudflare, Inc.

## 7 · Claims that must never be made

| Never say | Why |
| --- | --- |
| "The fastest / most secure / only / first …" | Unprovable, and 2.3.7 forbids unverifiable claims. |
| "Connects through Cloudflare Access" | No live connection has ever been made (§6). |
| "Two-factor authentication built in" | The app relays the **server's** prompt. It stores no TOTP secret and generates no codes. |
| "Sync across your devices" | CloudKit sync is offline-verified only; H-5 is open. |
| "Stays connected in the background" | iOS does not guarantee it and neither will we. |
| "Type Chinese in the terminal" | Implemented and unit-tested; the input method itself is unverified on hardware (H-1). |
| "Runs on Mac / Vision Pro" | Catalyst builds and runs 316/324 unit tests but has no signing identity (H-8); visionOS has never been run (H-9). |
| Any user count, rating, award or ranking | There are none. |

## 8 · Tone

Quiet, exact, unhurried. The reader is a professional who has been sold to badly by this
category before. Every sentence should be one they could check.

* Prefer the concrete over the superlative: *"one handshake, one Face ID prompt"* beats
  *"blazing fast"*.
* Name the limit in the same breath as the feature. It is what makes the rest believable.
* No exclamation marks. No "seamless", "effortless", "powerful", "revolutionary".
* Chinese copy is written in Chinese, not translated from English. English copy is written
  in English. Neither is a rendering of the other.
