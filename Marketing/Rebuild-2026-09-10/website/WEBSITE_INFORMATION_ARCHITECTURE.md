# Website information architecture — Apex Terminal

**Written:** 2026-09-10 · **Version described:** 0.1.0 (1), iOS and iPadOS 17 and later ·
**Gated by:** [`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md) and
[`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md) ·
**Language kit:** [`../strategy/MESSAGING_SYSTEM.md`](../strategy/MESSAGING_SYSTEM.md)

---

## 0 · Status, read this before anything else

**The site is not deployed.** There is no web project in this repository and no hosting has
been arranged. Everything here — this document and the three copy files beside it — is a
handover package for whoever builds the site. Nothing described below exists on the
internet today.

**Three links in this package are placeholders the owner must supply.** They are written in
the copy files as button labels with no destination, and they are named here as tokens so a
build can fail loudly rather than ship an empty `href`:

| Token | What it is | Who supplies it | Blocked until |
| --- | --- | --- | --- |
| `APP_STORE_URL` | The App Store product page for Apex Terminal | Owner | The app is accepted; App Store Connect issues the URL |
| `TESTFLIGHT_URL` | The public TestFlight invitation link | Owner | A build is uploaded and a public link is enabled in App Store Connect |
| `SUPPORT_EMAIL` | The address on the support page and in the footer | Owner | The owner decides which address to publish |

Two further values are owner-supplied and are not marketing decisions: `DEVELOPER_LEGAL_NAME`
for the footer copyright line, and the domain itself. `apexterminal.dev` is assumed
throughout because that is what the App Store metadata proposes; if the owner registers
something else, the URL column below is the file that changes.

The build must not ship a page containing an unresolved token. Until `APP_STORE_URL` and
`TESTFLIGHT_URL` exist, the download page renders its "what you need" and "what happens when
you open it" copy without a button, and the header's download control links to `/download`
rather than off-site.

**Why these pages matter beyond marketing.** App Store Connect will not accept a submission
without a reachable Support URL and a reachable Privacy Policy URL. `/support` and `/privacy`
are therefore not optional pages; they are submission blockers, and they are the two pages to
build first.

---

## 1 · What the site has to do

Three jobs, in this order. Every decision below is an answer to one of them.

1. **Let a sceptical professional check the claim.** The reader has been sold to badly by
   this category before. The site's job is not to excite them; it is to let them verify.
   Every page states a limit next to the capability it belongs to, because a limit that
   arrives late reads as something that was being hidden.
2. **Satisfy App Review.** A live support page and a live privacy page, both reachable
   without JavaScript, both in three languages.
3. **Send a decided reader to the App Store.** One download control, present on every page,
   saying the same thing everywhere.

**What the site deliberately will not do.** No newsletter, no sign-up, no account, no
analytics, no tag manager, no chat widget, no cookie banner — there is nothing to consent to
because nothing is set. A site that measured its readers would contradict the product's own
central claim in the same breath as making it. This is a design constraint, not a preference;
see §10.

---

## 2 · Site map and URL scheme

Twelve pages, flat. A `/features/` directory level was considered and rejected: the site is
small enough that the extra segment lengthens every URL without helping anyone find anything,
and short URLs survive being read aloud, pasted into an issue, and printed in a footer.

| # | Page | URL | Copy anchor | In header nav | In footer |
| --- | --- | --- | --- | :---: | :---: |
| 1 | Home | `/` | `B` | — (logo) | Yes |
| 2 | Terminal | `/terminal` | `C` | Features | Yes |
| 3 | Files | `/files` | `D` | Features | Yes |
| 4 | Port forwarding | `/port-forwarding` | `E` | Features | Yes |
| 5 | tmux | `/tmux` | `F` | Features | Yes |
| 6 | Remote desktop | `/remote-desktop` | `G` | Features | Yes |
| 7 | iPad | `/ipad` | `H` | Features | Yes |
| 8 | Security and keys | `/security` | `I` | Yes | Yes |
| 9 | Privacy | `/privacy` | `J` | Yes | Yes |
| 10 | FAQ | `/faq` | `L` | Yes | Yes |
| 11 | Support | `/support` | `M` | Yes | Yes |
| 12 | Download | `/download` | `N` | Button | Yes |

### 2.1 · Language routing

Three languages, three originals — the English and the two Chinese texts are written
separately and none is a rendering of another. Traditional Chinese is its own translation and
must never be produced by converting the Simplified characters.

| Language | Prefix | Copy file | `lang` attribute |
| --- | --- | --- | --- |
| English | none — `/terminal` | [`WEBSITE_COPY_EN.md`](WEBSITE_COPY_EN.md) | `en` |
| Simplified Chinese | `/zh-hans/` — `/zh-hans/terminal` | [`WEBSITE_COPY_ZH_HANS.md`](WEBSITE_COPY_ZH_HANS.md) | `zh-Hans` |
| Traditional Chinese | `/zh-hant/` — `/zh-hant/terminal` | [`WEBSITE_COPY_ZH_HANT.md`](WEBSITE_COPY_ZH_HANT.md) | `zh-Hant` |

Rules for the build:

* Every page carries `rel="alternate" hreflang` for all three, plus `x-default` pointing at
  the English page.
* No IP-based redirect. Serve the requested URL. A language control in the footer switches to
  the same page in another language, never to that language's home page.
* The slugs stay in English in all three trees. A reader pasting a URL into an issue should
  get a URL another reader can recognise.

### 2.2 · Files that are not pages

| Path | What it is |
| --- | --- |
| `/robots.txt` | Allows everything; names the sitemap |
| `/sitemap.xml` | All 36 URLs, each with its `hreflang` alternates |
| `/.well-known/security.txt` | A contact route for security reports; uses `SUPPORT_EMAIL` |
| `/og/*.png` | Open Graph images, one per page group (§7.3) |

There is no `/terms` page. The Terms of Use, the User Notice and the third-party licences
live inside the app, under Settings, and are the authoritative texts. The site does not
restate them, because a second copy of a legal text is a second copy that can drift. `/privacy`
is a summary and says so in its opening line.

---

## 3 · What each page has to accomplish

Each brief names the one thing the page must achieve, the claims it is allowed to use, the
proof it must show, and the limit it must state on the same screen as the capability.

### 3.1 · Home — `/`

**Must accomplish:** in one screen, tell a professional what this is and give them one
checkable fact; in one scroll, give them a reason to open a feature page or the App Store.

* **Claims:** C1, C2, C3, C4, C5, C24.
* **Proof on the page:** the arithmetic — one TCP connection, one key exchange, one
  authentication, one biometric prompt (P1); and the sentence that only the public half of a
  Secure Enclave key is placed in `authorized_keys` (P2).
* **Limit stated here:** the app is for iPhone and iPad, iOS and iPadOS 17 and later. Nothing
  else is implied.
* **Shape:** hero, three pillars, seven teasers (one per feature page), pricing, closing CTA.
* **Screenshot:** `01-terminal.png` from the iPhone 6.9-inch set, above the fold.

### 3.2 · Terminal — `/terminal`

**Must accomplish:** convince a reader who has been disappointed by a mobile terminal before
that this one draws what their programs actually send.

* **Claims:** C3, C20.
* **Proof:** the character-width table is generated from UCD 17.0.0 (P6); the fuzz suite was
  shown to catch a deliberately broken invariant (P7); vim, less and htop draw over a real
  PTY and put the shell back as it was.
* **Limits on the same screen:** sixel is the picture protocol that works — no other inline
  image protocol is claimed; three built-in themes, light and dark; correct CJK cell widths
  is a statement about display, not about typing.
* **Screenshots:** `01-terminal.png`, `03-panes.png`.

### 3.3 · Files — `/files`

**Must accomplish:** replace the second app. Show that files ride the same connection.

* **Claims:** C4.
* **Proof:** an upload from the Files app interrupted mid-transfer lands whole, once, and
  leaves no temporary file on the server (P10).
* **Limits on the same screen:** a failed transfer starts over rather than resuming from a
  byte offset; the browser does not refresh itself when the server changes; a download leaves
  through the share sheet.
* **Screenshot:** `04-files.png`.

### 3.4 · Port forwarding — `/port-forwarding`

**Must accomplish:** make a forward feel inspectable rather than magical.

* **Claims:** C6, C7.
* **Proof:** bytes out, bytes in, connections open now, connections carried in total — per
  rule, live.
* **Limits on the same screen:** local and dynamic forwards bind 127.0.0.1 and nothing else;
  a forward runs while the app is on screen, because iOS suspends a backgrounded app and its
  sockets stop being served; this is TCP forwarding, not a VPN; the SOCKS5 proxy handles
  CONNECT, and iOS has no system-wide proxy setting.
* **Screenshot:** `05-forwards.png`.

### 3.5 · tmux — `/tmux`

**Must accomplish:** explain the difference between speaking a protocol and scraping text,
to a reader who already knows what tmux is.

* **Claims:** C8.
* **Proof:** measured against tmux 3.3a in a Debian container — the version is named because
  it is the version that was run (P11).
* **Limits on the same screen:** scrolling is local over roughly 2 000 captured lines, not
  tmux copy mode; a tmux session keeps running on the server after a drop, and reattaching is
  something the reader does.
* **Screenshot:** `06-tmux.png`.

### 3.6 · Remote desktop — `/remote-desktop`

**Must accomplish:** show that the desktop arrives inside the SSH connection, so nothing has
to be exposed to the internet.

* **Claims:** C9.
* **Proof:** the route is the same `direct-tcpip` channel `ssh -L` uses.
* **Limits on the same screen:** the encodings are named — ZRLE, Hextile, RRE, Raw and
  CopyRect — so a reader can tell in five seconds whether their server is covered, and a
  server configured to offer Tight or TRLE and nothing else will not draw.
* **Screenshot:** `08-desktop.png`.

### 3.7 · iPad — `/ipad`

**Must accomplish:** speak to the audience that will keep the app open all day.

* **Claims:** C10, C11, C24.
* **Proof:** split panes tested against a real `sshd` on both an iPhone 17 Pro and an
  iPad Pro 13-inch M5; the divider has a minimum size and a VoiceOver-adjustable action.
* **Limits on the same screen:** sessions, screens and file browsers are rows in the sidebar
  list. **The word "tabs" must not appear on this page or anywhere on the site** — there is no
  tab bar in the app, and a reader who goes looking for one will file it as a missing feature.
* **Screenshot:** `03-panes.png`, iPad set.

### 3.8 · Security and keys — `/security`

**Must accomplish:** carry the whole second pillar, in enough detail that a security-minded
reader stops looking for the catch.

* **Claims:** C2, C12, C13, C14, C15, C16, C17, C18, C19, C21, C23.
* **Proof:** P2, P3, P8, P9 — including the control case that proves the same key is refused
  where it was not authorised, which is the part that makes the rest believable.
* **Limits on the same screen:** hardware security keys are refused, and the app says so on
  its own Keys screen; Face ID or Touch ID can gate a key or the app lock and is described as
  an option; post-quantum hybrid key exchange applies where the server supports it, on iOS 26
  and later; the app hides your terminal in the App Switcher and does not block screenshots.
* **Screenshot:** `07-security.png`.

### 3.9 · Privacy — `/privacy`

**Must accomplish:** satisfy App Store Connect's Privacy Policy URL requirement, and give a
reader the short version of a document they will not read in full.

* **Claims:** C5.
* **Proof:** P4 and P5 — the absences are grep-provable, and the whole dependency list is
  short enough to print.
* **Required framing:** the page's opening line says it is a summary and that the
  authoritative text is the Privacy Policy inside the app, under Settings. The page links to
  nothing that would contradict it.
* **Required care:** no absolute sentence about data never leaving the device. The approved
  formulation is used verbatim.

### 3.10 · FAQ — `/faq`

**Must accomplish:** answer the questions that would otherwise become support mail, and
answer the awkward ones plainly enough that the reader trusts the rest.

* At least ten questions, each with a real answer. The awkward ones — hardware security
  keys, background connections, syncing between devices, whether the price will change — are
  answered rather than avoided.
* Each answer is a paragraph, not a sentence fragment. Where an answer belongs to a page, it
  links there.
* Marked up with `FAQPage` structured data, generated from the same copy.

### 3.11 · Support — `/support`

**Must accomplish:** satisfy App Store Connect's Support URL requirement, and get a useful
bug report out of someone who is annoyed.

* Self-serve first: the three or four things that fix most problems.
* Then: exactly what to include in a report, and — stated plainly — what to leave out. A
  person sending a terminal transcript should be told to remove hostnames, user names and
  anything a key or a token might be sitting in.
* The contact control uses `SUPPORT_EMAIL`. No form. A form needs a back end, and there is
  no back end.

### 3.12 · Download — `/download`

**Must accomplish:** convert, and set expectations so the first launch is not a surprise.

* Requirements, the two buttons (`APP_STORE_URL`, `TESTFLIGHT_URL`), what you need before you
  start, what happens on first launch, and the pricing statement repeated in full.
* TestFlight is described as a build in testing, with the plain consequence: it expires, and
  it may have faults the App Store build does not.

---

## 4 · Navigation

### 4.1 · Header

Persistent, on every page, in this order:

`Apex Terminal` (wordmark, links to `/`) · `Features` · `Security` · `Privacy` · `FAQ` ·
`Support` · **`Download`** (the one filled button on the page)

* `Features` is a disclosure holding the six feature pages in the order of the site map. It
  must work as a `<details>`/`<summary>` or a button-driven menu with real focus management —
  never a hover-only menu, which is unusable on touch and with a keyboard.
* On narrow viewports the header collapses to the wordmark plus `Download`, with everything
  else behind a labelled menu button. `Download` never collapses; it is the conversion path.
* The current page's link carries `aria-current="page"`.

### 4.2 · Footer

Four columns, then a legal strip. Columns: **Features** (six links) · **Learn** (Security,
Privacy, FAQ) · **Get it** (Download, Support) · **Language** (three links, each to the same
page in that language). The legal strip carries the one-line boilerplate, the copyright line
using `DEVELOPER_LEGAL_NAME`, and the Apple trademark acknowledgement.

### 4.3 · Within a page

* Each feature page ends with a "next" pair pointing at the two most closely related pages —
  Terminal → tmux and iPad; Files → Port forwarding and Security; and so on. No "related
  articles" grid; two named links, in prose.
* Long pages (Security, Privacy, FAQ) carry a table of contents built from their own `h2`s,
  placed after the intro, not floating.
* No breadcrumbs. The site is one level deep.

---

## 5 · The conversion path

```
                        App Store search / a link from a friend
                                         │
   Search: "ssh client ipad" ──────► Home  /  ◄────── App Store listing's Marketing URL
                                         │
                     ┌───────────────────┼───────────────────┐
                     ▼                   ▼                   ▼
              a pillar reads       a feature page       the sceptic goes
              true enough to        answers the          straight to
              keep scrolling        actual question      /security or /privacy
                     │                   │                   │
                     └───────────────────┼───────────────────┘
                                         ▼
                                    /download
                                         │
                          ┌──────────────┴──────────────┐
                          ▼                             ▼
                   APP_STORE_URL                 TESTFLIGHT_URL
```

Three things this diagram is asserting:

1. **The sceptic's path is a first-class path.** For this audience `/security` and `/privacy`
   are not compliance pages a reader reaches after being convinced; they are where a reader
   goes *to be* convinced. They therefore carry a download control of their own, and they are
   linked from the header rather than buried in the footer.
2. **Every page can end the journey.** Each page carries the download control in the header
   and a closing CTA in its own words at the foot. Nobody should have to go back to the home
   page to act.
3. **There is one conversion event and it is off-site.** Nothing on this site can be
   submitted, signed up for, or subscribed to. The only thing a reader can do is leave for
   the App Store, and that is by design.

---

## 6 · SEO — title and meta description per page

Titles are written to be read in a result list, not to be stuffed. Format:
`<Page> — Apex Terminal` except the home page, which leads with the approved one-line
boilerplate. Descriptions are 150–160 characters and each contains one concrete fact rather
than a summary of the page.

| Page | `<title>` | `<meta name="description">` |
| --- | --- | --- |
| `/` | Apex Terminal — a full SSH workstation for iPhone and iPad | An SSH client for iPhone and iPad. One connection carries your shell, your files, your remote desktop and your tunnels. No account, no back end, nothing measured. |
| `/terminal` | The terminal — Apex Terminal | True colour, sixel pictures, mouse reporting and an alternate screen, with cell widths generated from Unicode 17.0.0 so CJK text and emoji line up in the grid. |
| `/files` | Files over SFTP — Apex Terminal | Browse your server over SFTP on the same SSH connection as your shell, open several remote folders at once, and reach a connection from the Files app. |
| `/port-forwarding` | Port forwarding — Apex Terminal | Local, remote and dynamic SOCKS5 forwarding, saved with a connection, each rule showing bytes out, bytes in and how many connections it is carrying. |
| `/tmux` | tmux — Apex Terminal | Apex Terminal speaks tmux's own control protocol, so the panes on screen are tmux's arrangement rather than scraped text. Detach, come back, they are still there. |
| `/remote-desktop` | Remote desktop over VNC — Apex Terminal | A machine's desktop in the same app as your terminals, travelling inside your SSH connection, so nothing has to be exposed to the internet. |
| `/ipad` | On iPad — Apex Terminal | Split panes with their own toolbars, several live sessions with typing following the one you are looking at, a second window, and hardware keyboard shortcuts. |
| `/security` | Security and keys — Apex Terminal | Create an SSH key inside the Secure Enclave, where the private half cannot leave the device, and log in to an ordinary, unmodified OpenSSH server with it. |
| `/privacy` | Privacy — Apex Terminal | What Apex Terminal stores, where it stores it, and what leaves your device. No account, no analytics, no telemetry, no crash reporter, no advertising identifier. |
| `/faq` | Questions and answers — Apex Terminal | What you need before you start, where your keys are kept, what happens when the network drops, and why there is no in-app purchase. |
| `/support` | Support — Apex Terminal | What to try when a connection will not open, what to include in a report, and what to remove from a transcript before you send it. |
| `/download` | Download — Apex Terminal | Free on the App Store for iPhone and iPad, iOS and iPadOS 17 and later. No in-app purchase, no subscription, no account to create. |

Chinese titles and descriptions are written in the corresponding copy file's §S, in Chinese,
not translated from the table above.

Other head requirements, on every page:

* `<link rel="canonical">` to the absolute URL of that page in that language.
* No `robots` meta. Nothing here should be hidden from a crawler.
* `SoftwareApplication` structured data on `/` and `/download`, carrying `name`,
  `operatingSystem: "iOS, iPadOS"`, `applicationCategory: "DeveloperApplication"`, and an
  `offers` block with `price: "0"` and `priceCurrency`. No `aggregateRating` and no
  `review` — there are none, and inventing them is exactly the failure this whole rebuild
  exists to avoid.
* `FAQPage` structured data on `/faq` only, and its questions and answers must match the
  visible text word for word.

---

## 7 · Open Graph and Twitter Card

### 7.1 · Fields on every page

| Property | Value |
| --- | --- |
| `og:site_name` | `Apex Terminal` |
| `og:type` | `website` |
| `og:url` | the page's canonical absolute URL |
| `og:locale` | `en_US`, `zh_CN`, `zh_TW` per language tree |
| `og:locale:alternate` | the other two |
| `og:image` | see §7.3 |
| `og:image:width` / `og:image:height` | `1200` / `630` |
| `og:image:alt` | see §7.3 — required, and it is real alt text, not the title again |
| `twitter:card` | `summary_large_image` |
| `twitter:title` / `twitter:description` / `twitter:image` / `twitter:image:alt` | as below |

`twitter:site` and `twitter:creator` are **omitted**. There is no account, and an empty
handle attribute is worse than no attribute.

### 7.2 · Per-page titles and descriptions

`og:title` and `twitter:title` drop the `— Apex Terminal` suffix, because `og:site_name`
already carries it. `og:description` and `twitter:description` are shorter than the meta
description: one sentence, under 120 characters, written to be read on a phone lock screen.

| Page | `og:title` / `twitter:title` | `og:description` / `twitter:description` |
| --- | --- | --- |
| `/` | A full SSH workstation for iPhone and iPad | One connection carries your shell, your files, your desktop and your tunnels — and your keys never leave the device. |
| `/terminal` | The terminal, not an approximation | True colour, sixel pictures, mouse reporting, and CJK cell widths taken from Unicode 17.0.0. |
| `/files` | Your server's files, on the same connection | SFTP over the SSH connection you already opened. Several remote folders at once, and a place in the Files app. |
| `/port-forwarding` | Tunnels you can see | Local, remote and SOCKS5 forwards, each showing bytes out, bytes in, and the connections it is carrying. |
| `/tmux` | tmux, spoken properly | The app speaks tmux's own control protocol, so what you see is tmux's arrangement, not scraped text. |
| `/remote-desktop` | The desktop, inside your SSH connection | A machine's screen in the same app as your terminals, reached without exposing anything to the internet. |
| `/ipad` | Built for iPad | Split panes with their own toolbars, several live sessions, a second window, and a hardware keyboard that reaches the app. |
| `/security` | A key that cannot leave the phone | Generated inside the Secure Enclave, with no private half outside the chip — and an ordinary OpenSSH server accepts it. |
| `/privacy` | What stays on your device | No account, no back end, nothing measured. Here is what is stored, where, and what leaves. |
| `/faq` | Questions and answers | What you need, where the keys are, what happens when the network drops, and why there is nothing to buy. |
| `/support` | Support | What to try, what to send, and what to take out of a transcript before you send it. |
| `/download` | Download Apex Terminal | Free on the App Store. iPhone and iPad, iOS and iPadOS 17 and later. No in-app purchase. |

### 7.3 · The images

Four images, 1200 × 630, PNG, under 300 KB each. Build them from the captured screenshots in
[`../app-store/raw-screenshots/`](../app-store/raw-screenshots/) rather than drawing new
artwork, so that the image a person sees in a link preview is the app they will get.

| File | Used by | Source shot | `og:image:alt` |
| --- | --- | --- | --- |
| `/og/home.png` | `/`, `/download`, `/faq` | `iphone69/<lang>/01-terminal.png` | A phone showing a terminal session with coloured output over SSH, beside the words "One connection, everything". |
| `/og/terminal.png` | `/terminal`, `/tmux`, `/ipad` | `ipad/<lang>/03-panes.png` | An iPad showing two terminal panes side by side, each with its own toolbar. |
| `/og/files.png` | `/files`, `/port-forwarding`, `/remote-desktop` | `ipad/<lang>/04-files.png` | A remote folder listing on an iPad, with file names, sizes and permissions. |
| `/og/security.png` | `/security`, `/privacy` | `iphone69/<lang>/07-security.png` | A key detail screen showing an SSH key held in the Secure Enclave. |

One set per language, at `/og/<lang>/…`, because the screenshots themselves are localised.
Any text drawn onto an image must also exist as real text on the page — an image is not a
place to put a claim.

---

## 8 · Accessibility checklist

Target: **WCAG 2.2 level AA**, verified by hand on a keyboard and with VoiceOver, not by an
automated scan alone. The app itself ships VoiceOver labels and an adjustable split divider;
a site that fell short of the app would be an odd advertisement for it.

**Structure**

- [ ] One `h1` per page, and heading levels descend without skipping.
- [ ] Landmarks: `header`, `nav`, `main`, `footer`. `main` has `id="main"`.
- [ ] A "Skip to content" link is the first focusable element on every page.
- [ ] `<html lang>` is set per language tree; any inline foreign-language phrase carries its
      own `lang`.

**Keyboard and focus**

- [ ] Every control is reachable and operable by keyboard, in a sensible order.
- [ ] The focus indicator is visible against every background it can land on, with at least
      3:1 contrast against the adjacent colour, and is never removed.
- [ ] The `Features` menu opens on click or Enter, closes on Escape, and returns focus to its
      button. No hover-only disclosure anywhere.
- [ ] No keyboard trap. No positive `tabindex`.

**Colour and text**

- [ ] Body text at 4.5:1 against its background; large text and UI borders at 3:1.
- [ ] Terminal-style code blocks are checked separately — the palette that looks right in a
      terminal often fails on white.
- [ ] Nothing is conveyed by colour alone; a byte counter's state also has a word.
- [ ] Text reflows without horizontal scrolling at 320 CSS pixels and at 200% zoom.
- [ ] Text spacing overrides (line height 1.5, paragraph spacing 2em) do not clip content.

**Images and media**

- [ ] Every screenshot's `alt` says what is happening in it, not "screenshot of the app". A
      terminal screenshot's alt names what is on the screen.
- [ ] Decorative shapes are `alt=""` and `aria-hidden`.
- [ ] The App Store badge's `alt` is "Download on the App Store".
- [ ] No text baked into an image that does not also exist as text on the page.

**Motion and interaction**

- [ ] `prefers-reduced-motion: reduce` removes every transition and any autoplaying loop.
- [ ] Nothing autoplays with sound. If a demo loop is added later it needs a pause control.
- [ ] Pointer targets are at least 24 × 24 CSS pixels with adequate spacing (WCAG 2.2
      Target Size, minimum).

**Content**

- [ ] Link text makes sense read alone. No "click here", no "learn more" on its own — the
      copy files give every link a full label for this reason.
- [ ] The language switcher names each language in that language: `English`, `简体中文`,
      `繁體中文`.
- [ ] Abbreviations that carry the argument (SFTP, PTY, SOCKS5, TOFU) are expanded once on
      first use on each page.

---

## 9 · Performance checklist

Budget: **under 120 KB transferred for a first view of any page**, excluding screenshots;
under 400 KB including them. On a throttled 4G profile: LCP under 2.0 s, CLS under 0.1,
INP under 200 ms.

- [ ] Static HTML, pre-rendered. No client-side framework and no hydration. The only
      JavaScript on the site is the `Features` menu and the mobile nav toggle, and both pages
      work with JavaScript disabled.
- [ ] CSS is one file, under 20 KB, with the above-the-fold rules inlined in `<head>`.
- [ ] Fonts are self-hosted, subset to the characters each language tree actually uses,
      `font-display: swap`, preloaded for the one face used above the fold. The Chinese trees
      need a subsetted CJK face or a system font stack; a full CJK web font would blow the
      budget on its own.
- [ ] Screenshots served as AVIF with a WebP fallback, `srcset` at 1×/2×, explicit `width`
      and `height` on every `<img>` so nothing shifts, `loading="lazy"` and
      `decoding="async"` below the fold, eager for the hero.
- [ ] No third-party requests of any kind. No CDN-hosted fonts, no embedded video, no chat
      widget, no analytics, no tag manager. This is checked in CI by asserting that every
      request a page makes is same-origin.
- [ ] Cache headers: immutable, one year, for fingerprinted assets; short for HTML.
- [ ] Compression: Brotli, with gzip as the fallback.
- [ ] A Content-Security-Policy that permits `self` and nothing else, plus
      `Referrer-Policy: strict-origin-when-cross-origin`, `X-Content-Type-Options: nosniff`
      and HSTS.
- [ ] No cookies are set, and no `localStorage` is written. The language preference is a
      link, not a stored value. This is what lets the site have no consent banner, and the
      absence of the banner is itself part of the argument.
- [ ] `prefers-color-scheme` is honoured, and both schemes are checked for contrast.
- [ ] The 404 page is a real page with the header and footer on it.

---

## 10 · Notes for whoever builds this

* **The copy files are the source.** Take the sentences whole. A shortened sentence is a new
  claim, and a new claim has to go back through
  [`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md) before it can be published.
* **Do not add social proof.** No counters, no ratings, no stars, no logos, no "trusted by",
  no testimonials. There are none, and a placeholder version of one is worse than nothing.
* **Do not add a competitor comparison table.** No competitor is named anywhere on this site.
* **Do not name the product `Apex` alone**, and do not use the one-word `ApexTerminal` in
  prose — that spelling belongs to identifiers.
* **The limit sentences are not filler.** Where the copy says a forward runs while the app is
  on screen, or that a failed transfer starts over, that clause is doing the work of making
  the rest believable. It stays in the same visual block as the capability, in the same type
  size. Not a footnote, not a tooltip, not smaller grey text.
* **When the App Store URL arrives**, the buttons appear, `/download` gets its badge, and the
  `SoftwareApplication` structured data gains its `url`. Nothing else about the site changes.
