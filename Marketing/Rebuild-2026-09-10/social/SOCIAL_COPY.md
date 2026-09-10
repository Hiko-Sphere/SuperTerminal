# Social copy — Apex Terminal

**Written:** 2026-09-10 · **Version described:** 0.1.0 · **Platforms described:** iPhone and iPad,
iOS and iPadOS 17 and later ·
**Gated by:** [`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md) and
[`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md) ·
**Language kit:** [`../strategy/MESSAGING_SYSTEM.md`](../strategy/MESSAGING_SYSTEM.md)

This is the evergreen library: posts that stay true for as long as 0.1.0 is the shipping
build, and that can be scheduled in any order on any day. Launch-day material — the things
that are said once, on a date — lives in [`LAUNCH_POSTS.md`](LAUNCH_POSTS.md).

Every fenced block is the literal text to post. Prose outside a block is guidance for
whoever is posting and is not part of the copy.

---

## 0 · House rules for anyone posting from this file

1. **Post the block, do not edit it.** Each sentence traces to a claim (`C1`–`C24`) or to a
   proof point (`P1`–`P11`) in the messaging system. A trimmed sentence is a new claim, and a
   new claim has to go through the claims matrix before it goes through a scheduler.
2. **Apex Terminal is an SSH client.** Commands run on the reader's own remote servers. Any
   post long enough to describe the product says so.
3. **Nothing here is a superlative, a ranking or a count.** There are no user numbers, no
   ratings, no awards, and no competitor is named — not in a post, not in a reply, not in a
   quote-post.
4. **No exclamation marks.** The voice is quiet, exact and unhurried. A reader in this
   category has been sold to badly before; every sentence should be one they could check.
5. **Limits travel inside the sentence that makes the claim**, not in a reply and not in a
   footnote. Where a block carries a limit, the limit is part of the block.
6. **Free, and that is a fact about the build.** No in-app purchase, no subscription, no
   account. There is no StoreKit code in the binary. Do not hint at a paid tier, a pro
   version or a future price.
7. **The Chinese posts are Chinese originals.** They are not translations of the English
   above them, and editing one does not license editing the other. The product name stays in
   Latin script, with a space either side, inside Chinese text.
8. **Links.** The marketing URL used across these channels is `https://apexterminal.dev`. It
   is a proposal in the App Store metadata and it is not live; nothing in this file may be
   posted until that page resolves. The App Store link is deliberately absent from every
   block — the listing has no numeric identifier until it exists, so it is pasted in at
   posting time from App Store Connect rather than written down here.
9. **No handle, hashtag or account name is invented in this file.** Where a platform needs
   one, the person posting uses the account that actually exists.

---

## 1 · The limits each block is written to

Written to the free-tier limit on every platform, so that nothing depends on a paid posting
account. Where a platform shows a truncated preview, the block is built so the part before
the fold stands alone.

| Platform | Field | Hard limit written to | Fold / preview | Note |
| --- | --- | ---: | --- | --- |
| X | Post | 280 characters | — | Written for the unpaid limit; a link, when added, consumes 23 characters of it |
| X | Thread post | 280 characters each | — | Each post is legible lifted out of the thread |
| X | Profile bio | 160 characters | — | §7 supplies the line |
| LinkedIn | Post | 3 000 characters | opening ~210 characters | The hook is a complete sentence before "…see more" |
| Instagram | Caption | 2 200 characters | opening ~125 characters | Up to 30 hashtags; these use ten |
| Instagram | Alt text | 1 000 characters | — | Written per image, never left to the platform |
| Xiaohongshu (小红书) | 标题 | 20 characters | — | Counted in Chinese characters |
| Xiaohongshu (小红书) | 正文 | 1 000 characters | opening ~2 lines | Tags count toward the 1 000 |
| Xiaohongshu (小红书) | 话题标签 | 10 tags | — | |
| Open Graph | `og:title` | 60 characters | — | §7 supplies it |
| Open Graph | `og:description` | 155 characters | — | §7 supplies it |

Counts in this file are characters as a person counts them, matching what each platform's own
composer reports.

---

## 2 · X — short posts

At least one of these should be scheduled per week; they do not expire and they do not depend
on each other. Numbers in brackets are the character count of the block.

### X-1 · The description (179)

```
Apex Terminal is an SSH client for iPhone and iPad. One connection carries your shell, your files, your remote desktop and your tunnels. No account, no back end, nothing measured.
```

The 30-word boilerplate, verbatim (`MESSAGING_SYSTEM.md` §3.2). Claims C1, C5.

### X-2 · The arithmetic (227)

```
Open a shell, a file browser, a remote desktop and a port forward on the same server: one TCP connection, one key exchange, one authentication, one biometric prompt. They are channels on a pooled SSH transport, not four logins.
```

Claim C1, proof point P1. The count comes out of a real `sshd`'s own log, not the app's
self-report — worth saying in a reply if anyone asks how it was measured.

### X-3 · The key (208)

```
A key generated inside the Secure Enclave has no private half outside the chip. There is no key file to export, back up or copy — and it logs in to an ordinary OpenSSH server, unmodified, on your own machine.
```

Claim C2, proof points P2 and P3.

### X-4 · Host keys (191)

```
A server's fingerprint is put in front of you before you trust it. If a key you already know later changes, the connection is refused outright rather than turned into a prompt to tap through.
```

Claim C17, proof point P8.

### X-5 · The terminal (235)

```
True colour, sixel pictures, mouse reporting in three modes, the alternate screen, and CJK, emoji and combining marks that occupy the right number of cells — from UCD 17.0.0. Quitting vim or less puts your shell back exactly as it was.
```

Claim C3, proof point P6.

### X-6 · tmux (234)

```
Apex Terminal speaks tmux's own control protocol, so the panes on screen are tmux's arrangement rather than scraped text. Detach, put the iPad down, attach again: the panes and their output are still there. Measured against tmux 3.3a.
```

Claim C8, proof point P11. Naming the version is the difference between evidence and a shrug.

### X-7 · Files (257)

```
Your server's files over SFTP on the same SSH connection as the terminal — no second sign-in, no second password. Put a connection in the Files app and open its documents from anywhere in iOS, or open several remote folders at once, side by side on an iPad.
```

Claim C4.

### X-8 · Tunnels (247)

```
Local, remote and dynamic (SOCKS5) forwarding, saved on a connection and started with it. Each rule shows bytes out, bytes in, how many connections are open now and how many it has carried. A forward that cannot start says why, and names the port.
```

Claims C6 and C7.

### X-9 · The absences (235)

```
No account. No back end operated by this project. No analytics, no telemetry, no crash reporter. No in-app purchase, no subscription. Every one of those is an absence — and an absence is proven by a search anyone can repeat in seconds.
```

Claim C5, proof points P4 and P5.

### X-10 · The clipboard (202)

```
A program on your server can write your clipboard once you have allowed it, and can never read it. The read request is refused, and the refusal is silent: the remote program is not told what you copied.
```

Claim C18, proof point P9.

### X-11 · Links that carry commands (172)

```
An ssh:// link cannot make the app run anything. The command is shown to you verbatim, in full, and waits for you to agree before a single character of it reaches a server.
```

Claim C21.

### X-12 · Reconnection, with its limit (241)

```
Terminal sessions come back on their own after the network drops, scrollback intact and the new shell marked as fresh — a tmux session keeps running on the server, but reattaching to it is something you do rather than something that happens.
```

Claim C22 with the limit inside the sentence (`MESSAGING_SYSTEM.md` §8.1). Never post the
half of this sentence before the dash on its own.

### X-13 · The price (169)

```
Apex Terminal is free. No in-app purchase, no subscription, no account, nothing measured. iPhone and iPad, iOS and iPadOS 17 and later. Commands run on your own servers.
```

Claims C5 and C24, and wording rule 1.

---

## 3 · X — a seven-post thread

Post as one thread, in order, in a single sitting. Each post is legible on its own if it is
quoted out of the thread — which is how threads are actually read.

### Thread 1 of 7 (256)

```
1/7 When you reach a server from a phone you usually want more than a shell: the files, sometimes the machine's desktop, sometimes a port handed back to you. In most tools each of those is its own login. Apex Terminal makes them channels on one connection.
```

### Thread 2 of 7 (267)

```
2/7 The arithmetic, and it is arithmetic rather than an adjective. A shell, a file browser, a remote desktop and a port forward on the same server cost one TCP connection, one key exchange, one authentication and one biometric prompt. Counted in the server's own log.
```

### Thread 3 of 7 (267)

```
3/7 The terminal is the product, not a text view. 24-bit colour in both SGR spellings, sixel pictures, mouse reporting in three modes, the alternate screen, reflow, search across the whole scrollback, and CJK and emoji cells sized from UCD 17.0.0 rather than by hand.
```

### Thread 4 of 7 (267)

```
4/7 tmux is spoken as a protocol, in tmux's own control mode, so what you see is tmux's arrangement rather than text scraped off a screen. Detach and reattach and the panes are where you left them. A tmux session keeps running on the server; reattaching is your move.
```

### Thread 5 of 7 (262)

```
5/7 Files and tunnels ride the same connection. SFTP with no second password, remote folders in the Files app, and local, remote and dynamic forwarding whose rules are saved with the connection and show bytes out, bytes in and connections carried while they run.
```

### Thread 6 of 7 (268)

```
6/7 Keys. Generate one inside the Secure Enclave and the private half is made in the chip and never exists outside it — no file to export, back up or copy — and it still logs in to an ordinary OpenSSH server. A known host key that changes is a hard stop, not a prompt.
```

### Thread 7 of 7 (238)

```
7/7 There is no account to make and no back end behind it. No analytics, no telemetry, no crash reporter, no in-app purchase, no subscription. Commands run on your own servers. iPhone and iPad, iOS and iPadOS 17 and later, and it is free.
```

---

## 4 · LinkedIn

One post, 1 442 characters. The hook is a complete sentence, so the truncated preview reads
as a sentence rather than as a fragment. No hashtags: they read as noise in this register and
the audience here arrives from the feed, not from a tag.

### LinkedIn — the post

```
Apex Terminal is an SSH client for iPhone and iPad, and the idea behind it is small enough to say in a sentence: when you reach a server, you usually want more than a shell.

You want the files. Sometimes the machine's desktop. Sometimes a port handed back to you. In most tools each of those is a separate login, which on cellular is four chances to fail, and on a hardware key is four touches.

Here they are channels on one SSH connection. A shell, a file browser, a remote desktop and a port forward on the same server cost one TCP connection, one key exchange, one authentication and one biometric prompt. That count is taken from the server's own log rather than from the app's self-report.

The other half of the product is the key. You can generate an SSH key inside the Secure Enclave, where the private half is made in the chip and never exists outside it. There is no key file to export, back up or copy, and it logs in to an ordinary, unmodified OpenSSH server. If a host key you already know later changes, the connection is refused outright rather than turned into a prompt to tap through.

Underneath both: no account to create, no back end operated by this project, no analytics, no telemetry, no crash reporter, no in-app purchase and no subscription. Those are absences, and an absence is proven by a search anyone can repeat in seconds.

Commands run on your own servers. iPhone and iPad, iOS and iPadOS 17 and later. Free.
```

---

## 5 · Instagram

Three captions. Each pairs with the image named beneath it; the alt text is written here and
is not left to the platform to guess. The hook line is under 125 characters so that the whole
of it survives the fold.

### Instagram 1 — the caption

```
One connection. A shell, your files, a desktop and a port forward — and one biometric prompt for all four.

Open four things on the same server in Apex Terminal and you pay for one TCP connection, one key exchange and one authentication. They are channels on a pooled SSH transport rather than four separate logins, which on cellular is the difference between four chances to fail and one.

Apex Terminal is an SSH client for iPhone and iPad. Commands run on your own servers. There is no account to create and no back end behind it, no analytics and no telemetry, no in-app purchase and no subscription.

iOS and iPadOS 17 and later.

#ssh #sftp #terminal #devops #sysadmin #homelab #selfhosted #vps #ipadpro #developertools
```

*Image:* the iPad split-pane frame from SS-1. *Alt text:*

```
An iPad showing Apex Terminal with two panes side by side: a shell session on the left and a file browser listing a remote directory on the right, both on the same server.
```

### Instagram 2 — the caption

```
A key that has no file. Generated inside the Secure Enclave, and it logs in to an ordinary OpenSSH server.

The private half is created in dedicated hardware on the device and never exists outside it. Nothing to export, nothing to back up, nothing to copy off — and the server it authenticates to is unmodified stock OpenSSH, with just the public half in authorized_keys.

The rest follows from the same idea. A server's fingerprint is shown to you before you trust it, and a known key that later changes is refused rather than turned into a prompt you tap through.

Apex Terminal, an SSH client for iPhone and iPad. No account, no back end, nothing measured.

#ssh #secureenclave #infosec #devops #sysadmin #keys #openssh #ios #ipad #developertools
```

*Image:* the key-generation screen from SS-7. *Alt text:*

```
An iPhone showing Apex Terminal's key screen, with a key listed as generated in the Secure Enclave and its public half displayed for copying to a server.
```

### Instagram 3 — the caption

```
Sixel pictures, true colour and a mouse that works — on a phone, over SSH, on your own server.

The terminal is the product rather than a text view. 24-bit colour in both SGR spellings. Sixel graphics, so a gnuplot plot is a real picture on the screen. Mouse reporting in three modes, so taps, drags and two-finger scrolling reach htop, tmux and less as real mouse events. The alternate screen, so quitting vim leaves your shell exactly as it was. CJK, emoji and combining marks sized from UCD 17.0.0, so a status line does not tear.

Apex Terminal is an SSH client for iPhone and iPad. Commands run on your own servers.

#ssh #terminal #sixel #tmux #vim #cli #linux #homelab #ipadpro #developertools
```

*Image:* the sixel plot frame from SS-3. *Alt text:*

```
An iPhone running Apex Terminal, showing a gnuplot chart drawn as a sixel image directly inside the terminal, above a shell prompt.
```

---

## 6 · 小红书

三组内容。小红书的语气比 X 和 LinkedIn 近，所以句子更短、更像一个人在讲自己怎么用；但不夸张、
不堆形容词、不用感叹号，也不放表情符号——这是品牌语气的一部分，不是疏漏。产品名保持拉丁字母
写法 Apex Terminal，前后各留一个空格。

标题上限 20 字，正文上限 1 000 字（话题标签计入正文字数），话题最多 10 个。

### 小红书 1 — 标题

```
iPad 当终端用的一种做法
```

### 小红书 1 — 正文

```
出门只带 iPad，还想连自己的服务器干点活，这是我现在的做法。

Apex Terminal 是 iPhone 和 iPad 上的 SSH 客户端。命令跑在你自己的服务器上，它只是把连接和画面做好。

最实用的一点是：在同一台服务器上打开终端、文件、远程桌面和端口转发，这四件事共用一条连接——一次握手、一次认证、一次生物识别提示。它们是同一条 SSH 连接上的四条通道，不是四次登录。在移动网络下，四次握手就是四次失败的机会，现在只剩一次。

终端本身也做得实：真彩色、sixel 图像、鼠标上报，中日韩字宽是按 UCD 17.0.0 的表来算的，所以 vim 的状态栏不会被中文推歪。退出 vim 或 less 之后，shell 原样还在。

文件走的是同一条连接的 SFTP，不用再登录一次、再输一次密码；也可以把一台服务器放进「文件」App，任何能打开文件的应用都能打开它上面的文档。

没有账号，没有本项目运营的后台服务，不采集任何使用数据，没有内购和订阅。

支持 iOS 与 iPadOS 17 及以上。

#iPad生产力 #SSH #运维 #服务器 #命令行 #开发者工具 #远程办公 #自建服务 #终端 #iPad
```

### 小红书 2 — 标题

```
密钥就留在手机里
```

### 小红书 2 — 正文

```
一直有个小顾虑：SSH 私钥放在手机上，手机丢了怎么办。

Apex Terminal 的做法是让这个问题不成立：密钥可以直接在 Secure Enclave 里生成，私钥是在芯片内部产生的，从来没有在芯片之外存在过。也就是说，没有密钥文件——没有东西可以导出、备份，或者被谁拷走。

而它登录的，是一台未经任何改动的标准 OpenSSH 服务器。你只需要把公钥放进服务器的 authorized_keys，其余什么都不用装。

配套的几件事也是同一个思路：

第一次连上一台服务器时，指纹会先摆在你面前让你核对；此后主机密钥一旦变了，就是直接拒绝连接，而不是弹个框让你点「继续」。

设备本身可以充当 SSH agent 并转发出去，所以服务器上执行的 git push，是由一把从未离开过手机的密钥来签名的。

需要一次性验证码的服务器也能登录：应用把服务器自己的提问原样显示出来，再把你的回答递过去。它不保存任何密钥，也不生成任何验证码。

导出备份的时候，那些无法导出的密钥会被明确列出来，而不是悄悄跳过。

没有账号，没有后台服务，不采集任何使用数据。

#SSH #密钥 #信息安全 #运维 #服务器 #程序员日常 #iPhone #iPad #开发者工具 #命令行
```

### 小红书 3 — 标题

```
在 iPad 上接着跑 tmux
```

### 小红书 3 — 正文

```
长时间跑着的任务，想在 iPad 上接着看一眼，这是我常用的一套。

Apex Terminal 说的是 tmux 自己的控制协议（tmux -C），不是把屏幕上的文字刮下来重画。所以屏幕上的面板就是 tmux 自己的布局，连应用自身的分屏表达不出来的布局也照样画得出来。断开、把 iPad 合上、过一会儿再接回去，面板和它们的输出都还在。这一套是对着 tmux 3.3a 实测的。

有一点先说清楚：终端会话在网络中断后会自己回来，回滚历史还在，新的 shell 会被标出来告诉你它是新的；而 tmux 会话是在服务器上继续跑着的，重新接上去这一步要你自己来，不会自动发生。

顺手好用的还有端口转发：本地、远程和动态（SOCKS5）三种都在，规则跟着连接一起保存、一起启动，每条规则会显示出站字节、入站字节、当前连接数和累计连接数。起不来的时候，它会告诉你原因，并且点名是哪个端口。

iPad 上可以分屏，一半看日志一半干活，每个面板都是完整的会话，各自带工具栏。

命令运行在你自己的服务器上。没有账号，也没有后台服务。

#tmux #SSH #iPad生产力 #运维 #服务器 #命令行 #远程办公 #开发者工具 #Linux #iPad
```

---

## 7 · Reusable one-liners

Short, load-bearing lines. Use them for bios, image captions, the alt text of a key visual,
an Open Graph description, a conference badge, a reply. They are drawn from the approved
boilerplate and the proof points, and they may be shortened at a comma but not rewritten.

### English

| # | Line | Chars | Where it fits |
| --- | --- | ---: | --- |
| L1 | A full SSH workstation for iPhone and iPad — your keys never leave the device. | 77 | Bio, `og:title` is too short for it; use as `og:description` opener |
| L2 | One connection carries your shell, your files, your desktop and your tunnels. | 76 | Image caption, section heading |
| L3 | One handshake, one authentication, one biometric prompt. | 55 | Key visual, badge, reply |
| L4 | No account, no back end, nothing measured. | 41 | Bio tail, sign-off line |
| L5 | Generated in the Secure Enclave. There is no key file. | 53 | Security visual |
| L6 | It logs in to an ordinary OpenSSH server, unmodified. | 52 | Reply to "does it need an agent on the server" |
| L7 | Commands run on your own servers. | 33 | Required client sentence, any post |
| L8 | tmux spoken as a protocol, not scraped as text. | 46 | tmux visual |
| L9 | Your server's files, in the Files app. | 38 | Files visual |
| L10 | A changed host key is a hard stop. | 34 | Security visual |
| L11 | Free. No in-app purchase, no subscription. | 42 | Price line, any post |
| L12 | iPhone and iPad. iOS and iPadOS 17 and later. | 45 | Availability line, any post |

### 中文

| # | 句子 | 用在哪里 |
| --- | --- | --- |
| Z1 | iPhone 与 iPad 上的完整 SSH 工作台，密钥不出这台设备。 | 简介、主视觉 |
| Z2 | 一条连接，同时承载终端、文件、远程桌面与端口转发。 | 图注、小标题 |
| Z3 | 一次握手、一次认证、一次生物识别提示。 | 主视觉、回复 |
| Z4 | 没有账号，没有后台服务，不采集任何使用数据。 | 结尾句 |
| Z5 | 在 Secure Enclave 内生成，没有密钥文件。 | 安全主题图 |
| Z6 | 登录的是一台未经改动的标准 OpenSSH 服务器。 | 回复常见提问 |
| Z7 | 命令运行在你自己的服务器上。 | 每条较长的帖子都带上 |
| Z8 | 把 tmux 当协议来说，而不是从文字里刮出来。 | tmux 主题图 |
| Z9 | 服务器上的文件，直接出现在「文件」App 里。 | 文件主题图 |
| Z10 | 主机密钥变了，就是直接拒绝连接。 | 安全主题图 |
| Z11 | 免费，没有内购，也没有订阅。 | 价格说明 |
| Z12 | 支持 iOS 与 iPadOS 17 及以上。 | 版本说明 |

### Open Graph pair

`og:title`, 49 characters:

```
Apex Terminal — an SSH client for iPhone and iPad
```

`og:description`, 152 characters:

```
One connection carries your shell, your files, your desktop and your tunnels. Keys can be generated in the Secure Enclave. No account, nothing measured.
```

---

## 8 · Social images that must be produced

**These are laid out per platform. They are not crops of the App Store screenshots.**

The store screenshots are 1 320 × 2 868 and taller shapes, built for a portrait phone frame
in a vertical scroller, with their captions set for that shape and that reading distance. A
landscape card at 1 600 × 900 cut out of one of them loses the caption, loses the device
frame, and puts type at a size that is unreadable in a feed on a small screen. Every size
below is composed on its own canvas from the source captures in
[`../app-store/raw-screenshots/`](../app-store/raw-screenshots/), with its own type size, its
own safe area and its own crop of the terminal content. The screenshot renderer already draws
onto arbitrary canvases; these are new placements, not new artwork.

### 8.1 · The sizes

| # | Platform and use | Pixels | Aspect | Safe area | Format |
| --- | --- | --- | --- | --- | --- |
| IMG-1 | X — in-feed single image, landscape | 1600 × 900 | 16:9 | 64 px on every edge | PNG, sRGB, no alpha |
| IMG-2 | X — summary card (`twitter:image`) | 1200 × 600 | 2:1 | 48 px on every edge; nothing load-bearing in the outer 8 % — the card is corner-rounded and edge-cropped in some clients | PNG, sRGB, no alpha |
| IMG-3 | LinkedIn — single-image post | 1200 × 627 | 1.91:1 | 60 px on every edge | PNG, sRGB, no alpha |
| IMG-4 | LinkedIn — square variant for the mobile feed | 1200 × 1200 | 1:1 | 72 px on every edge | PNG, sRGB, no alpha |
| IMG-5 | Instagram — square | 1080 × 1080 | 1:1 | 96 px on every edge | PNG, sRGB, no alpha |
| IMG-6 | Instagram — portrait | 1080 × 1350 | 4:5 | 96 px sides, 120 px top, 200 px bottom, clear of the caption overlay and the action rail | PNG, sRGB, no alpha |
| IMG-7 | Open Graph (`og:image`) | 1200 × 630 | 1.91:1 | 60 px on every edge | PNG, sRGB, no alpha |
| IMG-8 | Xiaohongshu (小红书) — cover and body images | 1080 × 1440 | 3:4 | 90 px sides, 120 px top, 260 px bottom, clear of the title overlay on the cover | PNG, sRGB, no alpha |

Additionally, and produced from the same layouts:

| # | Use | Pixels | Note |
| --- | --- | --- | --- |
| IMG-9 | Profile avatar | 1000 × 1000 | Legible at 48 px; the mark alone, no wordmark |
| IMG-10 | X header | 1500 × 500 | The centre 1 100 × 380 is what survives on every client |
| IMG-11 | LinkedIn page banner | 1128 × 191 | Type no smaller than 28 px at this size |

### 8.2 · Rules that apply to all of them

1. **Composed, not cropped.** Each canvas gets its own layout pass. If a shape cannot hold the
   sentence, the sentence changes for that shape — from §7, never invented.
2. **A screenshot inside an image is a real capture**, taken from
   [`../app-store/raw-screenshots/`](../app-store/raw-screenshots/) and scaled by the same
   factor on both axes. Nothing is stretched, re-typed or mocked up.
3. **The terminal content shown is the content that was captured.** No invented hostnames, no
   invented output. `127.0.0.1` is the address that may appear; no other address, and no key
   material of any kind, in any frame.
4. **Text is set at a size that survives a phone.** A body line under 28 px on a 1080-wide
   canvas is not shipped.
5. **Both appearances.** Every layout is produced against the app's dark terminal and its
   light chrome, and checked at 25 % scale, which is roughly what a feed shows.
6. **No logo but the app's own.** No platform logos, no third-party wordmarks, no device
   mock-ups that misrepresent a model the app was not captured on.
7. **Contrast is checked, not eyeballed.** Body text against its background at 4.5:1 or
   better; a caption over a screenshot gets a solid plate rather than a gradient.
8. **Localised sets are laid out separately.** A Chinese line is not poured into a box measured
   for English; the zh-Hans captures under `raw-screenshots/` are the sources for the
   Xiaohongshu set.
9. **File weight.** Under 1 MB each for the feed sizes, under 300 KB for `og:image`, so the
   preview fetch does not time out.
10. **Alt text ships with the image**, taken from §5 or written to the same pattern: what is
    on the screen, in a sentence, without adjectives.

---

## 9 · Pre-flight, before anything is scheduled

* The block is posted whole, with no sentence trimmed and none added.
* No superlative, no ranking, no count of users, no rating, no competitor.
* No exclamation mark.
* Any claim that carries a limit still carries it.
* The price sentence, where present, says free with no in-app purchase and no subscription,
  and promises nothing about a future one.
* Alt text exists for every image.
* The marketing page resolves, and the App Store link has been pasted in from App Store
  Connect rather than guessed.
* `automation/validate.py` has been run over this directory and reports no failure.
