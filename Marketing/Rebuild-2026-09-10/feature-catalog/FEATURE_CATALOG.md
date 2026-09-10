# Feature catalogue — Apex Terminal 0.1.0

**Written:** 2026-09-10 · **Gated by:** [`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md)
and [`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md) ·
**Voice from:** [`../strategy/MESSAGING_SYSTEM.md`](../strategy/MESSAGING_SYSTEM.md)

This is the definitive list of what Apex Terminal does. The website, the store listing, a
press enquiry, a screenshot caption and the user documentation all draw from here rather
than from the source, the README or anybody's memory.

Apex Terminal is an SSH **client** for iPhone and iPad, on iOS and iPadOS 17 and later.
Commands run on the customer's own remote servers. The app has no server of its own.

**The rule this file obeys.** A capability appears in §1–§10 as something the product does
if, and only if, the truth matrix records it as Verified: the code exists, a test exercises
it against something real — a real `sshd`, a real tmux, a real VNC server, a real Keychain,
a real device family — and nothing in `docs/HUMAN_ACTIONS.md` blocks it. Everything else
that is in the binary is listed in §11, separately and plainly, with the reason it is not
advertised.

**How to read an entry.**

| Field | What it is for |
| --- | --- |
| **Value** | The sentence a customer reads. Take it whole or shorten it; do not rewrite it into a claim it did not make. |
| **Scope** | What is actually supported, in the engineer's words. Never printed alone to a customer. |
| **Use case** | One concrete situation. Not a persona. |
| **Limits** | The named limit. It travels with the feature, in the same breath, always. |
| **Security note** | Present where the feature has a security consequence, good or bad. |
| **Shot** | `SS-1`…`SS-8` from [`../app-store/SCREENSHOT_PLAN.md`](../app-store/SCREENSHOT_PLAN.md), or *none*. |
| **Evidence** | The test that would have to fail for the claim to become untrue. |
| **First screen** | Whether it belongs above the fold — a hero, a subtitle, a first screenshot — or lower down. |

Screenshots, for reference: **SS-1** a real terminal · **SS-2** one connection carrying
everything · **SS-3** two terminals on one screen · **SS-4** the server's files ·
**SS-5** tunnels with live counters · **SS-6** tmux · **SS-7** a key that cannot leave ·
**SS-8** the machine's own desktop.

---

## 1 · The connection

The architectural idea the product is built on. Four things on one server are four SSH
channels on one transport, not four logins.

### 1.1 · One connection carrying shell, files, desktop and tunnels

* **Value.** Open a shell, a file browser, a remote desktop and a port forward on the same
  server, and you pay for one TCP connection, one key exchange, one authentication and one
  biometric prompt.
* **Scope.** A pooled SSH transport. Every session type — terminal, SFTP, `direct-tcpip`
  for a forward or a remote screen, and tmux's control channel — leases a channel from the
  same connection when the connection identity matches.
* **Use case.** On call from a phone on cellular: reach the box once, then read the log,
  pull the config file down and open a tunnel to the admin port without authenticating
  again.
* **Limits.** Reuse is exact by design: a different user name, credential, jump chain or
  agent setting is a different connection, which is the point. An idle connection closes
  after 30 seconds. The device is not kept connected in the background — iOS does not
  guarantee it, and neither do we.
* **Security note.** The pool never returns a connection belonging to another account and
  never returns a dead one; both are adversarial tests, not assertions.
* **Shot.** SS-2.
* **Evidence.** `ConnectionPoolTests.reuseCostsOneHandshake` (`ConnectionPoolTests.swift:29-53`)
  counts `Accepted publickey` lines in the real `sshd`'s own log and requires exactly one
  for four leases; `differentIdentitiesAreNotShared`, `deadConnectionsAreDiscarded`,
  `ConnectionReuseTests.swift:31` (a terminal and a file browser in the app sharing one
  transport). Claim C1.
* **First screen.** Yes. This is the subtitle and the hero.

### 1.2 · ProxyJump through a bastion

* **Value.** Reach a server that is reachable through a bastion, with the far server's host
  key checked as its own rather than the bastion's.
* **Scope.** A jump is a `direct-tcpip` channel on the previous hop, chained. Each hop keeps
  its own known-hosts entry and its own credentials.
* **Use case.** A production database host inside a VPC, reachable through one jump box.
* **Limits.** The chain named on the final connection is followed; a hop's own jump list is
  ignored. Self-references and duplicates are skipped rather than reported as errors.
* **Security note.** Losing the bastion ends the session rather than degrading it, and the
  two hosts get two separate known-hosts records.
* **Shot.** none.
* **Evidence.** `JumpHostTests.swift:45` runs a command on the far server through two
  separate real `sshd` processes and asserts the recorded host key is the destination's and
  differs from the bastion's; `:75`, `:92`, `:117`; app level `AppTests/JumpHostTests.swift:72`.
  Claim C12.
* **First screen.** No. Body copy, and a strong line for the bastion audience.

### 1.3 · Reconnection after the network drops

* **Value.** When the network goes, a terminal session comes back on its own with the
  scrollback intact, and the new shell is marked so you know it is a fresh one.
* **Scope.** Ordinary terminal sessions. Network-category failures are retried with backoff;
  the app waits for the network rather than spending attempts against a dead radio.
* **Use case.** A train tunnel in the middle of `tail -f`.
* **Limits.** The new shell is genuinely new — different working directory, nothing running,
  none of the environment, and the app writes that on screen. A changed host key or a
  rejected password stops and stays on screen rather than retrying. A tmux session keeps
  running on the server, but reattaching to it is something you do, not something that
  happens.
* **Shot.** SS-1 (the session is live in it).
* **Evidence.** `ReconnectionIntegrationTests.reconnectsAfterARealDrop`
  (`AppTests/ReconnectionIntegrationTests.swift:76-117`) severs the sockets underneath the
  session through `SeverableTCPProxy` with no SSH disconnect and requires the session to
  notice, come back, still show the pre-drop output and run a new command; `:119`, `:148`,
  `:171`, `:192`. Claim C22.
* **First screen.** Yes, with its limit attached.

### 1.4 · Post-quantum hybrid key exchange

* **Value.** On servers that support it, a recorded session is protected against a quantum
  computer built later; where they do not, the connection falls back on its own.
* **Scope.** `mlkem768x25519-sha256`, preferred where both ends offer it, on iOS 26 and
  later. Classical `curve25519-sha256` otherwise.
* **Use case.** A long-lived session to a host whose traffic an adversary could record now
  and try to read later.
* **Limits.** Offered on iOS 26 and later; older systems use the classical exchange. The
  server has to offer it (OpenSSH 9.9 or later).
* **Shot.** none.
* **Evidence.** `PostQuantumKeyExchangeTests.swift:33` asserts on `sshd`'s own
  `debug1: kex: algorithm: mlkem768x25519-sha256` line and runs a command under the derived
  keys; `:65` proves the fallback when the server narrows `KexAlgorithms`. Claim C16.
* **First screen.** No. Body copy, phrased as "where the server supports it".

### 1.5 · The algorithms actually offered

* **Value.** Reaches hardened servers narrowed to the CTR family or to chacha20, and prefers
  hardware-accelerated AES-GCM otherwise.
* **Scope.** Ciphers: `aes256-gcm@openssh.com`, `aes128-gcm@openssh.com`,
  `chacha20-poly1305@openssh.com`, `aes256-ctr`. MAC offered: `hmac-sha2-256-etm@openssh.com`.
  Key exchange: `mlkem768x25519-sha256` (iOS 26+), `curve25519-sha256`,
  `curve25519-sha256@libssh.org`, `ecdh-sha2-nistp384`, `ecdh-sha2-nistp256`,
  `ecdh-sha2-nistp521`.
* **Use case.** A hardened server whose `Ciphers` line has been cut to `aes256-ctr`.
* **Limits.** That list is the whole list. There is no CBC, no arcfour, no 3DES and no
  `diffie-hellman-group*` exchange. `ssh-rsa` with SHA-1 is refused. The non-ETM
  `hmac-sha2-256` is deliberately absent, so a server narrowed to plain-MAC CTR is
  unreachable — deliberately.
* **Security note.** The refusals are the feature. A published algorithm table must be built
  from `Constants.swift:37-40`, `SSHConnection.swift:289-298` and
  `SSHKeyExchangeStateMachine.swift:580-637`, not from any prose in the repository.
* **Shot.** none.
* **Evidence.** `CipherInteropTests.swift:48` (server narrowed to `aes256-ctr` +
  `hmac-sha2-256-etm`), `:102` (chacha20), `:159` (GCM preferred when both offered), with
  400 KB pushed through each at `:59` and `:116` to prove counter and nonce stay in step.
* **First screen.** No. Documentation and the security page.

---

## 2 · Keys and authentication

### 2.1 · SSH keys generated inside the Secure Enclave

* **Value.** Create a key whose private half is made inside dedicated hardware, never exists
  outside it, and cannot be copied off the device — and log in to an ordinary, unmodified
  OpenSSH server with it.
* **Scope.** `ecdsa-sha2-nistp256`, generated in the Secure Enclave under the
  unlocked-device policy. The app holds a wrapped reference; the chip signs.
* **Use case.** A contractor's laptop is not to be trusted with a production key, and the
  phone is the credential.
* **Limits.** One curve — the enclave signs with one. Such a key cannot be backed up,
  exported, synced or moved to another device: losing the device loses the key, and the app
  says so. A reference from another device is refused.
* **Security note.** This is the strongest security statement in the catalogue and it is
  literally true: there is no key file, so there is nothing to copy. The backup exporter
  names such keys as unexportable rather than silently dropping them.
* **Shot.** SS-7.
* **Evidence.** `SecureEnclaveKeyTests.swift:24` puts the public half alone in a real
  `sshd`'s `authorized_keys` and asserts `sshd`'s own log line
  `Accepted publickey … ECDSA <fingerprint>`; `:57` is the control case, where the same key
  is refused by a server never told about it; `:95` runs `/usr/bin/ssh-keygen -l` on the
  public line the app writes and requires it to agree; `:123` refuses a foreign reference.
  App level `AppTests/SecureEnclaveAuthTests.swift:32`. Claim C2.
* **First screen.** Yes. This is pillar two and screenshot SS-7.

### 2.2 · Generating a key on the device

* **Value.** Make an Ed25519 or ECDSA P-256 key on the phone, paste the public line into a
  server, and the key still works with `ssh` and `ssh-keygen` on a laptop.
* **Scope.** The `openssh-key-v1` container, re-parsed before it is handed back.
* **Use case.** Setting up a new VPS from the phone with no laptop in reach.
* **Limits.** Ed25519 and ECDSA P-256. No RSA generation, no choice of bit length, no
  passphrase set at generation — the Keychain, not a passphrase, is what protects it on the
  device.
* **Shot.** SS-7.
* **Evidence.** `SSHKeyGenerationTests.swift:24` runs `/usr/bin/ssh-keygen -y` and `-l` and
  requires agreement on the fingerprint; `:52` authenticates against a real `sshd` trusting
  that key alone; `:89`, `:97`.
* **First screen.** No. Body copy beside 2.1.

### 2.3 · Importing a key you already have

* **Value.** Bring an existing OpenSSH private key in, with the passphrase asked for when
  the file needs one and never stored.
* **Scope.** `-----BEGIN OPENSSH PRIVATE KEY-----` containers, bcrypt KDF, single-key files.
* **Use case.** Moving a working laptop workflow onto the iPad for a week away.
* **Limits.** The `openssh-key-v1` container alone — no traditional PEM (PKCS #1), no PKCS #8, no PuTTY
  `.ppk`. Bcrypt as the KDF. Multi-key files are refused.
* **Shot.** SS-7.
* **Evidence.** `SSHIntegrationTests.swift:85` asserts `passphraseRequired` with no
  passphrase, `incorrectPassphrase` with a wrong one, then logs in to a real `sshd` with the
  right one, against a key `ssh-keygen` itself encrypted.
* **First screen.** No.

### 2.4 · Logging in with Ed25519, ECDSA P-256 and RSA keys

* **Value.** The keys people already have keep working, including on servers that offer an
  RSA host key.
* **Scope.** User keys: `ssh-ed25519`, `ecdsa-sha2-nistp256`, and RSA signed as
  `rsa-sha2-256` / `rsa-sha2-512`.
* **Use case.** An estate where half the hosts predate Ed25519.
* **Limits.** P-384 and P-521 user keys are not parsed. `ssh-rsa` with SHA-1 is refused
  deliberately. RSA keys can be used but not generated in the app.
* **Shot.** none.
* **Evidence.** `SSHIntegrationTests.swift:56` (Ed25519, reaching a real shell and running a
  command), `:71` (ECDSA P-256); `RSAInteropTests.swift:45`, `:67` (a server offering an RSA
  host key alone), `:153`, plus adversarial signature-algorithm cases at `:173`–`:227`.
* **First screen.** No.

### 2.5 · Password authentication

* **Value.** Connect to a server that takes a password, with the password kept in the
  Keychain.
* **Scope.** The `password` method, stored per connection or prompted for at connect time.
* **Use case.** A shared appliance that has no key-based login.
* **Limits.** The proof for this one is incidental to the tmux suite and is Docker-gated.
* **Shot.** none.
* **Evidence.** `TmuxIntegrationTests.swift:43` authenticates with `.password` against stock
  OpenSSH configured `PasswordAuthentication yes` and then drives a real tmux over that
  session.
* **First screen.** No.

### 2.6 · Keyboard-interactive login, including one-time codes

* **Value.** Servers with PAM, an expired password or a one-time-code prompt log in from the
  phone — the app shows the server's own prompt, in the server's own words, and passes your
  answer along.
* **Scope.** RFC 4256, multi-round, including the zero-prompt round of §3.3. Prompts with
  echo off are rendered as secure fields.
* **Use case.** A hardened jump box with `pam_google_authenticator` in the stack.
* **Limits.** The app stores no secret and generates no codes of its own. This is
  "servers with 2FA work", never "2FA built in". The proof is Docker-gated; macOS's own
  `sshd` is built without PAM and cannot stand in.
* **Security note.** Cancelling a prompt sends nothing rather than sending blanks.
* **Shot.** none.
* **Evidence.** `KeyboardInteractiveTests.swift:45` answers a real RFC 6238 code against a
  container running `pam_unix` then `pam_google_authenticator`, and reads `sshd`'s own
  `Accepted keyboard-interactive/pam` line; `:95` a wrong answer is refused; `:119` cancel
  sends no blanks. Claim C15.
* **First screen.** No, and never in the false short form.

### 2.7 · OpenSSH user certificates

* **Value.** Log in with a certificate an authority issued, so the server needs no per-user
  `authorized_keys` entry.
* **Scope.** The certificate is pasted in as its `-cert.pub` line and attached to a key. The
  app reads principals, key ID, serial, issuer fingerprint and expiry, and skips an expired
  certificate rather than burning an authentication attempt on it.
* **Use case.** A team whose CA issues short-lived certificates every morning.
* **Limits.** No fetch and no auto-renewal from a CA service.
* **Shot.** none.
* **Evidence.** `CertificateTests.swift:50` gets a key the server has never heard of into a
  real `sshd` with `TrustedUserCAKeys`, with controls at `:61` (bare key refused), `:79`
  (untrusted authority), `:96` (wrong principal), `:113` (expired), `:135` (fields read
  correctly). Claim C13.
* **First screen.** No. A headline for the certificate-authority audience specifically.

### 2.8 · Host certificates and trusted certificate authorities

* **Value.** If your organisation signs its host keys, trust the authority once and there is
  no fingerprint left to eyeball.
* **Scope.** Authorities are trusted for host patterns the user types in. The key **inside**
  the certificate is what is remembered, so a renewal does not read as a changed host key.
* **Use case.** Two hundred hosts behind one CA, and nobody comparing fingerprints.
* **Limits.** `@cert-authority` lines from an existing `known_hosts` file are not imported.
  Critical options in a certificate are not accepted.
* **Security note.** A certificate that fails validation is refused outright — it is never
  downgraded into a prompt a person can tap through.
* **Shot.** none.
* **Evidence.** `CertificateTests.swift:162` (a certified host key needs no fingerprint; the
  approval delegate fails the test if it is consulted at all), `:188`, `:210`, `:243` (a
  certificate for another host name is refused and the user is not asked). Claim C13.
* **First screen.** No.

### 2.9 · Agent forwarding, with the device as the agent

* **Value.** A `git push` on the server is signed by a key that never leaves your phone —
  including an enclave key that cannot leave it at all.
* **Scope.** `auth-agent@openssh.com`, one-directional: the device answers the server.
  `REQUEST_IDENTITIES` and `SIGN_REQUEST` are served; nothing else is.
* **Use case.** Pulling a private repository onto a server without putting a deploy key on
  it.
* **Limits.** Off unless turned on per connection. Keys already attached to that connection
  are offered, and a passphrase-protected key is skipped. iOS has no system ssh-agent, so
  this is the device answering the server, never the reverse.
* **Security note.** Adding and removing identities over the forwarded channel is refused,
  and an agent channel a server opens where forwarding is off is refused outright.
* **Shot.** none.
* **Evidence.** `AgentForwardingTests.swift:26` — OpenSSH's own `ssh-add -l`, run on a real
  `sshd`, lists the fingerprint of a key that never left the device; `:59` is the control
  (no agent when forwarding is off), `:102` a key the device does not hold is refused, `:121`
  add and remove are refused. Claim C14.
* **First screen.** No, but it is the best pairing with 2.1 in body copy.

### 2.10 · Host key verification and the hard stop on a changed key

* **Value.** The first time you reach a server, its fingerprint is put in front of you to
  check. From then on, a server whose key has changed is refused outright.
* **Scope.** Trust on first use, then match-or-refuse. A replacement can be accepted, but
  through an explicit human decision that shows both fingerprints.
* **Use case.** Noticing that the box you are about to paste a password into is not the box
  you think it is.
* **Limits.** The record is the app's own JSON file, not OpenSSH's `~/.ssh/known_hosts`:
  there is no import or export of an existing `known_hosts`, no hashed hostnames, no
  `@cert-authority` or `@revoked` lines. Trust on first use is exactly that — on the very
  first connection the app cannot tell a real server from an impostor, and the app's own
  consent screen says so.
* **Security note.** The changed-key refusal is the case most mobile clients get wrong. Here
  the stored key is not silently replaced, and the failure carries the `.hostKey` category.
* **Shot.** SS-1 (the trust prompt is on the route to it).
* **Evidence.** `SSHIntegrationTests.swift:200` boots two real OpenSSH servers, seeds the
  store with the wrong one's key, connects, and requires the failure to carry `.hostKey` and
  the stored key to be unchanged; `:235` records the server's real key and fingerprint on
  first use; app level `AppTests/AppSSHIntegrationTests.swift:128` checks the fingerprint
  shown in the sheet is the server's real one. Claim C17.
* **First screen.** Yes, on the security page.

---

## 3 · The terminal

The terminal is the product, not a text view.

### 3.1 · VT/ANSI emulation, xterm-class, with the alternate screen

* **Value.** vim, less and htop draw correctly over a real PTY, and quitting them puts your
  shell back exactly as it was.
* **Scope.** A Williams VT500 parser in which every state has a transition for every byte.
  The CSI set includes CUU/CUD/CUF/CUB/CNL/CPL/CHA/CUP/CHT/ED/EL/IL/DL/DCH/SU/SD/ECH/CBT/
  ICH/VPA/SGR/DSR/DA/DECSTBM/DECSCUSR/TBC, plus DECSC/DECRC/IND/NEL/RI/HTS/RIS and the
  keypad modes. Modes 47, 1047 and 1049 give a separate alternate screen with no scrollback.
* **Use case.** Editing an nginx config in vim from an iPad on a hotel connection.
* **Limits.** The terminal identifies itself as a VT220 with no optional extensions.
  SCS / DEC Special Graphics line-drawing charsets (`ESC ( 0`) are not implemented, so a
  program that switches into the legacy line-drawing charset instead of using Unicode box
  characters prints letters. DECALN, DECRQSS and terminfo DCS queries are discarded.
* **Shot.** SS-1.
* **Evidence.** `TUIIntegrationTests.swift:201` (vim draws, holds typed text and restores
  the shell), `:252` (less uses the alternate screen — scrollback asserted under 100 lines
  after less displayed 500), `:280` (a mid-session resize reaches vim, which reports 100
  columns), `:347`; all over a real spawned OpenSSH `sshd`. Claim C3.
* **First screen.** Yes. This is SS-1 and the opening of the description.

### 3.2 · 256 colours and 24-bit true colour

* **Value.** `ls --color`, syntax highlighting and a powerline prompt show the colours the
  program actually asked for.
* **Scope.** Both SGR spellings — xterm's `38;2;r;g;b` and `38;5;n`, and ITU T.416's colon
  form `38:2::r:g:b` with the optional colour-space id. The 6×6×6 cube and the 24-step grey
  ramp are computed, not tabulated.
* **Use case.** Reading a diff where the colour is the information.
* **Limits.** Three built-in themes — Midnight, Daylight and a High Contrast one — with a
  separate light and dark choice. There are no user-defined or importable themes. SGR 5/6
  (blink) is parsed and stored but is never drawn as blinking; DECSCNM (whole-screen reverse
  video) is tracked but never applied.
* **Shot.** SS-1.
* **Evidence.** `TerminalEmulatorTests.swift:141` asserts indexed, 256, semicolon-RGB and
  colon-RGB forms; `TerminalParserTests.swift:61` sub-parameters; heavily coloured output
  also runs the throughput floor at `TerminalThroughputTests.swift:92`.
* **First screen.** Yes, as part of C3.

### 3.3 · Sixel graphics

* **Value.** A plot from gnuplot, or an image through `img2sixel`, is a real picture on the
  phone's screen.
* **Scope.** Raster attributes, run lengths, RGB percentages and DEC's HLS colour wheel.
  The server is told `ws_xpixel` and `ws_ypixel` so a program can size its output.
* **Use case.** Glancing at a Grafana-style plot rendered on the server rather than
  downloading a PNG.
* **Limits.** A 60000×60000 raster is refused rather than attempted, and the whole image
  store is capped at 64 MiB. A width change drops pictures rather than re-slicing them —
  rotate the device and the images go.
* **Shot.** SS-1 is the natural home; a dedicated capture exists in the graphics UI run.
* **Evidence.** `SixelTests.swift:27`, `:43` decode bytes ImageMagick produced and compare
  against pixels derived from the rule that drew the original; `:57` matches DEC's HLS
  rotation against ImageMagick's own decode. `AppTests/GraphicsSessionTests.swift:64` has a
  sixel printed by a remote shell become an image occupying cells.
  `AppUITests/GraphicsUITests.swift:33` scans the app's own screenshot for the pixels —
  recorded on iPhone 17 Pro and iPad Pro 13-inch M5 in `docs/RELEASE_EVIDENCE.md:321`.
* **First screen.** Yes. It is the most photographable single fact about the terminal.

### 3.4 · Mouse reporting

* **Value.** Taps, drags and two-finger scrolling reach htop, tmux and less as real mouse
  events.
* **Scope.** Modes 1000, 1002 and 1003, in both the legacy encoding and SGR 1006, with
  modifier bits, wheel codes and drag.
* **Use case.** Killing a process in htop by tapping it.
* **Limits.** The legacy encoding reports nothing past column 223, by design — better
  silent than a click somewhere the person did not touch. The gesture layer itself has no
  UI test; what is proven end to end is the encoding and the mode negotiation.
* **Shot.** SS-1.
* **Evidence.** `MouseReportingTests.swift:20-118` (silence when off, legacy and SGR press
  and release, modifiers, wheel, motion gating, the 223-column ceiling);
  `TUIIntegrationTests.swift:313` has a remote `printf` enable 1000+1006 and a remote
  `cat -v` echo back exactly `^[[<0;10;5M`.
* **First screen.** No. Body copy, and a bullet in the store description.

### 3.5 · CJK, emoji and combining-mark cell widths

* **Value.** Chinese, Japanese and Korean text, emoji and accented Latin line up in the grid
  instead of shifting every column after them.
* **Scope.** Per-scalar and per-grapheme-cluster widths from tables generated from
  `EastAsianWidth-17.0.0.txt` and `DerivedGeneralCategory-17.0.0.txt`. ZWJ sequences, flags
  and emoji-variation selectors take two cells; base plus marks takes the base's width.
  Wide characters are never split across the margin.
* **Use case.** A Chinese-language server whose vim status line must not tear.
* **Limits.** This is display width, matching `wcwidth(3)` — a policy, not a font
  measurement. Ambiguous-width East Asian characters are treated as narrow. The tables are
  pinned to Unicode 17.0.0. **This is about widths, not about typing:** entering Chinese,
  Japanese or Korean with a system input method is in §11.
* **Shot.** SS-1.
* **Evidence.** `CharacterWidthTests.swift:17`, `:25`, `:31`, `:40`, `:49`, `:64` (tables
  sorted and disjoint, so the binary search is valid); grid behaviour at
  `TerminalEmulatorTests.swift:41`, `:53`, `:62`; and real vim over a real `sshd` at
  `TUIIntegrationTests.swift:228`, rendering 中文测试, café and 😀.
* **First screen.** Yes in Chinese-language copy, phrased as widths.

### 3.6 · Scrollback, search, and selection

* **Value.** Find the error that went by three screens ago — including when the word is
  split across a wrapped line — then select it, block-select a column out of tabular output,
  and copy it without stray newlines breaking a pasted command.
* **Scope.** A bounded ring buffer, 10 000 lines by default and configurable. Search is
  case-insensitive by default, crosses wraps, counts matches and steps next and previous.
  Selection is stored in absolute coordinates including scrollback, so it stays on its text
  as output arrives.
* **Use case.** A deploy that failed 4 000 lines ago.
* **Limits.** Plain substring matching — no regular expressions — and results are capped at
  500 by default. The alternate screen has no scrollback at all, by design. Scrollback is in
  memory, is not written to disk and is not restored across a relaunch. Copying an image
  slice copies nothing; pictures are not part of the text model.
* **Shot.** SS-1.
* **Evidence.** `TerminalTextAccessTests.swift:102`, `:112`, `:120` (crosses wraps), `:131`;
  copy at `:26` (a soft wrap does not become a newline), `:50` (block), `:63`, `:76`;
  `AppUITests/TerminalUITests.swift:445` opens the find bar against a real `sshd` and reads
  a match count; `:312` drags a selection and copies it. Claim C18 is separate; this is C3.
* **First screen.** No. A strong second-screen bullet.

### 3.7 · Any monospaced font on the device, with size and line height

* **Value.** Use any monospaced face already on your device, and the server is told the new
  grid size so full-screen programs draw to it.
* **Scope.** Every family on the device is measured — narrow, wide and space glyph within
  0.1 pt — rather than trusting the font descriptor's monospace trait. Size 8–28 pt, line
  height 0.9–1.6×.
* **Use case.** Making a 6.1-inch screen readable at arm's length on a night shift.
* **Limits.** Faces already installed on the device; there is no font import or download.
  The picker offers families, not individual weights. Ligatures are off by default and are
  opt-in, because a font that draws `!=` as one glyph draws two grid cells as one.
* **Shot.** none.
* **Evidence.** `AppTests/TerminalFontTests.swift:14`, `:29`, `:40`, `:50`, `:59`, `:73`;
  and through the interface to a real server, `AppUITests/FontUITests.swift:32` reads the
  remote `stty size`, raises the line height eight steps and requires the server's row count
  to have fallen. Claim C20.
* **First screen.** No.

### 3.8 · OSC 7 and OSC 133 — working directory and shell marks

* **Value.** Panes are labelled by the directory they are actually in, a new pane can start
  where the last one was, and the app knows where a command began and what it exited with.
* **Scope.** OSC 7's `file://` URL, percent-decoded, capped at 4096 characters, control
  characters refused. OSC 133's four FinalTerm marks A/B/C/D, with D's exit status optional.
* **Use case.** Splitting a pane and landing in the same deployment directory.
* **Limits.** The host component of the OSC 7 URL is deliberately not checked, and is used
  to label a pane and to open a pane in the same place — never for a trust decision. OSC
  133's optional key=value fields are ignored, and what is proven is the mark and the exit
  code, not a particular affordance built on them.
* **Shot.** SS-1, SS-3.
* **Evidence.** `ShellIntegrationTests.swift:20`, `:27`, `:37`, `:49`, `:60`; against a real
  `sshd` with a real shell emitting them, `AppTests/ShellIntegrationSessionTests.swift:74`
  (working directory) and `:124` (`shellIntegration` flips and `lastExitCode == 3`).
* **First screen.** No.

### 3.9 · OSC 52 — the clipboard, one way, behind a permission

* **Value.** A yank in remote vim can reach your clipboard once you allow it — and a program
  on the server can never read what you have copied.
* **Scope.** Writes are reported by the emulator and performed by the app if, and after, the
  person turns the setting on. A read request (`OSC 52;c;?`) is refused outright and is not
  even reported back to the remote program. Payloads are capped at 64 KiB and base64 is
  validated.
* **Use case.** Copying a generated token out of a remote shell without retyping it.
* **Limits.** Off by default, with the refusal explained once per session. The setting is
  per app, not per server.
* **Security note.** The refusal of the read half is permanent and holds regardless of the
  setting. This is the point: the generous reading of "clipboard support" is that a server
  can also read. Here it cannot.
* **Shot.** none (it is a setting, not a picture).
* **Evidence.** `ShellIntegrationTests.swift:70`, `:77` (a read is refused and not
  reported), `:91`; against a real `sshd` with the real pasteboard,
  `AppTests/ShellIntegrationSessionTests.swift:89` asserts `UIPasteboard.general.string` is
  untouched, and `:108` asserts the same write lands once allowed. Claim C18, proof point P9.
* **First screen.** Yes, on the security page.

### 3.10 · Bracketed paste and multi-line paste confirmation

* **Value.** Pasting several lines asks before anything runs, and where the shell supports
  it the paste is bracketed so the shell knows it was pasted.
* **Scope.** Mode 2004, wrapping the paste in `ESC[200~ … ESC[201~`. Any text containing a
  newline or a bare carriage return triggers the confirmation, whether pasted or dropped.
* **Use case.** Dropping a block of six commands into a production shell by accident.
* **Limits.** Bracketed-paste mode does not suppress the confirmation, on purpose. The
  decision function is exhaustively tested; the sheet appearing in front of a live shell is
  not covered by a UI test.
* **Shot.** none.
* **Evidence.** `AppTests/PasteAndSearchTests.swift:17-63` covers every branch, and `:120`
  proves a drop takes the same path; mode negotiation at `TerminalEmulatorTests.swift:212`.
* **First screen.** No. A good security-page paragraph.

### 3.11 · Robustness against hostile or corrupt output

* **Value.** `cat` a binary file, or connect to a server sending garbage, and the terminal
  shows nonsense text — it does not hang, corrupt itself or run out of memory.
* **Scope.** Hard caps: 8 KiB strings, 4 MiB for pictures, 32 parameters, 4 intermediates,
  64 KiB on the answer-back a single write can produce. Parameters saturate rather than
  overflow. The UTF-8 decoder resynchronises on the next lead byte.
* **Use case.** A misbehaving log shipper writing raw bytes into a shared terminal.
* **Limits.** Seeded xorshift fuzzing with the seeds written into the test — reproducible
  rather than exhaustive. This is fuzzing, not proof. Over-long OSC/DCS strings are dropped
  entirely rather than truncated, so a picture larger than 4 MiB does not appear.
* **Security note.** The suite was shown to be able to fail: deleting the cursor clamp in
  `TerminalScreen.moveCursor` made it die with "Index out of range"
  (`docs/RELEASE_EVIDENCE.md:212-219`).
* **Shot.** none.
* **Evidence.** `FuzzTests.swift:45`, `:68`, `:103` (resizing while fed), `:138`; after every
  step the screen is still its declared size, every line that width, the cursor inside it,
  scrollback within its limit and images within budget. Proof point P7.
* **First screen.** No. Excellent press material.

### 3.12 · Throughput and frame time, measured

* **Value.** A burst of output — a big build log, `seq 1 20000` — is consumed and drawn
  without the terminal falling behind.
* **Scope.** Floors that fail the build on regression: 7 MB/s plain text, 15 MB/s heavily
  coloured, 7 MB/s CJK in a Release build, one fifth of each in Debug; a full redraw under
  16.6 ms at 80×24 and 200×55.
* **Use case.** `journalctl -f` on a busy host.
* **Limits.** **Quote the floors, not a headline number.** The emulator figures are measured
  by `swift test` on an Apple silicon Mac, and the render frame-time assertion runs in the
  iOS Simulator on a Mac. Nothing here was measured on an iPhone, and no MB/s figure appears
  in `docs/RELEASE_EVIDENCE.md`. Never attach a throughput number to the words "on iPhone".
* **Shot.** none.
* **Evidence.** `TerminalThroughputTests.swift:41`, `:92`, `:117`, `:134`, `:147`;
  `AppTests/RenderPerformanceTests.swift:64`, `:72`, `:106`; a real burst over a real `sshd`
  at `TUIIntegrationTests.swift:300`, with scrollback asserted bounded.
* **First screen.** No. Do not put a number on a screenshot.

---

## 4 · Files, over the same connection

### 4.1 · SFTP on the SSH connection

* **Value.** Your server's files are listed, read, written, renamed and deleted over the
  same connection as the terminal — no second sign-in, no second password.
* **Scope.** SFTP protocol version 3, 32 KiB chunks, request-id correlation, atomic rename,
  symbolic-link resolution, paged listings.
* **Use case.** Pulling `/etc/nginx/nginx.conf` down, editing it, and putting it back.
* **Limits.** Version 3 by design: a server offering less is refused, one offering more is
  used at 3. Creating a symbolic link is not exposed. The integration harness spawns a real
  `sshd` and runs on the Mac host, not on an iOS device.
* **Shot.** SS-4.
* **Evidence.** `SFTPIntegrationTests.swift` — seven tests against OpenSSH's own
  `internal-sftp`: `:54` handshake and realpath, `:62` write/read/list, `:99` multiple
  chunks, `:138` large listings, `:161` atomic rename, `:190` missing file, `:202` symbolic
  links; recorded in `docs/RELEASE_EVIDENCE.md:1523`. Claim C4.
* **First screen.** Yes. "Files, without a second app" is a first-screen section.

### 4.2 · Browsing a server's files in the app

* **Value.** Open any saved connection's files and see the real directory — name, size,
  modified date and permission string per row, a breadcrumb path bar, pull to refresh, and
  an "up one level" action.
* **Scope.** The app's own browser, a session of its own on the shared transport.
* **Use case.** Checking whether last night's backup actually wrote.
* **Limits.** The app's browser and the system Files view do not stay in step
  automatically — a pull-to-refresh is needed. The browser's upload reads the whole local
  file into memory. Transfers stop when iOS suspends the app; there is no background
  transfer.
* **Shot.** SS-4.
* **Evidence.** `AppUITests/FileBrowserUITests.swift:26` drives the real interface against
  the harness's own `sshd` and requires a real listing or the empty-folder state;
  `AppTests/ConnectionReuseTests.swift:67` connects a real SFTP session and lists a real
  directory. Claim C4.
* **First screen.** Yes, as SS-4.

### 4.3 · Several remote folders open at once

* **Value.** Two file browsers at the same time — the same server twice, or two different
  servers — and on an iPad, side by side.
* **Scope.** Each browser is its own session, listed under "Open file browsers", closable on
  its own, and able to live in a pane.
* **Use case.** Copying a config from staging to production, with both open.
* **Limits.** Side by side needs an iPad-sized pane layout; on a phone they are pushed one
  at a time. Dragging a file from one browser to the other is not a server-side move and has
  no test — it would be a download and a re-upload.
* **Shot.** SS-4.
* **Evidence.** `AppUITests/FileBrowserTabsUITests.swift:45` opens two against a real
  `sshd`, requires both to reach a real directory, closes one and requires the other to
  survive; `AppTests/MultipleFileBrowsersTests.swift:31`, `:71` (two in panes). Claim C4.
* **First screen.** Yes, on the iPad story.

### 4.4 · The remote file operations behind the Files integration

* **Value.** Enumerating a folder, downloading a file, uploading or overwriting one, making
  a folder, renaming, moving and deleting all really happen on the server.
* **Scope.** The library the system extension forwards to, exercised directly against a real
  server. Writes are commit-by-rename.
* **Use case.** Editing a remote file in another app and saving it back.
* **Limits.** This is proof of the library, not proof that the system's Files machinery
  serves those answers on a device — see §11 for that distinction, which matters. Overwriting
  is remove-then-rename, because version 3's RENAME refuses to clobber, so there is a brief
  window where the old name is gone — the same window `mv` has.
* **Shot.** none.
* **Evidence.** `DomainFileSystemTests.swift` — thirteen tests against a real OpenSSH
  `internal-sftp`, each checking the server's own filesystem rather than the client's
  opinion: `:183`, `:200`, `:227`, `:246`, `:266`, `:278`, `:295`, `:312`, `:333`, `:348`,
  `:363`.
* **First screen.** No.

### 4.5 · An interrupted upload lands whole, once, with nothing left behind

* **Value.** If the network dies mid-upload, the file still lands complete and the server is
  not left with a half-written temporary file.
* **Scope.** One retry, a fresh temporary name each attempt, the dead attempt's file removed
  over the next connection, and the local file re-read from the start.
* **Use case.** Uploading a 24 MB archive on a train.
* **Limits.** This is a restart, not a resume: the second attempt sends the file from byte
  zero. Exactly one retry, and for a dropped connection — a refusal is not retried. Never
  write "resumable transfers"; resuming from an offset is a deliberate refusal, written into
  the code, because SFTP has no notion of a partial upload the server will remember. What is
  true is that a running transfer can be paused and resumed.
* **Shot.** none.
* **Evidence.** `AppTests/FileProviderRetryTests.swift:33` severs a real TCP connection in
  the middle of a real 24 MB upload, observes the restart through KVO on `Progress`, then
  compares the server's own disk byte-for-byte and requires no leftovers.
  `docs/RELEASE_EVIDENCE.md:1484` records the defect this test found and four clean runs
  after it. Proof point P10.
* **First screen.** No. A very good press paragraph.

### 4.6 · Publishing a connection as a Files location

* **Value.** A switch in the connection's own editor registers that server with the system,
  and turning it off — or deleting the connection — takes it away again. When the switch
  cannot be turned on, the footer says which of the three conditions is missing.
* **Scope.** Registration and withdrawal of the domain, and the reason shown when it is not
  possible. The three conditions are a user name, an already-approved host key, and a
  credential that works with nobody present.
* **Use case.** Putting a build server where any app that opens documents can reach it.
* **Limits.** **Registration is what is verified. What the system then does with the domain
  on a device is not** — that step needs a physical device and is listed in §11. Do not
  photograph Apple's Files app as though it were a photograph of this app; the screenshot is
  the switch in the connection editor. The switch is absent on a Mac, where the replicated
  File Provider API is unavailable, and the app says so instead of showing a dead control.
* **Security note.** The background extension never asks anyone anything: it refuses an
  unknown or changed host key rather than trusting it, refuses a credential that needs a
  person present, and holds no secret in the record it shares.
* **Shot.** SS-4 (the `files-domain-toggle` switch).
* **Evidence.** `AppTests/FileProviderDomainTests.swift:156` runs in the app host with the
  real entitlements and asserts the system registered the domain and that turning it off
  removes it; `:227` deleting withdraws it; `:39` the real App Group container exists.
  Refusals: `DomainFileSystemTests.swift:111`, `:148`; `FileProviderDomainTests.swift:51`,
  `:59`, `:77`, `:99`, `:131`. Claim C4.
* **First screen.** No, and not as a photograph of Files.

### 4.7 · No trash, no undo, and fields SFTP cannot carry are reported as unapplied

* **Value.** Delete says Delete, because a server has no trash to move a file to — and tags,
  favourites and creation dates are handed back as not applied rather than silently dropped.
* **Scope.** The extension's declared capabilities and its unsupported-fields reply. Every
  SFTP failure maps to an error the system can act on.
* **Use case.** Knowing that a deletion on a server is a deletion.
* **Limits.** Verified as library behaviour. A folder must be empty before it can be
  deleted, since SFTP has no recursive remove, and the app says so in the confirmation.
* **Shot.** none.
* **Evidence.** `FileProviderUnitTests.swift:159` ("No trash on a server: offering it would
  promise an undo that does not exist"), `:187`, `:130`.
* **First screen.** No. A good line about honesty in documentation.

---

## 5 · Tunnels

### 5.1 · Local port forwarding (`ssh -L`)

* **Value.** Point a port on your iPhone or iPad at a database or an internal API the server
  can reach, and use it as if it were running on the device.
* **Scope.** Binds the port, accepts, opens a `direct-tcpip` channel and splices. A service
  that speaks first is not truncated.
* **Use case.** Opening a Postgres port on the iPad and querying it from a client app.
* **Limits.** Binds 127.0.0.1, deliberately — never the Wi-Fi address, so nothing else on
  the network can use it, and the device does not become a gateway. The forward lives as
  long as the app is running and on screen: iOS suspends a backgrounded app and the tunnel
  stops with it, and the app says so in the forwards screen. This is TCP forwarding, not a
  VPN.
* **Shot.** SS-5.
* **Evidence.** `ForwardingIntegrationTests.localForwardCarriesBytes:89-112` (a real socket
  to a real `sshd` to a real echo service, bytes compared) and `greetingIsNotLost:114-147`.
  Claim C6.
* **First screen.** Yes. SS-5 is a first-screen candidate.

### 5.2 · Remote port forwarding (`ssh -R`)

* **Value.** Ask the server to listen on a port and hand whatever connects there back to
  something running on your device.
* **Scope.** The global request, the port the server reports back, the onward local
  connection and the splice. Port 0 lets the server choose, and the app reports what it
  bound.
* **Use case.** Letting a colleague on the server hit a preview build running on the iPad.
* **Limits.** The server has to allow it — `AllowTcpForwarding`, and `GatewayPorts` for any
  bind wider than 127.0.0.1. A refusal says which setting to look at, but the app cannot
  change the server's mind.
* **Shot.** SS-5.
* **Evidence.** `ForwardingIntegrationTests.remoteForwardDeliversConnections:191-219` and
  `cancelledRemoteForwardStops:222-249`, against a real `sshd`. Claim C6.
* **First screen.** No.

### 5.3 · Dynamic forwarding — a SOCKS5 proxy on the device (`ssh -D`)

* **Value.** Run a SOCKS5 proxy on the device and send an app's traffic out through the
  server; apps you can point at a proxy can use it.
* **Scope.** RFC 1928, CONNECT, no authentication.
* **Use case.** Reaching an internal wiki that is allowed from the server's address.
* **Limits.** CONNECT alone, and no-authentication alone, deliberately: BIND and UDP
  ASSOCIATE are refused with 0x07, and an authentication-only client gets 0xFF. iOS has no
  system-wide SOCKS setting, so apps that let you name a proxy can use it and others cannot.
  The IPv4 destination form is what a test exercises; the hostname and IPv6 forms are code
  without proof, so do not write "proxy any destination".
* **Shot.** SS-5 (the forward editor shows that a SOCKS rule asks for no destination).
* **Evidence.** `ForwardingIntegrationTests.dynamicForwardSpeaksSOCKS5:253-283` completes a
  full RFC 1928 handshake and tunnels bytes through a real `sshd`;
  `dynamicForwardRefusesBind:285`, `dynamicForwardRefusesAuthOnly:303`. Claim C6.
* **First screen.** No.

### 5.4 · Rules saved on a connection and started with it

* **Value.** A forward you saved with a connection is already up by the time the terminal
  is.
* **Scope.** Rules are objects on the connection; auto-start runs as part of connecting.
  They can also be started and stopped by hand from the session.
* **Use case.** Every session to the staging box needs the same two tunnels, every time.
* **Limits.** Traffic counters move while the forwards screen is open — nothing pushes them
  from behind. A forward coming back by itself after an automatic reconnect is not covered
  by a test, so do not write "tunnels survive a network drop".
* **Shot.** SS-5.
* **Evidence.** `AppTests/PortForwardingTests.swift:130-159` forwards to the test server's
  own `sshd` port and asserts the real `SSH-2.0-` banner comes back, with
  `totalConnections == 1` and `bytesIn > 0`; `:161`; `AppUITests/PortForwardUITests.swift:36`
  taps it in the simulator against a seeded real server. Claim C6.
* **First screen.** Yes, as part of SS-5.

### 5.5 · Byte and connection counters per rule

* **Value.** Each forward shows bytes out, bytes in, how many connections are open now and
  how many it has carried.
* **Scope.** Accounting on both halves of the splice, per rule.
* **Use case.** Telling at a glance whether the tunnel is the problem or the service is.
* **Limits.** Counts are per rule and reset when a rule is started. They are not persisted.
* **Shot.** SS-5.
* **Evidence.** `ForwardingIntegrationTests.localForwardCarriesBytes:106-110` asserts
  `bytesOut`, `bytesIn` and `totalConnections`; `AppTests/PortForwardingTests.swift:153`.
  Claim C6.
* **First screen.** Yes. The counters are what make SS-5 worth photographing.

### 5.6 · A forward that cannot start says why, and names the port

* **Value.** "Port 8080 on this device is already in use", with a suggested fix — not a
  silent failure and not an error code.
* **Scope.** Address-in-use, ports below 1024, and a fallback, each rendering the port as
  text rather than as a formatted number. The editor refuses to save a rule that cannot
  work.
* **Use case.** Two rules that both want 8080.
* **Limits.** The below-1024 message is written but no test binds a privileged port to
  produce it.
* **Shot.** SS-5.
* **Evidence.** `ForwardingIntegrationTests.portInUseIsExplained:149-171` binds the port
  first and asserts the message names it and carries a recovery suggestion;
  `AppTests/PortForwardModelTests.swift:14`. Claim C7.
* **First screen.** No. A good detail for the tunnels section.

### 5.7 · Forwards never outlive their connection

* **Value.** Disconnect and every forward stops and gives its port back — nothing goes on
  claiming to be running over a connection that is gone.
* **Scope.** Teardown on disconnect, with the listening socket released.
* **Use case.** Restarting a session without hunting for what is still holding 5432.
* **Limits.** None known.
* **Security note.** A stale listener on a device is a way in. There is not one.
* **Shot.** none.
* **Evidence.** `ForwardingIntegrationTests.stoppingFreesThePort:173-187` restarts on the
  very port just held; `AppTests/PortForwardingTests.swift:184-208` asserts the forward
  states are empty and that something else can bind the port.
* **First screen.** No.

---

## 6 · tmux

### 6.1 · tmux spoken as a protocol

* **Value.** The app speaks tmux's own control protocol, so the panes on screen are tmux's
  own arrangement rather than text scraped off a screen.
* **Scope.** Control mode (`-C`): reply and notification demultiplexing, layout parsing with
  tmux's own 16-bit checksum, `%output` routed to the right pane, a refused command reported
  in tmux's own words with the session surviving.
* **Use case.** Driving a long-running job from a phone that was set up from a laptop.
* **Limits.** Measured against **tmux 3.3a** in a Debian container — that version is named
  because it is the version that was run; no other has been tested. `-C`, not `-CC`, so
  there is no pseudo-terminal on the control channel. The integration suite needs Docker.
* **Shot.** SS-6.
* **Evidence.** `TmuxIntegrationTests.swift:85`, `:112`, `:138` (a split produces a
  checksum-valid two-pane layout), `:174`, `:204`; plus 21 offline parser and session tests
  and `TmuxLayoutTests.swift:45` refusing bad checksums.
  `docs/RELEASE_EVIDENCE.md:716` records 34 STTmux tests passing six runs in a row.
  Claim C8, proof point P11.
* **First screen.** Yes. SS-6.

### 6.2 · Attach to tmux instead of a plain shell

* **Value.** Turn on "Attach to tmux" for a connection and opening it puts you inside a
  named session — created the first time, joined every time after.
* **Scope.** `tmux -C new-session -A -s <name>` on connect, one session per connection.
* **Use case.** Every connection to the build host lands in the same named session.
* **Limits.** Requires tmux installed and on the PATH for that account; where it is missing
  the app says so rather than dropping you into a shell. The app's own split (⌘D) is not
  offered inside a tmux session — two things deciding one layout would fight.
* **Shot.** SS-6.
* **Evidence.** `AppTests/TmuxSessionTests.swift:122-215` builds the app's own session
  against a real tmux over a real SSH connection, approves the container's unseen host key
  the way a person would, reaches `.attached` and gets a window with a pane and a terminal;
  `AppUITests/TmuxUITests.swift:18-63` does it through the interface. Claim C8.
* **First screen.** Yes, as part of SS-6.

### 6.3 · Detach, come back, and the panes are still there

* **Value.** What is running keeps running when you disconnect. Attach again and the panes
  come back with their output on screen, not blank.
* **Scope.** Attaching primes state with `list-windows`, then seeds each new pane's terminal
  once with `capture-pane -p -e -J -S -2000`, keeping colours and rejoining wrapped lines.
* **Use case.** Starting a migration from the desk, watching it from the platform.
* **Limits.** Seeded history is 2 000 lines; anything older is not brought over. Scrolling a
  tmux pane is local scrolling over those seeded lines, **not** tmux copy mode — so do not
  write "full tmux scrollback" or "search your tmux history". A tmux session keeps running
  on the server when a connection drops, but the app does not reattach on its own; opening
  the connection again is something you do.
* **Shot.** SS-6.
* **Evidence.** `TmuxWorkspaceTests.reattachSeesExistingWindows:109-138` finds a session
  with two windows and a split created before the client existed;
  `reattachShowsExistingContents:140-172` requires text printed before this client attached
  to be on screen after attaching. Claim C8.
* **First screen.** Yes, with the reattach limit in the same sentence.

### 6.4 · tmux's own layout on screen, and tmux's own commands in the toolbar

* **Value.** The panes are laid out where tmux says — including arrangements the app's own
  splitter could not express — and the toolbar lists windows, makes new ones, splits, closes
  a pane and detaches.
* **Scope.** Panes placed from tmux's own cell rectangles; `refresh-client -C` tells tmux the
  view's size in cells. Keystrokes reach a pane through `send-keys -H`, chunked so a paste is
  not one oversized command line.
* **Use case.** A four-pane layout built on a workstation, opened as it is on an iPad.
* **Limits.** Pane geometry is proportional to the tmux cell grid, so a small phone window
  gives tmux few cells to work with. The typing tests send ASCII with a newline; multi-byte
  UTF-8 through `send-keys -H` is byte-for-byte hex but is not separately exercised.
* **Shot.** SS-6.
* **Evidence.** `TmuxWorkspaceTests.splittingAddsAPane:174-209`, `.resizing:265-297` (tmux
  resizes the window to 132×43 and it stays), `.inputAndOutputRoundTrip:241-262`;
  `TmuxIntegrationTests.splittingChangesTheLayout:138-172`;
  `AppUITests/TmuxUITests.swift:51-62` taps Split Right and waits for the second pane.
* **First screen.** Yes, as SS-6.

---

## 7 · Remote screens

### 7.1 · Remote desktop over VNC/RFB, spoken natively

* **Value.** See and drive a machine's desktop in the same app as your terminals, without a
  wrapped third-party viewer.
* **Scope.** RFB 3.8, decoded in Swift. A screen is its own saved connection with its own
  editor, address, port, optional account name and optional password, so several screens can
  sit behind one bastion.
* **Use case.** A home-lab NAS whose web interface needs a desktop browser.
* **Limits.** Verified against one server implementation — LibVNCServer serving a 320×200
  pattern on loopback. Commercial and proprietary servers have not been connected to, so
  "works with any VNC server" is not supportable. RFB 3.8 is what is exercised; the 3.3 and
  3.7 paths have no test.
* **Shot.** SS-8.
* **Evidence.** `VNCClientTests.swift:28` runs one case per encoding set against a real
  LibVNCServer process and checks five known pixels; 32 tests in 5 suites passed on
  re-run in the audit. `AppTests/ScreenConnectionTests.swift:16`, `:98`, `:141`;
  `AppUITests/VNCUITests.swift:90`, `:122`. Claim C9.
* **First screen.** Yes. SS-8 carries breadth: terminal and desktop, one app.

### 7.2 · A screen reached through the SSH connection

* **Value.** Open a desktop that is behind a bastion, with nothing exposed to the internet
  and the picture travelling inside SSH's encryption.
* **Scope.** `direct-tcpip` on the existing SSH connection, the way `ssh -L` works.
* **Use case.** A Linux workstation on a private subnet, reachable through the same box you
  already have a shell on.
* **Limits.** In the proving run both ends are on one machine over loopback, with a real
  OpenSSH server in the path but no bastion and no remote network.
* **Security note.** This is the route to recommend. On a direct route, RFB carries the
  framebuffer in the clear and the app says so in the editor.
* **Shot.** SS-8.
* **Evidence.** `AppUITests/VNCUITests.swift:43` runs a real LibVNCServer behind a real
  local OpenSSH server, asserts the decoded value `ApexTerminal test desktop, 320 × 200`,
  and finds "client connected" in the server's own log; recorded on iPhone 17 Pro and iPad
  Pro 13-inch M5 in `docs/RELEASE_EVIDENCE.md:16-17`. Claim C9.
* **First screen.** Yes, as the SS-8 caption.

### 7.3 · Encodings, and incremental updates

* **Value.** The picture is correct whichever of the common encodings the server picks, and
  after the first frame what changed is what comes down.
* **Scope.** ZRLE, Hextile, RRE and Raw, decoded pixel-for-pixel. The first update is
  non-incremental; every one after it is incremental.
* **Use case.** Watching a progress dialog on a remote desktop over a phone connection.
* **Limits.** Tight, JPEG, TRLE and zlib are not implemented at all — a server configured to
  offer those alone will not draw. Say the encodings; the named list is more useful than the
  word "any". Bandwidth and latency on a cellular link have not been measured, and the client
  re-requests on every completed frame with no adaptive throttle.
* **Shot.** SS-8.
* **Evidence.** `VNCClientTests.swift:28` (per-encoding cases against LibVNCServer), `:48`
  (a toggling square arrives as incremental updates and lands where it should, with pixels
  outside it untouched); corner cases at `RFBDecoderTests.swift:19`, `:47`, `:61`, `:98`.
  Claim C9.
* **First screen.** No. The encoding list belongs in the sentence that carries the limit.

### 7.4 · Signing in to a screen

* **Value.** Connects to the ordinary password-protected VNC servers people already run, and
  says clearly when the password is wrong. A server with no password just opens.
* **Scope.** Classic VNC Authentication (the DES challenge), and the None security type.
* **Use case.** A LibVNCServer or x11vnc instance on a home-lab box.
* **Limits.** DES-challenge authentication is weak by design and RFB carries the framebuffer
  in the clear, which is why the SSH route exists and why the app says so in the editor.
  Eight characters of a password are what count. Signing in with a macOS Screen Sharing
  account, and VeNCrypt, are in §11.
* **Security note.** The password lives in the Keychain under the screen's id, never in the
  record.
* **Shot.** none.
* **Evidence.** `VNCClientTests.swift:69` against a real password-protected LibVNCServer:
  the right password connects, a wrong one throws, no password throws
  `.passwordRequired`; DES pinned to FIPS 46-3 known answers at `RFBDecoderTests.swift:186`.
* **First screen.** No.

### 7.5 · Touch and the on-screen key row

* **Value.** Tap the screen and the remote gets a real mouse press and release where you
  tapped; send the keys a touch keyboard has no way to type, and build chords by latching a
  modifier first.
* **Scope.** Esc, Tab, arrows, Home/End, PgUp/PgDn, Del, and latching Ctrl/Alt/Shift/Super.
  Your clipboard can be sent to the remote.
* **Use case.** Ctrl+Alt+F2 on a machine whose desktop session has hung.
* **Limits.** A single-finger tap and two key cases — Escape, and Ctrl latched before Tab —
  are what a test drives end to end; the rest of the row is the same code path. RFB cut text
  is Latin-1, so text sent to the remote does not carry CJK or emoji. Trackpad, mouse and
  hardware-keyboard input on iPad are in §11.
* **Shot.** SS-8.
* **Evidence.** `AppUITests/VNCUITests.swift:67-85` — tapping the Escape key produces
  `key down 0xff1b` / `key up 0xff1b` in the real server's log, and latching Ctrl then
  tapping Tab produces Control down before Tab down and Control up after; `:63-65` a tap
  produces `pointer 1` then `pointer 0`. Clipboard to remote at `VNCClientTests.swift:100`.
* **First screen.** No. The key row is worth being visible in SS-8.

---

## 8 · iPhone and iPad

### 8.1 · Split panes

* **Value.** Watch a log in one half of the iPad while you work in the other. Each pane is a
  full session with its own controls.
* **Scope.** A pane tree — split, close, focus, resize — drawn recursively, with tap to
  focus and a focus border.
* **Use case.** `tail -f` on the left, the deploy on the right.
* **Limits.** Splitting with ⌘D opens another shell on the same server, never an empty pane.
  A tmux pane cannot be split by the app; tmux owns its own arrangement. On iPhone the panes
  share one navigation bar and the focused pane fills it, so the two-pane phone layout is
  cramped by design — the iPhone story is several sessions and fast switching, not panes.
* **Shot.** SS-3 (iPad).
* **Evidence.** `AppUITests/TerminalUITests.swift:141-190` drives the real Session menu
  against a real `sshd`, asserts the pane count reads 2 with two live terminals, then closes
  back to 1; recorded on iPhone 17 Pro and iPad Pro 13-inch M5 in
  `docs/RELEASE_EVIDENCE.md:16-17`. Model coverage: `AppTests/PaneLayoutTests.swift:19-180`.
  Claim C10.
* **First screen.** Yes, on the iPad page and as SS-3.

### 8.2 · A divider you can drag, that cannot swallow a pane

* **Value.** Give one pane more room by dragging the divider — and it can never be dragged
  so far that a pane disappears and becomes impossible to close.
* **Scope.** An 8 pt line with a 44 pt hit area, clamped to between 0.15 and 0.85, with a
  VoiceOver-adjustable action.
* **Use case.** Two thirds for the editor, one third for the log.
* **Limits.** The divider is asserted present and accessible; no automated test drags it.
* **Shot.** SS-3.
* **Evidence.** `AppTests/PaneLayoutTests.swift:148-168` (0.0 clamps to 0.15, 1.0 to 0.85);
  `AppUITests/TerminalUITests.swift:177-179` asserts the divider element is on screen after
  a real split. Claim C10.
* **First screen.** No.

### 8.3 · Each pane on iPad carries its own toolbar

* **Value.** On iPad each half of a split is a complete session with its own controls, so it
  is never ambiguous which pane a command acts on.
* **Scope.** A per-pane toolbar contribution on regular width; one shared bar on compact.
* **Use case.** Finding in the left pane while the right one keeps printing.
* **Limits.** The iPad half of that assertion ran on iPad Pro 13-inch M5. Nothing asserts it
  in a narrow iPad window, where the compact branch applies.
* **Shot.** SS-3.
* **Evidence.** `AppUITests/TerminalUITests.swift:168-175` asserts exactly one session menu
  on the phone idiom and exactly two otherwise, in the same real-`sshd` run that produced
  the split. Claim C10.
* **First screen.** No.

### 8.4 · Several live sessions, and typing that follows the one you are looking at

* **Value.** Keep several servers connected and move between them; what you type always goes
  to the terminal you are looking at.
* **Scope.** Open sessions, screens and file browsers are rows in the sidebar list, reached
  by tapping, by ⌘1–⌘9, or by ⌘⇧[ and ⌘⇧].
* **Use case.** Three hosts during an incident, on a phone.
* **Limits.** **There is no tab bar in this app.** The vocabulary is "sessions in a sidebar
  list" and "split panes"; a reader who is told "tabs" will look for a tab strip and file its
  absence as a missing feature. Both proving tests use two sessions to the same seeded
  server, and no ceiling on concurrent sessions has been measured.
* **Shot.** SS-2, SS-3 (the iPhone subject).
* **Evidence.** `AppUITests/ZZClaimProbeUITests.swift:52-90` opens two real SSH sessions,
  writes a distinct marker into each, taps back to the first and asserts the first shell's
  output returns and new typing lands there;
  `AppUITests/HardwareKeyboardStateUITests.swift:109-132` proves the same without asking for
  a software keyboard. Claim C11.
* **First screen.** Yes, as the iPhone half of SS-3.

### 8.5 · A second window on iPad

* **Value.** Put a session in its own window beside another app, or beside another Apex
  Terminal window.
* **Scope.** "Open in New Window" on iPad, each window carrying its own selection.
* **Use case.** Notes on the left, a shell on the right.
* **Limits.** iPad only — iPhones do not offer multiple windows. The proving test shows a
  second scene exists and shows the session; it does not drive both windows at once, so
  nothing asserts the two windows show different things on screen.
* **Shot.** none (SS-3 is the split-pane story).
* **Evidence.** `AppUITests/TerminalUITests.swift:1047-1101` reads the scene-count probe
  before and after and asserts it increases; the iPad suite reports one more passing test
  than the iPhone suite, consistent with this being the iPad-only case. Claim C10.
* **First screen.** No.

### 8.6 · One app, iPhone and iPad, iOS and iPadOS 17 and later

* **Value.** One app for both, with nothing to buy twice.
* **Scope.** Device family 1 and 2, deployment target 17.0. The full UI suite runs on both
  families as a gate.
* **Use case.** Buying nothing, installing once, using it on both.
* **Limits.** One iPhone model and one iPad model are actually exercised — iPhone 17 Pro and
  iPad Pro 13-inch M5. Mac and Vision Pro are in §11 and must not be claimed. Hardware
  keyboard support is real but narrower than it looks: ⌘K, ⌘N, ⌘/, ⌘, and ⌘F have been sent
  as real keys by a test, and the split and session-switching shortcuts are unit-tested for
  the table and the routing but have never been pressed by one.
* **Shot.** every shot, implicitly.
* **Evidence.** `TARGETED_DEVICE_FAMILY = "1,2"`, `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, with
  the built Info.plist reading `UIDeviceFamily => [1, 2]` and `MinimumOSVersion => 17.0`;
  `docs/RELEASE_EVIDENCE.md:16-17` records the UI suite on both families and an archive that
  succeeded. Claim C24.
* **First screen.** Yes, as a plain fact in the footer of everything.

---

## 9 · Links, backup and the app itself

### 9.1 · A link carrying a command asks first, and shows the command verbatim

* **Value.** An `ssh://` link can never make the app run something without showing you the
  exact command and waiting for you to agree.
* **Scope.** `ssh://` and `apexterminal://`. Any command, and any server not already saved,
  raises a confirmation that shows the command as it is. Refusing does nothing at all. A
  link can never add a connection on its own; an unknown server is offered in the editor
  with the fields filled in.
* **Use case.** A runbook in a wiki that links straight to the host and the command.
* **Limits.** `ssh://` is not an exclusive scheme — any installed SSH client may claim it and
  iOS decides which one wins — so "tap any ssh link and it opens in Apex Terminal" is not a
  promise the app can keep. In the proving test the link is injected through a debug hook
  rather than delivered by iOS: the confirmation, the refusal and the execution are real;
  the system's URL delivery is not part of that test.
* **Security note.** This is the best security story in the area and it is proven against a
  real server on both halves.
* **Shot.** none.
* **Evidence.** `AppTests/IncomingURLTests.swift:52`, `:65`, `:100`, `:117`, `:129`, `:141`;
  end to end on a real `sshd`, `AppUITests/LinkUITests.swift:37` (refused, so nothing ran)
  and `:62` (allowed, and the shell prints `LINK_OK` on the server);
  `docs/RELEASE_EVIDENCE.md:583-593`. Claim C21.
* **First screen.** Yes, on the security page.

### 9.2 · A server cannot open a channel back into the device

* **Value.** A compromised or hostile server cannot push a connection into your device,
  cannot use your key unless you turned agent forwarding on for that connection, and cannot
  run anything on the device.
* **Scope.** An inbound channel is accepted where it is an agent channel and an agent
  exists, or a `forwarded-tcpip` matching a route that was actually requested. Everything
  else is refused, and asking for port 9001 does not open 9002.
* **Use case.** Connecting to a box you do not fully trust.
* **Limits.** Each refusal deliberately leaves the connection usable, so a hostile server can
  keep trying — it just never succeeds. The counterparty is the project's own hostile server
  fixture, which is unavoidable: stock `sshd` will not misbehave on request.
* **Security note.** X11 forwarding and `tunnel@openssh.com` are not implemented and are
  refused by construction. The app is not a VPN and has no Network Extension.
* **Shot.** none.
* **Evidence.** `InboundChannelRefusalTests.swift:41`, `:60`, `:75`, `:108`, each asserting
  the refusal and that the session survives it, driven by `HostileSSHTestServer.swift`.
* **First screen.** No. Security page and press.

### 9.3 · Encrypted backup, sealed with a password

* **Value.** Carry your setup to a new device in one sealed file, and see exactly what a
  restore would add and what it would collide with before anything is written.
* **Scope.** Export carries connections, saved screens, snippets, key metadata, trusted host
  keys and preferences. By default it carries no secret at all. Private keys go in on an
  explicit choice **and** a password; the password seals the whole payload, not just the
  keys (PBKDF2-HMAC-SHA256, then AES-GCM). Restore previews first and offers keep-existing
  or overwrite.
* **Use case.** A new phone on a Friday afternoon.
* **Limits.** The file is as strong as the password chosen for it. Keys held behind Face ID
  or Touch ID, and Secure Enclave keys, have no exportable form and are **named as
  unexportable** rather than silently dropped. No test writes a file through the real Files
  picker and re-imports it; the service and the screens are what is covered.
* **Security note.** Tampering with the ciphertext is caught by the seal, and a wrong
  password is reported as a wrong password rather than as a broken file.
* **Shot.** none.
* **Evidence.** `AppTests/BackupTests.swift:36` asserts on the encoded bytes that no
  "PRIVATE KEY" and no password field is present in a default export; `:110` the seal covers
  the whole payload; `:127`; `:135` (a Face ID-protected key is named as unexportable, with
  the reason); `:151`; `:190` (tampering caught); `:60`, `:76`, `:95` for the preview and
  the resolution. Claim C19.
* **First screen.** No.

### 9.4 · App lock

* **Value.** Put a second lock in front of the app itself, separate from the device
  passcode, with a delay after repeated wrong guesses.
* **Scope.** A passcode of the app's own: a 16-byte random salt, PBKDF2-HMAC-SHA256 at
  200 000 rounds, constant-time comparison, and the passcode itself never stored. Backoff at
  0/30/60/300 seconds. A grace period of immediately, 1, 5 or 15 minutes. The lock is its
  own window above the alert level, so an open sheet cannot sit on top of it.
* **Use case.** A shared iPad in a workshop.
* **Limits.** Minimum length is four characters. Failures cost time, never data — there is
  no wipe-after-N-attempts, and deleting all data cannot lock you out. Face ID or Touch ID
  can open it, and that is fair to describe as an option; the biometric check itself has
  never run in this project's automation, so it must not be presented as measured. The
  evidence is iOS and iPadOS.
* **Shot.** none.
* **Evidence.** `AppTests/AppLockTests.swift:33`, `:46`, `:73`, `:89` (five wrong guesses
  cost 30 seconds, and the right one is not taken during backoff), `:129`, all against the
  real Keychain; end to end, `AppUITests/AppLockUITests.swift:48-110` sets a passcode,
  terminates and relaunches the app, asserts the lock screen stands in front and nothing
  behind it is reachable, rejects a wrong passcode, accepts the right one, then backgrounds
  and returns to a lock. Claim C23.
* **First screen.** No.

---

## 10 · What is not there, and is worth saying

These are absences, proven by search rather than by test — which is the only way an absence
can be proven, and which anyone can repeat in seconds.

### 10.1 · No account, and no server operated by this project

* **Value.** There is nothing to sign up for. You install the app and use it.
* **Scope.** No sign-up or sign-in flow anywhere. No first-party domain appears in the
  source. The entitlements are deliberately minimal — no Network Extension, no VPN.
* **Limits.** State it precisely: **Apex Terminal has no server of its own; your data goes
  only where you send it.** Traffic goes to the servers a person connects to, and — if a
  person configures the optional assistant with their own provider endpoint and their own
  API key — to that endpoint. Do not write an unqualified "your terminal never leaves your
  device".
* **Shot.** SS-7.
* **Evidence.** The only "Sign in" strings in the app belong to the user's own server. Every
  outbound URL in the app belongs to somebody else. Every SSH, SFTP, tmux and forwarding
  test connects to a locally-run real server. Claim C5, proof point P4.
* **First screen.** Yes. It is in almost every piece of copy.

### 10.2 · No analytics, no telemetry, no crash reporter

* **Value.** Nothing about how you use the app is measured or sent anywhere, by anyone.
* **Scope.** The whole dependency list is swift-nio, swift-nio-ssl,
  swift-nio-transport-services, swift-crypto, swift-sodium, and a vendored swift-nio-ssh
  fork. Nothing else. `PrivacyInfo.xcprivacy` declares tracking false, an empty tracking-
  domains list and an empty collected-data-types list, with two required-reason APIs.
* **Limits.** This rests on the dependency manifest, the privacy manifest and a search, not
  on a test — because an absence cannot have one. The list is the argument: there is nowhere
  for a tracker to hide.
* **Shot.** SS-7.
* **Evidence.** An exhaustive search for the usual SDK names across every source, plist,
  entitlement and project file returns zero hits in shipping code; the two matches in the
  tree are the app's own sentences saying there is no analytics. Claim C5, proof point P5.
* **First screen.** Yes.

### 10.3 · Free, with nothing to buy

* **Value.** The app is free. There is no in-app purchase and no subscription.
* **Scope.** There is no StoreKit code in the binary: no purchase flow, no tiers, no trial,
  no paywall.
* **Limits.** Say it plainly and say what it is — a statement about this build. Do not hint
  at a future paid tier in customer copy.
* **Shot.** none.
* **Evidence.** An exhaustive search over every `.swift`, `.plist`, `.entitlements` and
  `.pbxproj` outside the build directory for StoreKit and purchase symbols returns zero
  monetisation hits. Claim C5, proof point P4.
* **First screen.** Yes, as a plain line in the pricing position.

### 10.4 · The App Switcher cover

* **Value.** When you leave the app, the App Switcher snapshot shows the logo instead of
  whatever was on your terminal.
* **Scope.** A cover over the window while the scene is not active. On by default,
  switchable.
* **Limits.** **This covers the App Switcher snapshot and nothing else.** There is no
  screenshot blocking, no screen-recording detection and no secure-display flag anywhere in
  the app. Never write "prevents screenshots" or "blocks screen recording". The correct
  sentence is "hides your terminal in the App Switcher". It has no test, so it belongs in
  body copy as a described behaviour, not in a headline.
* **Shot.** none.
* **Evidence.** By inspection of `PrivacyShield.swift` and the settings default; a search for
  screen-capture observers returns nothing.
* **First screen.** No.

---

## 11 · In the binary, not advertised

Everything below is present in the shipping build and works as far as it has been taken.
None of it may appear in a headline, a screenshot, a caption, the description, the keywords,
the website or a press note. All of it is disclosed to App Review, as guideline 2.3.1
requires; the disclosure is written in
[`../app-store/metadata/APP_STORE_METADATA_EN.md`](../app-store/metadata/APP_STORE_METADATA_EN.md).

The reason is the same in every case: the capability has not been exercised along the path a
customer would take, and a claim that cannot be reproduced is a claim that must not be made.

| Capability | Status | Why it is withheld | What would release it |
| --- | --- | --- | --- |
| A server appearing in the iOS Files app, opened and saved back from another app | Implemented, unverified | Every layer beneath it is proven against a real OpenSSH server — protocol, operations, enumeration, identity map, error mapping, domain registration, refusals. The one test of the system actually serving those answers disables itself on the simulator and has never run. | `docs/HUMAN_ACTIONS.md` H-6: a physical iPhone or iPad and a reachable server, recorded in release evidence |
| iCloud / CloudKit sync between devices | Withheld in this build | Sync is hard-disabled: the switch is shown disabled and says so in the app. A large, well-tested engine exists in the tree, which is easy to mistake for a feature. It is not one. Nothing about sync, multi-device or "your connections everywhere" may be written. | H-5: the container's own state fixed in the CloudKit console, then a sync between two signed devices |
| Storing a private key in iCloud Keychain | Unreachable | The per-key control sits behind the sync switch, so it never appears. Everything the app stores is written this-device-only by default, which is the true and checkable claim. | H-5 |
| Typing Chinese, Japanese or Korean into the terminal | Implemented, unit-tested | The composition buffer is well covered, with the test standing in for the input method. Candidate selection, deleting inside a composition and hardware-keyboard switching are input-method behaviours no automated test here exercises. Cell **widths** are a separate capability and are verified — do not let the two blur. | H-1: a real device and a real input method, both steps seen on hardware |
| A Secure Enclave key gated on Face ID or Touch ID at every signature | Implemented, unverified | No biometric surface in this project has ever run against real hardware; the Simulator has an enclave but no biometrics. "Can be protected with Face ID or Touch ID" is fair as an option. "Proven" is not, and a Face ID prompt must not be staged in a screenshot. | H-7: a device with an enrolled biometric |
| Per-key biometric gating for Keychain-stored keys, and biometric unlock of the app lock | Implemented, unverified | Same class of gap. The state machine around it is tested with a stub; the biometric check is not. | A device with an enrolled biometric |
| macOS Screen Sharing account sign-in, and VeNCrypt | Implemented, unverified | Tested against reference vectors and a server half written in the test. No real Mac and no real VeNCrypt server has ever answered this client. VeNCrypt's own TLS and x509 sub-types are deliberately not implemented at all. | H-3: a real Mac, a real VeNCrypt server |
| Running on Mac (Catalyst) | Implemented, unverified | The app builds, launches and passes 316 of 324 unit tests there, but the UI suite cannot load without a Catalyst signing identity, so nothing about how it behaves on a Mac is verified. There is no menu-bar construction in the code, and the Files integration is genuinely absent there. | H-8: a Mac Catalyst signing identity |
| Running on Vision Pro | Implemented, unverified | The app has never been executed on visionOS — the project cannot name that build destination today. The permitted phrasing, if any is ever needed, is Apple's own compatibility-mode listing. | H-9: a visionOS runtime |
| The optional assistant | Implemented, unverified | It prefers the device's own model and does nothing without a key the person supplies. It is also the one place terminal text can leave the device, which is why every privacy sentence in this rebuild is written to survive it. | A provider key, or an Apple Intelligence device |
| Kitty and iTerm2 inline images | Implemented, unit-tested | Good tests, including cross-implementation agreement on pixel data, but nothing sends one from a real server and nothing proves they are drawn. Sixel is the picture protocol that is verified end to end. | A real-server test and a pixel assertion, as sixel has |
| Siri and Shortcuts actions, Spotlight, Handoff | Implemented, unit-tested | The intent bodies and the indexed fields are covered by direct calls. Nothing has ever run them through the system. Handoff carries a saved-connection id, not the session — never write "pick up your session where you left off". | Device runs through Siri, Shortcuts, Spotlight and two devices |
| Download, Quick Look and Share; upload into the folder on screen; rename, delete and new folder in the app's browser; the transfer queue; drag and drop | Implemented, unverified | The equivalent operations are verified in the File Provider path and at the protocol level; these specific app-browser paths have no test. Downloads land in the app's temporary directory and leave through the share sheet — there is no destination picker, so "download to the Files app" overstates it. | Tests through the app's own browser against a real server |
| Colour themes | Implemented, untested | Three built-in schemes exist and work; the theme code has no test of any kind. User-defined themes are half-built and are never persisted, so a restored custom theme is lost on the next launch. Claim three built-in themes, light and dark, and nothing more. | Tests, and an editor, if custom themes are ever to be claimed |
| DEC 2026 synchronised output, DEC 1004 focus reporting | Negotiation only | The modes are parsed, stored and truthfully reported, but nothing consumes them: no code holds a frame back and no focus report is ever sent. Never claim tear-free rendering or focus-aware programs. | An implementation, not a claim |
| Stage Manager, iPad Split View and Slide Over | Declared, unobserved | The declaration and the size-class branch are real; the behaviour has never been observed in a shared-screen window. | A test, or an honest device observation |
| Trackpad and mouse on iPad; hardware special keys | Implemented, unverified | Configuration and key encodings are unit-tested exactly; no test moves a pointer or presses an arrow key into a real shell. | A device check with a real keyboard and pointer |
| The split-target picker ("Split With…") | In flight | Untracked work from another session at the time of the audit, with no decision record and no measured run. It must not appear in any claim, screenshot or release note until it lands. | A commit, a decision record, and a recorded run |
| Resuming an interrupted transfer from where it stopped | Refused, deliberately | SFTP has no notion of a partial upload the server will remember, and the code says so where it refuses. "Pause and resume a running transfer" is the true form. | Nothing. This is a decision |
| FIDO2 and hardware security keys | Refused, deliberately | iOS exposes security keys through WebAuthn, which signs a different structure from the one OpenSSH verifies, and there is no public raw CTAP2 API. The app says so on its own Keys screen — copy implying security-key support would contradict the shipping interface. Secure Enclave keys are the offered alternative: non-extractable, though not portable | A platform API |
| A local ssh-agent (`SSH_AUTH_SOCK`) | Refused, deliberately | iOS gives each app its own container and no way to reach another app's socket. Forwarding exists; general agent support does not | A platform API |
| Tabs | Does not exist | There is no tab bar. Sessions are rows in a sidebar list. Using the word in copy invites a reviewer to look for something that is not there | Nothing. This is vocabulary |
| X11 forwarding, `tunnel@openssh.com`, VPN-style tunnelling | Refused, deliberately | X11 would need an X server inside the app; a packet tunnel would need a Network Extension in a separate process. Never write "VPN" or "route all your traffic" | Nothing. This is a decision |
| Notifications, Live Activities, the Dynamic Island | Not started | The app cannot show a notification at all. Never write "get notified when the build finishes" | An implementation |
| Universal Links | Not started | There is no associated-domains entitlement and no site-association file. The app answers custom URL schemes | An implementation |
| Importing an OpenSSH config file or another client's connections | Not started | The way in is an Apex Terminal backup file. Do not imply migration from another client | An implementation |
| watchOS | Refused, deliberately | A terminal does not fit a watch, and what would fit has not been designed. Never mention a watch app or watch notifications | A design |

---

## 12 · Using this catalogue

* The **Value** line is the sentence a customer reads. Take it whole, or shorten it. Never
  rewrite it into a claim it did not make.
* The **Limits** line is not a footnote. It goes in the same sentence as the feature, in the
  same voice, with no softening word between them. A limit that arrives late reads as
  something that was being hidden.
* The word "Verified" is this project's internal gate. It never appears in customer copy.
* No competitor is named, anywhere, ever.
* When a `docs/HUMAN_ACTIONS.md` item clears, the capability moves out of §11 and into the
  body of this file — with its evidence — before it appears anywhere a customer can see it.
