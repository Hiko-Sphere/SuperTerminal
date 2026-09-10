# Screenshot plan — Apex Terminal

**Written:** 2026-09-10 · **Gated by:** [`../audit/PRODUCT_TRUTH_MATRIX.md`](../audit/PRODUCT_TRUTH_MATRIX.md) ·
**Claims:** [`../audit/CLAIMS_MATRIX.md`](../audit/CLAIMS_MATRIX.md)

Eight screens. Every one is a **Verified** capability that is reachable in the running
interface, and every one is photographed from the real app against real servers. Nothing
here is staged, redrawn, or composited.

This is a new plan, not the old one re-lettered. The previous set had six screens and led
with a generic terminal; four of its six subjects (host key, keys, vim, find) are now
demoted or absorbed, because the audit surfaced stronger, more distinctive material —
multiplexing, files, forwards, tmux, panes — that did not exist when the old set was made.

---

## The narrative

A store visitor decides in the first three seconds. The order is therefore: **what it is →
what makes it different → what you can do → why you can trust it.**

| # | Filename | Subject | Claim | Why it is here |
| --- | --- | --- | --- | --- |
| 1 | `01-terminal` | A live shell with real output | C3 | Says "professional SSH terminal" at thumbnail size |
| 2 | `02-one-connection` | Shell, file browser, forward and screen all open on one server | **C1** | The differentiator, and the one competitors cannot copy cheaply |
| 3 | `03-panes` | Split panes on iPad / several sessions on iPhone | C10, C11 | The iPad workstation story |
| 4 | `04-files` | The file browser on a real directory | C4 | The second-biggest reason to buy |
| 5 | `05-forwards` | The forwards list with a running rule and live counters | C6, C7 | Nobody else photographs this; it is concrete and real |
| 6 | `06-tmux` | An attached tmux session with its own panes | C8 | The long-running-work story |
| 7 | `07-security` | A Secure Enclave key, listed with its real fingerprint | **C2**, C5 | The trust close |
| 8 | `08-desktop` | A remote desktop over VNC | C9 | Breadth — "and it does this too" |

## Per-screen detail

Each entry: the point, the captions, the real screen, how the capture reaches it, and what
the fixture must provide.

---

### 1 · `01-terminal` — a genuine SSH session

* **Point:** this is a real terminal on a real server, not a log viewer.
* **EN title:** A real terminal, over SSH
* **EN subtitle:** True colour, a real PTY, and full-screen programs that put your shell back exactly as it was.
* **ZH title:** 真正的终端，跑在 SSH 上
* **ZH subtitle:** 真彩色、真实 PTY，全屏程序退出后，shell 原样还在。
* **Screen:** `TerminalView`, `terminal-grid`.
* **Route:** tap `host-row` "edge-01" → wait for the prompt → run a short, dense sequence
  (`ls -la`, `git status -sb`, `git log --oneline -3`, `cat config/api.yaml`, `uptime`).
* **Fixture:** `edge-01`, seeded home with a small Go service and a git repo.
* **iPhone vs iPad:** iPhone portrait shows the accessory key row above the keyboard — the
  keys a phone keyboard does not have. iPad landscape shows the sidebar beside the grid.

### 2 · `02-one-connection` — one connection, everything on it

* **Point:** one handshake, one authentication, four things running.
* **EN title:** One connection. Everything on it.
* **EN subtitle:** A shell, your files, a desktop and a tunnel — one handshake, one Face ID prompt, four SSH channels.
* **ZH title:** 一条连接，全部承载
* **ZH subtitle:** 终端、文件、桌面、隧道——一次握手、一次 Face ID，四条 SSH 通道。
* **Screen:** the connection list (`HostListView`) with **Open sessions**, **Open file
  browsers**, **Open screens** and a running forward all populated for the same server.
* **Route:** open a session on `edge-01`; `open-file-browser` on the same host; start a
  saved forward; open the screen. Return to the list.
* **Fixture:** `edge-01` must additionally run a VNC server and something to forward to.
* **iPhone vs iPad:** iPhone shows the stacked list — the proof is the four sections. iPad
  shows the sidebar with the terminal beside it, so the reader sees list *and* session.

### 3 · `03-panes` — two terminals at once

* **Point:** an iPad is a workstation, not a phone with a big screen.
* **EN title:** Two terminals, one screen
* **EN subtitle:** Split a pane, drag the divider, and watch a log while you work. Each pane is a full session with its own controls.
* **ZH title:** 一屏两个终端
* **ZH subtitle:** 分屏、拖动分隔条，一边看日志一边干活。每个窗格都是完整会话，各有各的控制。
* **Screen:** `PaneContainerView` with two live panes.
* **Route:** open `edge-01`, `terminal-menu` → `terminal-menu-split-right`, choose the
  second target in `split-target-picker`, run something long in the left pane
  (`tail -f` on the seeded log) and work in the right.
* **iPhone vs iPad:** **different subjects, not a rescale.** iPad = split panes. iPhone =
  three live sessions in the list plus fast switching, since panes are an iPad affordance.

### 4 · `04-files` — your server's files

* **Point:** SFTP is not a separate app or a separate login.
* **EN title:** Your server's files, right here
* **EN subtitle:** Browse, upload and download over the same SSH connection — and put the server in the Files app.
* **ZH title:** 服务器上的文件，就在手边
* **ZH subtitle:** 浏览、上传、下载，全走同一条 SSH 连接——还能把服务器挂进「文件」App。
* **Screen:** `FileBrowserView` — `files-path` breadcrumb, `file-row` rows with size, date
  and permission string.
* **Route:** `host-row` context menu → `open-file-browser` → navigate into `services/api`.
* **Fixture:** the seeded home is already right for this.
* **Note:** the **Files.app** half is shown by the `files-domain-toggle` switch in the
  connection editor, not by a screenshot of Files itself — publishing to Files is Verified,
  but a photograph of Apple's Files app is not a photograph of this app.

### 5 · `05-forwards` — tunnels you can see

* **Point:** forwards are a managed, observable thing here, not a command you retype.
* **EN title:** Tunnels you can see
* **EN subtitle:** Local, remote and SOCKS5 forwards saved with a connection, started with it, with live byte and connection counts.
* **ZH title:** 看得见的隧道
* **ZH subtitle:** 本地、远程、SOCKS5 转发随连接保存并自动启动，实时显示字节数与连接数。
* **Screen:** `PortForwardsView` — `port-forward-row` with counters, one rule running.
* **Route:** `terminal-menu` → `terminal-menu-forwards` → `start-port-forward` on a saved
  rule → let traffic flow so the counters are non-zero.
* **Fixture:** a small HTTP service inside `edge-01` to forward to, and the capture drives
  a request through the forward so the counters show real bytes.

### 6 · `06-tmux` — work that keeps running

* **Point:** detach, put the iPad down, come back to the same panes.
* **EN title:** Detach. Come back. Still there.
* **EN subtitle:** tmux over its own control protocol — the panes and their output are exactly where you left them.
* **ZH title:** 断开、回来，一切照旧
* **ZH subtitle:** 通过 tmux 自己的控制协议接入——窗格和输出都停在你离开时的样子。
* **Screen:** `TerminalView` in tmux mode with `tmux-menu` and `tmux-pane-*`.
* **Route:** a connection with `host-uses-tmux` on and `host-tmux-session` named; open it,
  `tmux-split-right`, run something in each pane.
* **Fixture:** tmux inside the container (the project's `TmuxTestServer` already does this).

### 7 · `07-security` — a key that cannot leave

* **Point:** the strongest security claim in the category, and it is literally true.
* **EN title:** A key that cannot leave your phone
* **EN subtitle:** Generate it inside the Secure Enclave. No copy of the private half exists — not to export, not to sync, not to steal. It still logs in to an ordinary OpenSSH server.
* **ZH title:** 一把带不走的密钥
* **ZH subtitle:** 在 Secure Enclave 里生成，私钥不存在任何副本——导不出、同步不了、偷不走，却照样登录标准 OpenSSH 服务器。
* **Screen:** `KeyManagementView` with an enclave key listed, its real SHA-256 fingerprint,
  and the enclave badge.
* **Route:** Settings → `settings-keys` → `add-key` → `generate-key` → `key-secure-enclave`
  on → `key-generate`.
* **Caveat:** the simulator's enclave is a software emulation. The key, the fingerprint and
  the badge are all real app behaviour; the caption claims only what the app does, and the
  hardware property is stated in the description, not in the image.

### 8 · `08-desktop` — the machine's own screen

* **Point:** breadth. Terminal *and* desktop, same app, same connection.
* **EN title:** The desktop, too
* **EN subtitle:** A remote screen over VNC, reached through the same SSH connection — nothing exposed to the internet.
* **ZH title:** 连桌面也一起
* **ZH subtitle:** 通过同一条 SSH 连接访问远程桌面，无需对公网暴露任何端口。
* **Screen:** `VNCView` — `vnc-screen` with the `vnc-key-row`.
* **Route:** `screen-row` for the seeded screen → connect through the SSH host.
* **Fixture:** LibVNCServer, as the project's existing VNC suite already runs it.

---

## Sizes, from Apple's current specification

Re-checked against Apple's page on 2026-09-10; the numbers live in
[`../../AppStore/APPLE_REQUIREMENTS.md`](../../AppStore/APPLE_REQUIREMENTS.md) and are
re-verified by `automation/validate.py` on every export.

| Slot | Pixels | Device that produces it natively | Orientation |
| --- | --- | --- | --- |
| iPhone 6.9" | 1320 × 2868 | iPhone 17 Pro Max | portrait |
| iPhone 6.5" | 1284 × 2778 | iPhone 14 Plus | portrait |
| iPad 13" | 2732 × 2048 | iPad Air 13-inch (M4) | landscape |

Nothing is ever scaled into a slot: 1320 × 2868 and 1284 × 2778 are different shapes, so
each is captured on hardware that produces it. Three slots × three languages = **72 final
images** (8 × 3 × 3).

## Languages

`en-US`, `zh-Hans`, `zh-Hant`. The app ships all three, so the interface in each set is
in that language — the captions and the app agree. Terminal output stays as the server
sent it, in English, because that is what the server sent.

## Visual system

A new template, not the old one with new text. Full specification in
[`SCREENSHOT_DESIGN.md`](SCREENSHOT_DESIGN.md). In short: white ground, black type, one
hairline rule, a single index mark, generous margin, and the device capture inset with a
thin outline and no bezel art, no shadow, no gradient, no 3-D. iPhone and iPad have
**different** layouts — the iPad canvas is landscape with the caption to the left of the
capture, not the same portrait stack scaled up.
