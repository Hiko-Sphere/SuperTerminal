# Website copy — English

**Written:** 2026-09-10 · **Version described:** 0.1.0 (1) · **Structure:**
[`WEBSITE_INFORMATION_ARCHITECTURE.md`](WEBSITE_INFORMATION_ARCHITECTURE.md) ·
**Gated by:** [`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md)

This is finished copy, ready to paste. Section letters match the copy anchors in the
information architecture. Text in *italics under a heading* is an instruction to the builder
and is not part of the page.

The site is not deployed. Where a button has no destination, that is because the owner has
not supplied one yet; the IA names the three placeholders and what unblocks them.

---

## A · Global elements

### A.1 · How the name is written

**Apex Terminal**, two words, capital A, capital T, everywhere a person reads it. Never
`ApexTerminal` in prose — that spelling is an identifier. Never `Apex` on its own, including
on second mention and in a chart label. No trademark symbol, no all-capitals setting.

### A.2 · Navigation labels

| Position | Label |
| --- | --- |
| Wordmark | Apex Terminal |
| Nav | Features |
| Nav, under Features | The terminal · Files · Port forwarding · tmux · Remote desktop · On iPad |
| Nav | Security |
| Nav | Privacy |
| Nav | Questions |
| Nav | Support |
| Button | Download |
| Skip link | Skip to content |
| Mobile menu button | Menu |

### A.3 · The download and TestFlight controls

*These strings are used on every page. They say the same thing everywhere, in the same order.
The App Store control is the filled button; TestFlight is the quiet one beside it.*

| Where | Control | Label | Supporting line beneath, where there is room |
| --- | --- | --- | --- |
| Header, every page | Primary | Download | — |
| Home hero | Primary | Download on the App Store | Free. iPhone and iPad, iOS and iPadOS 17 and later. |
| Home hero | Secondary | Read how the keys work | — |
| Foot of every feature page | Primary | Download on the App Store | Free, with no in-app purchase. |
| Foot of every feature page | Secondary | See what is stored on your device | — |
| Download page | Primary | Download on the App Store | Free. No in-app purchase, no subscription, no account. |
| Download page | Secondary | Join the TestFlight build | A build in testing. It expires, and it can have faults the App Store version does not. |

App Store badge alt text: `Download on the App Store`.

**If the App Store link is not live yet.** Do not render a dead button. Render this line
where the button would be, in the same position and the same weight:

> Apex Terminal is not on the App Store yet. This page will carry the link when it is.

### A.4 · The one-line description, used in the footer and in link previews

> A full SSH workstation for iPhone and iPad — your keys never leave the device.

---

## B · Home — `/`

### B.1 · Hero

**Headline**

> One connection. Your shell, your files, your desktop, your tunnels.

**Subhead** *(the approved fifty-word paragraph, verbatim)*

> Apex Terminal is an SSH client for iPhone and iPad. One connection carries your shell, your
> files, your desktop and your tunnels — one handshake, one authentication, one biometric
> prompt. Keys can be generated inside the Secure Enclave, where the private half cannot
> leave. No account, no back end, nothing measured.

**Primary CTA:** Download on the App Store
**Secondary CTA:** Read how the keys work

**Under the buttons**

> Free. iPhone and iPad, iOS and iPadOS 17 and later. Commands run on your own servers.

**Hero image alt text**

> An iPhone showing a terminal session over SSH: a shell prompt, coloured `ls` output, and a
> running program redrawing the screen.

### B.2 · The three pillars

*Three cards, equal weight, in this order. Each has a heading, two sentences, and a link with
a full label.*

**One connection, not four**

> Open a shell, a file browser, a remote desktop and a port forward on the same server and
> you pay for one TCP connection, one key exchange, one authentication and one biometric
> prompt. They are channels on a single pooled SSH transport, not four separate logins.
>
> Link: *See what rides on one connection*

**A key that cannot leave the phone**

> A key generated in the Secure Enclave has no private half outside the chip. There is no key
> file, so there is nothing to export, back up or steal — and it logs in to an ordinary,
> unmodified OpenSSH server.
>
> Link: *Read how the keys work*

**A terminal you can work in**

> True colour, sixel pictures, mouse reporting, an alternate screen that puts your shell back
> exactly as it was, and cell widths taken from the Unicode tables so text lines up in the
> grid. The file browser, the tmux client and the remote desktop are built the same way.
>
> Link: *Look at the terminal in detail*

### B.3 · The section teasers

*One block per feature page, in site-map order. Heading, one paragraph, one link.*

**The terminal** — Your programs draw what they meant to draw: 24-bit colour and 256 colours,
the alternate screen, sixel pictures, mouse reporting in three modes, reflow on a width
change, and search across the whole scrollback.
Link: *Look at the terminal in detail*

**Files** — Browse your server over SFTP on the same SSH connection as your shell. Upload,
download, rename, make folders, set permissions, and keep several remote folders open at
once.
Link: *See how files work*

**Port forwarding** — Local, remote and dynamic SOCKS5 rules, saved with a connection and
started with it. Each rule shows bytes out, bytes in, how many connections are open now and
how many it has carried.
Link: *See what a forward shows you*

**tmux** — Apex Terminal speaks tmux's own control protocol, so the panes on screen are
tmux's arrangement rather than text scraped off a screen. Detach, put the iPad down, attach
again.
Link: *Read how tmux is handled*

**Remote desktop** — A machine's screen in the same app as your terminals, travelling inside
your SSH connection, so nothing has to be exposed to the internet.
Link: *See the remote desktop*

**On iPad** — Split a pane and watch a log while you work. Each pane is a full session with
its own toolbar, and a session can be opened in a second window beside another app.
Link: *See what iPad adds*

**Security and keys** — Secure Enclave keys, OpenSSH certificates, ProxyJump through a
bastion, agent forwarding with the device acting as the agent, and a changed host key that
stops the connection instead of asking you to tap through.
Link: *Read how the keys work*

### B.4 · A fact worth checking, placed between the teasers and the pricing

*A short band, one paragraph. This is the page's proof point.*

> Four things on one server cost one TCP connection, one key exchange, one authentication and
> one biometric prompt. The count in that sentence is not the app's own report of itself — it
> is taken from the server's log, by a test that opens four channel types against a real
> `sshd` and reads back how many times it authenticated.

### B.5 · Pricing on the home page

*Use section K, in full. It is short enough to sit on the home page without a link-out.*

### B.6 · Closing CTA

**Heading**

> Free, and there is nothing else to it

**Body**

> No account to create, nothing to buy, and no back end operated by us. You supply the
> servers; the app connects to them.

**Primary CTA:** Download on the App Store
**Secondary CTA:** See what is stored on your device

---

## C · The terminal — `/terminal`

### C.1 · Header

**H1**

> The terminal, not an approximation

**Standfirst**

> This is the part most mobile terminals get approximately right, and approximately right is
> what makes a phone a place you check a log rather than a place you work. Here is what the
> emulator actually does, and where it stops.

### C.2 · What it draws

> **24-bit true colour and 256 colours**, in both SGR spellings, so `ls --color`, syntax
> highlighting and a powerline prompt show the colours the program asked for rather than an
> approximation of them.
>
> **The alternate screen.** Quitting vim, less or htop reveals the shell output that was
> underneath, untouched, and the program's redraws never pollute your history.
>
> **Sixel pictures.** A plot from gnuplot, or an image sent through `img2sixel`, is a real
> picture on the screen rather than a block of unreadable characters. Sixel is the picture
> protocol this app decodes; other inline-image protocols are not part of what is being
> claimed here.
>
> **Mouse reporting**, in all three tracking modes, with modifiers, wheel and drag. Taps,
> drags and two-finger scrolling reach htop, tmux and less as real mouse events.
>
> **Correct cell widths** for Chinese, Japanese and Korean text, emoji and combining marks.
> The width table is generated from Unicode 17.0.0 rather than maintained by hand, which is
> why a status line in vim does not tear when the text is not Latin. This is a statement
> about how text is drawn on screen; entering CJK text with a system input method is a
> separate matter and is not claimed here.
>
> **Reflow on a width change**, so rotating the device or opening a split does not shred what
> is already on screen, and the server is told the new grid size so a full-screen program
> redraws to fit it.
>
> **Scrollback with block selection, and search across all of it.** Find the error that went
> past three screens ago, including when the word it contains was split across a wrapped
> line.
>
> **OSC 7, OSC 52 and OSC 133** — the shell's working directory, the clipboard, and shell
> integration marks. A pane is labelled by the directory it is actually in; a new pane can
> start where the last one was; and the app knows where a command began and what it exited
> with.
>
> **Any monospaced font on your device**, with your own size and line height. Every family on
> the device is measured rather than trusted, so a face that claims to be monospaced and is
> not will not be offered to you.

### C.3 · The part that was tested by trying to break it

> A terminal is judged by what hostile output does to it. The fuzz suite here was not merely
> run until it passed — an invariant was deliberately broken to confirm the suite would catch
> it. Twenty thousand lines of burst output are consumed within a bounded scrollback, and
> corrupt escape sequences do not wedge the parser.
>
> vim, less and htop are exercised over a real PTY against a real OpenSSH server, and a
> resize in the middle of a session reaches the running program.

### C.4 · Where it stops

> Three built-in themes, light and dark. The scrollback lives in memory and is never written
> to disk, so it goes when the session does. Blinking text is parsed but drawn as ordinary
> text; the cursor blinks, the text does not.

### C.5 · Next

> Next: *how tmux is handled*, and *what iPad adds*.

---

## D · Files and the Files app — `/files`

### D.1 · Header

**H1**

> Your server's files, on the connection you already opened

**Standfirst**

> The usual arrangement is a terminal app and a separate SFTP app, each with its own login,
> its own stored password and its own idea of which server you meant. Here the file browser
> is a channel on the SSH connection your shell is already using: no second sign-in, no
> second password.

### D.2 · In the app

> List, read, write and rename over SFTP. Upload, download, make folders, delete, and set
> permissions. The transfer that matters is the one that goes wrong, so: a running transfer
> can be paused and picked up again, and a transfer that fails starts over rather than
> resuming from the byte it stopped at — that is a deliberate refusal, not a gap.
>
> **Several remote folders at once.** Two file browsers at the same time — the same server
> twice, or two different servers — and on an iPad, side by side. A file browser is a session
> in the sidebar list, alongside your terminals and screens, rather than a sheet you open and
> dismiss.

### D.3 · In the Files app

> Turn on "Show in the Files app" for a connection and the server appears in Files, where any
> app that can open a document can reach it. Nothing is copied to iCloud on the way; the
> bytes come off your server over the same SSH connection.
>
> An upload from the Files app that is cut off mid-transfer by a dead connection lands whole,
> once, and leaves no temporary file behind on the server. That is tested against a real
> 24 MB upload with the TCP connection genuinely severed, because it is the failure everyone
> in this category has had.

### D.4 · Where it stops

> A download lands in the app's own temporary storage and leaves for another app through the
> share sheet; there is no destination picker. The browser does not notice changes made on
> the server by someone else — pull down to refresh. Transfers stop when iOS suspends the
> app, so a large upload wants the app on screen.

### D.5 · Next

> Next: *what a forward shows you*, and *how the keys work*.

---

## E · Port forwarding — `/port-forwarding`

### E.1 · Header

**H1**

> Tunnels you can see

**Standfirst**

> A port forward is usually a thing you set up once and then wonder about. This one counts
> its own bytes.

### E.2 · The three kinds

> **Local (`ssh -L`).** Point a port on your device at a database or an internal API that the
> server can reach, and use it as though it were running on the device.
>
> **Remote (`ssh -R`).** Ask the server to listen on a port and hand whatever connects there
> back to something running on your device.
>
> **Dynamic (`ssh -D`).** Run a SOCKS5 proxy on the device and send an app's traffic out
> through the server.
>
> Rules are saved on a connection and start with it, so the forwards you always want are
> there when you open the server, without a command to remember.

### E.3 · What each rule shows

> Bytes out, bytes in, how many connections are open right now, and how many the rule has
> carried since it started — live, per rule. A forward that cannot start says why and names
> the port: "Port 8080 on this device is already in use", rather than an error code you have
> to go and look up.

### E.4 · Where it stops

*Stated in the same block as the capability, at the same size. This is not a footnote.*

> A forward runs while the app is on screen. iOS suspends a backgrounded app and its sockets
> stop being served — for work that has to outlive the app, run it under tmux on the server
> instead.
>
> Local and dynamic forwards bind to 127.0.0.1 and nothing else, deliberately. Another device
> on your network cannot use the tunnel, and the phone does not become a gateway.
>
> This is TCP port forwarding, not a VPN. There is no Network Extension, no VPN profile and
> no system-wide traffic capture; `tunnel@openssh.com` and X11 forwarding are refused by
> construction.
>
> The SOCKS5 proxy handles CONNECT, without proxy authentication, and iOS has no system-wide
> SOCKS setting — so apps you can point at a proxy yourself can use it, and apps you cannot
> will ignore it.

### E.5 · Next

> Next: *how tmux is handled*, and *how the keys work*.

---

## F · tmux — `/tmux`

### F.1 · Header

**H1**

> tmux, spoken properly

**Standfirst**

> Most mobile tmux support is a screen-scraper: the app sends keys, reads back the drawn
> characters and tries to work out where the panes are. Apex Terminal speaks tmux's own
> control protocol — the `-C` mode tmux provides for exactly this — so tmux is something the
> app drives rather than something it guesses at.

### F.2 · What that buys you

> The panes on screen are tmux's own arrangement, including layouts the app's own splitter
> cannot express. Turn on "Attach to tmux" for a connection, give the session a name, and
> opening that connection puts you inside it.
>
> Detach, put the iPad down, come back an hour later and attach again: the windows, the
> panes, and the output that was on them are still there. A long-running job on a server
> becomes something a phone can be a second seat at.
>
> This is measured against tmux 3.3a in a Debian container. The version is named because it
> is the version that was run.

### F.3 · Where it stops

> Scrolling inside a tmux pane is local, over roughly 2 000 captured lines. It is not tmux's
> own copy mode, and it is not a search of your tmux history.
>
> An ordinary terminal session comes back on its own after the network drops, with the
> scrollback intact and the new shell marked as fresh. A tmux session is different: it keeps
> running on the server, which is the reassuring half, but reattaching to it is something you
> do rather than something that happens.

### F.4 · Next

> Next: *look at the terminal in detail*, and *see what iPad adds*.

---

## G · Remote desktop — `/remote-desktop`

### G.1 · Header

**H1**

> The desktop, inside your SSH connection

**Standfirst**

> Sometimes the thing you need is not on the command line: an installer that insists on a
> window, a NAS admin page that renders as a desktop, a machine whose problem is visible
> rather than loggable. Apex Terminal opens a remote screen over VNC in the same app as your
> terminals.

### G.2 · The route is the point

> A screen can travel inside your SSH connection, over the same kind of channel `ssh -L`
> uses. The VNC server can stay bound to the machine's own loopback address, with nothing
> exposed to the internet and no extra port opened in a firewall — and the picture is inside
> SSH's encryption on the way to you.
>
> It is a session in the sidebar list, beside your shells and your file browsers, so
> switching to the desktop is the same gesture as switching to a terminal.

### G.3 · Using it from a touch screen

> Touch to click, with drag and scroll. A key row supplies the keys a touch keyboard does not
> have, and your clipboard can be sent across.

### G.4 · Where it stops

> The encodings it decodes are ZRLE, Hextile, RRE, Raw and CopyRect. A server configured to
> offer Tight, JPEG or TRLE and nothing else will not draw, so it is worth a glance at your
> server's configuration before you assume the network is at fault.

### G.5 · Next

> Next: *see how files work*, and *what a forward shows you*.

---

## H · On iPad — `/ipad`

### H.1 · Header

**H1**

> Built for the iPad you already work on

**Standfirst**

> The audience for this app is largely people who have decided their iPad is a work machine
> and are tired of being told it is not. Four things carry that, and all four are real on a
> device rather than declared in a plist.

### H.2 · Split panes

> Split a pane and watch a log in one half while you work in the other. Each pane is a
> complete session with its own toolbar, not a view of the same session. The divider drags,
> holds a minimum size on both sides, and is adjustable from VoiceOver.

### H.3 · Several sessions at once

> Terminals, remote screens and file browsers are rows in the sidebar list. Move between them
> by tapping, by ⌘1 through ⌘9, or with ⌘⇧[ and ⌘⇧]. Typing follows the session you are
> looking at — which is the sort of thing nobody notices until an app gets it wrong.

### H.4 · A second window

> "Open in New Window" gives a session a window of its own, so a terminal can sit beside the
> document, the ticket or the runbook you are working from.

### H.5 · A hardware keyboard that reaches the app

> A connected keyboard reaches new connection, the command palette, next and previous
> session, session by number, close, and font size. Command is never forwarded to the remote
> host, so ⌘C does what you expect and does not arrive at your shell as a control character.

### H.6 · Where it stops

> This is an iPhone and iPad app, on iOS and iPadOS 17 and later. One app covers both; there
> is nothing separate to buy for the other device.

### H.7 · Next

> Next: *how tmux is handled*, and *see how files work*.

---

## I · Security and keys — `/security`

### I.1 · Header

**H1**

> A key that cannot leave the phone

**Standfirst**

> Most claims in this category mean "the key file is encrypted". This one means there is no
> key file. Below is the whole security story, including the parts that are refusals rather
> than features.

### I.2 · Secure Enclave keys

> Generate an SSH key inside the Secure Enclave and the private half is created in dedicated
> hardware, never exists outside that chip, and cannot be read by any software — this app
> included. There is nothing to export, nothing to back up, nothing to copy off the device
> and nothing for malware on a laptop to find, because the thing it would look for does not
> exist anywhere.
>
> And it logs in to an ordinary, unmodified OpenSSH server. Nothing is installed on the
> server. Nothing is patched. The public half goes into `authorized_keys` the way any public
> key does.
>
> **How that is checked.** A test puts the public half — and nothing else — into a real
> `sshd`'s `authorized_keys`, connects, and asserts on the server's own log line:
> `Accepted publickey … ECDSA <fingerprint>`. A control case in the same test proves the same
> key is refused where it was not authorised, because a test that can never fail proves less
> than one that fails on purpose.

### I.3 · Keys you already have

> Generate an Ed25519 or ECDSA P-256 key on the device, in OpenSSH format — the public line
> pastes into a server and the key still works with `ssh` and `ssh-keygen` on a laptop. Or
> import a key you already have, passphrase and all; the passphrase is asked for when the
> file actually needs one and is not stored.
>
> Keys live in the iOS Keychain, marked so they cannot travel to another device. A key can be
> put behind Face ID or Touch ID if you want that; it is an option you turn on, not something
> the app does to you.

### I.4 · Knowing which server you reached

> The first time you reach a server, its host key fingerprint is put in front of you to
> check. From then on, a server whose key has changed is a hard stop — the connection is
> refused, not turned into a prompt to tap through. That is the case most mobile clients get
> wrong, and it is the case that matters.
>
> If your organisation signs its host keys, trust the certificate authority once and there is
> no fingerprint left to eyeball. OpenSSH host certificates and user certificates are both
> handled, and a certificate that fails validation is refused rather than downgraded into a
> question.

### I.5 · Getting through a bastion, and signing on the far side

> **ProxyJump.** Reach a server that is only reachable through a jump host, with the far
> server's host key and credentials checked as its own rather than the bastion's.
>
> **Agent forwarding, with the device acting as the agent.** A `git push` on the server is
> signed by a key that never leaves your phone — including a Secure Enclave key that cannot
> leave it at all. The key is not sent; a signature is. It works while that session is open,
> and it is a one-way arrangement: the device answers the server, and the server can never
> ask the device to open a channel of its own.

### I.6 · Logging in to servers that ask harder questions

> Servers with PAM, an expired password, or a one-time code prompt log in from the phone. The
> app shows the server's own question, in the server's own wording, and passes your answer
> along. It stores no secret and generates no codes of its own — the second factor stays
> between you and your server.

### I.7 · The wire

> Ciphers offered, in preference order: `aes256-gcm@openssh.com`, `aes128-gcm@openssh.com`,
> `chacha20-poly1305@openssh.com`, `aes256-ctr`. The MAC offered is
> `hmac-sha2-256-etm@openssh.com`. `ssh-rsa` with SHA-1 is refused.
>
> That list is shorter than a reader might assume, and it is short on purpose: a server
> narrowed to a non-ETM MAC with CTR is unreachable from here, and we would rather say so
> than let you find out at 3 a.m.
>
> Post-quantum hybrid key exchange (`mlkem768x25519-sha256`) is offered where the server
> supports it, on iOS 26 and later, so a recorded session is protected against a quantum
> computer built afterwards. Where a server does not offer it, the connection falls back on
> its own.

### I.8 · Around the session

> **Your clipboard is yours.** A program on the server can write to your clipboard once you
> allow it, and can never read it. A read request is refused and is not even reported back to
> the program that asked, so a server cannot learn that you have a clipboard, let alone what
> is in it.
>
> **A link cannot make the app run something.** An `ssh://` link that carries a command shows
> you the exact command, verbatim, and waits for you to agree. Nothing runs from a link on
> its own.
>
> **A lock in front of the app.** Set a passcode of the app's own, separate from your device
> passcode, with a grace period and a delay that grows after repeated wrong guesses.
>
> **A cover in the App Switcher.** The app puts its logo over the window while it is
> inactive, so your terminal is not sitting in the App Switcher for anyone glancing at your
> screen. It does not block screenshots or screen recording, and it is not offered as though
> it did.

### I.9 · What is refused, and why

> **Hardware security keys are not supported.** FIDO2 keys — `sk-ssh-ed25519` and
> `sk-ecdsa-sha2-nistp256` — are refused, and the app says so on its own Keys screen. iOS
> exposes security keys through WebAuthn, which signs a different structure than OpenSSH
> verifies, so an app that offered this would be offering something that cannot work.
>
> **There is no local ssh-agent to connect to.** iOS gives each app its own container and no
> way to reach another app's socket. Agent support here runs the other way: the device is the
> agent, for the server.

### I.10 · Carrying a setup to another device

> Export a backup sealed with a password you choose and which is stored nowhere. A restore
> previews what it would add and what it would collide with before it writes anything. Keys
> that cannot be exported are named in the backup rather than silently dropped, so a restore
> never leaves you believing you have a key you do not have.

### I.11 · Next

> Next: *see what is stored on your device*, and *questions and answers*.

---

## J · Privacy — `/privacy`

*This page is the Privacy Policy URL for App Store Connect. It must be reachable without
JavaScript and must never redirect.*

### J.1 · Header

**H1**

> What stays on your device

**Opening line, and it goes first**

> This page is a summary. The authoritative text is the Privacy Policy inside the app, under
> Settings, alongside the Terms of Use and the User Notice — those are the documents that
> govern, and they are shipped with the version you are running.

### J.2 · The short version

> Apex Terminal collects nothing about you. There is no account to create, no back end
> operated by us, and nothing measured. That is not a promise about intent; it is a fact
> about the build, and it is checkable.
>
> **Apex Terminal has no server of its own. Your data goes only where you send it.**

### J.3 · What is not in the app

> No analytics. No telemetry. No crash reporter. No advertising identifier. No third-party
> SDK of that kind. No sign-up flow. No in-app purchase and no subscription.
>
> These are absences, and an absence cannot have a test — it can have a search anyone can
> repeat in seconds, which is a stronger invitation than a promise. The app's whole
> dependency list is swift-nio, swift-nio-ssl, swift-crypto, swift-sodium and a vendored
> swift-nio-ssh fork. Nothing else. There is nowhere for a tracker to hide.
>
> The privacy manifest shipped in the app declares no collected data types and tracking
> false, which is why the App Store privacy label reads "Data not collected".

### J.4 · What is stored, and where

> **Private keys** are in the iOS Keychain, marked so they cannot travel to another device,
> or in the Secure Enclave, where the private half never exists outside the chip. Neither is
> ever displayed or transmitted by the app. A server sees a signature, never a key.
>
> **Connections, known host keys, trusted certificate authorities and snippets** are in the
> app's own storage, encrypted while the device is locked.
>
> **Passwords** — for servers and for remote screens — are in the Keychain, readable while
> the device is unlocked.
>
> **Terminal scrollback** is in memory and is never written to disk. It is gone when the
> session or the app ends.
>
> **Command history is not recorded unless you turn it on.** Turn it off and the stored file
> is deleted.
>
> **Answers to a server's own questions** — one-time codes, tokens, expired-password prompts
> — are held in memory for the moment it takes to answer the server, and then nowhere.

### J.5 · What leaves the device

> Traffic goes to the servers you connect to: SSH, encrypted end to end between your device
> and your server. Your user name, your key's signature or your password, what you type, and
> what comes back. Your server keeps its own login records, as any server does.
>
> Port forwards move bytes between a listener and a destination you specified, and nothing
> passing through a forward is inspected, recorded or stored.
>
> If you configure an optional feature that talks to a provider of your own choosing, it
> talks to that provider and to nobody else, and it does nothing at all until you have
> configured it. The in-app Privacy Policy sets out each case in full, and it is the document
> to read before you turn anything on.
>
> Nothing goes to the developer. There is no developer server, no analytics service and no
> tracking domain to send it to.
>
> As with any SSH client, whoever operates the network you are on can see which hostnames
> your device connects to. The contents of the connection are encrypted.

### J.6 · Syncing

> This version stores everything on the device you set it up on. There is no cross-device
> sync, and the app says so where you would look for it. To carry a setup to another device,
> export a password-sealed backup and restore it there.

### J.7 · Face ID and Touch ID

> Handled entirely by iOS. The app never sees your face or fingerprint data; it learns
> whether the system's check passed. A key protected this way stops working if a new face or
> finger is enrolled on the device, so someone who learns your device passcode cannot add
> themselves and then use your key.

### J.8 · Closing

> If something here does not match what the app does, the app is the thing that is wrong and
> we would like to know. See the support page.

---

## K · Pricing

*Used in full on the home page and on the download page. Do not shorten it — the value of
this block is that it answers the whole question at once.*

**Heading**

> Free

**Body**

> Apex Terminal is free. There is no in-app purchase, no subscription, no trial that ends, no
> tier that unlocks a feature, and no account to create. There is no purchasing code in the
> app at all: no StoreKit, no in-app-purchase symbol, nothing to buy anywhere in the build.
>
> You supply the servers. The app connects to them.

---

## L · Questions and answers — `/faq`

**H1**

> Questions and answers

**Standfirst**

> Including the awkward ones. If a question you have is not here, the support page has a way
> to ask it.

### What is Apex Terminal?

> An SSH client for iPhone and iPad. It opens a real interactive session on a server you
> already own, allocates a real PTY, and draws what comes back with its own terminal
> emulator. Commands run on your remote machine, not on your phone and not on any server of
> ours.

### What do I need before I start?

> A server you can reach over SSH, and a credential for it — a password, or a key you have
> put in `authorized_keys`. Nothing else. There is no account to create and no service to
> sign up for. If you want a server to try it against, the Remote Login setting on a Mac on
> your own network is enough.

### Which devices does it run on?

> iPhone and iPad, on iOS and iPadOS 17 and later. One app covers both.

### Is it really free? Will that change?

> It is free, and there is no in-app purchase and no subscription. That is a fact about this
> build rather than a promotion: there is no StoreKit code in the app, so there is nothing
> that could charge you.

### Do I need an account?

> No. There is no sign-up, no login to this app, and no back end operated by us. Nothing
> about your setup is stored anywhere except on your device.

### Where are my keys kept?

> In the iOS Keychain, marked so they cannot travel to another device — or, if you generate
> one there, inside the Secure Enclave, where the private half never exists outside the chip
> and cannot be read by any software including this app. A key can additionally be put behind
> Face ID or Touch ID. The security page goes through all of it.

### Can I use a key I already have?

> Yes. Import an existing OpenSSH private key, including a passphrase-protected one. The
> passphrase is asked for when the file needs it and is not stored. Ed25519, ECDSA P-256 and
> RSA keys (with SHA-2 signatures) all work.

### Does it support hardware security keys such as a YubiKey?

> No. FIDO2 SSH keys — `sk-ssh-ed25519` and `sk-ecdsa-sha2-nistp256` — are refused, and the
> app says so on its Keys screen rather than failing quietly. iOS exposes security keys
> through WebAuthn, which signs a different structure than OpenSSH verifies, so this is not a
> gap that a future release closes by trying harder.

### Does it do two-factor authentication?

> Servers that ask for a one-time code log in from the phone: the app shows the server's own
> prompt, in the server's own words, and passes your answer along. It stores no secret and
> generates no codes of its own, so it is your server's second factor, not the app's.

### Will it stay connected while I use another app?

> No, and no app on iOS can promise otherwise. iOS suspends a backgrounded app and its
> sockets stop being served, which matters most for port forwards — a forward runs while the
> app is on screen. For work that has to outlive the app, run it under tmux on the server.

### What happens when the network drops?

> An ordinary terminal session comes back on its own, with the scrollback intact, and the new
> shell is marked as fresh so you know you are not looking at the old one. A tmux session is
> different: it keeps running on the server, but reattaching to it is something you do.

### Does it sync between my devices?

> No. Everything stays on the device you set it up on. To move a setup, export a backup
> sealed with a password you choose and restore it on the other device; the restore shows you
> what it would add and what it would collide with before it writes anything.

### Can I use it as a VPN, or route all my traffic through my server?

> No. This is TCP port forwarding — local, remote and dynamic SOCKS5 — not a VPN. There is no
> Network Extension and no VPN profile, so nothing is captured system-wide. The SOCKS5 proxy
> can be used by apps you are able to point at a proxy yourself; iOS has no system-wide SOCKS
> setting.

### Will Chinese, Japanese and Korean output line up properly?

> Yes. Cell widths for CJK text, emoji and combining marks come from a table generated from
> Unicode 17.0.0 rather than maintained by hand, so a vim status line does not tear and the
> columns after a wide character do not shift.

### Which VNC servers work?

> The encodings decoded are ZRLE, Hextile, RRE, Raw and CopyRect. A server configured to
> offer Tight, JPEG or TRLE and nothing else will not draw, so check what your server offers
> before blaming the network. The screen can travel inside your SSH connection, so the VNC
> server does not need to be exposed to the internet.

### Is my command history saved?

> Not unless you turn it on, and turning it off deletes what was stored. Terminal scrollback
> lives in memory and is never written to disk.

### How do I report a problem?

> The support page says what to include and, importantly, what to take out of a transcript
> before you send it.

---

## M · Support — `/support`

*This page is the Support URL for App Store Connect. It must be reachable without JavaScript
and must never redirect.*

### M.1 · Header

**H1**

> Support

**Standfirst**

> Apex Terminal is made by one developer. Reports get read, and a reply comes from a person.

### M.2 · Try these first

> **The connection will not open.** Check the host name and the port, and confirm you can
> reach the same server from a laptop on the same network. If the server is on your local
> network, iOS may have asked for local network permission the first time and been declined —
> that permission is in the Settings app, under Apex Terminal.
>
> **The server refuses your key.** The public half has to be in `authorized_keys` on the
> server, on one line, with the right permissions on the file and on the `.ssh` directory.
> The Keys screen shows the public line for copying.
>
> **The host key prompt came back, or the connection was refused because the key changed.**
> That is deliberate. A server whose host key has changed is a hard stop. If you know why it
> changed — the server was rebuilt, say — remove the stored entry for that server and connect
> again to check the new fingerprint.
>
> **A full-screen program looks wrong.** Check that `TERM` on the server is something the
> program understands, and that the window size the server thinks you have matches what you
> see; changing the font size tells the server the new grid.
>
> **A port forward will not start.** The message names the port. Something else on the device
> is usually already listening on it.
>
> **A remote screen connects but stays blank.** Check which encodings your VNC server is
> configured to offer; ZRLE, Hextile, RRE, Raw and CopyRect are the ones decoded here.

### M.3 · Reporting a problem

> Send:
>
> * what you did, what you expected, and what happened instead
> * the app version, and your iOS or iPadOS version and device
> * the server's operating system and its SSH version — `ssh -V` on the server
> * whether it happens every time, or once
>
> **Take out before you send:** host names and IP addresses, user names, anything that
> resembles a key, a token, a password or a one-time code, and any output that names systems
> you would rather not name. A redacted report is more useful than one you had to think twice
> about sending. Redact it yourself rather than trusting a transcript to be boring.

### M.4 · What support cannot do

> The app is a client. If a server refuses a login, runs out of disk, or is configured in a
> way that will not let a session start, that is a conversation with your server rather than
> with this app — though if the app's message about it was unhelpful, that is worth reporting
> as its own fault.

### M.5 · Getting in touch

*The contact control uses the address the owner supplies. Button label below; the address
itself is inserted by the build.*

> Button label: **Email the developer**
>
> Beneath: Written in English, Simplified Chinese or Traditional Chinese, whichever suits you.

### M.6 · Also on this site

> *Questions and answers* covers what you need to start, where keys are kept and what happens
> when the network drops.
>
> *What stays on your device* sets out what the app stores and what leaves.
>
> The full Privacy Policy, the Terms of Use, the User Notice and the third-party licences are
> in the app, under Settings.

---

## N · Download — `/download`

### N.1 · Header

**H1**

> Download Apex Terminal

**Standfirst**

> Free, for iPhone and iPad, on iOS and iPadOS 17 and later.

### N.2 · The controls

**Primary:** Download on the App Store — *Free. No in-app purchase, no subscription, no
account.*

**Secondary:** Join the TestFlight build — *A build in testing. It expires, and it can have
faults the App Store version does not.*

*If neither link is live, render section A.3's holding line in place of the buttons.*

### N.3 · What you need

> A server you can reach over SSH, and a credential for it. That is the whole list. If you
> want something to try it against, Remote Login on a Mac on your own network is enough.

### N.4 · What happens when you open it

> A terms screen comes first, and you will be asked to confirm you may connect to the systems
> you are about to connect to. A short tour follows, and can be skipped.
>
> Then: add a connection with a host name, a port if it is not 22, and a user name. Choose a
> password or a key. When you open the connection, the server's host key fingerprint is put
> in front of you to check — that prompt is deliberate, and it is the last time you will see
> it for that server unless something changes.

### N.5 · Pricing

*Use section K in full.*

### N.6 · Before you install

> Read *what stays on your device* if you want to know what is stored before you store
> anything, and *how the keys work* if the Secure Enclave claim is the reason you are here.

---

## O · Footer

*On every page, in every language.*

**Line one, beside the wordmark**

> Apex Terminal — a full SSH workstation for iPhone and iPad. Your keys never leave the
> device.

**Column headings and links**

| Column | Links |
| --- | --- |
| Features | The terminal · Files · Port forwarding · tmux · Remote desktop · On iPad |
| Learn | Security and keys · Privacy · Questions and answers |
| Get it | Download · Support |
| Language | English · 简体中文 · 繁體中文 |

**Legal strip**

> Apex Terminal is an SSH client. Commands run on your own servers.
>
> The Privacy Policy, the Terms of Use, the User Notice and the third-party licences shipped
> with the app are the authoritative texts, and are in the app under Settings.
>
> © 2026 — *(developer legal name, supplied by the owner)*
>
> Apple, iPhone, iPad, iPadOS, Face ID, Touch ID and App Store are trademarks of Apple Inc.
> OpenSSH, tmux and Unicode are the property of their respective owners.

---

## S · Page titles and descriptions

The English `<title>`, `<meta name="description">`, Open Graph and Twitter Card values are
tabulated in [`WEBSITE_INFORMATION_ARCHITECTURE.md`](WEBSITE_INFORMATION_ARCHITECTURE.md)
§6 and §7, so that there is one copy of each string rather than two that can drift. The
Chinese equivalents are written in their own copy files, in Chinese.
