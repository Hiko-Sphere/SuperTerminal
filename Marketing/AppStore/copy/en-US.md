# App Store copy — en-US

Every claim below is traced to running code and a passing test in
[`FEATURE_AUDIT.md`](../FEATURE_AUDIT.md). Anything the audit marked *not advertisable* is
absent from this file, and `scripts/validate.py` fails the build if it reappears.

Character counts are measured by the validator against the fenced blocks, not estimated.

---

### App Name

```
SuperTerminal: SSH Client
```

### Subtitle

```
A real terminal, over SSH
```

### Promotional Text

```
A genuine SSH session on iPhone and iPad: a real PTY, true colour, scrollback you can search, and private keys that stay in the Keychain.
```

### Keywords

```
ssh,terminal,shell,server,sysadmin,devops,console,ed25519,keychain,xterm,vt100,scrollback,tty
```

### Description

```
SuperTerminal is an SSH client for iPhone and iPad. It opens a real interactive session on a server you already have, allocates a real PTY, and draws what the far end sends with its own terminal emulator — no web view, no relay of ours in the middle, and no account to create.

Commands you type run on your own remote machines. SuperTerminal is the terminal; the work happens on the servers you connect to.

A REAL TERMINAL
Its own VT/ANSI emulator, written for this app. 256 colours, alternate screen, mouse reporting, and correct cell widths for CJK, emoji, combining marks and flags — checked against the Unicode 17.0.0 tables. Editors and pagers behave: vim and less are run over a real SSH connection by the test suite on every change, including a resize in the middle of an edit.

MORE THAN ONE MACHINE
Open several servers at once. Sessions are independent and switching between them costs nothing. Each connection reports what the server is running — macOS, Linux, one of the BSDs, Windows — detected over a channel of its own, and overridable by hand when you know better.

HOST KEYS YOU ARE ASKED ABOUT
The first time you reach a server, SuperTerminal shows you the key it presented and waits. If a key later changes, you are told plainly and the connection stops until you decide — it is never accepted quietly. Known hosts are yours to inspect and to remove.

KEYS THAT STAY ON THE DEVICE
Generate Ed25519 or ECDSA P-256 keys in the app, copy the public half to your server, and leave the private half in the Keychain, where the app never displays it and never sends it anywhere. A key can be put behind Face ID or Touch ID when you create it. Existing OpenSSH keys import, including passphrase-protected ones. RSA keys you already have keep working (rsa-sha2-256 and rsa-sha2-512; SHA-1 is refused on purpose).

MADE FOR TOUCH, AND FOR A KEYBOARD
A key row that gives you Escape, Tab, Control, arrows, Home, End and page keys — the keys a software keyboard does not have and a terminal cannot do without. Pinch to resize, and the remote program is told. On iPad: a sidebar beside the terminal, a second window when you want one, and hardware-keyboard shortcuts that land where you expect — new connection, command palette, next and previous session, close, and font size.

FINDING THINGS AGAIN
Search the scrollback of a live session, with matches counted and stepped through, including matches that span a wrapped line. A command palette with real fuzzy ranking reaches connections, open sessions, snippets and actions. Snippets insert text on the line and wait for you to press Return, rather than running it.

QUIET BY DEFAULT
Command history is off until you turn it on, and turning it off deletes the file rather than hiding the list. Copied terminal text expires from the clipboard, by default after a minute. Multi-line pastes ask first. The terminal can be hidden in the App Switcher. The app itself can be locked with a passcode of its own, with Face ID or Touch ID in front of it.

PRIVACY
There is no account, no telemetry and no analytics. Your connections, keys and snippets live on your device. Nothing about what you type or what a server sends is collected by the developer, because none of it is sent anywhere except to the server you chose.

English, Simplified Chinese and Traditional Chinese throughout. Terminal output is never translated.

Requires iOS or iPadOS 17.0 or later. You supply the servers; SuperTerminal connects to them.
```

---

## Core features, as short lines

Usable on a web page, in a release post, or as the bullets in a listing that wants them.

1. **A real interactive SSH session** — a genuine PTY on your own server, not a
   line-by-line remote command runner.
2. **Its own terminal emulator** — 256 colours, alternate screen, mouse reporting, and
   correct widths for CJK, emoji and combining marks.
3. **Full-screen programs run** — `vim` and `less` are exercised over a real SSH
   connection by the test suite, including a resize mid-edit.
4. **Several servers at once** — independent sessions, and each connection says what the
   server is running.
5. **Host keys you are asked about** — the fingerprint is shown before the first
   connection, and a changed key stops the connection until you decide.
6. **Keys generated on the device** — Ed25519 or ECDSA P-256, private half in the
   Keychain, optionally behind Face ID or Touch ID.
7. **Searchable scrollback** — matches counted and stepped through, across wrapped lines.
8. **A key row and hardware shortcuts** — Escape, Tab, Control and arrows on the phone;
   a sidebar, a second window and keyboard shortcuts on iPad.
9. **Snippets and a fuzzy command palette** — a snippet is placed on the line, not run;
   the palette ranks by match quality, not by substring.
10. **Off by default** — no history until you ask for it, clipboard entries that expire,
    and an app lock with a passcode of its own.

## Privacy and security, in plain terms

* **No account, no telemetry, no analytics.** Nothing is collected by the developer.
* **Nothing is relayed.** The app connects to the server you name, directly.
* **Private keys stay in the Keychain**, with explicit protection classes, and are never
  shown in the interface or included in anything the app exports.
* **A key can require Face ID or Touch ID** before it is used, chosen when the key is made.
* **Host keys are verified**, recorded on first use, and a change is surfaced rather than
  absorbed.
* **Command history is opt-in**; turning it off deletes the file.
* **Copied terminal text expires** from the system clipboard, by default after 60 seconds.
* **The terminal can be hidden** from the App Switcher snapshot.
* **The app can be locked** behind a passcode of its own, with biometrics in front of it.

Nothing in this section is a guarantee against every threat; it is a description of what
the app does. The project's threat model is in `SECURITY.md`.

## Short description, for a support page

> SuperTerminal is a native SSH client for iPhone and iPad. It opens a real interactive
> session on your own servers — a genuine PTY, its own terminal emulator, searchable
> scrollback — and keeps your private keys in the device's Keychain. There is no account
> and no telemetry.

## First release — feature summary

> **Not the App Store "What's New" field.** A first version has no "what's new"; this is a
> summary for a release post or a support page. The What's New field should be left empty
> for version 1, or filled with Apple's own suggested first-release text.

SuperTerminal 0.1.0 is the first release. It includes:

* SSH over direct TCP with Ed25519, ECDSA P-256 and RSA (SHA-2) key authentication,
  passphrase-protected keys, and passwords;
* trust-on-first-use host-key verification with an explicit prompt, and a distinct,
  deliberately uninviting path for a key that has changed;
* key generation, import and export of the public half, with an optional biometric gate;
* a terminal emulator with 256 colours, alternate screen, mouse reporting, reflow,
  selection, copy and search;
* several concurrent sessions, automatic reconnection with backoff, and an offer to reopen
  the machines that were open last time;
* an accessory key row, pinch-to-resize, snippets, a fuzzy command palette, and hardware
  keyboard shortcuts;
* an app lock, clipboard expiry, App Switcher shielding, and opt-in command history;
* English, Simplified Chinese and Traditional Chinese.

## Screenshot captions

| # | Title | Subtitle |
| --- | --- | --- |
| 01 | A genuine SSH session | A real PTY, true colour and scrollback, drawn by the app's own emulator. |
| 02 | Several servers, at once | *(iPhone)* Independent sessions, switched between at any time. Each server says what it runs. · *(iPad)* The sidebar keeps every session in reach while the terminal keeps the screen. |
| 03 | The fingerprint comes first | A host you have not met is shown its key and waits for your answer. A changed key is never accepted quietly. |
| 04 | Your keys stay here | Generated on the device, held in the Keychain, and — if you ask — behind Face ID. |
| 05 | Full-screen programs run | Alternate screen, syntax colour, a cursor the remote program places. Editors and pagers behave. |
| 06 | Search the scrollback | Matches found across wrapped lines and stepped through while the session keeps running. |
