# FAQ — Apex Terminal 0.1.0

**Prepared:** 2026-09-10 · **Companion to:** [`PRESS_KIT.md`](PRESS_KIT.md) ·
**Gated by:** [`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md) and
[`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md)

Twenty questions a journalist, a reviewer or a customer would actually ask, including the
uncomfortable ones. Each answer says what the app does, and says the boundary in the same
breath. Where the honest answer is "that has not been checked", it says that instead of
reaching for a softer word.

Nothing here introduces a claim that is not in the claims matrix. An answer may be quoted
whole or shortened; a shortened answer that drops the boundary is a different answer.

**The facts underneath every answer:** Apex Terminal 0.1.0, an SSH client for iPhone and
iPad, iOS and iPadOS 17.0 or later. Free, with no in-app purchase and no subscription. No
account. English, Simplified Chinese and Traditional Chinese.

---

### 1 · What is Apex Terminal?

An SSH client for iPhone and iPad. It opens a real interactive session on a server the
customer already owns, allocates a real PTY, and draws what comes back with its own terminal
emulator. One connection carries the shell, the files, a remote desktop and the port
forwards on that server.

It is a single universal app with a layout made for each device family, running on iOS and
iPadOS 17.0 and later. It is not a Mac app, not a web terminal, not a VPN and not a service.

### 2 · Who is it for?

People who already have servers. In rough order: engineers who work from an iPad and want
split panes, a hardware keyboard and tmux; on-call operations staff who need to reach a
machine from a phone at three in the morning without a laptop; owners of a VPS or a home lab
who would rather carry one app than a terminal plus a file-transfer app; people working
inside a bastion, with jump hosts, certificates and agent forwarding; and anyone who wants
their SSH keys off other people's computers.

It assumes the reader knows what SSH is. It does not try to teach that, and it supplies no
servers.

### 3 · Is it free? Why?

It is free. There is no in-app purchase, no subscription, no trial period, no paid tier and
no unlockable feature. Everything described in this kit is in the free download.

The reason is structural rather than promotional. The app has nothing to run: no accounts to
hold, no back end to operate, no relay to pay for, no analytics pipeline to feed. The
customer supplies the servers and the app talks to them. A product with no running costs has
nothing to bill for.

This is checkable rather than promised: there is no StoreKit code in the binary at all, so
there is no mechanism in the build by which the app could charge for anything. Anyone can
search the source tree for it in a few seconds.

### 4 · Is there an account? Is there anything to sign in to?

No, and no. There is no registration, no sign-in, no profile, no licence key, no email
capture and no "continue with" button anywhere in the app. Open it and it shows an empty
list of connections, waiting for a server.

There is also no back end operated by this project — no service, no relay, no telemetry
endpoint, and no domain belonging to this project anywhere in the source. The credentials
the app holds are the ones for the customer's own servers, and they are stored on the
device in the iOS Keychain.

### 5 · What data leaves the device?

**Apex Terminal has no server of its own. Your data goes only where you send it.**

In practice: the app makes SSH connections to the hosts a person types in, and those
connections carry what an SSH connection carries. That traffic goes to their servers. There
is no analytics SDK, no telemetry, no crash reporter and no advertising identifier, and the
privacy manifest declares no collected data types and no tracking.

The reason that sentence is written as "goes only where you send it" rather than "never
leaves your device" is that the second version would be too strong to survive every setting
in the app, and a privacy claim that has an exception is worth less than one that does not.
Connections, keys, snippets and known host keys stay on the device; command history is off
until it is turned on, and turning it off deletes the stored file.

### 6 · Where do commands run?

On the customer's own remote machines. The app runs nothing itself and relays nothing
through any infrastructure belonging to this project. Everything visible in a session came
from a server the person signed in to.

This matters for a reviewer's framing: the content in a screenshot of the app is whatever
that server printed, in the same way that any SSH client is in that position.

### 7 · What does "one connection, not four" actually mean?

Open a shell, a file browser, a remote desktop and a port forward on the same server, and it
costs one TCP connection, one key exchange, one authentication and one biometric prompt.
They are SSH channels on a single pooled transport rather than four separate logins.

On a cellular link, four handshakes are four chances to fail. On a hardware token they are
four touches. Here they are one.

It can be checked from the other end: open those four things and read the server's `sshd`
log. The project's own test does exactly that — it counts the handshake in the server's log
rather than trusting what the client reports about itself — and its adversarial half proves
the pool never returns a connection belonging to another account and never returns a dead
one.

### 8 · What is a Secure Enclave key, and why does it matter?

An SSH key can be generated inside the iPhone's Secure Enclave. The private half is created
in dedicated hardware and never exists outside that chip: there is no key file on disk, no
copy in a backup, no copy to sync, and nothing to exfiltrate from a compromised app. It
still logs in to an ordinary OpenSSH server that nobody had to modify.

Most "your keys are safe" claims in this category mean "the key file is encrypted". This one
means there is no key file.

What stands behind it: the project's test places the public half, and nothing else, into a
real `sshd`'s `authorized_keys`, then asserts on the server's own log line recording an
accepted public key and its fingerprint. A control case in the same suite proves the same
key is refused where it was not authorised.

The boundary worth stating: an enclave key can be configured to require Face ID or Touch ID
before each use, and that is a real option in the app — but biometric hardware has never
been exercised in this project's tests, because a simulator has no biometrics. Treat
"protected with Face ID" as an option the app offers, not as something measured.

### 9 · Can I use SSH keys I already have?

Yes. An existing OpenSSH private key can be imported, including a passphrase-protected one;
the passphrase is asked for when the file needs it and is not stored. Keys can also be
generated on the device in OpenSSH format, as Ed25519 or ECDSA P-256.

The boundaries: the importer reads the `openssh-key-v1` container — the format `ssh-keygen`
has written by default for years. Older PEM and PKCS#8 files, and `.ppk` files, are not
read, so those need converting elsewhere. There is no RSA key generation and no choice of
bit length. Hardware security keys (FIDO2) are refused, and the app says so on its own Keys
screen rather than failing quietly.

### 10 · Do servers that ask for a one-time code work?

Yes — servers with PAM, an expired password, or a one-time-code prompt log in from the
phone. The app shows the server's own question, in the server's own words, and passes the
answer along.

What it is not: there is no authenticator inside the app. It stores no shared secret and
generates no codes. Anyone writing "two-factor authentication built in" would be describing
a different product; the accurate line is that servers with 2FA work.

### 11 · What happens to a session when the network drops?

A terminal session comes back on its own, with the scrollback intact, and the new shell is
marked as fresh so nobody mistakes it for the one that was interrupted.

A tmux session is a different case, and the difference is worth printing: it keeps running
on the server, but reattaching to it is something a person does, not something that happens
by itself.

### 12 · Does it stay connected in the background?

No, and no such promise is made. iOS does not guarantee that an app keeps a socket open once
it is no longer in front, so a connection may be gone when the app comes back — which is
what the reconnection behaviour in question 11 is for.

Anyone who needs work to survive being put down should run it under tmux on the server, and
reattach. That is what tmux is for, and it is why the app speaks tmux's protocol properly.

### 13 · Do my connections sync between my iPhone and my iPad?

No. There is no sync in this version, and the app's own settings screen shows the switch
disabled and says so. What is set up on one device stays on that device.

There is an encrypted backup instead: one sealed file, protected by a password, carrying
connections, saved screens, snippets, key metadata, trusted host keys and preferences. A
restore previews what it would add and what it would collide with before it writes anything.
Private keys travel only if that is chosen explicitly and a password is set; keys held in
the Secure Enclave, and keys gated behind biometrics, have no exportable form and are named
in the backup as unexportable rather than dropped in silence.

### 14 · Is there a Mac version? Vision Pro? Apple Watch?

No, to all three, and none of them should be written up as coming.

It is an iPhone and iPad app: a single universal build, iOS and iPadOS 17.0 or later. There
is no Mac app, native or otherwise. There is no visionOS app. There is no watchOS app.

The precise position, since it tends to come up: every capability described in this kit was
measured on iOS and iPadOS, and no claim in it extends to any other platform.

### 15 · What does the terminal actually handle?

24-bit true colour in both SGR spellings and 256 colours; the alternate screen, so quitting
vim or less puts the shell back exactly as it was; sixel graphics, so a gnuplot plot or an
image through `img2sixel` is a real picture on the screen; mouse reporting in three modes
with modifiers, wheel and drag, reaching htop, tmux and less as real mouse events; reflow on
a width change; scrollback with block selection and search across all of it, including where
a word is split by a wrapped line; OSC 7, OSC 52 and OSC 133 for the working directory, the
clipboard and shell integration; and any monospaced font already on the device at a chosen
size and line height, with the server told the new grid size.

Cell widths for Chinese, Japanese and Korean text, for emoji and for combining marks come
from tables generated from Unicode 17.0.0 rather than a hand-maintained list, which is why
vim's status line does not tear. Hostile or corrupt output does not wedge the emulator: the
fuzz suite behind that was shown to catch a deliberately broken invariant, rather than
merely to pass.

Clipboard behaviour is worth one extra sentence, because it cuts both ways: a program on the
server can write the clipboard once permission is given, and can never read it — a read
request is refused and is not even reported back to the remote program.

### 16 · Can I type Chinese, Japanese or Korean into the terminal?

The honest answer is that the app displays those scripts correctly and that typing them has
not been checked.

Display is measured: the cell widths are generated from Unicode tables and are asserted
against real vim over a real server, which is the part that makes CJK text usable in a
full-screen program. Input through a system input method is implemented and unit-tested, but
it has never been exercised on real hardware with a real input method, so this project does
not claim it. The app's own interface is available in Simplified and Traditional Chinese.

### 17 · Can I get at my server's files?

Yes, over SFTP on the same SSH connection as the terminal — no second sign-in and no second
password. List, read, write, rename, make folders, set permissions, upload and download.
Several remote folders can be open at once: the same server twice, or two different servers,
side by side on an iPad. A connection can also be published to the Files app, so its
documents open from any app that can open a file.

An upload is written under a temporary name and renamed into place, so an interrupted
transfer does not leave something that looks whole. That case is tested: the file lands
whole, once, with no temporary left behind on the server.

Boundaries: SFTP is spoken at protocol version 3, and a server offering more is used at 3.
Deleting through the Files app says Delete rather than "move to Trash", because a server has
no trash to move a file to. A folder must be empty before it can be deleted, because SFTP
has no recursive remove, and the confirmation says so.

### 18 · What about port forwarding, tmux and remote desktops?

**Forwards.** Local, remote and dynamic (SOCKS5) forwarding, saved with a connection and
started with it. Each rule shows bytes out, bytes in, how many connections are open now and
how many it has carried. A forward that cannot start says why and names the port — "port
8080 on this device is already in use", rather than an error number.

**tmux.** The app speaks tmux's own control protocol, so the panes on screen are tmux's
arrangement rather than text scraped from a screen — including layouts the app's own
splitter cannot express. Detach, come back, and the panes and their output are where they
were left. Every protocol shape was measured against tmux 3.3a; no other version has been
exercised. Scrolling inside a tmux pane is local, over roughly two thousand captured lines,
and is not tmux's copy mode.

**Remote desktop.** A screen over VNC, in the same app, reached through the SSH connection
so that nothing has to be exposed to the internet. It decodes ZRLE, Hextile, RRE and Raw, so
a server configured to offer Tight or TRLE alone will not draw. Touch to click, a key row
for the keys a touch keyboard lacks, and the clipboard sent across.

### 19 · What does it not support yet?

Set out plainly, because a reviewer will find these anyway:

* No background connections. iOS does not guarantee them.
* No sync between devices. An encrypted backup file is the way to carry a setup across.
* No Mac, Vision Pro or Apple Watch version.
* No hardware security keys (FIDO2); the app refuses them and says so.
* No RSA key generation; keys are generated as Ed25519 or ECDSA P-256.
* No reading of PEM, PKCS#8 or `.ppk` private keys; the `openssh-key-v1` container is
  what the importer takes.
* No import or export of an existing `~/.ssh/known_hosts`; the record of which key belongs
  to which server is the app's own file.
* No Tight, TRLE or zlib decoding for remote desktops.
* No tmux copy mode, and no search of tmux's own history.
* No screenshot or screen-recording blocking, and no claim of it. What exists is a cover
  over the window while the app is inactive, so the App Switcher shows the logo rather than
  a terminal.
* No verified support for typing CJK into the terminal, per question 16.

None of these is described as arriving. When one of them has been run against something
real, it will be written up then.

### 20 · How does it compare with other SSH clients?

This project does not name other apps, publish comparison tables or quote benchmarks against
anyone, so the useful answer is a list of questions a reviewer can put to any client in the
category, this one included:

1. **Count the handshakes.** Open a shell, a file browser, a forward and a desktop on the
   same server, then read the server's `sshd` log. How many authentications does the client
   cost for four things?
2. **Ask where the private key lives.** Is it an encrypted file, or is there no file at all?
   Can the key be exported? If the answer is "it is encrypted at rest", that is a different
   answer from "the private half was made inside the chip and cannot be read out".
3. **Run a real program.** Open vim, resize the window, put Chinese text in a status line,
   quit — and see whether the shell comes back exactly as it was.
4. **Change a host key.** Point the client at a server whose key has changed. A hard stop is
   the correct behaviour; a prompt to tap through is the case most mobile clients get wrong.
5. **Read the dependency list and the privacy manifest.** How many third-party SDKs are
   linked in, and what do they collect? An absence cannot have a test, but it can have a
   search that takes seconds.
6. **Ask what the app does not do**, and see whether the answer is specific enough to act
   on. "Some servers may not work" is a hedge. "A server offering Tight or TRLE alone will
   not draw" tells a reader whether it affects them.

Where Apex Terminal stands on each of those is written out above, with the test that would
have to fail for it to stop being true. That is the comparison this project is willing to
make: not against another product, but against a check the reader can run.
