# App Store metadata — en-US

**Written:** 2026-09-10 · **Gated by:** [`../../audit/CLAIMS_MATRIX.md`](../../audit/CLAIMS_MATRIX.md)
· Character counts are checked by `automation/validate.py`, not by eye.

Every fenced block below is the literal value to paste into App Store Connect. Text outside
the blocks is guidance for whoever is submitting and is not part of the listing.

---

## App Name

Limit 30 characters.

### App Name

```
Apex Terminal: SSH & SFTP
```

25 characters. The name is two words. `ApexTerminal` is an identifier — the Xcode scheme,
the bundle path — and never appears in customer-facing text.

## Subtitle

Limit 30 characters. Must make only verifiable claims (2.3.7).

### Subtitle

```
One connection, everything
```

26 characters. Claim C1.

## Promotional Text

Limit 170 characters. Can be changed without a new build, so it carries what is newest.

### Promotional Text

```
A shell, your files, a remote desktop and your tunnels — on one SSH connection, with one authentication. Your keys can be generated inside the Secure Enclave.
```

156 characters. Claims C1, C2.

## Keywords

Limit 100 bytes. No competitor names, no trademarks, no repetition of the app name.

### Keywords

```
ssh,sftp,terminal,shell,server,tmux,console,devops,sysadmin,port,tunnel,vnc,key,xterm
```

84 bytes. Deliberately excludes "cloudflare" (withheld), "apex" and "terminal" as a pair
(the name is already indexed), and every competitor's name.

## Description

Limit 4 000 characters.

### Description

```
Apex Terminal is an SSH client for iPhone and iPad. It opens a real interactive session on a server you already own, allocates a real PTY, and draws what comes back with its own terminal emulator.

Commands run on your own remote machines. There is no account to create, no back end operated by us, and nothing to buy.

ONE CONNECTION, NOT FOUR

Open a shell, a file browser, a remote desktop and a port forward on the same server and you pay for one TCP connection, one key exchange, one authentication and one biometric prompt. They are channels on a single pooled SSH transport — not four separate logins.

A TERMINAL, NOT AN APPROXIMATION

• 24-bit true colour and 256 colours, both SGR spellings
• The alternate screen, so quitting vim or less leaves your shell exactly as it was
• Sixel graphics — gnuplot and img2sixel put real pictures on the screen
• Mouse reporting in all three modes, with modifiers, wheel and drag
• Correct cell widths for CJK, emoji and combining marks, from the Unicode tables
• Reflow on width change, scrollback with block selection, and search across all of it
• OSC 7, OSC 52 and OSC 133 — working directory, clipboard and shell integration
• Any monospaced font on your device, with your own size and line height

FILES, WITHOUT A SECOND APP

Browse your server over SFTP on the same SSH connection. Upload, download, rename, make folders, set permissions. Open several remote folders at once — the same server twice, or two servers side by side on an iPad. Publish a connection to the Files app and reach it from anywhere in iOS.

TUNNELS YOU CAN SEE

Local, remote and dynamic (SOCKS5) forwarding. Rules are saved with a connection and start with it, and each one shows bytes out, bytes in, connections open now and connections carried in total. A forward that cannot start says why, and names the port.

TMUX, SPOKEN PROPERLY

Apex Terminal speaks tmux's own control protocol, so tmux is something it drives rather than text it scrapes. Turn on "Attach to tmux" and opening a connection puts you inside a named session. Detach, put the iPad down, attach again — the windows, the panes and their output are still there.

THE DESKTOP, TOO

A remote screen over VNC, in the same app, reached through the same SSH connection — so nothing needs to be exposed to the internet. Touch to click, a key row for the keys a touch keyboard lacks, and your clipboard sent across.

KEYS THAT STAY WHERE YOU PUT THEM

Generate an Ed25519 or ECDSA P-256 key on the device. Or generate one inside the Secure Enclave: the private half is created in dedicated hardware, never exists outside it, and cannot be exported, backed up or moved — and it still logs in to an ordinary OpenSSH server. Keys you already have import, passphrase and all.

The first time you reach a server, its fingerprint is put in front of you. If a known key later changes, that is a hard stop, not a shrug. If your organisation signs host keys, trust the authority once instead.

Also: OpenSSH user and host certificates, ProxyJump through a bastion, agent forwarding with the device as the agent, servers with PAM or a one-time-code prompt, and post-quantum hybrid key exchange where a server offers it.

BUILT FOR IPAD

Split a pane and watch a log while you work; each pane is a full session with its own controls. Open a session in a second window. A hardware keyboard reaches new connection, the command palette, next and previous session, session by number, close, and font size — and Command is never forwarded to the remote host.

QUIET BY DEFAULT

No analytics, no telemetry, no crash reporter, no advertising identifier, no third-party SDK of that kind. Command history is off until you turn it on. Copied text expires from the clipboard. A program on the server can write your clipboard only if you allow it, and can never read it. The app itself can be locked with a passcode of its own.

Requires iOS or iPadOS 17.0 or later. You supply the servers; the app connects to them.
```

3 983 characters. (17 to spare.)

## What's New

Not applicable to a first submission. The field should carry the standard first-release
line; a fabricated changelog for a version nobody has seen is exactly what 2.3 forbids.

### What's New

```
First release.
```

## URLs

These are **not decided** — they are proposals, and they are a blocker until the owner
supplies real ones. App Store Connect requires a reachable Support URL and a Privacy Policy
URL; a listing cannot be submitted without them.

| Field | Proposal | Status |
| --- | --- | --- |
| Support URL | `https://apexterminal.dev/support` | **Blocked** — needs a live page |
| Marketing URL | `https://apexterminal.dev` | **Blocked** — needs a live page |
| Privacy Policy URL | `https://apexterminal.dev/privacy` | **Blocked** — must be live at submission |

The copy for all three pages is written and ready in [`../../website/`](../../website/).

## Category, rating, pricing

| Field | Value | Why |
| --- | --- | --- |
| Primary category | Developer Tools | What the app is |
| Secondary category | Utilities | Where a sysadmin would look |
| Age rating | 4+ | Nothing in the app exceeds it. The *content* is whatever the user's own server prints — the position every SSH client is in |
| Price | Free, no in-app purchases | There is no StoreKit code in the binary. This is a fact about the build, not a decision to revisit in copy |

## App Review Notes

Paste the block below into **App Review Information → Notes**.

### App Review Notes

```
WHAT THE APP IS

Apex Terminal is an SSH client. It opens an interactive SSH session on a server the user
already owns, allocates a PTY, and renders the output with a terminal emulator built into
the app. Everything a user sees in a session comes from their own remote machine. The app
runs nothing itself and relays nothing through any server of ours.

There is no account, no sign-in, no registration and no server-side component. There is
nothing to purchase: no in-app items, no tiers, no trial.

HOW TO TEST IT

You will need any SSH server you can reach and a credential for it. On a Mac, System
Settings > General > Sharing > Remote Login is enough.

1. Launch the app and accept the terms screen. A short tour follows; it can be skipped.
2. Tap + > New Connection. Enter the hostname, the port if it is not 22, and a user name.
   Both port and user name may be left blank; blank means "use the default" or "ask me".
3. Choose how to authenticate:
   - Password: pick Password and the app prompts during the connection.
   - Key: Settings > Keys > + > Generate. Copy the public key it shows into
     ~/.ssh/authorized_keys on the server, then select that key on the connection.
4. Tap the connection. The app shows the server's host key fingerprint and waits for you
   to accept it. This prompt is deliberate.
5. A shell prompt appears. Type any command; try vim or top for a full-screen program.

SFTP: long-press a connection and choose Browse Files. This uses the SFTP subsystem on the
same SSH connection. To test the Files integration, open the connection's editor and turn
on "Show in the Files app", then open Files.

PORT FORWARDING: open a session, then the Session menu > Port Forwards > +. A local rule
listening on 8080 and targeting 127.0.0.1:22 on the server is enough to see it work.

TMUX: the server needs tmux installed. Edit a connection, turn on "Attach to tmux", give
the session a name, and open it.

VNC: + > New Screen. Point it at a VNC server, and choose "Through an SSH connection" to
reach one that is not exposed to the internet.

PERMISSIONS

- Face ID / Touch ID (NSFaceIDUsageDescription): used only for two optional things the
  user turns on — unlocking the app when App Lock is enabled, and using a private key the
  user chose to protect biometrically. Neither is required to use the app.
- Local network: iOS may ask the first time the app connects to a server on the same
  network. That request is the SSH connection itself.

WHAT IS IN THE BINARY BUT NOT ADVERTISED

Per guideline 2.3.1, these are working features present in this build. They are absent from
the screenshots, the description and the keywords because they have not been verified along
the path a reviewer would take, and we did not want to claim them until they are:

- Connecting through a Cloudflare Tunnel to a host behind Cloudflare Access. The protocol
  is implemented and tested against a local server that reproduces the edge's wire
  behaviour, but no connection has ever been made through a live Cloudflare account.
  Nothing in the listing mentions Cloudflare. The app is not affiliated with, endorsed by
  or connected to Cloudflare, Inc. To exercise it you would need your own Cloudflare
  tenant, a tunnel, an Access application and either a service token or an identity
  provider; + > New Cloudflare Connection is the entry point.
- macOS Screen Sharing's own sign-in, and VeNCrypt, for remote screens. Implemented and
  tested against reference vectors; not yet run against a real Mac or a real VeNCrypt
  server. Ordinary VNC authentication is tested and does work.
- Typing Chinese, Japanese or Korean into the terminal with a system input method. The
  protocol handling is unit-tested; the input methods themselves have not been exercised on
  hardware.
- Optional sync of connections, snippets, known hosts and public key metadata through the
  user's own private CloudKit database. Off by default, and not verified between devices.
- An assistant that explains commands and output. It runs on the device's own model where
  the device supports one, otherwise on a provider endpoint and API key the user supplies.
  The app ships no key and sends nothing without one. It shows what it will send before
  sending it, and a suggested command is inserted into the command line, never executed.
- Mac Catalyst. The app builds and runs on macOS but has no signing identity for it, so it
  is not submitted for Mac.
- Shortcuts / App Intents, URL scheme and Handoff for opening a saved connection.

PRIVACY

No analytics, no telemetry, no advertising identifiers, no third-party SDKs that collect
anything. Connections, keys, snippets and known hosts are stored on the device. Private
keys are in the Keychain with explicit protection classes, or in the Secure Enclave, and
are never displayed or transmitted by the app. Command history is off unless the user turns
it on, and turning it off deletes the stored file.

CONTENT

The app displays whatever the user's own server sends. It has no content of its own beyond
its interface, and no way to browse, search or discover third-party content.
```

## Encryption and export compliance

**This is the submitter's answer to give, not ours.** The project does not set
`ITSAppUsesNonExemptEncryption`, so App Store Connect will ask at submission.

Draft reasoning, to be checked against `docs/EXPORT_COMPLIANCE.md` and against counsel:

> The app uses encryption. It is standard, published cryptography — SSH (RFC 4251–4254),
> TLS for the transport underneath a tunnelled connection, and the OS's own Keychain and
> Secure Enclave — used to authenticate to, and protect a connection with, a server the
> user already controls. No proprietary or non-standard cryptography is implemented. This
> normally falls within the exemption for software using only standard encryption for
> authentication and secure communications.

Decide it deliberately rather than clicking through: some jurisdictions require an annual
self-classification report even where the exemption applies.

## Blockers before this can be submitted

| # | Blocker | Who | What unblocks it |
| --- | --- | --- | --- |
| 1 | Support, Marketing and Privacy Policy URLs are not live | Owner | Publish the pages in `website/`; App Store Connect rejects a listing without a reachable Support and Privacy URL |
| 2 | The legal texts in the app carry placeholders | Owner | Effective date, developer legal name, governing law and venue, in all three languages under `App/Resources/Legal/`, plus a counsel review (`PROJECT_STATUS.md` B-5) |
| 3 | Export compliance answer | Owner | The question above |
| 4 | A distribution certificate and App Store profile | Owner | Only development identities exist; the archive cannot be exported for the store yet (`PROJECT_STATUS.md` B-4) |
