# Press release — Apex Terminal 0.1.0

**Prepared:** 2026-09-10 · **Drawn from:** [`../strategy/MESSAGING_SYSTEM.md`](../strategy/MESSAGING_SYSTEM.md)
· **Gated by:** [`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md) and
[`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md)

Two releases follow, each complete and each meant to be sent on its own: one in English, one
in Simplified Chinese. They are two originals. The Chinese release is written in Chinese and
is not a rendering of the English one; a sentence changed in one does not license the same
change in the other.

The blocks marked **`OWNER SUPPLIES`** are the three facts this project does not hold: the
place and date of the dateline, the press contact, and the address of the product page. They
are the sender's to fill in, and the release is not ready to leave the building until they
are filled. Nothing else in either release is to be edited: the "About Apex Terminal" block
and the opening paragraph are approved boilerplate, copied word for word from the messaging
system, and a trimmed sentence there is a new claim.

**Do not send either release before the app is live on the App Store.** As of the date this
was prepared it is not submitted, and the outstanding items are listed in
[`../app-store/metadata/APP_STORE_METADATA_EN.md`](../app-store/metadata/APP_STORE_METADATA_EN.md).

**A Traditional Chinese release is not below, and must not be made by converting the
Simplified one.** The app ships in Traditional Chinese and the screenshot set exists in it;
what is missing is approved zh-Hant boilerplate in the messaging system. Written as its own
original, from its own vocabulary, it belongs in that file before it belongs in this one.

---
---

# FOR IMMEDIATE RELEASE

## Apex Terminal puts the shell, the files, the desktop and the tunnels on one SSH connection

### An SSH client for iPhone and iPad. Keys can be generated inside the Secure Enclave, where the private half cannot leave the device. Free, with no account and nothing to buy.

**`OWNER SUPPLIES` — place, and date of release** — Apex Terminal is an SSH client for
iPhone and iPad. One connection carries your shell, your files, your desktop and your
tunnels — one handshake, one authentication, one biometric prompt. Keys can be generated
inside the Secure Enclave, where the private half cannot leave. No account, no back end,
nothing measured.

Version 0.1.0 is available today for iPhone and iPad running iOS or iPadOS 17.0 and later.
It is free. There is no in-app purchase, no subscription and no account to create.

### One connection, not four

Open a shell, a file browser, a remote desktop and a port forward on the same server, and it
costs one TCP connection, one key exchange, one authentication and one biometric prompt.
They are SSH channels on a single pooled transport, not four separate logins.

The arithmetic is the point. On a cellular link, four handshakes are four chances to fail.
On a hardware token they are four touches. Here they are one. The project's own test counts
the handshakes in a real OpenSSH server's log rather than in the client's self-report, and
its adversarial half proves the pool never hands back a connection belonging to another
account and never hands back a dead one.

### A key with no file behind it

An SSH key can be generated inside the Secure Enclave. The private half is created in
dedicated hardware and never exists outside it, so there is nothing to export, back up, move
or copy — and it logs in to an ordinary, unmodified OpenSSH server.

The test that stands behind that sentence puts the public half, and nothing else, into a
real `sshd`'s `authorized_keys`, then asserts on the server's own log line recording an
accepted public key and its fingerprint. A control case in the same suite proves the same
key is refused where it was not authorised — a test that can succeed and also fail on
purpose proves more than one that merely passes.

Keys already in hand can be imported, passphrase and all, and keys can be generated on the
device in OpenSSH format instead. Where an organisation signs its host keys, the certificate
authority can be trusted once and there is no fingerprint left to compare by eye. Agent
forwarding runs with the device acting as the agent, so a `git push` on the server is signed
by a key that never leaves the phone.

### A terminal, not an approximation

The terminal is the product rather than a view that displays text: 24-bit colour in both SGR
spellings, the alternate screen so that quitting vim or less puts the shell back exactly as
it was, sixel pictures from gnuplot or `img2sixel`, mouse reporting in three modes with
modifiers, wheel and drag, reflow on a width change, block selection, search across the
whole scrollback, and any monospaced font already on the device at a chosen size and line
height, with the server told the new grid size.

Cell widths for Chinese, Japanese and Korean text, for emoji and for combining marks come
from generated Unicode 17.0.0 tables rather than a hand-maintained list, which is why vim's
status line does not tear. The emulator's fuzz suite was shown to catch a deliberately
broken invariant, not merely to pass.

### Files and tunnels on the same connection

The server's files are listed, read, written and renamed over SFTP on the same SSH
connection as the terminal — no second sign-in and no second password. Several remote
folders can be open at once, the same server twice or two different servers, side by side on
an iPad, and a connection can be published to the Files app so its documents open from any
app that can open a file.

Local, remote and dynamic (SOCKS5) forwarding is saved with a connection and starts with it.
Each rule shows bytes out, bytes in, how many connections are open now and how many it has
carried. A forward that cannot start says why, and names the port.

### tmux as a protocol, and an iPad as a workstation

Apex Terminal speaks tmux's own control protocol, so the panes on screen are tmux's own
arrangement rather than text scraped from a screen. Detach, put the iPad down, attach again:
the windows, the panes and their output are where they were left. The protocol shapes were
measured against tmux 3.3a.

On an iPad a pane can be split and each half is a full session with its own toolbar; a
session can be moved into a second window beside another app. A hardware keyboard reaches
new connection, the command palette, next and previous session, session by number, close and
font size — and Command is never forwarded to the remote host.

### Nothing to sign up for, nothing measured

There is no account, no back end operated by this project, no analytics, no telemetry, no
crash reporter, no advertising identifier and no third-party SDK of that kind. There is no
StoreKit code in the binary, so there is no in-app purchase and no subscription. Command
history is off until it is turned on. Copied terminal text is set to expire from the
clipboard. A program on the server can write the clipboard once permission is given, and can
never read it. The app itself can be put behind a passcode of its own, separate from the
device passcode.

The whole dependency list is swift-nio, swift-nio-ssl, swift-crypto, swift-sodium and a
vendored swift-nio-ssh fork. Nothing else. An absence cannot have a test; it can have a
search that anyone can repeat in seconds, which is a stronger invitation than a promise.

### The limits, in the same voice as the features

Apex Terminal does not hold a connection open in the background — iOS does not guarantee it,
and neither will this project. It does not sync between devices; what is set up on one
device stays on that device. Terminal sessions come back on their own after the network
drops, with the scrollback intact and the new shell marked as fresh — a tmux session keeps
running on the server, but reattaching to it is something a person does, not something that
happens. The remote desktop decodes ZRLE, Hextile, RRE and Raw, so a server configured to
offer Tight or TRLE alone will not draw. Keys are generated as Ed25519 or ECDSA P-256, and
imported keys are read from the `openssh-key-v1` container. Hardware security keys are
refused, and the app says so on its own Keys screen. It ships for iPhone and iPad; there is
no Mac, Vision Pro or Apple Watch version.

### A note from the developer

"The idea is small enough to say in a sentence. When you reach a server you usually want
more than a shell — you want the files, sometimes the machine's desktop, sometimes a port
brought back to you. In most tools each of those is its own login. Here they are channels on
one connection, so four things cost one handshake, one authentication and one biometric
prompt," said the developer of Apex Terminal.

"The other half is the key. A key made inside the Secure Enclave has no private half outside
the chip, which means there is no key file for anyone to copy, and it still logs in to a
plain OpenSSH server that nobody had to modify. Everything else in the app follows from
those two decisions — including the ones I had to leave out. This release ships what has
been run against real servers, and says plainly what it does not do. That seemed a better
opening version than a longer feature list."

### Availability

| | |
| --- | --- |
| Product | Apex Terminal, version 0.1.0 |
| Platform | iPhone and iPad — a single app, not two |
| Requires | iOS or iPadOS 17.0 or later |
| Price | Free. No in-app purchase, no subscription, no trial |
| Account | None. There is nothing to register and nothing to sign in to |
| Languages | English, Simplified Chinese, Traditional Chinese |
| Category | Developer Tools, with Utilities as the secondary category |
| Age rating | 4+ |
| Product page | **`OWNER SUPPLIES`** — the address of the page, once it is live |

Apex Terminal is an SSH client. Commands run on servers the customer already owns, and the
app runs nothing itself.

### About Apex Terminal

Apex Terminal is an SSH client for iPhone and iPad, running on iOS and iPadOS 17 and later.
Commands run on your own servers. One connection carries your shell, your files, your
desktop and your tunnels: one handshake, one authentication, one biometric prompt. The
terminal handles true colour, sixel pictures, mouse reporting and full-screen programs that
put your shell back as it was. A key can be generated inside the Secure Enclave, where the
private half cannot leave the device, and it logs in to an ordinary, unmodified OpenSSH
server. There is no account, no back end and nothing measured.

### Press contact

**`OWNER SUPPLIES`** — a name and a route by which a journalist can reach it. This project
holds no press address of its own, and one must not be invented here. Whoever sends the
release fills this line before it goes out.

### Notes to editors

* The name is **Apex Terminal**, two words, capital A and capital T. It is never shortened
  to "Apex" and never set as one word in prose. In Chinese text the name stays in Latin
  script; there is no Chinese name.
* Screenshots, the fact sheet, and what the app deliberately does not do are in the press
  kit at [`PRESS_KIT.md`](PRESS_KIT.md). Rules for the name and the images are in
  [`MEDIA_KIT.md`](MEDIA_KIT.md).
* Screenshots are photographs of the running app against real servers. Nothing in them is
  staged, redrawn or composited.
* No user count, rating, award or ranking is quoted here because none exists.

---
---

# 立即发布

## Apex Terminal：终端、文件、远程桌面与端口转发，共用一条 SSH 连接

### iPhone 和 iPad 上的 SSH 客户端。密钥可以在 Secure Enclave 内生成，私钥无法离开这台设备。免费，没有账号，也没有任何可买的东西。

**`OWNER SUPPLIES` —— 发布地点与发布日期** —— Apex Terminal 是 iPhone 和 iPad 上的 SSH
客户端，命令运行在你自己的服务器上。一条连接同时承载终端、文件、远程桌面与端口转发：一次
握手、一次认证、一次生物识别提示。密钥可以在 Secure Enclave 内生成，私钥无法离开这台设备。
没有账号，没有后台服务，不采集任何使用数据。

0.1.0 版今日上架，适用于运行 iOS 或 iPadOS 17.0 及以上的 iPhone 与 iPad。免费，没有内购，
没有订阅，也不需要注册任何账号。

### 一条连接，而不是四条

在同一台服务器上打开终端、文件浏览、远程桌面和一条端口转发，代价是一次 TCP 连接、一次密钥
交换、一次认证、一次生物识别提示。它们是同一条 SSH 传输上的四条通道，不是四次登录。

重点在这笔账本身。在移动网络上，四次握手就是四次失败的机会；用硬件令牌，就是按四次。在这里
只按一次。项目自己的测试不去数客户端怎么说，而是去数真实 OpenSSH 服务器日志里出现了几次
握手；同一组测试里还有对抗性的一半：连接池不会把属于另一个账号的连接递出去，也不会递出一条
已经死掉的连接。

### 一把没有文件的密钥

SSH 密钥可以在 Secure Enclave 内生成。私钥是在专用硬件内部产生的，从未在芯片之外存在过，
所以没有东西可以导出、备份、搬走或复制——而它登录的，是一台未经任何改动的标准 OpenSSH
服务器。

支撑这句话的测试，只把公钥放进真实 `sshd` 的 `authorized_keys`，然后断言服务器自己那行日志：
公钥被接受，以及被接受的那把密钥的指纹。同一组测试里还有一个对照用例，证明同一把密钥在没有
被授权的地方会被拒绝——一个既能成功、也能按设计失败的测试，比一个只会通过的测试说明更多。

已有的密钥可以导入，带口令的也可以；也可以直接在设备上生成 OpenSSH 格式的密钥。如果你所在的
组织会给主机密钥签名，那么只需信任这个证书颁发机构一次，之后再没有指纹需要人眼比对。agent
转发由设备本身充当 agent，所以服务器上执行的 `git push`，是由一把从未离开过手机的密钥签的名。

### 终端本身就是产品

终端不是一个用来显示文字的视图：24 位真彩色（两种 SGR 写法都认）、备用屏缓冲，所以退出 vim
或 less 之后 shell 原样还在；gnuplot 或 `img2sixel` 送来的 sixel 图像就是一张真的图；鼠标上报
支持三种模式，带修饰键、滚轮和拖动；宽度变化时重新折行；支持块选择；整段回滚历史都能搜索；
设备上任何一款等宽字体都能用，字号和行高自己定，改完之后新的网格尺寸会告知服务器。

中日韩文字、emoji 和组合符号的单元格宽度，来自按 Unicode 17.0.0 生成的表，而不是一份手工维护
的清单——这就是 vim 状态栏不会被推歪的原因。终端的模糊测试套件被证明能抓出一个故意写坏的
不变量，而不只是能跑通。

### 文件和隧道，走同一条连接

服务器上的文件通过 SFTP 列出、读取、写入和改名，和终端走同一条 SSH 连接——不需要第二次登录，
也不用再输一次密码。可以同时打开多个远程目录：同一台服务器开两次，或者两台不同的服务器，在
iPad 上还能并排放；一条连接也可以挂进"文件"App，任何能打开文件的应用都能打开它上面的文档。

本地、远程和动态（SOCKS5）转发随连接一起保存，也随连接一起启动。每条规则都显示出站字节、
入站字节、当前连接数和累计连接数。启动不了的转发会说明原因，并且把端口号说出来。

### 把 tmux 当协议来说，把 iPad 当工作台来用

Apex Terminal 说的是 tmux 自己的控制协议，所以屏幕上的面板就是 tmux 自己的布局，而不是从
文字里刮出来的。断开、把 iPad 放下、再接回来——窗口、面板和它们的输出，都停在你离开时的样子。
协议的每一处形状，都是对着 tmux 3.3a 量出来的。

在 iPad 上可以把一个面板分开，两半各自是一个完整会话，各有各的工具栏；也可以把一个会话单独
放进第二个窗口，和别的应用并排。硬件键盘能直接触及新建连接、命令面板、上一个和下一个会话、
按序号切换会话、关闭会话和字号——而 Command 键永远不会被转发给远端主机。

### 没有什么需要注册，也没有什么被采集

没有账号，没有本项目运营的后台服务，没有分析、遥测或崩溃上报，没有广告标识符，也没有任何这
一类的第三方 SDK。二进制里没有 StoreKit 代码，所以没有内购，也没有订阅。命令历史默认关闭，
要用才开。从终端复制走的文本会被设定为过期。服务器上的程序在你允许之后才能写你的剪贴板，而
永远读不到它。应用本身还可以再加一道口令锁，和设备密码分开。

整份依赖清单是：swift-nio、swift-nio-ssl、swift-crypto、swift-sodium，以及一个内置的
swift-nio-ssh 分支。没有别的了。"不存在"这件事没法用测试来证明，但可以用任何人几秒钟就能自己
重跑一遍的搜索来证明——这比一句承诺更值得信。

### 把限制讲清楚，用同一种语气

Apex Terminal 不会在后台替你保持连接——iOS 并不保证这件事，本项目也不会替它保证。它不做多设备
同步；在哪台设备上配好的，就留在哪台设备上。网络中断后，终端会话会自己回来，回滚历史还在，
新的 shell 会被标出来告诉你它是新的——tmux 会话在服务器上继续跑着，但重新接上去这一步是你自己
做的，不会自动发生。远程桌面支持 ZRLE、Hextile、RRE 和 Raw 这几种编码，所以只提供 Tight 或
TRLE 的服务器不会出画面。生成的密钥是 Ed25519 或 ECDSA P-256；导入的密钥读的是
`openssh-key-v1` 容器。硬件安全密钥会被拒绝，应用在自己的"密钥"界面上就这么写着。它面向
iPhone 和 iPad 发布，没有 Mac 版、没有 Vision Pro 版，也没有 Apple Watch 版。

### 开发者的话

"想法小到一句话就能说完。人连上一台服务器，往往不只是想要一个 shell——还想看文件，有时想看那台
机器的桌面，有时要把一个端口转发回来。在多数工具里，这几件事各自是一次登录。在这里，它们是同
一条连接上的几条通道，所以四件事只需要一次握手、一次认证、一次生物识别提示，"Apex Terminal
的开发者说。

"另一半是密钥。在 Secure Enclave 里生成的密钥，私钥从未在芯片之外存在过，也就没有密钥文件可供
任何人复制——而它登录的，仍然是一台谁也不必去改的标准 OpenSSH 服务器。应用里其余的东西，都是从
这两个决定推出来的，包括那些我不得不留在外面的东西。这一版只发布已经对着真实服务器跑过的部分，
并且把做不到的事情原样说出来。对一个初版来说，这比一份更长的功能清单要好。"

### 上架信息

| | |
| --- | --- |
| 产品 | Apex Terminal，0.1.0 版 |
| 平台 | iPhone 与 iPad——一个应用，不是两个 |
| 系统要求 | iOS 或 iPadOS 17.0 及以上 |
| 价格 | 免费。没有内购，没有订阅，也没有试用期 |
| 账号 | 没有。没有需要注册的东西，也没有需要登录的东西 |
| 语言 | 英语、简体中文、繁体中文 |
| 分类 | 开发者工具，次分类为工具 |
| 年龄分级 | 4+ |
| 产品页 | **`OWNER SUPPLIES`** —— 页面上线之后填入其地址 |

Apex Terminal 是一个 SSH 客户端。命令运行在用户自己已有的服务器上，应用本身不执行任何东西。

### 关于 Apex Terminal

Apex Terminal 是 iPhone 和 iPad 上的 SSH 客户端，支持 iOS 与 iPadOS 17 及以上；命令运行
在你自己的服务器上。一条连接同时承载终端、文件、远程桌面与端口转发——四条通道共用
一次握手、一次认证、一次生物识别提示。终端本身做得很实：真彩色、sixel 图像、鼠标上报、
正确的中日韩字宽，vim、less、htop 退出之后 shell 原样还在。密钥可以在 Secure Enclave 内
生成，私钥无法离开这台设备，而它登录的是一台未经改动的标准 OpenSSH 服务器。没有账号，
没有后台服务，不采集任何使用数据。

### 媒体联系

**`OWNER SUPPLIES`** —— 一个名字，以及记者可以联系到的方式。本项目自己不持有任何媒体联系
地址，也不允许在这里编一个出来。发稿的人在稿件发出之前把这一行填好。

### 给编辑的说明

* 产品名是 **Apex Terminal**，两个词，A 和 T 大写。不缩写成"Apex"，正文里也不写成一个词。
  在中文里名字保持拉丁字母原样，前后各留一个空格；它没有中文名。
* 截图、事实清单，以及应用刻意不做的那些事，都在媒体资料包
  [`PRESS_KIT.md`](PRESS_KIT.md) 里。名称与图片的使用规则在 [`MEDIA_KIT.md`](MEDIA_KIT.md)。
* 截图都是对着真实服务器、从运行中的应用里拍下来的。没有一张是摆拍、重绘或合成的。
* 这里不引用任何用户数、评分、奖项或排名，因为它们并不存在。
