# Press kit — Apex Terminal 0.1.0

**Prepared:** 2026-09-10 · **Language of this document:** English ·
**Drawn from:** [`../strategy/MESSAGING_SYSTEM.md`](../strategy/MESSAGING_SYSTEM.md) ·
**Gated by:** [`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md) and
[`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md)

Everything a journalist needs in one file: the product at three lengths, the facts, what is
worth writing about and why, what the app deliberately does not do, the screenshots and
their captions, where the assets are, and the rules for using the name and the images.

The three summaries are approved text. Take one whole. A summary that has been trimmed to
fit a column is a different claim from the one that was checked, so use the next shorter
summary rather than cutting a longer one.

Two things this project does not hold, and will not invent: a press contact address and the
address of a live product page. Both are marked **`OWNER SUPPLIES`** in
[`PRESS_RELEASE.md`](PRESS_RELEASE.md) and are the sender's to fill in.

---

## 1 · The product, at three lengths

### 1.1 · One line — under 15 words

> A full SSH workstation for iPhone and iPad — your keys never leave the device.

*For:* a standfirst, a caption, a listing headline, a bio line.

### 1.2 · Thirty words

> Apex Terminal is an SSH client for iPhone and iPad. One connection carries your shell, your
> files, your remote desktop and your tunnels. No account, no back end, nothing measured.

*For:* a round-up entry, a directory listing, the opening of a short review.

### 1.3 · One hundred words

> Apex Terminal is an SSH client for iPhone and iPad, running on iOS and iPadOS 17 and later.
> Commands run on your own servers. One connection carries your shell, your files, your
> desktop and your tunnels: one handshake, one authentication, one biometric prompt. The
> terminal handles true colour, sixel pictures, mouse reporting and full-screen programs that
> put your shell back as it was. A key can be generated inside the Secure Enclave, where the
> private half cannot leave the device, and it logs in to an ordinary, unmodified OpenSSH
> server. There is no account, no back end and nothing measured.

*For:* an "about the app" box, a long directory entry, the foot of an article.

The same three lengths exist in Simplified Chinese in
[`../strategy/MESSAGING_SYSTEM.md`](../strategy/MESSAGING_SYSTEM.md) §3, and are used the
same way. They are originals, not translations of the English, so quote whichever language
the piece is written in rather than translating from the other.

---

## 2 · Fact sheet

| Field | Value |
| --- | --- |
| Name | Apex Terminal — two words, capital A, capital T |
| What it is | An SSH client. Commands run on servers the customer already owns |
| Version | 0.1.0 |
| Platform | iPhone and iPad. One app, one download, both device families |
| Minimum OS | iOS 17.0 / iPadOS 17.0 |
| Price | Free. No in-app purchase, no subscription, no trial, no paid tier |
| Account | None. Nothing to register, nothing to sign in to |
| Interface languages | English, Simplified Chinese, Traditional Chinese |
| Category | Developer Tools (primary), Utilities (secondary) |
| Age rating | 4+ |
| Network use | SSH to servers the customer names. No back end operated by this project |
| Analytics | None. No telemetry, no crash reporter, no advertising identifier |
| Dependencies | swift-nio, swift-nio-ssl, swift-crypto, swift-sodium, and a vendored swift-nio-ssh fork |
| Product page | `OWNER SUPPLIES` — not live as this kit was prepared |
| Press contact | `OWNER SUPPLIES` |

Two notes on the table, because both are easy to write wrongly:

* **Free is a fact about the build, not a launch offer.** There is no StoreKit code in the
  binary, so there is no mechanism by which the app could charge for anything. Nothing here
  should be written as an introductory price or a limited period.
* **"One app for iPhone and iPad" is literal.** It is a single universal app with a layout
  made for each, not a phone app stretched onto a tablet — the iPad screenshots and the
  iPhone screenshots show different subjects for that reason.

---

## 3 · What is notable, and why

Five things worth a paragraph, each with what stands behind it. They are ordered by how hard
they would be to copy, not by how they look in a screenshot.

### 3.1 · Four things on one server cost one handshake

Opening a shell, a file browser, a remote desktop and a port forward on the same server
costs one TCP connection, one key exchange, one authentication and one biometric prompt.
These are SSH channels on a single pooled transport rather than four separate logins.

*Why it is notable:* it is arithmetic rather than an adjective, and it is architectural — it
falls out of how the connection pool is built, not from a setting. On a cellular link four
handshakes are four chances to fail; on a hardware token they are four touches.

*Behind it:* the pool's tests count the handshake in a real OpenSSH server's own log rather
than trusting the client's self-report, and the adversarial pair in the same suite proves
the pool never returns a connection belonging to another account and never returns a dead
one.

### 3.2 · A key with no key file

An SSH key can be generated inside the Secure Enclave. The private half is created in
dedicated hardware and never exists outside it. There is nothing to export, back up, move or
steal — and it logs in to an ordinary, unmodified OpenSSH server.

*Why it is notable:* most "your keys are safe" sentences in this category mean "the key file
is encrypted". This one means there is no key file.

*Behind it:* the test places the public half, and nothing else, in a real `sshd`'s
`authorized_keys` and asserts on the server's own log line recording an accepted public key
and its fingerprint. A control case in the same suite proves the same key is refused where
it was not authorised. The app's encrypted backup names enclave keys as unexportable rather
than dropping them quietly.

### 3.3 · The terminal is the product

True colour in both SGR spellings, sixel pictures, mouse reporting in three modes, the
alternate screen, OSC 7, OSC 52 and OSC 133, reflow, block selection, scrollback search, and
any monospaced font on the device with the server told the new grid size. Cell widths for
CJK text, emoji and combining marks come from generated Unicode 17.0.0 tables.

*Why it is notable:* it is the difference between checking a log from a phone and doing the
work from one. The Unicode detail is the reason vim's status line does not tear on Chinese
text, and it is checkable — the tables are generated, not hand-maintained.

*Behind it:* vim, less and htop are driven over a real PTY on a real server and are asserted
to put the shell back as it was. The emulator's fuzz suite was shown to catch a deliberately
broken invariant rather than merely to pass.

### 3.4 · tmux spoken as a protocol

The app speaks tmux's own control protocol, so what is on screen is tmux's arrangement —
including layouts the app's own splitter cannot express — rather than text scraped from a
screen. Detach, come back, and the panes and their output are where they were left.

*Why it is notable:* it is what makes a phone a usable second seat at a long-running job,
and it is the part of a mobile SSH client that is usually faked.

*Behind it:* every protocol shape was measured against tmux 3.3a in a container, and the
suite includes a refused command reported in tmux's own words with the session surviving,
and a killed session that ends the stream and fails what was waiting on it.

### 3.5 · Absences that can be checked in seconds

No account. No back end operated by this project. No analytics, telemetry or crash reporter.
No in-app purchase and no subscription.

*Why it is notable:* an absence cannot have a test, so it is usually asserted and left
there. Here the whole dependency list is five entries long and the privacy manifest declares
no collected data types and no tracking, which means a sceptical reader can settle the
question with a search rather than with trust.

---

## 4 · What the app deliberately does not do

This section is here so that a reviewer does not have to discover it, and so that nothing in
this kit reads as an oversight. Each line is a decision or a measured boundary, and none of
them is described as temporary.

**On connections and sessions**

* It does not hold a connection open in the background. iOS does not guarantee it.
* Terminal sessions come back on their own after the network drops, with the scrollback
  intact and the new shell marked as fresh. A tmux session keeps running on the server, but
  reattaching to it is something a person does.
* tmux scrolling is local, over roughly two thousand captured lines. It is not tmux's copy
  mode, and it does not search tmux's own history.
* tmux was measured against version 3.3a. No other version has been exercised.

**On keys and authentication**

* Hardware security keys (FIDO2) are refused, and the app says so on its own Keys screen.
* Keys are generated as Ed25519 or ECDSA P-256. There is no RSA generation and no choice of
  bit length.
* Imported private keys are read from the `openssh-key-v1` container. PEM, PKCS#8 and
  `.ppk` files are not read.
* There is no authenticator inside the app. Servers that ask for a one-time code work
  because the app relays the server's own prompt in the server's own words; it stores no
  secret and generates no codes.
* The record of which key belongs to which server is the app's own file, not OpenSSH's
  `known_hosts` format. There is no import or export of an existing `known_hosts`.
* The cipher list is deliberately short, and a server narrowed to older constructions is
  unreachable rather than accommodated.

**On files**

* SFTP is spoken at protocol version 3. A server offering more is used at 3.
* Deleting through the Files app says Delete rather than "move to Trash", because a server
  has no trash to move a file to, and fields SFTP cannot carry are handed back as not
  applied rather than dropped in silence.
* A folder must be empty before it can be deleted; SFTP has no recursive remove, and the
  confirmation says so.

**On the remote desktop**

* It decodes ZRLE, Hextile, RRE and Raw. A server configured to offer Tight or TRLE alone
  will not draw.

**On the device and the platform**

* There is no sync between devices. What is set up on one device stays on that device.
* There is no Mac version, no Vision Pro version and no Apple Watch app. It is an iPhone and
  iPad app.
* It does not block screenshots or screen recording, and no such claim is made. What exists
  is a cover over the window while the app is inactive, so the App Switcher shows the logo
  rather than a terminal.
* It is not a VPN. There is no Network Extension, no VPN profile and no system-wide traffic
  capture.
* It is not a web terminal and not a service. There is no Apex Terminal account and no Apex
  Terminal server.

**On privacy, stated so that it survives every case**

Apex Terminal has no server of its own. Your data goes only where you send it.

---

## 5 · Screenshots, and their captions

Eight images, in the order they are meant to be read. Every one is a photograph of the
running app against real servers. Nothing is staged, redrawn or composited, and no caption
claims anything the picture does not show.

| # | File | Caption title | Caption subtitle |
| --- | --- | --- | --- |
| 1 | `01-terminal` | A real terminal, over SSH | True colour, a real PTY, and full-screen programs that put your shell back exactly as it was. |
| 2 | `02-one-connection` | One connection. Everything on it. | A shell, your files, a desktop and a tunnel — one handshake, one Face ID prompt, four SSH channels. |
| 3 | `03-panes` | Two terminals, one screen | Split a pane, drag the divider, and watch a log while you work. Each pane is a full session with its own controls. |
| 4 | `04-files` | Your server's files, right here | Browse, upload and download over the same SSH connection — and put the server in the Files app. |
| 5 | `05-forwards` | Tunnels you can see | Local, remote and SOCKS5 forwards saved with a connection, started with it, with live byte and connection counts. |
| 6 | `06-tmux` | Detach. Come back. Still there. | tmux over its own control protocol — the panes and their output are exactly where you left them. |
| 7 | `07-security` | A key that cannot leave your phone | Generate it inside the Secure Enclave. No copy of the private half exists — not to export, not to sync, not to steal. It still logs in to an ordinary OpenSSH server. |
| 8 | `08-desktop` | The desktop, too | A remote screen over VNC, reached through the same SSH connection — nothing exposed to the internet. |

Notes a picture editor will want:

* **Screens 1, 2 and 7 carry the story.** If a piece has room for three, take those: what it
  is, what makes it different, why it can be trusted.
* **The iPhone and iPad sets are different pictures, not one picture at two sizes.** Screen 3
  in particular is split panes on iPad and several live sessions on iPhone, because panes are
  an iPad affordance.
* **Terminal output in every set is in English**, including in the Chinese sets, because that
  is what the server sent. The interface around it is in the language of the set.
* **The Secure Enclave screen** shows a key listed with its real fingerprint and its enclave
  badge. The caption claims what the app does; the hardware property is a sentence, not a
  picture, and is written out in §3.2 above.
* **There is no Face ID prompt in any screenshot**, and none may be staged into one.

---

## 6 · Asset manifest

Paths are relative to the repository root. Nothing here is published anywhere; a kit for a
journalist is assembled from these files, and this project makes no claim that any of it is
hosted or reachable on the web.

### 6.1 · Finished screenshots — 72 images

`Marketing/Rebuild-2026-09-10/app-store/screenshots/<language>/<slot>/<NN-name>.png`

| Part of the path | Values |
| --- | --- |
| `<language>` | `en-US`, `zh-Hans`, `zh-Hant` |
| `<slot>` | `iphone-6.9` (1320 × 2868), `iphone-6.5` (1284 × 2778), `ipad-13` (2732 × 2048) |
| `<NN-name>` | `01-terminal`, `02-one-connection`, `03-panes`, `04-files`, `05-forwards`, `06-tmux`, `07-security`, `08-desktop` |

3 languages × 3 slots × 8 screens = 72 files. Each is 8-bit RGB sRGB PNG with no alpha
channel, at the exact pixel size of its slot. None is scaled into a slot it was not captured
for.

### 6.2 · Contact sheets — 3 images

```
Marketing/Rebuild-2026-09-10/app-store/preview/en-US-contact-sheet.png
Marketing/Rebuild-2026-09-10/app-store/preview/zh-Hans-contact-sheet.png
Marketing/Rebuild-2026-09-10/app-store/preview/zh-Hant-contact-sheet.png
```

One sheet per language, all eight screens at a glance. Use these to choose; use the files in
§6.1 to print.

### 6.3 · Raw captures, without the caption template — 72 images

`Marketing/Rebuild-2026-09-10/app-store/raw-screenshots/<device>/<language>/<NN-name>.png`,
where `<device>` is `iphone69`, `iphone65` or `ipad`.

These are the app on its own, with no title, no subtitle, no rule and no index mark. Take
these when a layout supplies its own caption, so that a caption is not printed twice.

### 6.4 · Icon

```
App/Resources/Assets.xcassets/AppIcon.appiconset/icon-light.png    1024 × 1024
App/Resources/Assets.xcassets/AppIcon.appiconset/icon-dark.png     1024 × 1024
App/Resources/Assets.xcassets/AppIcon.appiconset/icon-tinted.png   1024 × 1024
```

Light, dark and tinted, as iOS uses them. The light icon is the default for print and for a
light page; the dark icon is for a dark page, and is a different drawing rather than the
light one inverted. Rules for using it are in [`MEDIA_KIT.md`](MEDIA_KIT.md) §5.

### 6.5 · Monochrome mark

```
App/Resources/Assets.xcassets/Logo.imageset/logo.png      128 × 128
App/Resources/Assets.xcassets/Logo.imageset/logo@2x.png   256 × 256
App/Resources/Assets.xcassets/Logo.imageset/logo@3x.png   384 × 384
```

A single-colour mark that the app itself tints. It is for small in-line use — a byline chip,
a favicon, a footer — where the full icon would be illegible. It is not a replacement for
the icon at large sizes.

### 6.6 · What this kit does not contain

* **No app preview video.** None has been made, and nothing should be described as one.
* **No lifestyle or hands-on photography.** No device photographs, no desk scenes.
* **No wordmark or logotype.** The name is set in type; there is no drawn wordmark to
  supply, and one must not be improvised. See [`MEDIA_KIT.md`](MEDIA_KIT.md) §2.
* **No developer portrait or biography.** The quote in the release is attributed to the
  developer, and no name is given.
* **No charts, benchmarks or comparison tables.** Nothing in this project has a published
  figure that would survive being printed next to someone else's.

---

## 7 · Using the name

The complete rules are in [`MEDIA_KIT.md`](MEDIA_KIT.md). The short form, for an editor
working to a deadline:

* **Apex Terminal**, two words, capital A and capital T. Not `ApexTerminal`, not APEX
  TERMINAL, not apex terminal.
* **Never "Apex" on its own** — not on second mention, not in a headline, not in a chart
  label. If the name will not fit, rewrite the sentence.
* **No trademark symbol.** None is used by the project.
* **In Chinese text the name stays in Latin script**, with a space on either side. There is
  no Chinese name for the product, and one may not be coined.
* Call it **an SSH client**, or **a terminal app**. It is not a terminal emulator alone, and
  it is not a VPN, a service or a web terminal.

---

## 8 · Using the images

* **Reproduce them whole.** Do not crop into a screenshot to remove a caption, and do not
  crop a capture in a way that makes a claim the whole picture does not make.
* **Do not recolour, filter, blur or re-typeset them.** The captions are approved text; a
  retyped caption is a new claim.
* **Do not composite them into a device photograph**, add a bezel, a shadow, a gradient, a
  reflection or a 3-D perspective. The template has none of those on purpose.
* **Do not place another company's logo on or beside them**, and do not present them in a
  layout that implies a partnership or an endorsement.
* **Scaling proportionally is fine.** Scaling width and height by different amounts is not.
* **Attribution:** "Screenshot: Apex Terminal" is enough. No credit line is required beyond
  the product name.
* **Editorial use is granted** — press, reviews, round-ups, teaching material. Use in
  advertising, on merchandise, or as part of another product's identity is not.

---

## 9 · Where each sentence in this kit comes from

Nothing above was written for this document. Every claim traces to a numbered row in
[`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md), and every row there names the test
that would have to fail for the claim to stop being true. The three summaries in §1 and the
"About Apex Terminal" block in the release are final text in
[`../strategy/MESSAGING_SYSTEM.md`](../strategy/MESSAGING_SYSTEM.md) §3.

If a journalist asks for a claim that is not in this kit, the answer is that it has not been
checked yet — not that it is unavailable for comment. The matrix is the whole reason this
kit is as short as it is.
