# ApexTerminal — what it is and what it does

A product introduction for a website, a product page or a release post. Everything here is
traced to running code and a passing test in [`FEATURE_AUDIT.md`](../FEATURE_AUDIT.md);
nothing that has not been seen to work appears in it.

---

## The short version

ApexTerminal is an SSH client for iPhone and iPad. It opens a real interactive session on
a server you already have, allocates a real PTY, and draws what comes back with a terminal
emulator written for this app. There is no account, no relay, and nothing to buy.

Commands run on your machines. ApexTerminal is the terminal.

---

## A terminal, not an approximation

The emulator is the product. It parses VT/ANSI itself and keeps its own screen, so the
things that separate a terminal from a log viewer are all present:

* **256 colours and full SGR**, including the attributes a prompt actually uses.
* **The alternate screen**, saved and restored — which is what lets an editor open and
  leave your shell where it was.
* **Mouse reporting**, in both encodings, with modifiers, wheel and drag gating. A remote
  program that turns tracking on gets exactly the bytes a desktop terminal would send;
  that is asserted by reading them back through `cat -v` on the far end.
* **Correct cell widths** for CJK, halfwidth kana, combining marks, ZWJ emoji sequences,
  flags and variation selectors, generated from the Unicode 17.0.0 tables rather than
  guessed at.
* **Reflow on width change**: widening rejoins wrapped lines, narrowing re-wraps them,
  hard breaks survive, and a wide character is never split down the middle.
* **Scrollback** with selection, copy and search — a soft-wrapped line copies without a
  newline injected into it, and a search match may span the wrap.

Full-screen programs work because they are tested: every change runs `vim` and `less` over
a real SSH connection, including a window resize in the middle of an edit.

It is fast enough not to be the bottleneck, and the numbers were measured rather than
assumed: in a Release build the emulator takes 14.7 MB/s of plain text, 33.5 MB/s of
coloured text and 14.9 MB/s of CJK, and reflows a full 5 000-line scrollback in 17 ms.

## Connections, and more than one of them

Several servers can be open at once. Each session is independent — switching between them
costs nothing and drops nothing.

A connection is a small record: a name, an address, a user name, and which stored
credential to offer. The port and the user name may both be left blank, which means "the
default" and "ask me when I connect". Pasting `host:port` into the hostname field does what
you meant.

Once connected, the server is asked what it is — over a channel of its own, never by
typing into your session — and the row says macOS, Linux, FreeBSD, Windows or whatever it
answered. You can overrule it by hand, and your answer wins.

When a connection dies, the app notices, backs off, and comes back with the scrollback
intact. It does not reconnect when you typed `exit`, because you meant it. And when the app
is launched again after being terminated, it offers to reopen the machines that were open —
honestly labelled, because those are new sessions: the shells that were running are gone.

## Host keys, taken seriously

The first time you reach a server, the key it presented is put in front of you with its
SHA-256 fingerprint and the command to verify it on the server. Nothing connects until you
answer.

If a key later changes, you get a different screen — one deliberately styled so that
continuing feels like the unusual choice it is, with the key you trusted and the key being
offered shown side by side. There is no code path that accepts a changed key quietly.

Known hosts are yours: you can look at them and remove them, and a host removed by hand
stays removed.

## Keys that stay where you put them

Generate an Ed25519 or ECDSA P-256 key in the app. It shows you the public half, ready to
paste into `authorized_keys`, and keeps the private half in the Keychain with an explicit
protection class. The interface never displays it, and nothing the app exports contains it.

When you create a key you can require Face ID or Touch ID before it is ever used; the key
then becomes unusable if the device's biometric enrolment changes, which is the point.

Keys you already have import, including passphrase-protected OpenSSH keys — the bcrypt KDF
is bit-exact, which is proved the only way it can be: a wrong passphrase has to fail.

RSA keys keep working, over `rsa-sha2-256` and `rsa-sha2-512`. `ssh-rsa` with SHA-1 is
refused on purpose: OpenSSH disabled it by default in 8.8, and accepting it would ship a
downgrade a server could ask for.

## A phone is not a laptop, and the app knows it

Above the keyboard is a row with Escape, Tab, Control, the arrows, Home, End and the page
keys — the keys a software keyboard does not have and a terminal cannot work without.
Control latches rather than requiring a chord, because holding a modifier on a touchscreen
is awkward: tap ctrl, then c, and `^C` is sent.

Pinch to change the font size, and the remote program is told the new geometry — including
when the view's bounds did not change, which is the case that quietly breaks wrapping in
lesser implementations.

Text drags out of the terminal and drops back in, and a multi-line drop is confirmed
exactly as a multi-line paste is, because either one could run several commands on one
gesture.

## An iPad that is actually an iPad

The layout follows the size class, not the device, so a Slide Over window gets the compact
layout and Stage Manager resizing moves between them live. In the regular layout the
connection list sits beside the terminal instead of covering it.

A session can be opened in a second window, and a session is displayed by one window at a
time — so two windows can never fight over the remote program's window size.

A hardware keyboard reaches: new connection, the command palette, next and previous
session, session by number, close, and font size. Modified arrows, function keys, editing
keys and Meta follow the xterm rules, one test per rule. Command is never forwarded to the
remote host.

## Finding things again

Search a live session's scrollback, with the match count shown and matches stepped
through — including a match that crosses a wrapped line.

The command palette ranks connections, open sessions, snippets and actions by real fuzzy
match quality, with the matched characters emboldened. `wp` finds `web-prod-01` rather than
`wrapper`; `dfh` finds a snippet called "Disk Free Here", which a substring filter would
never surface.

Snippets place their text on the command line and wait for you to press Return. That is the
default and it is the safety property, so it is tested by observing the absence of output
until the key is pressed.

## Quiet by default

* **Command history is off.** Turn it on and it records commands as typed — no prompts, no
  output, nothing resurrected from before you opted in. Turn it off and the file is
  deleted, not just the list.
* **Copied terminal text expires** from the system clipboard, after a minute by default,
  configurable in Settings.
* **Multi-line pastes ask first**, and so do drops.
* **The terminal can be hidden** from the App Switcher snapshot.
* **The app itself can be locked** with a passcode of its own, with Face ID or Touch ID in
  front of it, a grace period you choose, and a backoff that makes five wrong guesses cost
  thirty seconds.

## Accessibility, run rather than claimed

The UI tests launch the app with accessibility text sizes, Bold Text and Reduce
Transparency actually enabled and assert that every control is labelled. The terminal
exposes its rendered text as an accessibility value, because the grid is a drawing and
there is nothing else for VoiceOver to read. Three themes ship, including a high-contrast
one, and the terminal can follow the system's light and dark setting.

## Languages

English, Simplified Chinese and Traditional Chinese, throughout — 601 strings, with a
build-time audit that fails on an untranslated one. Terminal output is never translated.

## What it does not do

Said plainly, because a feature list that only lists features is not honest:

* **No SFTP and no port forwarding.** Neither is implemented.
* **No agent forwarding.**
* **No custom theme editor** — three built-in themes, not an unlimited palette.
* **No cloud of ours.** There is nothing to sign into, and nothing is stored anywhere but
  your device and the servers you connect to.

---

# ApexTerminal — 中文介绍

给官网、产品页或发布贴用的版本。内容与上文一致，同样只写经过验证的部分。

## 一句话

ApexTerminal 是 iPhone 和 iPad 上的 SSH 客户端。它在你自己已有的服务器上打开真正的交互式
会话，分配真实的 PTY，并用为这个应用写的终端模拟器把远端送来的内容画出来。没有账号，没有
中转，也没有任何需要额外付费的东西。命令跑在你的机器上，ApexTerminal 只是那台终端。

## 一个真正的终端

模拟器本身就是产品。它自己解析 VT/ANSI 并维护屏幕状态，所以把终端和"日志查看器"区分开的
那些东西都在：256 色与完整 SGR；备用屏幕的保存与恢复（编辑器退出后 shell 还在原处）；
两种编码的鼠标上报，带修饰键、滚轮与拖拽门控；按 Unicode 17.0.0 表计算的字符宽度，涵盖
中日韩文字、半角假名、组合符号、ZWJ emoji、旗帜与变体选择符；改变宽度时的重排——变宽会
重新接起来，变窄会重新折行，硬换行不受影响，宽字符永远不会被从中间劈开；以及带选择、
复制和搜索的回滚缓冲——软换行复制出来不会多一个换行符，搜索匹配可以跨过折行处。

全屏程序能跑，是因为它被测试着：每次改动，`vim` 和 `less` 都会通过一条真实的 SSH 连接跑
一遍，包括编辑途中改变窗口大小。

速度是量出来的，不是说出来的：Release 构建下，纯文本 14.7 MB/s，带色文本 33.5 MB/s，
中日韩文字 14.9 MB/s，5000 行回滚缓冲的整体重排耗时 17 ms。

## 连接，而且不止一条

可以同时打开多台服务器，会话彼此独立，切换不需要重连也不会丢东西。

一条连接就是一小段记录：名字、地址、用户名，以及优先使用哪份已保存的凭据。端口和用户名
都可以留空——分别表示"用默认值"和"连接时再问我"。把 `host:port` 直接粘进主机名一栏，它会
按你想的那样处理。

连上之后，应用会通过一条单独的通道问服务器"你是什么"，而不是往你的会话里敲命令；行上随后
会显示 macOS、Linux、FreeBSD、Windows 或它自己报出来的名字。你也可以手动指定，手动的优先。

连接断了，应用会察觉、退避重试，并带着完好的回滚缓冲回来。你自己敲 `exit` 时它不会重连，
因为那是你的本意。应用被彻底关闭后再次启动，会问你要不要重新打开上次那些机器——并且老实
说明：这些是新的会话，原来跑着的 shell 已经没了。

## 认真对待主机密钥

第一次连到一台服务器，它出示的密钥会连同 SHA-256 指纹、以及在服务器上核对指纹的命令一起
摆在你面前。你不回答，就不会连上去。

之后密钥若发生变化，你看到的是另一个界面——刻意做得让"继续"显得不寻常，把你信任过的密钥和
现在出示的密钥并排放着。代码里没有任何一条路径会静默接受一把变了的密钥。

已知主机是你的：可以查看，也可以删除；手动删掉的，就一直是删掉的状态。

## 密钥留在你放的地方

在应用里生成 Ed25519 或 ECDSA P-256 密钥。它会把公钥显示出来，方便你粘进 `authorized_keys`，
私钥则留在钥匙串里，并带明确的保护等级。界面上不显示它，应用导出的任何东西里也不包含它。

创建密钥时可以要求以后每次使用都先过一次 Face ID 或 Touch ID；设备的生物识别注册一旦变化，
这把密钥就会失效——这正是它的意义。

已有的密钥可以导入，包括带口令保护的 OpenSSH 私钥：bcrypt KDF 必须逐位精确，而这一点只能
用一种方式证明——错误的口令必须失败。

RSA 密钥仍然可用，走 `rsa-sha2-256` 与 `rsa-sha2-512`。使用 SHA-1 的 `ssh-rsa` 是有意不
支持的：OpenSSH 从 8.8 起就默认禁用了它，接受它等于把一个可以被服务器要求的降级带上船。

## 手机不是笔记本，应用知道这件事

键盘上方那一行提供 Esc、Tab、Ctrl、方向键、Home、End 和翻页键——软键盘没有、终端却离不开的
那些键。Ctrl 是"锁存"而不是要你按住组合键，因为在触摸屏上按住修饰键很别扭：点 ctrl，再点
c，发出去的就是 `^C`。

双指捏合改变字号，远端程序会收到新的窗口尺寸——包括视图边界并没有变化的那种情况，那正是
很多实现里悄悄弄错换行的地方。

文本可以从终端里拖出去，也可以拖进来；多行拖入会像多行粘贴一样先确认，因为两者都可能让
一个手势执行好几条命令。

## iPad 就是 iPad

布局跟随尺寸类别而不是设备型号，所以侧拉窗口会得到紧凑布局，台前调度调整大小时也会实时
切换。在常规布局里，连接列表在终端旁边，而不是盖在上面。

会话可以在第二个窗口里打开；同一个会话同一时间只由一个窗口显示，所以两个窗口不会为远端
程序的窗口尺寸打架。

外接键盘可以直达：新建连接、命令面板、上一个/下一个会话、按编号切换、关闭、调整字号。
带修饰键的方向键、功能键、编辑键和 Meta 都按 xterm 的规则来，每条规则一个测试。Command
永远不会被转发给远端主机。

## 把翻过去的内容找回来

在正在运行的会话里搜索回滚缓冲，匹配数看得见，可以逐个跳转，跨过折行的匹配也找得到。

命令面板对连接、已开会话、片段和操作做真正的模糊排序，并把命中的字符加粗——`wp` 找到的是
`web-prod-01` 而不是 `wrapper`；`dfh` 能找到名为 "Disk Free Here" 的片段，而子串过滤什么
也找不到。

片段只会把文字放到命令行上，等你按回车。这是默认行为，也是它的安全属性，所以测试的方式是
观察"在按下回车之前，输出不出现"。

## 默认就很安静

* **命令历史默认关闭。** 打开后按你敲下的样子记录——没有提示符、没有输出，也不会把开启之前
  的东西补回来。关掉时删除的是文件，不只是列表。
* **复制的终端文本会过期**，默认一分钟，可以在设置里调整。
* **多行粘贴会先问一句**，拖入也一样。
* **终端可以在应用切换器里被遮住。**
* **应用本身可以上锁**：一个独立的密码，前面加 Face ID 或 Touch ID，宽限时间由你决定，
  连续五次输错要等三十秒。

## 无障碍，是跑出来的

UI 测试会带着放大的字体、粗体文本和"降低透明度"真正开启的状态启动应用，并断言每个控件都有
标签。终端把渲染出来的文字作为无障碍值暴露出来——因为那一格一格是画出来的，VoiceOver 没有
别的东西可读。内置三套主题，其中一套是高对比度的，终端也可以跟随系统的浅色/深色设置。

## 语言

英文、简体中文、繁体中文，全应用覆盖——601 条字符串，构建时有一道审计，只要有一条没翻译
就失败。终端里的输出永远不翻译。

## 它不做什么

功能列表只写功能，是不诚实的：

* **没有 SFTP，也没有端口转发**，两者都没有实现。
* **没有 agent 转发。**
* **没有自定义主题编辑器** —— 是三套内置主题，不是任意配色。
* **没有我们的云。** 没有账号可登录，除了你的设备和你连上去的服务器，数据不存在别的地方。
