# Messaging system — Apex Terminal

**Written:** 2026-09-10 · **Decided by:** [`POSITIONING.md`](POSITIONING.md) ·
**Gated by:** [`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md) and
[`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md)

This is the language kit. Every other document in this rebuild — the App Store listing, the
press kit, the website, the screenshot captions, the social posts — draws its sentences from
here rather than writing new ones. The boilerplate in §3 and the pitch in §4 are **final
text**: they are copied verbatim, not paraphrased, so that the same product is described the
same way in every place a person can find it.

Nothing here introduces a claim. Every sentence traces to a row in the claims matrix (`C1`–`C24`)
or to a Verified row in the truth matrix. Where a sentence carries a limit, the limit is part
of the sentence and travels with it.

---

## 1 · The message hierarchy

### 1.0 · The positioning line (the roof)

> **Apex Terminal is a full SSH workstation for iPhone and iPad: one connection carries your
> shell, your files, your remote desktop and your tunnels — and your keys never leave the device.**

> **Apex Terminal 是 iPhone 与 iPad 上的完整 SSH 工作台：一条连接同时承载终端、文件、
> 远程桌面与隧道，而密钥始终不离开这台设备。**

This line is not itself a claim to be printed everywhere. It is the shape the three pillars
have to fit. Where a short form is needed, use the one-line boilerplate in §3.

### 1.1 · Pillar one — One connection, not four

**The message:** opening a shell, a file browser, a remote desktop and a port forward on the
same server is one connection, not four logins.

**支柱一 —— 一条连接，而不是四条。** 在同一台服务器上打开终端、文件、远程桌面和端口转发，
是一条连接上的四条通道，不是四次登录。

| Proof | Claim | What stands behind it |
| --- | --- | --- |
| Four channel types ride one pooled transport | C1 | `SSHConnectionPoolTests`; the count comes out of the real `sshd`'s own log, not the client's self-report |
| The arithmetic: one handshake, one authentication, one biometric prompt | C1 | `ConnectionPoolTests.swift:29-53` — four sessions, one handshake counted in the server's log |
| The pool never returns a connection belonging to another account, and never a dead one | C1 | The adversarial pair in the same suite |
| A remote desktop can travel inside the SSH connection (`direct-tcpip`, the way `ssh -L` works) | C9 | Verified route; VNC decoding verified against one server implementation |
| Files travel on that same connection — no second sign-in, no second password | C4 | SFTP v3 over the existing transport |

**Why a person cares:** on cellular, four handshakes is four chances to fail. On a hardware
key it is four touches. Here it is one.

### 1.2 · Pillar two — A key that cannot leave the phone

**The message:** a key generated in the Secure Enclave has no private half outside the chip.
There is no key file, so there is nothing to export, back up, sync or steal — and it logs in
to an ordinary OpenSSH server.

**支柱二 —— 一把无法离开这台设备的密钥。** 在 Secure Enclave 里生成的密钥，私钥从未在芯片
之外存在过。没有密钥文件，也就没有东西可以导出、备份、同步或被偷走——而它登录的是一台
未经改动的标准 OpenSSH 服务器。

| Proof | Claim | What stands behind it |
| --- | --- | --- |
| Only the public half is placed in a real `sshd`'s `authorized_keys` | C2 | `SecureEnclaveKeyTests`; the assertion is `sshd`'s own line `Accepted publickey … ECDSA <fingerprint>` |
| The same key is refused where it was not authorised | C2 | The control case in the same test |
| The device can act as the SSH agent, including for an enclave key | C14 | Agent forwarding, Verified; a `git push` on the server is signed by a key that never left the phone |
| A changed host key is a hard stop, not a prompt to tap through | C17 | Proven against two real OpenSSH servers |
| A backup names unexportable keys instead of silently dropping them | C19 | The encrypted export refuses to pretend |
| Nothing on the device is offered to a server that did not ask for it, and a server cannot push a channel back | C21, and inbound-channel refusal | `InboundChannelRefusalTests` |

**Why a person cares:** every other "your keys are safe" sentence in this category means "the
key file is encrypted". This one means there is no key file.

### 1.3 · Pillar three — A terminal you can actually work in

**The message:** the terminal is the product, not a text view — and the same is true of the
file browser, the tmux client and the remote desktop.

**支柱三 —— 一个真的能干活的终端。** 终端本身就是产品，不是一个显示文字的视图；文件浏览、
tmux 客户端和远程桌面同理。

| Proof | Claim | What stands behind it |
| --- | --- | --- |
| True colour, sixel pictures, mouse reporting, alternate screen, OSC 7 / 52 / 133, DECRQM | C3 | `TerminalEmulatorTests`, `SixelTests`, `MouseReportingTests` |
| vim, less and htop draw correctly over a real PTY and put the shell back as it was | C3 | `TUIIntegrationTests` |
| CJK, emoji and combining marks occupy the right number of cells | C3 | `CharacterWidthTests`, against UCD 17.0.0 |
| Hostile or corrupt output does not wedge the terminal | C3 | A fuzz suite shown to catch a deliberately broken invariant, rather than merely passing |
| tmux spoken as a protocol, not scraped as text — detach, reattach, panes still there | C8 | tmux control mode (`-C`), measured against tmux 3.3a |
| Your server's files in the Files app, and several remote folders at once in the app | C4 | `FileProviderDomainTests`, the SFTP suite, the interrupted-upload test |
| Split panes on iPad, each with its own toolbar; a second window | C10 | Divider has a minimum size and a VoiceOver-adjustable action |
| Local, remote and dynamic (SOCKS5) forwarding, saved on a connection and started with it | C6, C7 | Live byte and connection counters per rule |

**Why a person cares:** this is the difference between checking a log and doing the work.

### 1.4 · The foundation — nothing to sign up for, nothing measured

Not a pillar, because it is not what the product *is*; it is the ground the other three stand
on, and it is stated in almost every piece of copy.

**No account. No back end operated by this project. No analytics, no telemetry, no crash
reporter. No StoreKit, no in-app purchase, no subscription.** (C5.) Each is proven as an
absence by grep, which is the only way an absence can be proven — and which anyone can repeat
in seconds.

**没有账号，没有本项目运营的后台服务，没有分析、遥测或崩溃上报，没有内购与订阅。**（C5）
这些都是以"不存在"的方式被证明的——用 grep 逐一搜遍源码，任何人几秒钟就能自己复核一遍。

---

## 2 · The message house

**Roof — the position**

| | |
| --- | --- |
| **EN** | Apex Terminal is a full SSH workstation for iPhone and iPad: one connection carries your shell, your files, your remote desktop and your tunnels — and your keys never leave the device. |
| **ZH** | Apex Terminal 是 iPhone 与 iPad 上的完整 SSH 工作台：一条连接同时承载终端、文件、远程桌面与隧道，而密钥始终不离开这台设备。 |

**Pillars**

| | **1 · One connection, not four** | **2 · A key that cannot leave** | **3 · A terminal you can work in** |
| --- | --- | --- | --- |
| **In one line (EN)** | Four things on one server cost one handshake, one authentication, one biometric prompt. | Generated in the Secure Enclave; the private half never exists outside the chip. | True colour, sixel, mouse reporting, tmux as a protocol, files in the Files app. |
| **In one line (ZH)** | 同一台服务器上的四件事，只需一次握手、一次认证、一次生物识别提示。 | 在 Secure Enclave 内生成，私钥从不在芯片之外存在。 | 真彩色、sixel、鼠标上报、把 tmux 当协议来说，文件直接进"文件"App。 |
| **Claims** | C1, C4, C9, C11 | C2, C12, C13, C14, C17, C19 | C3, C6, C7, C8, C10, C18, C20, C21, C22 |
| **Named limit it travels with** | The device is not kept connected in the background; iOS does not guarantee it. | Face ID or Touch ID can gate a key — describe it as an option, never as measured. | Terminal sessions reconnect on their own; tmux sessions do not reattach on their own. |
| **Photographable in** | SS-1 | SS-7 | SS-1, SS-3, SS-4 |

**Foundation**

| | |
| --- | --- |
| **EN** | No account, no back end, nothing measured. One app for iPhone and iPad, iOS and iPadOS 17 and later. Commands run on your own servers. |
| **ZH** | 没有账号，没有后台服务，不采集任何使用数据。一个应用同时适用于 iPhone 和 iPad，支持 iOS 与 iPadOS 17 及以上。命令运行在你自己的服务器上。 |
| **Claims** | C5, C24, and wording rule 1 |

---

## 3 · Approved boilerplate

Final text. Copy it; do not rewrite it. Where a store or a press outlet imposes a shorter
limit than any of these, use the next shorter one rather than trimming a longer one — a
trimmed sentence is a new claim.

The English and the Chinese are two originals. Neither is a translation of the other, and a
change to one does not license a change to the other.

### 3.1 · One line — under 15 words

**EN** (14 words)

> A full SSH workstation for iPhone and iPad — your keys never leave the device.

**ZH**

> iPhone 与 iPad 上的完整 SSH 工作台，密钥不出这台设备。

*Used in:* the App Store subtitle line, press-kit header, social bio, the website's title tag.

### 3.2 · Thirty words

**EN** (30 words)

> Apex Terminal is an SSH client for iPhone and iPad. One connection carries your shell, your
> files, your remote desktop and your tunnels. No account, no back end, nothing measured.

**ZH**

> Apex Terminal 是 iPhone 和 iPad 上的 SSH 客户端。一条连接同时承载终端、文件、远程桌面与
> 端口转发。没有账号，没有后台服务，不采集任何使用数据。

*Used in:* the App Store promotional text, directory listings, the press kit's one-paragraph
description, the opening of a pitch email.

### 3.3 · Fifty words

**EN** (50 words)

> Apex Terminal is an SSH client for iPhone and iPad. One connection carries your shell, your
> files, your desktop and your tunnels — one handshake, one authentication, one biometric
> prompt. Keys can be generated inside the Secure Enclave, where the private half cannot
> leave. No account, no back end, nothing measured.

**ZH**

> Apex Terminal 是 iPhone 和 iPad 上的 SSH 客户端，命令运行在你自己的服务器上。一条连接
> 同时承载终端、文件、远程桌面与端口转发：一次握手、一次认证、一次生物识别提示。密钥
> 可以在 Secure Enclave 内生成，私钥无法离开这台设备。没有账号，没有后台服务，不采集
> 任何使用数据。

*Used in:* the website hero paragraph, the press release's standfirst, the first screen of the
long App Store description.

### 3.4 · One hundred words

**EN** (100 words)

> Apex Terminal is an SSH client for iPhone and iPad, running on iOS and iPadOS 17 and later.
> Commands run on your own servers. One connection carries your shell, your files, your
> desktop and your tunnels: one handshake, one authentication, one biometric prompt. The
> terminal handles true colour, sixel pictures, mouse reporting and full-screen programs that
> put your shell back as it was. A key can be generated inside the Secure Enclave, where the
> private half cannot leave the device, and it logs in to an ordinary, unmodified OpenSSH
> server. There is no account, no back end and nothing measured.

**ZH**

> Apex Terminal 是 iPhone 和 iPad 上的 SSH 客户端，支持 iOS 与 iPadOS 17 及以上；命令运行
> 在你自己的服务器上。一条连接同时承载终端、文件、远程桌面与端口转发——四条通道共用
> 一次握手、一次认证、一次生物识别提示。终端本身做得很实：真彩色、sixel 图像、鼠标上报、
> 正确的中日韩字宽，vim、less、htop 退出之后 shell 原样还在。密钥可以在 Secure Enclave 内
> 生成，私钥无法离开这台设备，而它登录的是一台未经改动的标准 OpenSSH 服务器。没有账号，
> 没有后台服务，不采集任何使用数据。

*Used in:* the "About Apex Terminal" block at the foot of every press release, the media kit,
the long-form directory entry, the App Review notes' opening paragraph.

---

## 4 · Elevator pitch — spoken, about 45 seconds

Written to be said out loud, at an ordinary pace, without slides. The pauses are where the
paragraph breaks are.

### 4.1 · English

> Apex Terminal is an SSH client for iPhone and iPad.
>
> The idea is small. When you reach a server you usually want more than a shell — you want the
> files, sometimes the machine's desktop, sometimes a port forwarded back to you. In most
> tools each of those is its own login. Here they are channels on one connection, so four
> things cost one handshake, one authentication and one biometric prompt.
>
> The second half is the key. You can generate an SSH key inside the Secure Enclave. The
> private half is made in the chip and never exists outside it, so there is no key file for
> anyone to copy — and it still logs in to an ordinary OpenSSH server, unmodified.
>
> There is no account to make and nothing behind it. Commands run on your servers, not ours.
> iOS and iPadOS 17 and later.

### 4.2 · 中文

> Apex Terminal 是 iPhone 和 iPad 上的 SSH 客户端。
>
> 想法很简单。人连上一台服务器，往往不只是想要一个 shell——还想看文件，有时想看那台机器
> 的桌面，有时要把一个端口转发回来。多数工具里，这几件事各自是一次登录。在这里，它们是
> 同一条连接上的几条通道，所以四件事只需要一次握手、一次认证、一次生物识别提示。
>
> 另一半是密钥。你可以在 Secure Enclave 里生成一把 SSH 密钥。私钥是在芯片内部产生的，从未
> 在芯片之外存在过，也就没有密钥文件可供任何人复制——而它登录的，是一台未经任何改动的
> 标准 OpenSSH 服务器。
>
> 不需要注册账号，背后也没有服务器。命令运行在你自己的机器上，不在我们这里。支持 iOS 与
> iPadOS 17 及以上。

---

## 5 · Feature → benefit

The left column is the technical name, drawn from the Verified set in the truth matrix. The
right column is the sentence a customer reads. Never print the left column on its own to a
customer; never print the right column to an engineer who asked what it actually is.

### 5.1 · English

| Verified capability | What the customer reads |
| --- | --- |
| SSH connection multiplexing — one transport, many channels | Open a shell, the files, a desktop and a port forward on the same server, and you pay for one handshake, one authentication and one biometric prompt. |
| Secure Enclave SSH keys (unlocked-device policy) | Create a key whose private half is made inside the chip and cannot be copied off the device — and log in to an ordinary OpenSSH server with it. |
| SSH agent forwarding, device as the agent | A `git push` on the server is signed by a key that never leaves your phone. |
| ProxyJump / bastion (jump host) chains | Reach a server that is only reachable through a bastion, with the far server's host key checked as its own rather than the bastion's. |
| OpenSSH user and host certificates, trusted certificate authorities | If your organisation signs its host keys, trust the authority once and there is no fingerprint left to eyeball. |
| Host key verification and known-hosts memory | The first time you reach a server you are shown its fingerprint to check; from then on a server whose key has changed is refused outright. |
| Keyboard-interactive authentication (RFC 4256), multi-round | Servers with PAM, an expired password or a one-time code prompt log in, and the server's own wording is shown to you unchanged. |
| Post-quantum hybrid key exchange (`mlkem768x25519-sha256`) | On servers that support it, a recorded session is protected against a quantum computer built later; where they do not, the connection falls back on its own. |
| VT/ANSI escape-sequence emulation (xterm-class), alternate screen buffer | vim, less and htop draw correctly, and quitting them puts your shell back exactly as it was. |
| 24-bit true colour (both SGR spellings) | `ls --color`, syntax highlighting and a powerline prompt show the colours the program actually asked for. |
| Sixel graphics | A plot from gnuplot, or an image through `img2sixel`, is a real picture on the phone's screen. |
| Mouse reporting (1000/1002/1003, legacy and SGR 1006) | Taps, drags and two-finger scrolling reach htop, tmux and less as real mouse events. |
| CJK, emoji and combining-mark cell widths (UCD 17.0.0) | Chinese, Japanese and Korean text, emoji and accented Latin line up in the grid instead of shifting every column after them. |
| OSC 52 — clipboard writes behind a permission | A yank in remote vim can reach your clipboard once you allow it — and a program on the server can never read what you have copied. |
| OSC 7 — the shell's working directory | Panes are labelled by the directory they are actually in, and a new pane can start where the last one was. |
| OSC 133 — shell integration marks | The app knows where a command began and what it exited with, so a failure can be surfaced instead of scrolled past. |
| Search across the whole scrollback | Find the error that went by three screens ago, including when the word is split across a wrapped line. |
| Custom monospaced fonts, size and line height | Use any monospaced face already on your device, and the server is told the new grid size so full-screen programs draw to it. |
| SFTP over the SSH connection (protocol version 3) | Your server's files are listed, read, written and renamed over the same connection as the terminal — no second sign-in, no second password. |
| File Provider extension — "Show in the Files app" | Put a server in the Files app and open its documents from any app that can open a file. |
| Several remote folders open at once | Two file browsers at the same time — the same server twice, or two different servers — and on an iPad, side by side. |
| Local port forwarding (`ssh -L`) | Point a port on your iPad at a database or an internal API the server can reach, and use it as if it were running on the device. |
| Remote port forwarding (`ssh -R`) | Ask the server to listen on a port and hand whatever connects there back to something running on your device. |
| Dynamic forwarding — a SOCKS5 proxy on the device (`ssh -D`) | Run a SOCKS5 proxy on the device and send an app's traffic out through the server; apps you can point at a proxy can use it. |
| Byte and connection counters per rule | Each forward shows bytes out, bytes in, how many connections are open now and how many it has carried. |
| tmux control mode client (the `-C` protocol) | The app speaks tmux's own protocol, so the panes on screen are tmux's own arrangement rather than scraped text. |
| Remote desktop over VNC/RFB, routed through the SSH connection | See and drive a machine's desktop in the same app as your terminals, with the picture travelling inside SSH's encryption. |
| Split panes, each with its own toolbar; a second window on iPad | Watch a log in one half of the iPad while you work in the other, or put a session in its own window beside another app. |
| Reconnection after network loss (ordinary terminal sessions) | When the network goes, a terminal session comes back on its own with the scrollback intact, and the new shell is marked as fresh. |
| App lock: a passcode of the app's own, with backoff and a grace period | Put a second lock in front of the app itself, separate from the device passcode, with a delay after repeated wrong guesses. |
| Encrypted backup sealed with a password; restore previews before it writes | Carry your setup to a new device in one sealed file, and see exactly what a restore would add and what it would collide with before anything is written. |
| A link carrying a command asks first and shows the command verbatim | An `ssh://` link can never make the app run something without showing you the exact command and waiting for you to agree. |

### 5.2 · 中文

| 已验证能力 | 用户读到的句子 |
| --- | --- |
| SSH 连接复用——一条传输，多条通道 | 在同一台服务器上打开终端、文件、桌面和端口转发，只花一次握手、一次认证、一次生物识别提示。 |
| Secure Enclave 内生成的 SSH 密钥（设备解锁策略） | 生成一把私钥只存在于芯片内部、无法被拷走的密钥——而它照样登录标准 OpenSSH 服务器。 |
| SSH agent 转发，设备本身充当 agent | 服务器上执行的 `git push`，由一把从未离开过手机的密钥来签名。 |
| ProxyJump / 跳板机链路 | 连上那些只能经由跳板机抵达的服务器，并且是按目标服务器自己的主机密钥来校验，而不是跳板机的。 |
| OpenSSH 用户证书、主机证书与受信任的 CA | 如果你的组织会给主机密钥签名，只需信任这个 CA 一次，之后再没有指纹需要人眼比对。 |
| 主机密钥校验与 known_hosts 记忆 | 第一次连上一台服务器时，会把指纹交给你核对；此后主机密钥一旦变了，就是直接拒绝连接。 |
| 键盘交互式认证（RFC 4256，多轮） | 使用 PAM、密码已过期、或需要一次性验证码的服务器都能登录，服务器自己的提问原样呈现给你。 |
| 后量子混合密钥交换（`mlkem768x25519-sha256`） | 在支持的服务器上，即使会话被录下来，也能抵御日后造出的量子计算机；不支持的服务器会自动回退。 |
| VT/ANSI 转义序列仿真（xterm 级）、备用屏缓冲 | vim、less、htop 显示正常，退出之后 shell 原样还在。 |
| 24 位真彩色（两种 SGR 写法） | `ls --color`、语法高亮和 powerline 提示符，显示的是程序真正要的那些颜色。 |
| Sixel 图形 | gnuplot 画的图、`img2sixel` 送来的图像，在手机屏幕上就是一张真的图。 |
| 鼠标上报（1000/1002/1003，传统与 SGR 1006） | 点按、拖动和双指滚动，会作为真正的鼠标事件抵达 htop、tmux 和 less。 |
| 中日韩、emoji 与组合符号的字宽（UCD 17.0.0） | 中日韩文字、emoji 和带音标的拉丁字母在网格里对得齐，不会把后面每一列都推歪。 |
| OSC 52——需先授权的剪贴板写入 | 远程 vim 里的一次 yank，在你允许之后可以送到设备剪贴板；而服务器上的程序永远读不到你复制过什么。 |
| OSC 7——shell 的当前目录 | 每个面板按它实际所在的目录来标注，新开的面板可以从上一个停下的地方开始。 |
| OSC 133——shell 集成标记 | 应用知道一条命令从哪里开始、以什么状态结束，失败的命令可以被指出来，而不是被滚过去。 |
| 全量回滚历史搜索 | 三屏之前滚过去的那条报错，找得回来——即使那个词被折行切成了两半。 |
| 自定义等宽字体、字号与行高 | 用设备上任何一款等宽字体，改完之后新的网格尺寸会告知服务器，全屏程序照着重新绘制。 |
| SFTP 走同一条 SSH 连接（协议第 3 版） | 服务器上的文件，和终端走同一条连接来列出、读取、写入和改名——不需要第二次登录，也不用再输一次密码。 |
| File Provider 扩展——"在'文件'App 中显示" | 把一台服务器放进"文件"App，任何能打开文件的应用都能打开它上面的文档。 |
| 同时打开多个远程目录 | 两个文件浏览同时开着——同一台服务器开两次，或者两台不同的服务器——在 iPad 上还能并排放。 |
| 本地端口转发（`ssh -L`） | 把 iPad 上的一个端口指向服务器能访问到的数据库或内部 API，然后当作本机服务来用。 |
| 远程端口转发（`ssh -R`） | 让服务器监听一个端口，把连到那里的流量交回给设备上正在跑的东西。 |
| 动态转发——设备上的 SOCKS5 代理（`ssh -D`） | 在设备上跑一个 SOCKS5 代理，让流量从服务器出去；能手动指定代理的应用都可以用。 |
| 每条规则的字节与连接计数 | 每条转发规则都显示出站字节、入站字节、当前连接数和累计连接数。 |
| tmux 控制模式客户端（`-C` 协议） | 应用说的是 tmux 自己的协议，屏幕上的面板就是 tmux 自己的布局，而不是从文字里刮出来的。 |
| VNC/RFB 远程桌面，经由 SSH 连接抵达 | 在放终端的同一个应用里看到并操作远端桌面，画面本身走在 SSH 的加密里。 |
| 分屏面板，各自带工具栏；iPad 上的第二个窗口 | iPad 一半看日志、一半干活；也可以把一个会话单独放进一个窗口，和别的应用并排。 |
| 网络中断后的重连（普通终端会话） | 网断了，终端会话会自己回来，回滚历史还在，新的 shell 会被标记出来告诉你它是新的。 |
| 应用锁：独立于设备密码的口令，带失败延迟与宽限期 | 在应用前面再加一道锁，和设备密码分开，连续输错会有延迟。 |
| 密码封装的加密备份；恢复前先预览 | 用一个封好的文件把整套设置带到新设备；恢复之前先看清楚会新增什么、会和什么冲突，然后再写入。 |
| 带命令的链接先询问，并原样显示命令 | 一条 `ssh://` 链接永远无法让应用替你执行什么——命令原文会先摆在你面前，等你同意。 |

---

## 6 · Vocabulary

### 6.1 · The product name

* **Apex Terminal**, two words, everywhere a person reads it. Capital A, capital T.
* **`ApexTerminal`**, one word, only as an identifier: the Xcode scheme, the project file, the
  package directory, the `User-Agent`. It never appears in prose.
* Bundle identifier `dev.apexterminal.app`. It belongs in App Review notes and developer
  documentation, not in marketing copy.
* Never **SuperTerminal** — the retired name, absent from shipped code and resources.
* Never **Hiko** — the GitHub organisation, not a brand.
* Never **Apex** alone. Not on second mention, not in a headline, not in a chart label.
* In Chinese, the name stays in Latin script: **Apex Terminal**. There is no Chinese name and
  none may be invented. Set it with a space on either side inside Chinese text.
* No trademark symbol. Do not typeset the name in all capitals or all lower case.

### 6.2 · Words we use

**English.** connection · session · channel · transport · handshake · authentication ·
biometric prompt · key · public half / private half · Secure Enclave · fingerprint ·
known hosts · certificate authority · server · host · shell · pane · split · scrollback ·
file browser · remote desktop · port forward · tunnel · SSH client.

**中文。** 连接 · 会话 · 通道 · 传输 · 握手 · 认证 · 生物识别提示 · 密钥 · 公钥 / 私钥 ·
Secure Enclave（不翻译）· 指纹 · 已知主机 · 证书颁发机构 · 服务器 · 主机 · 终端 · 面板 ·
分屏 · 回滚历史 · 文件浏览 · 远程桌面 · 端口转发 · 隧道 · SSH 客户端.

Preferred constructions, in both languages:

* *"one handshake, one authentication, one biometric prompt"* — an arithmetic sentence beats
  an adjective.
* *"an ordinary OpenSSH server"* / *"未经改动的标准 OpenSSH 服务器"* — says the interoperability
  claim without a superlative.
* *"nothing measured"* / *"不采集任何使用数据"* — plainer and stronger than "privacy-focused".
* *"commands run on your own servers"* / *"命令运行在你自己的服务器上"* — the client sentence,
  required by wording rule 1.

### 6.3 · Words we never use

**Superlatives and inflation.** fastest · most secure · only · first · #1 · best · leading ·
seamless · effortless · powerful · revolutionary · blazing · lightning · magic · just works ·
military-grade · bank-grade · enterprise-grade · unhackable · unbreakable · next-generation.

**中文对应。** 最快 · 最安全 · 唯一 · 第一 · 最佳 · 领先 · 无缝 · 毫不费力 · 强大 · 革命性 ·
极速 · 军工级 · 银行级 · 无法破解 · 下一代 · 完美.

**Claims we do not have.** Any user count, download count, rating, award or ranking. Any named
competitor. Any "trusted by" line. Any figure not measured in `docs/RELEASE_EVIDENCE.md` on
the date it names.

**Sentences that are specifically wrong, with the reason:**

| Never write | Why |
| --- | --- |
| "Two-factor authentication built in" / "内置双因素认证" | The app relays the **server's** prompt. It stores no secret and generates no codes. Write "servers with 2FA work". |
| "Sync across your devices" / "多设备同步" | iCloud sync is hard-disabled in this build; the switch is shown disabled and says so. |
| "Stays connected in the background" / "后台保持连接" | iOS does not guarantee it, and neither will we. |
| "Type Chinese in the terminal" / "终端里可以打中文" | Cell **widths** for CJK are Verified; the input method itself has never been exercised on hardware. Say the widths, not the typing. |
| "Runs on Mac" / "Runs on Vision Pro" | No Catalyst signing identity; visionOS has never been run. |
| "Blocks screenshots" / "防截屏" | There is no screen-capture detection anywhere. What exists is a cover in the App Switcher — write "hides your terminal in the App Switcher". |
| "Face ID-protected keys, proven" | Biometrics can gate a key, and that is fair to say as an option. No biometric surface in this project has ever run against real hardware. |
| "Your terminal never leaves your device" | Unqualified, it is not survivable: the optional assistant, if a person configures a provider and a key of their own, sends text to that endpoint. Write "Apex Terminal has no server of its own. Your data goes only where you send it." |
| "Full tmux scrollback" / "搜索 tmux 历史" | Scrolling is local over roughly 2 000 captured lines, not tmux copy mode. |
| "Works with any VNC server" / "兼容所有 VNC 服务器" | Verified against one server implementation; Tight/JPEG, TRLE and zlib are not implemented. |
| The word **"Verified"** in customer copy | It is this project's internal gate, not a marketing word. |

**Cloudflare — internal note, not a claim.** Cloudflare appears in no public-facing text: not
in the name, the subtitle, the description, the keywords, a screenshot, a caption, a social
post or the press kit. This is a decision, not an oversight, and the reasoning is in
[`POSITIONING.md`](POSITIONING.md) §6: no connection has ever been made through a live
Cloudflare account, and roughly 950 lines of the authentication half carry no test at all. A
claim we cannot reproduce is a claim we must not make. Writers do not need to work around
this; they simply do not have it. When `docs/HUMAN_ACTIONS.md` H-4 clears, the claim is
already written and waiting, marked blocked. If Cloudflare is ever mentioned at all — in App
Review notes, say — the permitted forms are "works with Cloudflare Access" and "supports
Cloudflare Tunnel"; "official", "approved", any implication of partnership, and any logo or
wordmark are forbidden.

---

## 7 · Proof points

A handful of facts that a sceptical reader can check, or that a journalist can quote. They are
short on purpose: a proof point that needs a paragraph is not a proof point.

| # | The fact | Why it carries weight | Behind it |
| --- | --- | --- | --- |
| **P1** | Four things on one server: **one** TCP connection, **one** key exchange, **one** authentication, **one** biometric prompt. | It is arithmetic, not an adjective, and the count is taken from the server's own log rather than the app's self-report. | `ConnectionPoolTests.swift:29-53`, against a real `sshd` |
| **P2** | Only the **public** half of a Secure Enclave key is placed in `authorized_keys`. The test asserts `sshd`'s own line: `Accepted publickey … ECDSA <fingerprint>`. | Proves both halves of the claim at once — the private half stays in the chip, and an unmodified OpenSSH server accepts it. | `SecureEnclaveKeyTests` |
| **P3** | A control case proves the same key is **refused** where it was not authorised. | A test that only ever succeeds proves less than one that also fails on purpose. | `SecureEnclaveKeyTests` |
| **P4** | The absences are grep-proven: zero StoreKit, in-app-purchase or subscription symbols in the tree; no analytics, telemetry or crash-reporter SDK; no server operated by this project; no sign-up flow. | An absence cannot have a test. It can have a search anyone can repeat in seconds — which is a stronger invitation than a promise. | Exhaustive grep over `App/`, `Packages/…/Sources`, `FileProvider/`, `Config/` |
| **P5** | The whole dependency list: swift-nio, swift-nio-ssl, swift-crypto, swift-sodium, and a vendored swift-nio-ssh fork. Nothing else. | The list is the argument. There is nowhere for a tracker to hide. | `Package.swift`, plus `PrivacyInfo.xcprivacy` with empty `NSPrivacyCollectedDataTypes` and tracking false |
| **P6** | The character-width table is generated from **UCD 17.0.0**, not hand-maintained. | Explains why vim's status line does not tear on CJK text, and names the source of truth. | `CharacterWidthTests` |
| **P7** | The terminal fuzz suite was shown to **catch** a deliberately broken invariant. | Anyone can say "we fuzz it". The interesting claim is that the fuzzer was proven able to fail. | The fuzz suite in `STTerminalTests` |
| **P8** | A changed host key is a hard stop, proven against two real OpenSSH servers. | It is the case most mobile clients get wrong, and it is the case that matters. | `HostKeyVerifier` tests |
| **P9** | An OSC 52 **read** request is refused and not even reported back to the remote program. | The generous reading of "clipboard support" is that a server can also read. Here it cannot, and the refusal is silent to the server. | Proven against a real `sshd` with the real pasteboard |
| **P10** | An upload from the Files app interrupted mid-transfer lands **whole**, once, and leaves no temporary file on the server. | The failure everyone has had, tested for. | The interrupted-upload test in the SFTP suite |
| **P11** | tmux is measured against tmux **3.3a** in a Debian container — the version is named because it is the version that was run. | Naming the version is the difference between evidence and a shrug. | `TmuxIntegrationTests` |

Quoting rule: a proof point may be shortened, but the named artefact — the log line, the
standard, the version number — is the part that makes it a proof and may not be dropped.

---

## 8 · How to talk about limits

**The pattern.** Name the limit in the same sentence as the feature, in the same voice, with
no softening word between them. Not a footnote, not an asterisk, not a separate "known issues"
paragraph a reader has to go and find. A limit that arrives late reads as something that was
being hidden; a limit that arrives inside the sentence reads as competence.

Three rules that follow from it:

1. **One sentence, one clause each.** The feature earns the first half, the limit earns the
   second, joined by an em dash or a semicolon. If the limit needs its own sentence, the
   feature has been over-claimed.
2. **The limit is stated as a fact, not as an apology.** No "unfortunately", no "currently",
   no "for now", no "in this first version" — those are promises about a future we have not
   tested either.
3. **The limit is specific enough to act on.** "Some servers may not work" is not a limit; it
   is a hedge. "A server that offers only Tight or TRLE encoding will not draw" tells a person
   whether it affects them.

### 8.1 · Worked example — reconnection

Reconnection is Verified for ordinary terminal sessions and is **not** true for tmux sessions;
the truth matrix says to keep those two claims apart.

> **Do not write:** "Sessions come back automatically after a drop."
>
> **Write (EN):** Terminal sessions come back on their own after the network drops, with the
> scrollback intact and the new shell marked as fresh — a tmux session keeps running on the
> server, but reattaching to it is something you do, not something that happens.
>
> **写作（中文）：** 网络中断后，终端会话会自己回来，回滚历史还在，新的 shell 会标出来告诉你
> 它是新的——tmux 会话在服务器上继续跑着，但重新接上去这一步是你自己做的，不会自动发生。

*What the pattern bought:* the honest half is also the reassuring half. "Keeps running on the
server" is the thing the reader actually wanted to know.

### 8.2 · Worked example — remote desktop over VNC

Every Verified VNC row rests on one server implementation and one test pattern. Tight/JPEG,
TRLE and zlib are not implemented at all.

> **Do not write:** "Connect to any VNC server."
>
> **Write (EN):** Remote desktop over VNC, in the same app and reachable through your SSH
> connection — it decodes ZRLE, Hextile, RRE and Raw, so a server configured to offer only
> Tight or TRLE will not draw.
>
> **写作（中文）：** 在同一个应用里通过 SSH 连接打开 VNC 远程桌面——支持 ZRLE、Hextile、RRE
> 和 Raw 这几种编码，所以只提供 Tight 或 TRLE 的服务器不会出画面。

*What the pattern bought:* the named encodings are more useful than the word "any", and a
reader who runs one of the common servers can tell in five seconds that they are covered.

### 8.3 · Worked example — servers that ask for a one-time code

The app relays the server's prompt. It stores no TOTP secret and generates no codes. "2FA
built in" is one of the sentences that must never be written.

> **Do not write:** "Two-factor authentication built in."
>
> **Write (EN):** Servers that ask for a one-time code log in from the phone — the app shows
> the server's own prompt, in the server's own words, and passes your answer along; it stores
> no secret and generates no codes of its own.
>
> **写作（中文）：** 需要一次性验证码的服务器，在手机上也能登录——应用把服务器自己的提问
> 原样显示出来，再把你的回答递过去；它不保存任何密钥，也不生成任何验证码。

*What the pattern bought:* the sentence is longer than the false one and does more work. It
tells the reader their PAM stack will behave, and it tells them where the secret is not.

---

## 9 · Using this kit

* Boilerplate (§3) and the pitch (§4) are copied **verbatim**. A new length is a new decision
  and belongs in this file, not in the document that needed it.
* The feature→benefit table (§5) is the source for screenshot captions, App Store feature
  bullets and website section headings. Take the right-hand sentence whole, or shorten it —
  never rewrite it into a claim it did not make.
* A sentence not traceable to `C1`–`C24` or to a Verified row does not ship. If a document
  needs one, the claims matrix is amended first and this file second.
* When a `docs/HUMAN_ACTIONS.md` item clears, the claim it unblocks is added here before it is
  added anywhere a customer can see it.
