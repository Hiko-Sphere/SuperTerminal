# Capability self-assessment — internal

**Written:** 2026-09-10 · **Status: INTERNAL. Not for publication, in whole or in part.**
· **Gated by:** [`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md)

## Why there is no comparison table, and will not be one

No public comparison table will be produced for Apex Terminal, and no competitor will be
named in any customer-facing text at any time. The reason is not politeness; it is that a
comparison table is a set of claims about products we have not audited, and this project has
spent an entire rebuild establishing that a claim we cannot reproduce is a claim we must not
make. We hold ourselves to evidence — a test against a real `sshd`, a real tmux 3.3a, a real
VNC server, a real Keychain — and we cannot hold a column about somebody else's app to the
same standard without buying it, instrumenting it, and re-testing it on every release it
ships. Anything short of that is a table that is wrong within a month and was never checkable
in the first place. There is the further problem that a competitive table invites the
superlatives the messaging system forbids, and the App Store's own rule against unverifiable
claims applies to a chart exactly as it applies to a sentence. So the public position is the
one the product can defend: say what this app does, say the limit in the same breath, and let
a reader who is comparing do the comparing. This file exists so that the people writing that
copy know, internally and honestly, where the product is strong and where it is thin — and so
that nobody mistakes an internal judgement for a publishable one.

What follows is a self-assessment against the seven categories buyers actually compare on.
No other product appears in it. Where a row says "thin", that is a note to engineering and to
the roadmap, not an admission to be published; where it says "strong", that is a licence for
the copy to lead with it, subject to the claims matrix.

---

## 1 · Terminal fidelity

**Strong.** This is the deepest part of the product, and the evidence is unusually good. A
full VT500-class parser in which every state has a transition for every byte; the alternate
screen, proven by real vim and real less over a real PTY putting the shell back as it was;
24-bit colour in both SGR spellings; sixel proven three ways — against ImageMagick's own
bytes, arriving over a real `sshd`, and confirmed as actual pixels in the app's own
screenshot on two device families; mouse reporting round-tripped byte-for-byte through a
remote `cat -v`; cell widths generated from Unicode 17.0.0 rather than hand-maintained;
OSC 7, 52 and 133 against a real shell and the real pasteboard; scrollback search that
crosses a wrapped line; any monospaced font on the device, with the new grid size reaching
the server, proven by reading `stty size` back. The fuzz suite was demonstrated able to
**fail** — the invariant was deliberately broken and the suite caught it — which is a
different and better claim from "we fuzz it".

**Thin.** Line-drawing charsets (`ESC ( 0`) are not implemented, so a program that switches
into the legacy charset instead of Unicode box characters prints letters. Blinking text is
parsed and stored but never drawn, and whole-screen reverse video is tracked but never
applied. Synchronised output and focus reporting are negotiation only: the modes are
acknowledged truthfully and then nothing consumes them, which means a program that asks for
tear-free frames will not get them and a program that enables focus reporting waits forever.
Themes are three built-ins with no test coverage at all, and user-defined themes are
half-built and do not survive a relaunch. Kitty and iTerm2 inline images are unit-tested but have never come from a real
server. Typing Chinese, Japanese or Korean is implemented and unit-tested but has never been
exercised against a real input method on hardware — a gap that is invisible in an English
review and fatal in a Chinese-language one. Throughput numbers exist as enforced floors, not
as device measurements; there is no iPhone figure and copy must never imply one.

**Verdict for copy.** Lead with it. It is the strongest body of evidence in the product and
the one a technical reviewer will probe first.

## 2 · File transfer

**Strong.** SFTP rides the same SSH connection as the terminal, so there is no second sign-in
and no second password — that is the architectural point, and it is verified. Seven protocol
tests against OpenSSH's own `internal-sftp`; thirteen more file-system tests that check the
server's own disk rather than the client's opinion. Several remote folders open at once, side
by side in panes on an iPad. The interrupted-upload test is the best single piece of evidence
in the area: a real TCP connection severed in the middle of a real 24 MB upload, and the file
still lands whole, once, with no debris on the server — and that test found a real defect
before it passed four times running. The background extension's refusals are principled and
tested: it will not trust an unknown or changed host key, and it will not use a credential
that needs a person present.

**Thin.** The headline everybody wants — "your servers in the Files app" — is the one that
cannot be made. Every layer beneath it is proven, and the single test of the system actually
serving those answers has never run, because it needs a physical device. Publishing the
domain is verified; what the system does with it afterwards is not. Inside the app's own
browser, upload, rename, delete and new-folder have no test of their own (the equivalent
operations are proven in the other code path); downloads land in a temporary directory and
leave through the share sheet, with no destination picker; drag and drop has no coverage and
a cross-browser drag is not a server-side move. Transfers stop when iOS suspends the app.
Nothing resumes from an offset, by deliberate refusal. The two views do not stay in step
automatically — a pull-to-refresh is needed, and the plumbing that would fix it exists but is
called from nowhere, which is worth reporting to engineering.

**Verdict for copy.** Lead with "the same connection, no second login" and with the file
browser. Keep the Files-app half to the switch in the connection editor, never a photograph
of the system's own app.

## 3 · Tunnelling

**Strong.** Local, remote and dynamic forwarding are all proven with real bytes through a
real server, including the awkward case where the far service speaks first. Rules are saved
objects on a connection and start with it. Live byte and connection counters per rule make
forwards an observable, managed thing rather than a command somebody retypes — that is a
genuine product idea and it photographs well. A forward that cannot start says why and names
the port. Forwards never outlive their connection and always give the port back, which is a
security property as much as a tidiness one.

**Thin.** Local and dynamic forwards bind 127.0.0.1 and nothing else, deliberately, so the
device never becomes a gateway — correct, and also a limit somebody will ask about. The SOCKS
proxy is CONNECT-only with no authentication, and iOS has no system-wide proxy setting, so it
serves apps you can point at a proxy and no others; the hostname and IPv6 destination forms
are code without a test. There is no VPN and no IP-level tunnel, by decision. A forward
coming back by itself after an automatic reconnect is untested, so "tunnels survive a drop"
cannot be written. Counters only advance while the forwards screen is open. And the whole
category is bounded by iOS: a backgrounded app is suspended and the tunnel stops with it,
which rules out the "always-on tunnel" framing the category tends to reach for.

**Verdict for copy.** Strong, and safe, provided every sentence carries the foreground limit.

## 4 · Session persistence

**Mixed, and the two halves must be kept apart.**

**Strong.** Ordinary terminal sessions come back on their own after the network drops, with
the scrollback intact and the new shell marked as fresh — proven against a proxy that really
severs the sockets, with the session required to notice, return, still show the pre-drop
output, and run a new command. On the tmux side, the app speaks tmux's own control protocol
rather than scraping text, draws tmux's own arrangement including layouts the app's own
splitter could not express, and reattaching finds the windows, the panes and their output
already on screen rather than blank.

**Thin.** Reattaching to a tmux session is something a person does, not something that
happens: there is no automatic reconnection for tmux, and a detached session in the app stays
detached until the connection is opened again. Scrolling a tmux pane is local scrolling over
roughly 2 000 captured lines, not tmux copy mode — so no copy-mode search, no copy-mode
selection, and nothing older than the capture. The app-level round trip (detach here,
reattach here, find the work) is not covered by a test, although tmux's own survival is. Only
tmux 3.3a has been measured. Terminal scrollback is in memory and does not survive a
relaunch. And the honest framing of the whole category is that persistence lives on the
server: the app is a good client of something that keeps running, not a thing that keeps
running itself.

**Verdict for copy.** Excellent material, dangerous to blur. "Terminal sessions come back on
their own" and "a tmux session keeps running on the server, but reattaching is something you
do" are two sentences and must stay two sentences.

## 5 · Security

**The strongest category in the product, and the one with the sharpest edges.**

**Strong.** Secure Enclave keys are the best claim available anywhere in this app: the
private half is made in the chip, no copy exists, and it logs in to an unmodified OpenSSH
server — proven by the server's own log line, with a control case proving refusal where the
key was not authorised. The changed-host-key hard stop is proven against two real servers.
Certificates, both host and user, are proven against a real CA, including the cases where a
certificate must be refused rather than turned into a prompt. Agent forwarding is proven by
OpenSSH's own `ssh-add` listing a key that never left the phone. A hostile server cannot open
a channel back into the device, proven against a fixture written to misbehave. OSC 52 lets a
program write your clipboard only after you allow it and never lets one read it — proven
against a real pasteboard, with the read refusal silent to the server. A link carrying a
command always shows the command and waits. The app lock is proven end to end through a
relaunch. And the absences — no account, no back end, no analytics, no purchase — rest on a
dependency list short enough to read and a search anyone can repeat.

**Thin.** No biometric surface in this project has ever run against real hardware: three
exist, all blocked on a device check. The specific Keychain protection classes are read out
of the code, not asserted by a test. Trust on first use is exactly what it says, and the
product's own consent screen admits it. Known hosts are the app's own format and interoperate
with nothing. The App Switcher cover is untested and covers precisely one thing, which the
category's usual copy tends to overstate into screenshot blocking. Diagnostics redaction has
a thin test. And the one real crack in an absolute privacy sentence is the optional assistant:
it is off, prefers the device's own model, and does nothing without a key the person supplies
— but if a person points it at a provider, terminal text goes there. Every privacy sentence
in this rebuild is written to survive that, and that discipline must not slip.

**Verdict for copy.** Lead with it, and lead with the arithmetic and the artefacts rather
than adjectives. The category is full of "military-grade" noise; the way to stand apart in it
is to be the one that names a log line.

## 6 · Platform breadth

**Honestly narrow, and the narrowness is the strategy.** One app, iPhone and iPad, iOS and
iPadOS 17 and later. That is the whole list, and it is what may be said.

**Strong.** Within it, the iPad story is real: split panes with a draggable divider that
cannot swallow a pane, each pane a complete session with its own toolbar, several live
sessions with typing following the one on screen, and a genuine second window. The full UI
suite runs on both device families as a release gate, on real device simulations against real
servers.

**Thin.** Mac Catalyst builds, launches and passes 316 of 324 unit tests — and nothing about
how it behaves on a Mac is verified, because the UI suite cannot load without a signing
identity. There is no menu-bar construction in the code despite a decision record that reads
as though there were, and the Files integration is genuinely absent there. visionOS has never
been executed even once; the project cannot name that build destination today. There is no
watchOS and it was refused on purpose. Stage Manager, Split View and Slide Over are declared
and have never been observed. Trackpad and pointer support is real code with configuration
tests and no test that moves a pointer. Of the hardware-keyboard shortcuts, five have been
pressed by a test; the split and session-switching ones are proven as a table and a router,
not as keys. Sync between devices is off in this build, which also means Handoff can only
open a connection the second device already has saved by hand.

**Verdict for copy.** Say "iPhone and iPad" and stop. Every temptation in this category —
Mac, Vision Pro, a watch, "works with Stage Manager" — is a claim nobody here can support,
and one of them would cost more credibility than all of them together would earn.

## 7 · Price model

**Strong, and unusually clean.** The app is free. There is no in-app purchase and no
subscription, and this is not a marketing position but a fact about the binary: there is no
StoreKit code in it, provable by a search over every source and project file. There is no
account, so there is nothing to be upsold from, and no back end, so there is nothing whose
running costs would later argue for a tier. In a category where the normal shape is a
subscription for a terminal, "free, and here is why there is nothing to charge for" is a
distinctive and completely defensible position.

**Thin — internally.** A product with no revenue has no funded maintenance, and the honest
internal risk is sustainability rather than positioning: a vendored SSH fork is maintained by
this project, and the platform moves every September. That is a roadmap question, not a copy
question.

**Verdict for copy.** State it plainly and once: free, no in-app purchase, no subscription.
Do not hint at a future paid tier in any customer-facing text — a hint is a promise about a
decision nobody has made, and it would make the plain statement read as a trial.

---

## Summary, for the writer in a hurry

| Category | Where we stand | What copy may lead with |
| --- | --- | --- |
| Terminal fidelity | Strong, deeply evidenced | Yes — it is pillar three |
| File transfer | Strong under the surface, thin at the system boundary | Yes, up to the Files-app line |
| Tunnelling | Strong and observable, bounded by iOS backgrounding | Yes, with the foreground limit attached |
| Session persistence | Strong for terminals; server-side for tmux | Yes, as two separate sentences |
| Security | The strongest category, with sharp edges | Yes — it is pillar two |
| Platform breadth | Narrow on purpose, and thin outside iPhone and iPad | Only "iPhone and iPad" |
| Price model | Free, with nothing to buy, provable | Yes, plainly and once |

**The rule that survives this document:** none of the judgements above may be published, and
no sentence anywhere may compare Apex Terminal to a product that is not named — a nameless
comparison is still a comparison, and "unlike other SSH clients" is a claim about products we
have not tested. Describe this one. Let the reader compare.
