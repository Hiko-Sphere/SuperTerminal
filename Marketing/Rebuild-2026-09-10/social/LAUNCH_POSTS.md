# Launch posts — Apex Terminal 0.1.0

**Written:** 2026-09-10 · **Version announced:** 0.1.0 ·
**Gated by:** [`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md) and
[`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md) ·
**Language kit:** [`../strategy/MESSAGING_SYSTEM.md`](../strategy/MESSAGING_SYSTEM.md) ·
**Evergreen library:** [`SOCIAL_COPY.md`](SOCIAL_COPY.md)

These are the things that are said once, on a date. Everything that stays true afterwards
lives in the evergreen library and is scheduled from there.

Every fenced block is the literal text to post or send. Prose outside a block is guidance for
whoever is posting.

---

## 0 · Before any of this goes out

Nothing here may be published until all five are true. They are conditions, not preferences.

| # | Condition | Where it is tracked |
| --- | --- | --- |
| 1 | The listing is **approved and live** on the App Store, and its numeric link has been copied out of App Store Connect | App Store Connect |
| 2 | The marketing, support and privacy pages resolve at `https://apexterminal.dev` | [`../app-store/metadata/APP_STORE_METADATA_EN.md`](../app-store/metadata/APP_STORE_METADATA_EN.md) — blocker 1 |
| 3 | The legal texts in the app carry no placeholder | Blocker 2 in the same file |
| 4 | The tag `v0.1.0` exists and its release notes are staged as a draft | The repository's Releases page |
| 5 | `automation/validate.py` reports no failure over this directory | `automation/validate.py` |

Two conventions that apply to every block below:

* **The App Store link is not written into this file.** The listing has no numeric identifier
  until it exists, so it is pasted in at posting time. Where a block needs it, the guidance
  says so and the block leaves the sentence able to stand without it.
* **No claim is added at posting time.** If a channel asks for something this file does not
  provide, the answer comes from `SOCIAL_COPY.md` §7 or from the claims matrix — not from
  whoever happens to be at the keyboard.

---

## 1 · Product Hunt

### 1.1 · Tagline

Limit 60 characters.

### Product Hunt — tagline

```
One SSH connection: your shell, files, desktop, tunnels
```

55 characters. Claim C1.

### 1.2 · Description

Limit 260 characters.

### Product Hunt — description

```
Apex Terminal is an SSH client for iPhone and iPad. A shell, a file browser, a remote desktop and a port forward on one server cost one handshake and one authentication. Keys can be generated in the Secure Enclave. No account, no back end, nothing measured.
```

257 characters. Claims C1, C2, C5.

### 1.3 · Topics, and the fields around the post

| Field | Value |
| --- | --- |
| Topics | Developer Tools · iOS · Productivity · Privacy |
| Pricing | Free |
| Platforms | iOS, iPad |
| Gallery | IMG-5 and IMG-6 from `SOCIAL_COPY.md` §8, then the store screenshots in their published order |
| Link | The App Store listing, pasted at posting time |

### 1.4 · The maker's opening comment

Posted by the maker within a minute of the listing going live, before any other comment. It
is long on purpose: this is the one place on launch day where the reasoning fits.

### Product Hunt — maker's opening comment

```
Apex Terminal is an SSH client for iPhone and iPad. Commands run on servers you already own; the app connects to them and draws what comes back.

It started with an annoyance. When you reach a server you usually want more than a shell — the files, sometimes the machine's desktop, sometimes a port handed back to you. In most tools each of those is a separate login. On cellular that is four handshakes and four chances to fail. On a hardware key it is four touches.

So they are channels on one SSH connection here. A shell, a file browser, a remote desktop and a port forward on the same server cost one TCP connection, one key exchange, one authentication and one biometric prompt. The count in that sentence is taken out of a real sshd's own log rather than out of the app's self-report.

The other half is the key. You can generate one inside the Secure Enclave, where the private half is made in the chip and never exists outside it. There is no key file to export, back up or copy, and it still logs in to an ordinary, unmodified OpenSSH server with just the public half in authorized_keys. If a host key you already know later changes, the connection is refused rather than turned into a prompt to tap through.

A few things that are true and worth saying plainly:

— No account. No back end operated by this project. No analytics, no telemetry, no crash reporter. No in-app purchase, no subscription. Those are absences, and an absence is proven by a search anyone can repeat in seconds.
— The terminal is the product rather than a text view: 24-bit colour, sixel pictures, mouse reporting in three modes, the alternate screen, reflow, scrollback search, and CJK and emoji cells sized from UCD 17.0.0.
— tmux is spoken as a protocol, in tmux's own control mode, measured against tmux 3.3a.

And what it does not do. The device is not kept connected in the background; iOS does not guarantee that, and neither will I. Terminal sessions come back on their own after a drop with the scrollback intact, but reattaching to a tmux session is your move rather than something that happens. The remote desktop decodes ZRLE, Hextile, RRE and Raw, so a server configured to offer Tight or TRLE alone will not draw.

iOS and iPadOS 17 and later. It is free.

I will be here all day. Ask me anything, including the awkward parts.
```

---

## 2 · GitHub release

Tag `v0.1.0`. Publish the draft at the moment the App Store listing goes live, not before.
Paste the store link into the "Where to get it" line at publication; the sentence reads
correctly with or without it, so a delayed link does not hold up the release.

### GitHub release — title

```
Apex Terminal 0.1.0
```

### GitHub release — notes

```
Apex Terminal is an SSH client for iPhone and iPad. It opens a real interactive session on a
server you already own, allocates a real PTY, and draws what comes back with its own terminal
emulator. This is the release the App Store listing describes.

Requires iOS or iPadOS 17.0 or later. Free, with no in-app purchase and no subscription.

## What is in it

**One connection, not four.** A shell, a file browser, a remote desktop and a port forward on
the same server ride one pooled SSH transport: one TCP connection, one key exchange, one
authentication, one biometric prompt. The connection pool never hands back a connection
belonging to another account, and never a dead one.

**Terminal.** 24-bit colour in both SGR spellings, 256 colours, the alternate screen, sixel
graphics, mouse reporting in three modes with modifiers and drag, OSC 7, OSC 52 and OSC 133,
DECRQM, reflow on width change, block selection, search across the whole scrollback, and cell
widths for CJK, emoji and combining marks generated from UCD 17.0.0. Any monospaced font on
the device, with your own size and line height; the server is told the new grid size.

**Files.** SFTP protocol version 3 over the same SSH connection — list, read, write, rename,
make folders, set permissions. A File Provider extension puts a connection in the Files app.
Several remote folders can be open at once, including the same server twice.

**Tunnels.** Local, remote and dynamic (SOCKS5) forwarding. Rules are saved with a connection
and start with it, and each shows bytes out, bytes in, connections open now and connections
carried in total. A rule that cannot start says why, and names the port.

**tmux.** A control-mode client speaking tmux's own protocol, so panes on screen are tmux's
arrangement rather than scraped text. Measured against tmux 3.3a.

**Remote desktop.** VNC/RFB in the same app, routed through the SSH connection, decoding ZRLE,
Hextile, RRE and Raw.

**Keys and authentication.** Ed25519 and ECDSA P-256 generated on the device, or generated
inside the Secure Enclave where the private half never exists outside the chip. Import of
existing keys, passphrase and all. OpenSSH user and host certificates and trusted certificate
authorities. ProxyJump through a bastion, with the far server's host key checked as its own.
Agent forwarding with the device acting as the agent, including for an enclave key.
Keyboard-interactive authentication over multiple rounds, so servers with PAM, an expired
password or a one-time-code prompt log in. Post-quantum hybrid key exchange
(mlkem768x25519-sha256) where a server offers it, with fallback where it does not.

**Host keys.** A fingerprint is shown before you trust a server. A known key that later changes
is a hard stop.

**iPad.** Split panes, each a full session with its own toolbar. A second window. Hardware
keyboard commands for new connection, the command palette, next and previous session, session
by number, close and font size — and Command is never forwarded to the remote host.

**Quiet by default.** No analytics, no telemetry, no crash reporter, no advertising identifier.
Command history is off until you turn it on. A program on the server can write your clipboard
once you have allowed it, and can never read it: the read request is refused and the refusal
is not reported back. An ssh:// link shows the exact command and runs it if you agree, and
not otherwise. The
app can be locked with a passcode of its own, with backoff and a grace period. An encrypted
backup is sealed with a password, and a restore previews before it writes.

## What it deliberately does not promise

- The device is not kept connected in the background. iOS does not guarantee it.
- Terminal sessions return on their own after a network drop with the scrollback intact and
  the new shell marked as fresh. A tmux session keeps running on the server, but reattaching
  to it is something you do.
- The remote desktop draws ZRLE, Hextile, RRE and Raw. A server configured to offer Tight or
  TRLE alone will not draw.
- Scrolling inside a tmux pane is local, over roughly 2 000 captured lines. It is not tmux
  copy mode.

## Dependencies, in full

swift-nio, swift-nio-ssl, swift-crypto, swift-sodium, and a vendored swift-nio-ssh fork.
Nothing else. PrivacyInfo.xcprivacy declares no collected data types and no tracking.

## Where to get it

On the App Store, for iPhone and iPad.
```

The limits named under "What it deliberately does not promise" are quoted from approved
wording and must not be softened, shortened or moved below the fold.

---

## 3 · Developer forum — Show HN

Submitted by the maker, from the maker's own account, with the marketing page in the URL
field and the text below in the text field. No image, no tagline, no adjectives that a reader
would have to take on trust. If the post gets attention, the maker answers in the thread
rather than editing the post.

### Show HN — title

Limit 80 characters.

### Show HN — title

```
Show HN: Apex Terminal – an SSH client for iPhone and iPad
```

58 characters.

### Show HN — URL field

```
https://apexterminal.dev
```

### Show HN — text

```
I have been building an SSH client for iOS and iPadOS. It is on the App Store today, version
0.1.0, free, with no in-app purchase and no account.

The thing I actually wanted to solve: when you reach a server you rarely want just a shell.
You want the files, sometimes the machine's desktop, sometimes a port forwarded back to you.
In most mobile clients each of those is a separate SSH session with its own handshake and its
own authentication. On cellular that is several chances to fail, and with a hardware key it is
several touches.

Here they are channels on one pooled transport. Opening a shell, an SFTP browser, a VNC screen
routed through direct-tcpip, and a local forward against the same host costs one TCP
connection, one key exchange, one authentication and one biometric prompt. The test that
covers this counts the handshakes in a real sshd's log rather than trusting the client's own
accounting, and there is an adversarial pair alongside it: the pool must never return a
connection belonging to a different account, and must never return a dead one.

The second piece is Secure Enclave keys. You can generate a P-256 key whose private half is
created inside the enclave and never exists outside it, so there is no key file to exfiltrate.
It authenticates to stock OpenSSH — the test puts the public half in a real sshd's
authorized_keys and asserts sshd's own log line, "Accepted publickey ... ECDSA <fingerprint>",
with a control case proving the same key is refused where it was not authorised. Agent
forwarding works with it too, so a git push executed on the server is signed by a key that
never left the phone.

Terminal internals, since that is usually the part that disappoints: a from-scratch VT/xterm
emulator with the alternate screen, 24-bit colour in both SGR spellings, sixel, mouse
reporting in 1000/1002/1003 with legacy and SGR 1006 encodings, OSC 7, OSC 52 and OSC 133,
DECRQM, reflow on resize, and a character-width table generated from UCD 17.0.0 rather than
hand-maintained. There is a fuzz suite, and the thing I care about is that it was demonstrated
to catch a deliberately broken invariant instead of merely passing. TUI integration tests drive
vim, less and htop over a real PTY and assert the shell comes back as it was.

tmux is driven in control mode (-C), not scraped, so the panes drawn are tmux's own layout —
including layouts the app's own splitter cannot express. Measured against tmux 3.3a in a
Debian container.

Port forwarding is local, remote and dynamic (SOCKS5), with per-rule byte and connection
counters. A local rule on 8080 pointed at 127.0.0.1:22 on the far side is the quickest way to
see it working.

Dependencies in full: swift-nio, swift-nio-ssl, swift-crypto, swift-sodium and a vendored
swift-nio-ssh fork. There is no analytics SDK, no telemetry, no crash reporter and no server
operated by me — those are absences, so the honest proof is that you can grep for them.

Things it does not do, said plainly because they will otherwise be the top comment:

- It does not hold the connection in the background. iOS does not guarantee that.
- Ordinary sessions reconnect after a drop with scrollback intact; a tmux session survives on
  the server but reattaching is a deliberate action, not automatic.
- The VNC client decodes ZRLE, Hextile, RRE and Raw. Tight, TRLE and zlib are not implemented,
  so a server configured for those will not draw.
- Scrollback inside a tmux pane is local over roughly 2 000 captured lines, not copy mode.
- There is no Apex Terminal account, and therefore nothing to sync through me.

Happy to answer questions about the transport, the emulator or the enclave key path.
```

The word "just" in the opening paragraph is doing real work ("just a shell"); do not change it
to a word that reads as a hedge.

---

## 4 · Email announcement

Plain text, sent to people who asked to be told. No tracking pixel, no click-wrapping of the
links, no image. The sender name is the product; the reply address is the one the list already
uses. Nothing in the body needs personalisation, so nothing in the body is personalised.

### Email — subject

```
Apex Terminal 0.1.0 is on the App Store
```

39 characters.

### Email — preheader

```
An SSH client for iPhone and iPad. One connection carries your shell, your files, your desktop and your tunnels.
```

112 characters.

### Email — body

```
Apex Terminal 0.1.0 is available on the App Store, for iPhone and iPad, running iOS and
iPadOS 17 and later. It is free: no in-app purchase, no subscription, no account.

It is an SSH client. Commands run on servers you already own; the app connects to them, opens
a real PTY and draws what comes back with its own terminal emulator.

What it does

A shell, a file browser, a remote desktop and a port forward on the same server are channels
on one SSH connection — one TCP connection, one key exchange, one authentication and one
biometric prompt, rather than four separate logins.

The terminal handles 24-bit colour, sixel pictures, mouse reporting in three modes, the
alternate screen, scrollback search, and CJK and emoji cells sized from the Unicode tables, so
full-screen programs draw correctly and put your shell back as it was when you quit them.

Your server's files travel over SFTP on that same connection, with no second sign-in and no
second password. A connection can be published to the Files app, and several remote folders
can be open at once.

Local, remote and dynamic (SOCKS5) forwarding, with per-rule counters for bytes out, bytes in
and connections carried. A forward that cannot start says why, and names the port.

tmux is spoken over its own control protocol, so the panes on screen are tmux's arrangement
rather than scraped text.

A key can be generated inside the Secure Enclave, where the private half is made in the chip
and never exists outside it. There is no key file to export, back up or copy, and it logs in
to an ordinary, unmodified OpenSSH server. A host key you already know, if it changes, is a
hard stop rather than a prompt to tap through.

What it does not do

The device is not kept connected in the background; iOS does not guarantee it. Terminal
sessions come back on their own after a drop with the scrollback intact, while a tmux session
keeps running on the server and reattaching to it is something you do. The remote desktop
decodes ZRLE, Hextile, RRE and Raw, so a server configured to offer Tight or TRLE alone will
not draw.

What is behind it

No account. No back end operated by this project. No analytics, no telemetry, no crash
reporter, no advertising identifier. The dependency list is swift-nio, swift-nio-ssl,
swift-crypto, swift-sodium and a vendored swift-nio-ssh fork, and nothing else.

Where to get it

On the App Store, for iPhone and iPad.

You are receiving this because you asked to be told when it shipped. Unsubscribing takes one
click and removes the address rather than pausing it.

— Apex Terminal
```

At send time, paste the App Store link under "Where to get it" and the marketing page under
the sign-off. The list footer with the postal address and the unsubscribe link is supplied by
the sending platform and is not reproduced here.

---

## 5 · Launch-day timeline

Launch on a **Tuesday**, and not before the listing is approved and live. An approval that
lands on a Friday waits until the following Tuesday; a date is worth less than a full working
day of attention on three continents.

Times are Pacific, with UTC alongside for September (UTC−7). One person is at the keyboard for
the whole run.

### T minus one day

| Time (PT / UTC) | Channel | What happens |
| --- | --- | --- |
| 10:00 / 17:00 | App Store Connect | Confirm the listing is approved and the release is set to manual, so the moment is chosen rather than discovered |
| 10:30 / 17:30 | Website | Confirm the marketing, support and privacy pages resolve, and that `og:image` and `og:description` render correctly in a link preview |
| 11:00 / 18:00 | Assets | IMG-1 to IMG-8 exported, alt text written, every block in this file and in `SOCIAL_COPY.md` pasted into its platform's composer and left unsent, so the character counts are confirmed by the composer itself |
| 11:30 / 18:30 | Repository | The `v0.1.0` release notes staged as a draft, unpublished |
| 12:00 / 19:00 | Validation | `automation/validate.py` run over the rebuild directory; no failure |

### Launch day

| Time (PT / UTC) | Channel | What goes out | Asset |
| --- | --- | --- | --- |
| 00:01 / 07:01 | Product Hunt | The listing goes live at the start of the Product Hunt day, so it has the full 24 hours | Tagline §1.1, description §1.2, gallery IMG-5 and IMG-6 |
| 00:03 / 07:03 | Product Hunt | The maker's opening comment, posted before any other comment | §1.4 |
| 05:30 / 12:30 | App Store Connect | Release the build. Wait for the listing to be reachable from a device before anything links to it | — |
| 06:00 / 13:00 | Repository | Publish the `v0.1.0` release, with the store link pasted in | §2 |
| 06:15 / 13:15 | X | The launch post: `SOCIAL_COPY.md` X-1 with the store link appended, quote-posting nothing | X-1, IMG-1 |
| 06:20 / 13:20 | X | The seven-post thread, posted as a thread under the launch post, in a single sitting | `SOCIAL_COPY.md` §3 |
| 06:30 / 13:30 | Developer forum | Show HN, from the maker's own account, marketing page in the URL field | §3 |
| 06:35 / 13:35 | Developer forum | The maker sits with the thread and answers, and does not edit the post | — |
| 07:30 / 14:30 | LinkedIn | The LinkedIn post, with IMG-3 | `SOCIAL_COPY.md` §4, IMG-3 |
| 08:00 / 15:00 | Email | The announcement to the list, sent as plain text | §4 |
| 09:00 / 16:00 | Instagram | Caption 1, portrait crop composed for 1080 × 1350, with alt text | `SOCIAL_COPY.md` §5, IMG-6 |
| 16:00 / 23:00 | Xiaohongshu | 小红书 set 1, posted at 08:00 the next morning China time, which is where its readers are | `SOCIAL_COPY.md` §6, IMG-8 |
| 21:00 / 04:00+1 | Product Hunt | A closing comment answering whatever came up during the day; no ranking is mentioned, whatever the ranking is | — |

Two rules for the day itself:

* **Replies do not invent claims.** If a question cannot be answered from the claims matrix,
  the answer is that it has not been verified along the path a reader would take, and what
  would change that. Saying so has been the strongest material in this whole rebuild.
* **Nothing is boosted, promoted or reciprocated.** No upvote asks, no follow-for-follow, no
  posting into unrelated threads.

### The week after

| Day | Channel | What goes out |
| --- | --- | --- |
| +1 | X | X-2 or X-3 from the evergreen library, whichever the launch-day questions pointed at |
| +2 | Xiaohongshu | 小红书 set 2 |
| +3 | Instagram | Caption 2 with IMG-5 |
| +4 | X | X-9, the absences, which is the post that travels furthest with this audience |
| +6 | Xiaohongshu | 小红书 set 3 |
| +7 | Review | Read what people actually asked. Anything asked three times becomes a claims-matrix question before it becomes a post |

Nothing in this table is scheduled beyond the week. The evergreen library is written to be
posted in any order, and a second week of launch talk about a version nobody has updated is
just noise.
