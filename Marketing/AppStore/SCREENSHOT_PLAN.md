# Screenshot plan

Six images, in one order, for both localizations and both device sizes. Every one of them
is a photograph of the app running against a real OpenSSH server; the plan below says
which screen, how the capture reaches it, what the server has to be holding, and what
proves the feature is real.

The captions live in [`scripts/shotlist.json`](scripts/shotlist.json), which is what
`render.sh` reads — this document explains them; that file is what produces them.

## The order, and why

The store shows the first image as a thumbnail next to the icon. It has to answer *what is
this* before anyone reads a word, so it is a dark terminal full of a real shell session:
a coloured prompt, `ls`, `git`, a cursor. Nothing else in a phone screenshot looks like
that.

The next two carry the reasons to install: **more than one server at once**, and **the app
asks about a host key before it connects**. Four to six fill in the rest — where keys live,
that full-screen programs work, and that the scrollback can be searched.

One image, one claim. Nothing carries two.

| # | File | The claim | Why a user cares |
| --- | --- | --- | --- |
| 01 | `01-terminal.png` | A genuine SSH session — real PTY, real colour, real scrollback | It is a terminal, not a remote-control app and not a web view |
| 02 | `02-sessions.png` | Several servers open at once, each identified | The work is never one machine |
| 03 | `03-host-key.png` | The fingerprint is shown and waits for an answer | Connecting blind is how you connect to the wrong host |
| 04 | `04-keys.png` | Keys are generated on the device and stay in the Keychain | The private half is the thing worth worrying about |
| 05 | `05-vim.png` | Full-screen programs run properly | A terminal that cannot run an editor is a toy |
| 06 | `06-find.png` | The scrollback can be searched while the session runs | Output scrolls away faster than you can read it |

---

## 01 · A genuine SSH session

|  |  |
| --- | --- |
| **Selling point** | A real interactive SSH session with a PTY, rendered natively |
| **User value** | The thing you type into behaves like the terminal on your desk |
| **zh-Hans title** | 真实的 SSH 会话 |
| **zh-Hans subtitle** | 完整的 PTY、真彩色与回滚缓冲，全部由应用自带的终端模拟器绘制。 |
| **en-US title** | A genuine SSH session |
| **en-US subtitle** | A real PTY, true colour and scrollback, drawn by the app's own emulator. |
| **Screen** | `TerminalView` with a live `TerminalSession` |
| **How the capture gets there** | `MarketingCaptureTests.test01Terminal` — taps the `edge-01` row in the connection list, waits for the shell's own prompt, then runs `cd services/api`, `ls -la`, `git status -sb`, `git log --oneline -3`, `cat config/api.yaml`, `wc -l src/*.go`, `df -h /`, `uptime`, waiting for each command's output before typing the next |
| **Data needed** | The `edge-01` container: a git repository with three commits and a dirty working tree, a YAML config, a Go source tree |
| **iPhone** | Portrait. The software keyboard is up and the accessory key row sits above it — which is what the app looks like while it is being typed into, and the row is the reason a terminal is usable on a phone at all |
| **iPad** | Landscape. The keyboard is dismissed with its own key, so the sidebar, the full grid and the whole key row are all visible at once |
| **Evidence** | `SSHIntegrationTests.ed25519KeyAuthenticationRunsCommand`, `.interactivePTYSession`; `TerminalParserTests`; `TerminalEmulator+SGR`; `scripts/app-integration-e2e.sh` |

## 02 · Several servers, at once

|  |  |
| --- | --- |
| **Selling point** | Concurrent sessions to different machines, with the platform detected |
| **User value** | Move between machines without dropping any of them |
| **zh-Hans title** | 多台服务器，同时在线 |
| **zh-Hans subtitle** | 每个会话彼此独立，随时切换；服务器是什么系统，连上就会告诉你。 |
| **en-US title** | Several servers, at once |
| **en-US subtitle** | Independent sessions, switched between at any time. Each server says what it runs. |
| **Screen** | `HostListView` — the "Open sessions" section above "Connections" |
| **How the capture gets there** | `test02Sessions` opens all three connections in turn, runs a command on each so that each is genuinely connected, and returns to the list |
| **Data needed** | Three containers on three ports; the platform row text comes from the server's own `uname -s`, over a second channel |
| **iPhone** | Portrait. The list is the whole screen; three green "Connected" rows above three saved connections |
| **iPad** | Landscape, and the composition is different on purpose: the sidebar holds the same list while the terminal keeps the rest of the screen — which is the iPad argument, not a bigger version of the phone one. The subtitle is rewritten to say that |
| **Evidence** | `MultiSceneTests`; `HostPlatformTests` (5); `TerminalUITests.testConnectingDetectsTheServerPlatform` |

## 03 · The fingerprint comes first

|  |  |
| --- | --- |
| **Selling point** | Host-key verification, with the real fingerprint, before any connection |
| **User value** | You find out you are talking to a different machine *before* you type into it |
| **zh-Hans title** | 先看指纹，再谈连接 |
| **zh-Hans subtitle** | 没见过的主机会先把密钥指纹摆出来等你确认；密钥变了，绝不静默通过。 |
| **en-US title** | The fingerprint comes first |
| **en-US subtitle** | A host you have not met is shown its key and waits for your answer. A changed key is never accepted quietly. |
| **Screen** | `PromptSheet.unknownHostKey` |
| **How the capture gets there** | `test00HostKeyPrompt` launches **without** the automatic-trust flag that the other UI tests use, taps `edge-01`, and photographs the sheet the app puts up; the capture script uninstalls the app first, so this is genuinely a first connection. The "How do I check this?" disclosure is opened, because a screenshot of a security control should show the whole control |
| **Data needed** | A server whose host key this device has never seen. `SHA256:` in the image is the fingerprint of the key that container really presented |
| **iPhone** | Portrait, sheet over a dimmed list |
| **iPad** | Landscape, the same sheet centred over the split view |
| **Evidence** | `SSHIntegrationTests.trustOnFirstUseRecordsKey`; `HostKeyVerifier.swift:65,95`; `scripts/app-integration-e2e.sh` proves refusing the prompt fails the session with `.hostKey` |

## 04 · Your keys stay here

|  |  |
| --- | --- |
| **Selling point** | Keys generated on the device; the private half in the Keychain, optionally behind Face ID |
| **User value** | Nothing to upload, nothing to trust with the secret |
| **zh-Hans title** | 密钥留在这台设备 |
| **zh-Hans subtitle** | 在设备上生成，私钥存进钥匙串；愿意的话，还能加一道 Face ID。 |
| **en-US title** | Your keys stay here |
| **en-US subtitle** | Generated on the device, held in the Keychain, and — if you ask — behind Face ID. |
| **Screen** | Settings → Keys (`KeyManagementView`) |
| **How the capture gets there** | `test03Keys` opens Settings, scrolls to Keys, and generates **two real keys through the app's own sheet** — one Ed25519, one ECDSA P-256. The fingerprints in the image are the fingerprints of keys that were actually created during the run |
| **Data needed** | None on the server side |
| **iPhone** | Portrait; two key rows with algorithm capsules and full SHA-256 fingerprints |
| **iPad** | Landscape; Settings is a form sheet over the split view |
| **Evidence** | `SSHKeyGenerationTests` — `ssh-keygen` agrees on the fingerprint of a generated key, and both algorithms authenticate against a real `sshd`; `TerminalUITests.testGeneratingAKeyShowsSomethingTheUserCanPasteIntoAServer` |

## 05 · Full-screen programs run

|  |  |
| --- | --- |
| **Selling point** | Alternate screen, syntax colour, remote cursor placement — a real terminal, not a line printer |
| **User value** | `vim`, `less`, `htop` behave the way they do on a laptop |
| **zh-Hans title** | 全屏程序，照常运行 |
| **zh-Hans subtitle** | 备用屏幕、语法着色、光标位置，全部按远端程序画的来。编辑器和分页器都正常。 |
| **en-US title** | Full-screen programs run |
| **en-US subtitle** | Alternate screen, syntax colour, a cursor the remote program places. Editors and pagers behave. |
| **Screen** | `TerminalView`, with `vim` running on the far end |
| **How the capture gets there** | `test04Vim` opens the session, `cd services/api`, runs `vim src/server.go`, waits until the file's own text is on screen, then photographs it and leaves with `:q!` |
| **Data needed** | A Go source file whose lines are short enough not to wrap at a phone's column count — the fixture writes one |
| **iPhone** | Portrait; the file fills the grid above the keyboard |
| **iPad** | Landscape; the whole file and vim's status line, with the sidebar beside it |
| **Evidence** | `TUIIntegrationTests` — **`vim` and `less` over a real SSH PTY**, alternate-screen restore, vim honouring a mid-session resize |

## 06 · Search the scrollback

|  |  |
| --- | --- |
| **Selling point** | Find text anywhere in a live session's history, across wrapped lines |
| **User value** | Output scrolls past faster than anyone reads it |
| **zh-Hans title** | 回滚缓冲，随手可搜 |
| **zh-Hans subtitle** | 匹配可以跨越自动换行，逐个跳转，会话照常运行。 |
| **en-US title** | Search the scrollback |
| **en-US subtitle** | Matches found across wrapped lines and stepped through while the session keeps running. |
| **Screen** | `TerminalView` with `FindBar` open |
| **How the capture gets there** | `test07Find` runs `git log --oneline` and `cat ../../notes.md` so the scrollback has something in it, opens Find from the session menu, and types `queue`. The "2 of 2" in the image is the app counting real matches |
| **Data needed** | Two files whose text contains the same word twice |
| **iPhone** | Portrait, find bar under the navigation bar |
| **iPad** | Landscape, same bar across the detail column |
| **Evidence** | `TerminalTextAccessTests` (11) — search crosses wraps and is bounded; the find-bar UI test asserts the match count |

---

## What is deliberately not here

* **Cloudflare Access / Tunnel.** The reason is in [`FEATURE_AUDIT.md`](FEATURE_AUDIT.md)
  §2. No screenshot, no caption, no word in any field.
* **Remote screens, the assistant, iCloud sync, Siri.** All real code, none of it verified
  along the path a reviewer would take. `FEATURE_AUDIT.md` §6.
* **The command palette, `htop`, the new-key screen and the connection editor.** Captured
  and kept in `raw/`, held back from the listing — `FEATURE_AUDIT.md` §8.

## The canvas

White ground, black type, one hairline, and the screenshot itself in a rounded rectangle
with a two-pixel black outline. No gradient, no glass, no shadow, no device mock-up, no
badge, no logo other than the app's own — which appears only where the app itself draws
it. Everything the app rendered keeps the colour the app gave it; the black-and-white rule
is for the canvas around it, never for the screenshot inside it.

Layout is identical in structure across all twenty-four images — index, title, subtitle,
rule, screenshot — but the type is set to the caption, not poured into a fixed box, so a
short title and a long one both sit right.
