# Audience matrix — Apex Terminal

**Written:** 2026-09-10 · **Gated by:** [`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md) ·
**Claims:** [`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md) ·
**Position:** [`POSITIONING.md`](POSITIONING.md)

[`POSITIONING.md`](POSITIONING.md) §5 names the audience in one line each. This document is
the long form: nine groups, and for each of them the job, the pain, the two or three
**Verified** capabilities that decide the purchase, the sentence to lead with in English
and in Chinese, the screenshot that carries it, and the channel that reaches them.

Three rules govern every line below.

1. **Only Verified capabilities are described as things the product does.** A capability
   that is Implemented but Unverified may appear in this file as an internal note about
   what is *withheld*, never as a customer sentence.
2. **The lead sentences are customer-facing copy** and are drawn from, or written to sit
   under, the approved wording in `CLAIMS_MATRIX.md`. Where a lead sentence is a claim
   verbatim, it is marked *(C-n verbatim)*.
3. **No competitor is named anywhere in this file.** "What they use today" describes
   categories of tool, not products. Competitor analysis lives elsewhere and is internal.

Screenshot references are `SS-1` … `SS-8` from
[`../app-store/SCREENSHOT_PLAN.md`](../app-store/SCREENSHOT_PLAN.md).

---

## 1 · Engineers who work from an iPad

**Who they are.** People who have already decided the iPad is a real machine and have spent
money proving it — keyboard case or Magic Keyboard, a stand, an external display. They are
software engineers, data people, and researchers whose actual compute lives on a Linux box
somewhere: a workstation under a desk, a GPU host, a build server. The iPad is the seat,
not the computer.

**The job.** Sit down for two hours of genuine work — editing, running a build, watching a
log — without the session, the layout, or the keyboard behaviour reminding them every few
minutes that they are on a tablet.

**What they use today, and where it hurts.** A general-purpose mobile terminal that renders
a single full-screen text view. It works for one command. It does not survive an afternoon:
one session on screen at a time, so watching a log while editing means switching back and
forth; full-screen programs that leave the shell in a state the app cannot put back; a font
they cannot choose; and no way to keep a long job attached when the app goes away. The
common outcome is that they open the laptop after twenty minutes, which is the moment the
purchase is lost.

**The capabilities that decide it.**

| Claim | What it gives this person |
| --- | --- |
| **C10** | Split panes on iPad, each with its own toolbar, and a second window. Two full sessions on one screen, not one session and a scrollback. |
| **C8** | tmux over its own control protocol — detach, and reattach to find the panes still there. The long job survives the app being put down. |
| **C3** | A real terminal: true colour, sixel pictures, mouse reporting, correct CJK widths, and full-screen programs that put your shell back exactly as it was. |

Supporting, where there is room: **C20** (any monospaced font on the device, with size and
line height), **C11** (several live sessions, typing follows the one you are looking at).

**Lead with.**

> **EN:** Two full terminals on one iPad screen, each with its own toolbar — and a tmux session that is still there when you come back.
>
> **ZH:** 一块 iPad 屏幕上并排开两个完整终端，各有各的工具栏；离开再回来，tmux 里的窗格和输出都还在原处。

**Screenshot.** **SS-3** (`03-panes`) leads — the iPad canvas with two live panes is the
single image that answers "is this a workstation". **SS-6** (`06-tmux`) closes. Note that
SS-3 is a *different subject* on iPhone by design, so this audience is served by the iPad
slot specifically.

**Channel.** Publications and forums built around working from an iPad; Apple-adjacent
Mastodon; video creators whose subject is "the iPad as a main machine". In Chinese: 少数派,
Bilibili 的 iPad 生产力向频道, 小红书. This group reads long reviews and rewards specificity,
so the long-form website page matters more here than the store listing does.

**Internal note.** Reflow on resize is Implemented but Unverified (H — rotation, keyboard,
Stage Manager). Do not promise that rotating the iPad reflows the buffer. Stage Manager and
iPad Split View are likewise unverified and stay out of copy aimed at this group, which is
unfortunate because they would ask about it. C10 is enough on its own.

---

## 2 · DevOps and SRE on call

**Who they are.** People carrying a pager on a rota. The phone is the machine they actually
have at 03:00, in a taxi, in a corridor, on a train. They are not trying to do a day's work
on it; they are trying to stop something.

**The job.** Get to a shell on a named host in under a minute, run three or four commands
they already know, and either fix it or gather enough to hand off — on a network that is
cellular, lossy, and about to go into a tunnel.

**What they use today, and where it hurts.** A phone terminal kept installed for exactly
this, plus a laptop they did not bring. The pain is not features, it is failure under
conditions: the connection drops as the train moves, the session dies, the scrollback is
gone, and the reconnect means retyping the host, waiting on a fresh handshake, and answering
a fresh authentication prompt. Where the server requires a one-time code, some clients make
the code prompt unusable or refuse the login outright.

**The capabilities that decide it.**

| Claim | What it gives this person |
| --- | --- |
| **C22** | Sessions come back on their own after the network drops, scrollback intact — and the new shell is marked as fresh, so nobody mistakes a reconnected shell for a continued one. |
| **C1** | One connection carries the shell, the files, the desktop and the tunnels: one handshake, one authentication, one biometric prompt instead of four. On a bad link, four handshakes is four chances to fail. |
| **C15** | Servers with PAM, expired passwords or a one-time code prompt log in, with the server's own wording shown unchanged. |

Supporting: **C8** (reattach to tmux and find the incident session as the previous responder
left it), **C21** (an `ssh://` link from the alert shows the exact command and runs it only
if you agree).

**Lead with.**

> **EN:** The train goes into a tunnel; the session comes back with your scrollback intact, and the new shell says it is new.
>
> **ZH:** 进隧道断线，出来会话自己接上，回滚缓冲还在；重开的 shell 会明确标出这是新开的。

**Screenshot.** **SS-2** (`02-one-connection`) leads for this group — the proof that one
server costs one login. **SS-1** (`01-terminal`) is the thumbnail that gets them to stop
scrolling in the store.

**Channel.** Hacker News and lobste.rs for the launch write-up; the operations subreddits;
on-call and incident-response newsletters. In Chinese: V2EX, 知乎 长文, 运维方向的微信公众号.
This group converts from a technical post that names limits, not from a feature list.

**Internal note.** **C15 is the highest-risk claim in this document.** The approved sentence
is "servers with 2FA work". "Two-factor authentication built in" is forbidden: the app
relays the **server's** keyboard-interactive prompt and neither generates nor stores a code.
Equally: never write or imply that sessions stay connected while the app is in the
background. iOS does not guarantee it, and C22 is a claim about *recovery*, not about
persistence.

---

## 3 · Cloud-server and VPS owners

**Who they are.** One person with between one and five machines they pay for monthly: a
small production service, a side project, a personal mail or media host, a box that runs
some cron. They are competent but not full-time infrastructure people, and every machine is
theirs alone to fix.

**The job.** Everything a small box needs from a phone or an iPad: read a log, restart a
unit, edit a config file, pull a backup down, put a file up, and occasionally reach a
service that is bound to localhost.

**What they use today, and where it hurts.** Two or three apps. A terminal for the shell, a
separate file-transfer app for anything involving a file, and a note somewhere with the
host details typed into both. Each app holds its own copy of the key or the password, each
opens its own connection, and the config file they want to edit has to be pulled down in one
app and pushed back in another. Reaching a service bound to localhost means remembering an
`ssh -L` invocation, retyping it, and having nothing on screen to tell them whether it is
actually carrying traffic.

**The capabilities that decide it.**

| Claim | What it gives this person |
| --- | --- |
| **C1** | One connection carries your shell, your files, your desktop and your tunnels — so the shell and the file browser are the same login, not two apps holding the same key. |
| **C4** | Your server's files, in the Files app — and in the app, several folders at once. |
| **C6** | Local, remote and dynamic (SOCKS5) port forwarding, saved on a connection and started with it, with live byte and connection counters. |

Supporting: **C7** (a forward that cannot start says why, naming the port), **C17** (host key
checked on first connection; a changed key is a hard stop).

**Lead with.**

> **EN:** One connection carries your shell, your files, your desktop and your tunnels. *(C1 verbatim)*
>
> **ZH:** 一条连接，同时承载终端、文件、桌面与隧道。 *(C1 verbatim)*

**Screenshot.** **SS-2** (`02-one-connection`) leads; **SS-4** (`04-files`) and **SS-5**
(`05-forwards`) do the work. SS-5 is the image nobody else in the category publishes, and
this is the audience that understands it on sight.

**Channel.** Self-hosting and small-hosting communities; the low-end hosting forums where
people compare providers monthly; Hacker News. In Chinese: V2EX, 主机与建站类论坛,
电报群. Also the highest-value App Store search terms — this group searches for the tool
by function, not by name.

**Internal note.** Upload from the app's own browser, the transfer queue, and drag-and-drop
are all Implemented but Unverified. C4 covers *browsing*, the Files integration, and several
folders at once — which is what the Verified SFTP suite proves. Copy for this group must
therefore say "browse" and "in the Files app", and must not promise a progress-and-resume
transfer manager.

---

## 4 · Home-lab owners

**Who they are.** People running hardware at home for the pleasure and the control of it: a
NAS, a mini PC or two, a hypervisor, a rack in a cupboard, a handful of containers. Often
the same person as §3, but the machines are physically present and the failure modes are
different — a box that will not come up, a service that needs a click in a graphical
console, a disk that needs looking at.

**The job.** Deal with the house's machines from the sofa or from work: check a container,
restart a service, look at a share, and when the thing genuinely needs a desktop, get to
the desktop without opening a port to the internet.

**What they use today, and where it hurts.** A terminal app, a separate VNC or screen-
sharing viewer, and a file app — three separate logins to one machine, and the desktop
viewer usually wants its own port reachable, which means either a VPN they maintain or a
port they would rather not open. When something is wrong at 22:00, the friction is enough
to make them walk to the machine instead.

**The capabilities that decide it.**

| Claim | What it gives this person |
| --- | --- |
| **C9** | Remote desktop over VNC, in the same app, reachable through the SSH connection — so the desktop rides the tunnel rather than needing a port of its own. |
| **C1** | One connection carries the shell, the files, the desktop and the tunnels: the NAS is one entry in one app. |
| **C4** | Your server's files, in the Files app — and in the app, several folders at once. |

Supporting: **C6** (a saved forward to the container's admin page, started with the
connection), **C11** (several machines live at once).

**Lead with.**

> **EN:** The shell, the files and the machine's own screen, all reached through the same SSH connection — nothing new exposed to the internet.
>
> **ZH:** 终端、文件、机器自己的桌面，全部走同一条 SSH 连接——不必再对公网多开一个端口。

**Screenshot.** **SS-8** (`08-desktop`) leads for this group — it is the "and it does this
too" image, and for a home-lab owner it is the reason to look further. **SS-2** follows.

**Channel.** The home-lab and self-hosting subreddits; NAS-vendor community forums; home
automation communities. In Chinese: NAS 相关的论坛与值 得买 版块, 小众软件, Bilibili 的
NAS/软路由 频道. Video is unusually effective here because the payoff — a desktop appearing
inside a terminal app — is visual.

**Internal note.** The VNC routes that are Verified are **through an existing SSH
connection** and **classic VNC authentication**. macOS Screen Sharing account sign-in and
VeNCrypt are Implemented but Unverified (H-3), so a Mac mini in the cupboard is **not** a
supported story and must not be shown or implied. Direct TCP to a VNC port is likewise
unverified. Every sentence for this group says "through the SSH connection".

---

## 5 · People who must reach a corporate internal network

**Who they are.** Employees of organisations where nothing is directly reachable: a bastion
or jump host in front of everything, keys issued rather than generated, an agent expected
on the client, and a security team with opinions. They are often the same engineers as §1
and §2, wearing a different hat between 09:00 and 18:00.

**The job.** Reach an internal host from a phone or an iPad through the sanctioned path,
without installing anything the security team has not approved and without a private key
sitting in a file that could be copied off the device.

**What they use today, and where it hurts.** A managed laptop, and nothing else — because
mobile clients typically either cannot chain through a bastion at all, or fake it in a way
that checks the bastion's host key and not the destination's. Where a client does support
agent behaviour, it is usually the wrong direction: the client wants a local agent that iOS
does not have. The result is that the phone is not part of the workflow at all, and the
purchase never happens because the person assumes it cannot.

**The capabilities that decide it.**

| Claim | What it gives this person |
| --- | --- |
| **C12** | ProxyJump / bastion chains, with the far server's host key checked as its own — two separate host-key records, not one. |
| **C14** | Agent forwarding with the device as the agent, including an enclave key: a `git push` on the internal server is signed by a key that never left the phone. |
| **C15** | Servers with PAM, expired passwords or a one-time code prompt log in — which is what a corporate login usually is. |

Supporting: **C2** (a key whose private half cannot leave the device is the sentence that
gets a security team to say yes), **C13** where the organisation also runs a CA — see §6.

**Lead with.**

> **EN:** Reach an internal server through your bastion, with the far server's host key checked as its own — and the server's own login prompts relayed to you unchanged.
>
> **ZH:** 通过跳板机连到内网服务器，末端服务器的主机密钥按它自己的来校验；服务器的登录提问原样转达给你。

**Screenshot.** No screen in the eight-shot set photographs a jump chain, which is a known
gap. **SS-7** (`07-security`) leads for this group, because the enclave key plus agent
forwarding is the argument that survives a security review; **SS-2** supports. The bastion
story is carried in the long description and on the website, in words.

**Channel.** Not a consumer channel. This group is reached by App Store search on the exact
vocabulary — bastion, jump host, ProxyJump, agent forwarding — and by a technical page that
ranks for those terms and states the limits. Word of mouth inside an organisation does the
rest: one engineer gets it approved, the team follows. In Chinese: 知乎 and 掘金 长文 aimed at
the same vocabulary.

**Internal note — the Cloudflare decision applies most sharply here.** This is precisely the
audience Cloudflare Access support would be sold to, and it may not be sold to them.
Connecting through Cloudflare Access and browser SSO sign-in are Implemented but Unverified
(H-4: no connection has ever been made through a live Cloudflare account), and per
[`POSITIONING.md`](POSITIONING.md) §6 they appear in **no** public-facing claim, keyword,
caption or post. Nothing in this section's copy may hint at it. When H-4 clears, this
section is the first to be rewritten.

Second note: **C14** carries a real limit — the device answers the server, never the
reverse. There is no local ssh-agent on iOS to consume. Say "the device acts as the agent".
Third: per-signature Face ID gating on an enclave key is unverified (H-7), so no caption or
sentence for this group may show or state a Face ID prompt on key use.

---

## 6 · Teams using an SSH certificate authority

**Who they are.** Organisations that stopped distributing `authorized_keys` and issue
short-lived certificates instead: a CA, a signing service, principals, expiries. Small in
number, disproportionate in influence — the person who chooses tools for a platform team is
usually in this group, and they evaluate a client by whether it understands certificates or
merely tolerates them.

**The job.** Use the certificate the organisation already issues, from a mobile device, with
host trust coming from the CA rather than from a human comparing fingerprints — and have a
bad certificate be refused rather than downgraded into a dialog someone taps through.

**What they use today, and where it hurts.** Mobile clients that accept a private key and
have nowhere to put the `-cert.pub` line, so the certificate is unusable and the person
falls back to a bare key the server will not accept. On the host side, a client that knows
nothing about `@cert-authority` shows a fingerprint prompt for every new machine, which in a
fleet that rotates hosts is a prompt trained into meaninglessness — the exact failure the CA
was adopted to remove.

**The capabilities that decide it.**

| Claim | What it gives this person |
| --- | --- |
| **C13** | OpenSSH user **and** host certificates, and trusted certificate authorities. A certificate that fails validation is refused, not turned into a prompt. |
| **C17** | Host key checked on first connection; a changed key is a hard stop. The behaviour underneath the CA is the strict one. |
| **C2** | Create a key inside the Secure Enclave — a key the CA can certify and that still cannot leave the device. |

**Lead with.**

> **EN:** Trust the authority once: a server it certified connects with no fingerprint to compare, and a certificate that fails validation is refused rather than turned into a prompt.
>
> **ZH:** 信任一次证书颁发机构，之后由它签发的服务器无需再比对指纹；校验不通过的证书直接拒绝，而不是弹个窗让你点过去。

**Screenshot.** **SS-7** (`07-security`) leads. As in §5, the certificate screen itself is
not in the eight — the certificate story is carried in the description, the website security
page and the press kit, all of which can quote C13's second half, which is the part this
audience actually cares about.

**Channel.** A single long technical post, published once and left to rank: what the app
does with user certificates, host certificates and CA host patterns, with the limits named.
Hacker News and lobste.rs for the day it goes up; practitioner blogs and infrastructure
newsletters afterwards. In Chinese: 知乎 / 掘金, same article written in Chinese rather than
translated.

**Internal note.** Two limits must appear in the same breath as C13 wherever there is room
for them: the CA is trusted for host patterns the person types in — `@cert-authority` lines
from an existing `known_hosts` file are not imported — and there is no fetch or renewal from
a CA service; the `-cert.pub` line is pasted in. This audience will find both in ten minutes
and respects being told first. Critical options in a certificate are not accepted.

---

## 7 · People who need SFTP on mobile

**Who they are.** A need, not an identity. Somebody with a server and a file: a designer
pushing assets to a staging host, a photographer pulling a shoot off a machine, a developer
who has to change one line in a config file, a student with a university box. They arrive by
searching, they are not attached to any tool, and they buy the thing that works this
afternoon.

**The job.** Get at files on a remote machine from a phone or an iPad: look at what is
there, get one down, put one up, and open a remote file in the app they already use for
files.

**What they use today, and where it hurts.** A dedicated mobile file-transfer app, usually
old, usually holding its own copy of the credentials, usually isolated from everything else
on the device — the file can be moved but not opened in place, so editing means download,
edit in a second app, upload, and hope. Where the app does publish into the system file
browser, an interrupted upload can leave a half-written file and a temporary artefact on the
server.

**The capabilities that decide it.**

| Claim | What it gives this person |
| --- | --- |
| **C4** | Your server's files, in the Files app — and in the app, several folders at once. The interrupted upload lands whole and leaves no temporary behind. |
| **C1** | The file browser is a channel on the same connection as the shell — one login, and the terminal is there when a file is not enough. |
| **C24** | One app for iPhone and iPad, iOS/iPadOS 17 and later. |

**Lead with.**

> **EN:** Your server's files, in the Files app — and in the app, several folders at once. *(C4 verbatim)*
>
> **ZH:** 服务器上的文件，直接出现在"文件"App 里；应用内还能同时打开多个远程目录。 *(C4 verbatim)*

**Screenshot.** **SS-4** (`04-files`) leads and, for this audience, is the whole argument.
Note the plan's rule: the Files.app half is shown by the `files-domain-toggle` in the
connection editor, never by a photograph of Apple's Files app.

**Channel.** App Store search, first and mostly: this group types what it needs into the
store. The keyword set and the first two lines of the description carry the weight, not a
campaign. Secondarily, practical how-to writing that ranks in search. In Chinese: App Store
搜索 plus 小红书 教程向内容, which is where this need is expressed in Chinese.

**Internal note.** The Verified surface is browsing, the Files integration, several folders
at once, and the remote file operations behind it (list, read, write, mkdir, move, delete).
Upload from the in-app browser, download and Quick Look, drag-and-drop, rename/delete/new
folder in the app's own browser, and the transfer queue are all Implemented but Unverified —
so no copy for this audience may show a progress bar, a speed, a time-remaining figure, or a
pause/resume control. Resuming an interrupted transfer from where it stopped is *Removed*;
it must never be resurrected in copy. Also Partial: permissions editing, and Files.app
noticing in-app changes without a refresh.

---

## 8 · People who need terminal and remote desktop together

**Who they are.** People whose remote machine has a graphical half that matters: a lab
instrument, a workstation running an application with no command-line equivalent, a media or
automation box with a browser-based console, a machine whose installer refuses to be
scripted. Overlaps §4 heavily and §3 partly; distinct because the desktop is the reason they
are shopping.

**The job.** Do the command-line part and the point-and-click part of one task without
carrying two apps, two sets of credentials, and two exposed ports.

**What they use today, and where it hurts.** A terminal app plus a screen-sharing viewer.
The viewer usually needs the desktop port reachable from wherever they are, which means a
VPN or an open port; the credentials are stored twice; and the two apps know nothing about
each other, so a task that alternates between them is a sequence of app switches on a small
screen.

**The capabilities that decide it.**

| Claim | What it gives this person |
| --- | --- |
| **C9** | Remote desktop over VNC, in the same app, reachable through the SSH connection. |
| **C1** | One connection carries your shell, your files, your desktop and your tunnels — the desktop is a channel on the login you already made. |
| **C10** | Split panes on iPad, each with its own toolbar: the shell and the screen side by side rather than one after the other. |

**Lead with.**

> **EN:** A remote screen over VNC, in the same app and on the same SSH connection as the shell.
>
> **ZH:** 远程桌面走 VNC，和终端在同一个 App、同一条 SSH 连接上。

**Screenshot.** **SS-8** (`08-desktop`) leads; **SS-3** (`03-panes`) supports on iPad, where
the side-by-side arrangement is the point.

**Channel.** App Store search on the combined intent — the person searching for both words
at once is this audience and nobody else. Home-lab and self-hosting communities as in §4.
In Chinese: 小红书 and Bilibili, where the visual payoff carries.

**Internal note.** Two constraints, both hard. First, this is **VNC/RFB, not RDP** — see
§11. Copy must say VNC, and search vocabulary must not chase RDP intent, because the person
who arrives wanting RDP is an unhappy purchase and a refund. Second, C9's Verified surface
is the SSH route and classic VNC auth; macOS Screen Sharing sign-in and VeNCrypt are
unverified (H-3), and the pointer, hardware-keyboard and multi-touch gesture set on iPad is
unverified. Show the on-screen key row, which is Verified; do not show or claim trackpad
control of a remote desktop.

---

## 9 · People who want local-first tools with no account

**Who they are.** People for whom a sign-up screen is a reason to close an app. Some hold
this position on privacy grounds, some on durability grounds — a tool with a back end is a
tool that can be switched off — and some because their keys are the credentials to
everything they are responsible for and they will not put them on another company's
computer. They are also, reliably, the people who read the privacy label before the
description.

**The job.** Have a serious tool that keeps working, unchanged, with no account to create,
no subscription to lapse, no telemetry to opt out of, and no third party in the path between
the device and their own servers.

**What they use today, and where it hurts.** A capable client wrapped in a subscription and
an account, where the sync they never asked for is the reason the account exists; or an
open-source client that respects them but was last updated some time ago and does not
support the device properly. The specific pain is not price, it is the shape of the
arrangement: the credential to their infrastructure now depends on somebody else's service
staying up and staying honest.

**The capabilities that decide it.**

| Claim | What it gives this person |
| --- | --- |
| **C5** | No account, no back end, nothing measured. Proven as an absence by grep: no purchase machinery, no analytics or crash-reporting SDK, no server operated by this project. |
| **C2** | Create a key inside the Secure Enclave. Its private half cannot leave the device — and it logs in to an ordinary OpenSSH server. |
| **C19** | Encrypted backup sealed with a password, and a restore that previews before it writes — so "no cloud" does not mean "no way out". Keys that cannot be exported are named rather than silently dropped. |

Supporting: **C23** (app lock: a passcode of the app's own, with backoff and a grace
period), **C18** (a remote program can write your clipboard only after you allow it, and can
never read it).

**Lead with.**

> **EN:** No account, no back end, nothing measured. *(C5 verbatim)*
>
> **ZH:** 没有账号，没有后台服务，不采集任何使用数据。 *(C5 verbatim)*

**Screenshot.** **SS-7** (`07-security`) leads and closes: it is the trust screen, and it
carries C2 and C5 together.

**Channel.** Privacy-minded and open-source-adjacent communities; Mastodon; lobste.rs;
Hacker News, where an absence stated precisely travels further than a feature. The App Store
privacy label is itself a channel for this audience and should be treated as copy. In
Chinese: V2EX and 少数派, where the "本地优先、无账号" framing is well understood.

**Internal note.** The pairing to avoid is C5 with any sync language. iCloud/CloudKit sync
is Implemented but Unverified (H-5) and is withheld in this build; "sync across your devices"
is on the forbidden list. C19 exists precisely so this audience has an answer to "what
happens when I get a new phone" that does not require a sync claim. Private keys are stored
in the iOS Keychain marked this-device-only, which is *Partial* — describe it only with its
limit, or lean on C2 instead, where the guarantee is architectural.

---

## 10 · Priority, and why

Rows 1–7 preserve the order in [`POSITIONING.md`](POSITIONING.md) §5 exactly. Rows 8 and 9
are the two need-shaped groups, which sit below the identity-shaped groups in *messaging*
priority for the reason given underneath the table.

| # | Audience | Why here |
| ---: | --- | --- |
| 1 | Engineers who work from an iPad | The strongest fit between what the product is and what somebody is already trying to do. They have paid to make the iPad work and will pay again for the thing that finishes the job. Highest willingness to pay, longest retention, and the group most likely to write about it — which supplies the material every other group reads. |
| 2 | DevOps / SRE on call | The clearest urgency. The need recurs on a rota, the alternative is a laptop they do not have, and C22 answers the exact failure that makes them give up. They buy quickly and, once the app has worked once at 03:00, they do not re-evaluate. |
| 3 | Cloud-server and VPS owners | The largest of the groups, and the one where C1 does the most work: one app replacing two or three. Broad and search-reachable, but each individual has less at stake than 1 or 2, so persuasion depends on the store listing rather than on a relationship. |
| 4 | Home-lab owners | Nearly as large as 3, enthusiastic, and communities that talk. Ranked below 3 because the strongest hook for them, C9, has a narrower Verified surface — the SSH route and classic VNC auth — so more of the copy has to be careful. |
| 5 | People who must reach a corporate internal network | Small in count, high in value: one approval brings a team. Ranked fifth rather than higher because the most persuasive thing available to them, Cloudflare Access, is withheld (§5's internal note), and because there is no screenshot of a jump chain. Both are fixable, and fixing them moves this group up. |
| 6 | Teams using an SSH certificate authority | The smallest group here and the most influential per person: they choose tools for others. C13 is genuinely uncommon and the refusal-not-prompt behaviour is exactly what they check. Low volume keeps it sixth; a single well-made technical page is the whole plan. |
| 7 | People who want local-first tools with no account | Not a separate market so much as a decisive attribute inside all six above. Ranked seventh as a *primary* target because few people search for a terminal by its absence of an account — but C5 and C2 close purchases begun for other reasons, which is why they appear on SS-7 and in the press kit. |
| 8 | People who need SFTP on mobile | High search intent, low loyalty. This is a demand pocket, not an identity: they arrive through the store, buy on SS-4, and become members of 3 or 4 afterwards. Funded through keywords and the first two description lines rather than through headline copy — which is why it sits below the groups whose story the headline has to tell. |
| 9 | People who need terminal and remote desktop together | The same logic as 8, at smaller volume, with an added filter: a meaningful share of that search intent wants RDP and must be turned away rather than converted (§11). Real, worth serving, and served almost entirely by SS-8 and by the store's own search. |

Two consequences of this ranking, stated so nobody has to infer them.

* **The headline copy is written for 1 and 2, and works for 3 and 4.** C1 and C3 do that.
  The listing is not rewritten to chase 8 and 9; the keyword field reaches them instead.
* **5, 6 and 7 are served by depth, not by breadth.** One technical page each, written once,
  accurate, left to rank. They do not repay campaign spending and they punish overstatement
  more than any other group.

---

## 11 · Anti-audience — who this is not for

Said plainly, in the listing and in every channel, because a purchase from one of these
people is a refund, a one-star review and a support burden — and because saying it is the
same discipline that makes the rest of the copy believable.

**Casual users with no servers.** This is an SSH **client**. It connects to remote machines
that already exist and that the customer already administers; the commands run on those
machines, not on the phone. It is not a local shell for iOS, not a Linux environment on the
device, and not a way to acquire a server. Somebody with no server to connect to has nothing
to do here, and the first line of the description says so.

**People who want a Windows RDP client.** The remote-desktop support is **VNC/RFB**, spoken
natively. It reaches a machine running a VNC server, through the SSH connection. It is not
RDP, and there is no plan in this release to make it RDP. Search vocabulary must not chase
RDP intent (§8), and the description must say VNC where a hurried reader would otherwise
assume.

**People who want a hosted or cloud shell.** There is no Apex Terminal account and no Apex
Terminal server (C5). Nobody here operates infrastructure the customer's session runs on or
passes through, and nothing is stored off the device on this project's behalf. A person who
wants a browser-reachable shell, a provisioned VM, or a session they can pick up on any
machine by logging in wants a service, and this is not one.

Three more, less obvious, that cost real support time when they are not said:

* **People who want a VPN.** No Network Extension, no VPN profile, no system-wide traffic
  capture. Port forwarding, including SOCKS5 (C6), moves specific traffic through the SSH
  connection. It does not route the device.
* **People who want an authenticator.** Servers with a one-time code prompt log in (C15)
  because the app relays the server's prompt. The app generates no codes and stores no TOTP
  secret; anyone wanting an authenticator wants a different app.
* **People who want it on a Mac or a Vision Pro today.** iPhone and iPad, iOS/iPadOS 17 and
  later (C24). The Catalyst build has no signing identity (H-8) and visionOS has never been
  run (H-9); neither is offered, mentioned, or implied.

And one boundary that is a *timing* statement rather than a rejection: people who need their
connections mirrored between devices are not served in this build. Sync is unverified (H-5)
and withheld; C19's encrypted backup and restore is the honest answer for now, and it is the
answer support should give.

---

## 12 · Channel → audience map

Read the other way round: for each channel, who is there, what is published, and which
claims are used. Nothing on this list carries a claim outside `CLAIMS_MATRIX.md`, and
nothing on it mentions Cloudflare.

| Channel | Reaches | What is published there | Claims | Language |
| --- | --- | --- | --- | --- |
| App Store — title, subtitle, first two description lines | 3, 4, 7, 8, 9 | The position in one line, then what it is: an SSH client for servers the customer already runs | C1, C3, C24 | en-US, zh-Hans, zh-Hant |
| App Store — keywords | 8, 9, 5 | Function words people actually type: sftp, sftp client, vnc, port forwarding, tmux, bastion, jump host, ssh certificate. No competitor names, no RDP | — | all three |
| App Store — screenshots | all | SS-1 … SS-8, in the plan's order | C1–C11 as mapped in the plan | all three |
| App Store — privacy label | 7, 5, 6 | Treated as copy, not paperwork: it is the first thing 7 reads | C5 | all three |
| Website — home | 1, 2, 3, 4 | The position, the one-connection argument, the eight screens | C1, C3, C4, C5 | EN, ZH |
| Website — security page | 5, 6, 7 | Enclave keys, host key policy, certificates, clipboard policy, app lock, what does not leave the device, with limits named | C2, C13, C17, C18, C23, C5 | EN, ZH |
| Website — a page each for bastions, certificates, forwards, tmux | 5, 6, 3 | One long, exact page per subject, written once and left to rank | C12, C14, C13, C6, C7, C8 | EN, ZH |
| Hacker News / lobste.rs | 2, 3, 6, 7 | The launch write-up and the certificate page. Limits stated in the post itself | C1, C2, C5, C13 | EN |
| Operations and SRE communities and newsletters | 2 | The reconnection and one-connection story; the incident-shaped use | C22, C1, C15, C8 | EN |
| Self-hosting and small-hosting forums | 3, 4, 8 | One app instead of three; the forwards screen | C1, C4, C6, C9 | EN |
| Home-lab and NAS communities | 4, 9 | Terminal plus desktop plus files on the same box, through the SSH connection | C9, C1, C4 | EN |
| iPad-workflow publications, video and Mastodon | 1 | Split panes, tmux, fonts, hardware keyboard behaviour | C10, C8, C3, C20, C11 | EN |
| Privacy and open-source-adjacent communities | 7 | The absences, proven as absences | C5, C2, C19, C23 | EN |
| Press kit | 1, 2, 6, 7 | Fact sheet, the eight screens, the security section | C1, C2, C5 | EN, ZH |
| V2EX | 2, 3, 7 | 技术长文与发布帖，写明限制 | C1, C22, C5 | ZH |
| 知乎 / 掘金 | 2, 5, 6 | 跳板机、证书、Agent 转发的长文，各写一篇 | C12, C13, C14 | ZH |
| 少数派 | 1, 7 | iPad 工作流与「本地优先、无账号」两个角度 | C10, C8, C5 | ZH |
| 小红书 | 8, 9, 1 | 教程向短内容：文件、远程桌面，画面本身就是理由 | C4, C9 | ZH |
| Bilibili | 4, 9, 1 | NAS / 软路由 与 iPad 生产力两条线，演示为主 | C9, C1, C10 | ZH |
| 主机与建站类论坛、电报群 | 3 | 一台 VPS 的日常：看日志、改配置、传文件、开转发 | C1, C4, C6 | ZH |
| NAS 论坛与相关版块 | 4 | 家里的机器，终端、文件、桌面走同一条连接 | C9, C1, C4 | ZH |

**Channels deliberately not used.** Paid acquisition of any kind before the listing has been
tested against organic search; any channel where the format forces a superlative; any
comparison post, table or page that names another product; and any placement where the
limits cannot travel with the claim. The last one is the general rule: if a channel has no
room for the sentence that names the limit, it has no room for the claim.
