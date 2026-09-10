# Competitor differentiation — internal

**Written:** 2026-09-10 · **Classification: internal. Never published, never quoted, never
shown to a customer, a reviewer or a journalist.**
**Gated by:** [`PRODUCT_TRUTH_MATRIX.md`](PRODUCT_TRUTH_MATRIX.md) ·
[`CLAIMS_MATRIX.md`](CLAIMS_MATRIX.md) ·
[`../strategy/POSITIONING.md`](../strategy/POSITIONING.md)

This document exists so that the people writing public copy know what the field actually
looks like, and therefore know which of our own true sentences are worth spending the
reader's attention on. It is a planning input, not a source of copy. Nothing here is
allowed to leak into the store listing, the website, the press kit or a social post — see
§9.

---

## 1 · Method, and what "checked" means here

Every factual line about another product below was read on **2026-09-10** from either the
vendor's own page or the app's US App Store listing, and each carries its URL and that
date. Where two sources published different numbers on the same day, both are recorded and
the discrepancy is named rather than resolved by preference.

Three standing caveats:

* **Storefront prices are US-dollar, US-storefront, on the date checked.** App Store tiers
  differ by country and change without notice. Never treat a number here as durable.
* **In-app-purchase lists on an App Store page do not say which purchase is current.**
  Legacy, upgrade and grandfathered items sit in the same list as the live one. Where the
  vendor's own page disagrees with the listing, the vendor's page is the better guide to
  intent and the listing is the better guide to what a buyer is actually charged.
* **An absence of evidence is recorded as unverified, not as an absence.** "Their page does
  not mention X" is written that way. We never say a competitor lacks something we did not
  test.

No competitor product was installed, purchased or run for this document. Every capability
line is therefore *what the vendor states*, not what we observed. That limit is the reason
§7 exists.

---

## 2 · The field, app by app

### 2.1 · Termius (Termius Corporation)

*What it is.* A cross-platform SSH/SFTP client with an account and a synchronised
credential vault at its centre. The mobile app is one client of a service.

*Shape of the offering.* Free tier with a local vault; paid tiers add a cloud vault and,
above that, team and organisation features. The product ladder runs individual → team →
business → enterprise, which is a sales motion, not just a price list.

*Pricing as published today (2026-09-10).* Vendor page: Starter free (commercial use
allowed, local vault, SSH/SFTP, port forwarding, autocomplete); Pro $10/user/month billed
annually; Team $20/seat/month; Business $30/seat/month; Enterprise custom, with SAML SSO,
a SOC 2 Type II report and onboarding assistance named at the top tiers.
(https://termius.com/pricing, checked 2026-09-10.) The US App Store listing shows in-app
purchases "Termius Pro Monthly $15.00" and "Termius Pro Annual $119.00", iOS 17.0 or
later, iPhone / iPad / Apple Vision. (https://apps.apple.com/us/app/termius-ssh-client/id549039908,
checked 2026-09-10.) The annual figure and the vendor's $10/month-billed-annually are
consistent within rounding; the monthly figure is the one a casual buyer meets.

*Stated strengths.* Sync of hosts and credentials across desktop and mobile; SSH, SFTP,
Mosh, Telnet and serial connections; port forwarding; a virtual keyboard covering special
keys; snippets; session logs; jump hosts, agent forwarding, biometric unlock and cloud
provider imports at the paid tier. (Vendor pricing page and App Store description, both
checked 2026-09-10.)

*Read.* The account is the product. That is simultaneously their strongest asset — a team
can adopt them — and the thing a certain kind of buyer refuses outright.

### 2.2 · Prompt 3 (Panic, Inc.)

*What it is.* A terminal client with a long-standing reputation for craft, sold as one app
across four Apple platforms.

*Shape of the offering.* One purchase covers macOS, iOS, iPadOS and visionOS; a
subscription and a one-time price are offered side by side, which is unusual and worth
noting as a pricing pattern.

*Pricing as published today (2026-09-10).* Vendor support page: $9.99 USD/year, with a
7-day unrestricted trial on first launch, covering all four platforms; also available as a
one-time purchase of $49 with no recurring charge.
(https://help.panic.com/prompt/purchase-faq/, checked 2026-09-10.) The US App Store listing
shows "Prompt 3 iOS + Mac (Annual) $9.99" and "Prompt 3 One Time $49.99", iOS 17.0 or
later, with Mac (macOS 14.6+) and Apple Vision Pro (visionOS 2.2+) among supported devices.
(https://apps.apple.com/us/app/prompt-3/id1594420480, checked 2026-09-10.) The $49 / $49.99
difference between the two pages is unresolved and is recorded as such.

*Stated strengths.* SSH, Mosh, Eternal Terminal and local connections; a rewritten text
engine with optional GPU acceleration; clips/snippets; themes and fonts; Panic Sync for
servers and credentials; biometric encryption and YubiKey support; jump hosts; mouse
support; a visionOS spatial environment. (https://panic.com/prompt/, checked 2026-09-10.)
Third-party listicles also attribute Secure Enclave authentication to Prompt; that is
**unverified** — it did not appear on the vendor pages read today and must not be treated
as established.

*Read.* The closest competitor on taste and on the "quiet, exact" register we intend to
occupy. They will out-brand us. They are not obviously trying to be a workstation.

### 2.3 · Blink Shell (Blink Shell, Inc)

*What it is.* A terminal for iOS and iPadOS oriented around Mosh, a real shell environment
on the device, and a remote-development story.

*Shape of the offering.* Subscription, with a free legacy tier still listed, plus a
separate metered add-on for cloud build environments.

*Pricing as published today (2026-09-10).* Vendor site: a two-week free trial and
$19.99/year. (https://blink.sh/, checked 2026-09-10.) The US App Store listing for "Blink
Shell, Build & Code" shows in-app purchases "Blink+ $19.99", "Blink Plus $19.99", "Blink
Shell Classic $0.00", "Blink+Build Basic $9.99" and "Build Basic (50 credits/month)
$7.99", iOS 17.6 or later, iPhone / iPad / Apple Vision.
(https://apps.apple.com/us/app/blink-shell-build-code/id1594898306, checked 2026-09-10.)
Which of the duplicate $19.99 items is live is **unverified**; the credit mechanics of
Build are **unverified** beyond the item names.

*Stated strengths.* Mosh with local echo to hide latency; PKI and agent support; SFTP and
Files.app integration; sync across devices; a large set of on-device Unix tools;
remappable Bluetooth keyboard handling; external and 4K display support; integration with
VS Code, Codespaces and GitPod; developed in the open.
(https://blink.sh/, checked 2026-09-10.)

*Read.* On flaky cellular, Mosh is a real advantage and we do not have an answer to it.
They own "works when the network doesn't" and we should not contest that phrase.

### 2.4 · Secure ShellFish (Anders Borum)

*What it is.* An SSH terminal built around the iOS Files layer, from a developer with a
long record in that specific corner of the system.

*Shape of the offering.* Free with in-app purchase; monthly, annual and a lifetime unlock
that spans the developer's Apple platforms.

*Pricing as published today (2026-09-10).* US App Store listing: free with in-app
purchases "ShellFish Monthly $2.99", "ShellFish Annual $14.99", "ShellFish Lifetime Pro
Unlock $29.99"; iOS 17.4 or later; iPhone, iPad, Mac, Apple Vision, Apple Watch.
(https://apps.apple.com/us/app/ssh-client-secure-shellfish/id1336634154, checked
2026-09-10.) Secondary sources seen the same day quoted $12.99 annual and $24.99 lifetime;
those figures are **not** what the listing showed today and are recorded only so that a
later reader does not mistake a stale number for a price change.

*Stated strengths.* A terminal built from system text components, with the accessibility
that implies; filename detection in terminal output; Files app and Finder integration; tmux
support; configurations synced through iCloud Keychain and snippets through iCloud;
Shortcuts automation; widgets, Lock Screen Live Activity and picture-in-picture; security
keys and short-lived SSH certificates; management of DigitalOcean and Hetzner servers.
(https://secureshellfish.app/ and the App Store listing, both checked 2026-09-10.)

*Read.* The most direct overlap with our C4 story, and they got there first and go
further — widgets, Watch, Shortcuts depth, cloud provider integration. Treat the Files
integration as table stakes, not as a differentiator.

### 2.5 · Jump Desktop (Phase Five Systems)

*What it is.* A remote-desktop client, not a terminal. RDP, VNC and their own Fluid
protocol.

*Shape of the offering.* One-time app purchase for the individual, with a separate
per-seat team service layered above it.

*Pricing as published today (2026-09-10).* US App Store listing: $14.99, no in-app
purchases listed, iOS 12.0 or later, iPhone / iPad / iPod touch / Apple Vision.
(https://apps.apple.com/us/app/jump-desktop-rdp-vnc-fluid/id364876095, checked 2026-09-10.)
Vendor pricing page: a free individual plan with unlimited connections and browser access,
noting that platform apps may require a one-time purchase; Teams Pro $7.49/user/month and
Teams Enterprise $14.99/user/month, both with a 14-day trial, the Enterprise tier adding
SSO/SCIM, higher video bandwidth, multi-channel audio and virtual displays.
(https://jumpdesktop.com/pricing-plans.html, checked 2026-09-10.)

*Stated strengths.* Fluid as a proprietary high-quality protocol; physical mouse and
multi-monitor support; audio streaming; clipboard sharing and folder redirection; Apple
Pencil support; external displays; SSH tunnelling with password and public-key
authentication. (App Store description and https://jumpdesktop.com/, both checked
2026-09-10.) Their marketing page read today did not describe a terminal emulator; whether
one exists is **unverified**.

*Read.* When someone's job is the remote desktop, they buy this. Our C9 is not competing
for that person.

### 2.6 · Screens (Edovia)

*What it is.* A VNC client for Apple platforms with a long history and a strong
design reputation.

*Shape of the offering.* Subscription with a lifetime option; one purchase spans iPhone,
iPad, Mac and Vision Pro.

*Pricing as published today (2026-09-10).* Vendor support page: $3.99/month, $29.99/year,
or $179.99 lifetime; prices stated as USD and subject to change.
(https://help.edovia.com/en/screens-5/faq/s5-pricing, checked 2026-09-10.) Secondary
sources the same day quoted $24.99/year and $139.99 lifetime; those are older numbers and
are recorded only as a trap to avoid. The App Store in-app-purchase list for Screens 5 was
**not** read today and is unverified.

*Stated strengths.* VNC over RFB with end-to-end encryption and SSH tunnelling; display
selection on multi-monitor Macs; Curtain Mode; hardware keyboard and pointer support;
drag-and-drop file transfer; a companion assist utility; biometric protection; iCloud sync;
Tailscale and NordVPN integration; stated requirements iOS/iPadOS 17.6, macOS 14.0 or
visionOS 2.0 and later. (https://edovia.com/en/screens/, checked 2026-09-10.)

*Read.* Same conclusion as Jump. They are the reference for VNC quality on this platform,
and they are not trying to be a shell.

### 2.7 · Working Copy (Anders Borum)

*What it is.* A Git client for iOS and iPadOS. Adjacent rather than competing, and included
here for two reasons: it shares a developer with Secure ShellFish, and it is the standing
proof that a professional single-purpose iOS tool can sustain a high one-time price.

*Pricing as published today (2026-09-10).* US App Store listing: free with in-app
purchases "Working Copy Pro Unlock $35.99", several "Pro Upgrade" items at $17.99, and a
$1.99 tip; iOS 18.2 or later; iPhone, iPad, Apple Vision.
(https://apps.apple.com/us/app/working-copy-git-client/id896694807, checked 2026-09-10.)
The free tier is described as limited to five repositories, with push behind the unlock.

*Stated strengths.* Cloning, editing, committing and pushing; syntax highlighting across
many languages; offline commits; Files app integration; Shortcuts and x-callback-url
automation; GPG signing; Git LFS; merge and rebase conflict resolution.
(https://workingcopy.app/ and the App Store listing, both checked 2026-09-10.) The site
read today did not describe SSH or remote shell access; whether Git-over-SSH key handling
is exposed to the user is **unverified**.

*Read.* Not a competitor for the session. It *is* a competitor for the same reader's
willingness to pay once, at a real price, for a tool that does one thing exactly.

### 2.8 · Notable current alternatives

**WebSSH — Sysadmin Toolbox (MENGUS ARNAUD).** Free with in-app purchases "WebSSH PRO
$15.00" plus developer tips at $1.99 and $9.99; iOS 26.0 or later as listed; iPhone, iPad,
Mac, Apple Vision, Apple Watch, Apple TV. SSH, SFTP, Telnet, port forwarding, serial, an
integrated Proxmox client and network diagnostics (ping, traceroute, DNS lookup, whois);
the developer states a one-time purchase model and that credentials stay on the device.
(https://apps.apple.com/us/app/webssh-sysadmin-toolbox/id497714887 and https://webssh.net/,
both checked 2026-09-10.) This is the one product in the set whose *pricing philosophy* and
*local-only* framing sit closest to ours, and it has been shipping since 2012. It deserves
more attention than its profile suggests.

**a-Shell (Nicolas Holzschuch).** Free, no in-app purchases, iOS 14.0 or later. A local
Unix environment — Python, Lua, Perl, JavaScript, C/C++, TeX, common utilities, WebAssembly
— rather than an SSH client. (https://apps.apple.com/us/app/a-shell/id1473805438, checked
2026-09-10.) Relevant because it sets the free-tier expectation for "a terminal on my
iPad" among people who have not yet worked out that they want a *remote* one.

**Names seen in aggregator listings but not verified.** "Termix", "Easy SSH", "NeoServer"
and a second, unrelated app also called "WebSSH" (a different developer) appeared in
third-party 2026 round-ups read today. None was checked against a vendor page or listing.
They are recorded as **unverified** and no planning decision may rest on them until
someone opens their store pages.

---

## 3 · Pricing shape at a glance (internal)

All figures US storefront, checked 2026-09-10, sourced in §2.

| Product | Free tier | Recurring | One-time | Account required |
| --- | --- | --- | --- | --- |
| Termius | Yes, local vault | $10/user/mo annual (listing: $119/yr, $15/mo) | No | Yes for sync and above |
| Prompt 3 | 7-day trial | $9.99/yr | $49 vendor / $49.99 listing | Sync is optional |
| Blink Shell | Classic item at $0.00; 2-week trial | $19.99/yr, plus metered Build | No | Unverified |
| Secure ShellFish | Yes, with ads per description | $2.99/mo, $14.99/yr | $29.99 lifetime | iCloud, not a vendor account |
| Jump Desktop | Free plan; browser | Teams $7.49–$14.99/user/mo | $14.99 iOS app | Yes for Teams |
| Screens | Trial stated on site | $3.99/mo, $29.99/yr | $179.99 lifetime | iCloud |
| Working Copy | 5 repositories | No | $35.99 unlock | No |
| WebSSH | Yes, one saved connection | No | $15.00 PRO | No |
| a-Shell | Entirely free | No | No | No |

**Where we sit.** Apex Terminal has no StoreKit, no in-app purchase and no subscription in
the audited build — Verified as an absence, and part of C5. That is a positioning asset and
an unanswered commercial question at the same time, and the question is not this document's
to settle. What this table does establish: the one-time price band for a serious,
single-purpose iOS professional tool is roughly $15–$50, set by WebSSH, Prompt and Working
Copy. Nothing in the field supports a subscription for a product with no service behind it.

---

## 4 · The positioning map, honestly drawn

Two axes carry most of the information.

**Axis 1 — what the connection is for.** At one end, the shell (Blink, Prompt, a-Shell). In
the middle, shell plus files (Termius, Secure ShellFish, WebSSH). At the other end, the
screen (Jump, Screens). Nobody read today publishes shell + files + screen + tunnels as one
offering. Apex sits alone at that point on the axis — which is a claim about the *shape of
the offering*, and is exactly as strong as C1's evidence and no stronger.

**Axis 2 — where the trust lives.** At one end, a vendor account and a cloud vault
(Termius, and Jump/Screens for their team layers). In the middle, the platform's own sync
(Prompt via Panic Sync, ShellFish and Screens via iCloud, Blink's sync). At the other end,
the device only (WebSSH's local-only framing, a-Shell trivially, and Apex, whose sync is
withheld in this build). This end of the axis is occupied but not crowded, and it is the
only end where our C2 and C5 mean anything.

A third, weaker axis is **platform breadth**: Prompt, ShellFish, Screens, Jump, Termius and
WebSSH all span Mac and in several cases Vision Pro. Apex is iPhone and iPad, iOS/iPadOS 17
and later (C24), and will be for this release. We lose this axis and should not draw it in
any deck where the audience will ask about it.

---

## 5 · Where Apex Terminal is genuinely differentiated

Strict test applied: the capability must be **Verified** in the truth matrix, it must
appear in C1–C24, and the differentiation must survive the question *"what would a
competitor's page have to say for this to be unremarkable?"*

**5.1 · One connection carrying four kinds of channel (C1). Strong.** One TCP connection,
one key exchange, one authentication, one biometric prompt for shell, files, screen and
forwards. Adversarially tested: the pool never returns a connection belonging to another
account and never returns a dead one. No product read today publishes this as a property of
its own architecture, and for the two remote-desktop products it is structurally unavailable
because they do not have a shell to share the transport with. *Caveat to keep us honest:* we
verified our own behaviour, not their absence of it. The claim we make in public is about
what our app does, never about what theirs does not.

**5.2 · A key whose private half cannot leave the device, logging into a stock OpenSSH
server (C2). Strong, and contested at the edges.** Secure Enclave key generation is proven
against a real `sshd`, asserting `sshd`'s own `Accepted publickey` line, with a control case
showing the same key refused where it was not authorised. Others in the field advertise
adjacent things — YubiKey (Prompt), security keys and short-lived certificates (ShellFish),
biometric unlock (most) — and one third-party listicle attributes Secure Enclave support to
Prompt, unverified. So the differentiator is **not** "we have hardware-backed keys". It is
the precise, checkable sentence: *there is no key file, and the server is unmodified*. That
sentence is ours because we can prove it, not because nobody else could.

**5.3 · No account, no back end, nothing measured, nothing to buy (C5). Strong, one
neighbour.** Proven as an absence by grep: no StoreKit or subscription symbol, no
analytics, telemetry or crash reporter, no server operated by this project. Against
Termius this is a category difference. Against Prompt, Blink, ShellFish and Screens it is a
real difference of degree — they all sync through something. WebSSH makes a similar
local-only statement, so we are not alone here; we are simply able to state it more
completely, including the absence of a purchase mechanism.

**5.4 · The terminal itself (C3). Moderate, and hard to sell.** Sixel, true colour, mouse
reporting in three modes, correct CJK cell widths against UCD 17.0.0, alternate screen with
the shell restored exactly, a fuzz suite demonstrated to catch a deliberately broken
invariant. Every serious competitor also claims a good terminal, and a reader cannot check
any of them from a store page. This wins arguments once someone is already trying the app;
it does not win the decision to try it. Use it in screenshots (SS-1, SS-3), not in the
subtitle.

**5.5 · tmux control mode (C8) and VNC on the SSH connection (C9). Moderate, and narrow.**
tmux over `-C` rather than scraped text is a genuine engineering difference, but ShellFish
states tmux support, so the public difference is invisible without a demonstration. VNC
routed through the existing SSH connection is differentiating only inside the C1 story —
as a standalone remote-desktop pitch it loses to Jump and Screens on every axis they care
about.

**5.6 · The forwarding story (C6, C7). Moderate, and underrated.** Local, remote and
dynamic forwarding saved on a connection and started with it, with live byte and connection
counters per rule, and a failure that names the port in words. Termius, Prompt and WebSSH
all list port forwarding; none read today publishes per-rule live counters or an error that
names the port. It photographs well, and it is the kind of small exactness this audience
notices.

**Not differentiation, and to be argued down if raised:** Files app integration (C4) —
ShellFish and Blink both have it and ShellFish goes further; certificates and ProxyJump
(C12, C13) — expected in this class; split panes (C10) — expected on iPad. These are
*table stakes we meet*, and they belong in the feature list, not in the lead.

---

## 6 · Where competitors are genuinely ahead — do not pick these fights

1. **Mosh and Eternal Terminal (Blink, Prompt, Termius).** We have neither. C22 —
   sessions come back after the network drops, scrollback intact — is a reconnection story,
   not a roaming-session story, and conflating the two would be the exact kind of
   overstatement this rebuild exists to end. Never claim or imply Mosh-class behaviour.
2. **Sync across devices (Termius, Panic Sync, ShellFish, Screens, Blink).** Ours is
   withheld: implemented, offline-verified only, H-5 open. It is on the never-say list. The
   honest reframe is "nothing you save leaves the device", which is C5's territory and is
   only credible while it is literally true.
3. **Mac and Vision Pro (Prompt, ShellFish, Screens, Jump, WebSSH, Termius).** Catalyst has
   no signing identity (H-8); visionOS has never been run (H-9). We are iPhone and iPad
   (C24). Say that plainly and do not gesture at more.
4. **Remote-desktop depth (Jump, Screens).** Fluid, RDP, multi-monitor, audio channels,
   Curtain Mode, drag-and-drop file transfer. We have VNC, and macOS Screen Sharing sign-in
   is itself unverified (H-3). C9 is "a screen in the same app on the same connection",
   full stop.
5. **On-device Unix and remote-development workflows (Blink, a-Shell).** No local shell, no
   package set, no VS Code or Codespaces bridge. Nothing here to contest.
6. **Team and fleet operations (Termius, Jump Teams).** Shared vaults, access groups,
   session logs, SSO/SCIM, compliance reporting. We have no account, by design, so this
   entire buyer does not exist for us. That is a decision, not a gap to close quietly.
7. **Cloud-provider and infrastructure integrations (Termius: AWS and DigitalOcean;
   ShellFish: DigitalOcean and Hetzner; WebSSH: Proxmox).** None of it here.
8. **Automation surface (ShellFish, Working Copy).** Widgets, Live Activity, Watch,
   picture-in-picture, deep Shortcuts coverage. We have Shortcuts actions and an `ssh://`
   handler; several matrix rows in this area are unverified. Do not lead here.
9. **Track record.** Panic, WebSSH since 2012, ShellFish and Working Copy with years of
   reviews behind them. We are version 0.1.0 with no ratings, no awards and no user count —
   and by rule we would not cite such numbers even if we had them. The substitute for
   reputation, for us, is checkability: every sentence a reader could verify themselves.
10. **Free-tier and trial mechanics.** Termius, WebSSH and a-Shell all give a usable free
    path; Prompt and Blink both run trials. With no StoreKit in the build we have no trial
    machinery at all. Whoever decides pricing needs to read §3 before deciding.

---

## 7 · Fights that look winnable and are not

* **"More complete than X."** We cannot substantiate a completeness comparison without
  running their products, and running them still would not license the sentence. Drop it.
* **"Better terminal fidelity."** True in our tests, unfalsifiable in a store listing, and
  a comparative claim in a category where several competitors have shipped good emulators
  for years.
* **"Cheaper."** Pricing is unsettled here, competitor prices move, and a price argument
  invites the buyer to compare feature lists — which is §6's territory, where we lose.
* **Cloudflare, in any form.** It is implemented and carefully built, and it is the one
  genuinely unusual thing in the codebase that no product in §2 appears to offer. It is
  also unverifiable today: no connection has ever been made through a live Cloudflare
  account, the entire authentication half is untested, and three internal documents
  overstate it. Until H-4 clears it is not a differentiator, it is a liability, and it
  appears in no public claim of any kind — not the name, subtitle, description, keywords,
  screenshots, captions, social posts or press kit. When H-4 clears, re-read this section:
  it is likely to become the strongest entry in §5.

---

## 8 · Strategic conclusion — what to lead with

Lead with **two claims, closed by a third**. In this order, and in this proportion.

**Lead 1 — C2, the key that cannot leave the device.** It is the most checkable sentence we
own, it is the one whose evidence is strongest (a real `sshd`'s own log line, plus a control
case), and it speaks directly to audience 7 and to everyone in §4's trust axis. It is also
the claim least vulnerable to a competitor's next release: they can add features, but they
cannot retroactively make their key files not be files.

**Lead 2 — C1, one connection carrying shell, files, desktop and tunnels.** It is the
architectural claim, it is the one nobody else in the field publishes, and it explains the
product's shape in a single sentence — which is what a subtitle has to do. Keep it concrete
in support copy: one handshake, one authentication, one biometric prompt.

**Closer — C5, no account, no back end, nothing measured.** Not a headline; a full stop at
the end of the other two. It converts the first two claims from features into a posture,
and it is the only one of the three that a reader can confirm before installing anything,
by noticing what the listing does not ask of them.

**Held in reserve, in this order:** C6/C7 (forwarding with per-rule counters and errors that
name the port) as the strongest *demonstrable* second-tier claim; C3 (the terminal) as
screenshot material; C8 (tmux control mode) for the iPad audience specifically; C22
(sessions returning after a drop) written carefully so it can never be read as Mosh.

---

## 9 · What we will not do

* **No comparison table in any public material.** Not on the website, not in the press kit,
  not in a screenshot caption, not in a social post.
* **No competitor named in any customer-facing copy**, in English or in Chinese, including
  by implication, nickname or unmistakable paraphrase.
* **No disparagement**, direct or oblique. No "unlike other clients", no "most SSH apps
  make you…", no strawman of a rival's architecture.
* **No screenshots, copy, marks or visual language taken from any product in §2.** This
  document itself paraphrases; nothing in it may be reproduced verbatim outward.

The reasoning is short. A comparison table is a claim about someone else's product on a date
we cannot control, and the moment they ship an update it becomes a false statement with our
name on it — the same failure mode as the Cloudflare copy this rebuild is replacing.
Beyond that, the reader we want has been sold to badly by this category before; an app that
argues against its neighbours reads as an app with a weak case of its own, and our case is
strong enough to state on its own terms.

---

## 10 · Re-check schedule

This data decays. Whoever is responsible for the listing owns these dates.

| Cadence | What to re-check | Why |
| --- | --- | --- |
| **Every 90 days** — next due **2026-12-09** | Every price in §2 and §3, from the vendor page *and* the US App Store listing; both figures recorded, discrepancies preserved | Prices moved twice in the sources read today; the table is the fastest part of this file to become wrong |
| **Every 180 days** — next due **2027-03-09** | The capability paragraphs in §2, and §6's ten items | Feature parity is what would invalidate §5 and §8 |
| **Within 14 days of any of our own releases** | §5 and §8, against the then-current truth matrix | A status change from Unverified to Verified can add a differentiator; a regression can remove one |
| **On the day H-4 clears** | §7's Cloudflare paragraph, then §5 and §8 in that order | It is the single largest pending change to our position |
| **On the day H-5, H-8 or H-9 clears** | §6 items 2 and 3, then §4's platform-breadth axis | Each of those closes a gap we currently concede |
| **Immediately, out of cadence** | Any line here that a colleague finds contradicted in the wild | A wrong internal fact becomes a wrong public sentence within one writing cycle |

Every re-check rewrites the URL-and-date stamp in place. A line whose date is more than 180
days old is to be treated as unverified and struck from planning until it is re-read.

---

## 11 · Source ledger

All checked **2026-09-10**.

* Termius pricing — https://termius.com/pricing
* Termius, App Store (US) — https://apps.apple.com/us/app/termius-ssh-client/id549039908
* Termius, free-for-iPhone page — https://termius.com/free-ssh-client-for-iphone
* Prompt (Panic) product page — https://panic.com/prompt/
* Prompt purchase FAQ — https://help.panic.com/prompt/purchase-faq/
* Prompt 3, App Store (US) — https://apps.apple.com/us/app/prompt-3/id1594420480
* Blink Shell — https://blink.sh/
* Blink Shell, App Store (US) — https://apps.apple.com/us/app/blink-shell-build-code/id1594898306
* Secure ShellFish — https://secureshellfish.app/
* Secure ShellFish, App Store (US) — https://apps.apple.com/us/app/ssh-client-secure-shellfish/id1336634154
* Jump Desktop — https://jumpdesktop.com/
* Jump Desktop pricing plans — https://jumpdesktop.com/pricing-plans.html
* Jump Desktop, App Store (US) — https://apps.apple.com/us/app/jump-desktop-rdp-vnc-fluid/id364876095
* Screens (Edovia) — https://edovia.com/en/screens/
* Screens 5 pricing FAQ — https://help.edovia.com/en/screens-5/faq/s5-pricing
* Working Copy — https://workingcopy.app/
* Working Copy, App Store (US) — https://apps.apple.com/us/app/working-copy-git-client/id896694807
* WebSSH — https://webssh.net/
* WebSSH, App Store (US) — https://apps.apple.com/us/app/webssh-sysadmin-toolbox/id497714887
* a-Shell, App Store (US) — https://apps.apple.com/us/app/a-shell/id1473805438

Third-party round-ups were read on the same date and are deliberately **not** listed as
sources for any fact in §2. Where one of them is the only support for a statement, that
statement is marked unverified in the text above.
