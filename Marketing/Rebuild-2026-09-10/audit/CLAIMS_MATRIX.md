# Claims matrix — every public claim, and what proves it

**Written:** 2026-09-10 · **Gate:** [`PRODUCT_TRUTH_MATRIX.md`](PRODUCT_TRUTH_MATRIX.md)

Nothing may be said to a customer unless it appears in this table. Each row names the exact
wording that is approved, where it may be used, and the test that would have to fail for
the claim to become untrue.

`SS-n` refers to screenshot *n* in [`../app-store/SCREENSHOT_PLAN.md`](../app-store/SCREENSHOT_PLAN.md).

---

## The five claims the whole listing rests on

| # | Approved wording (EN) | Approved wording (ZH) | Evidence — the test that would have to fail | Used in |
| --- | --- | --- | --- | --- |
| **C1** | One connection carries your shell, your files, your desktop and your tunnels. | 一条连接，同时承载终端、文件、桌面与隧道。 | `SSHConnectionPoolTests` — four channel types on one pooled transport; plus the adversarial pair: never returns a connection belonging to another account, never returns a dead one | Subtitle, SS-1, hero, PH tagline |
| **C2** | Create a key inside the Secure Enclave. Its private half cannot leave the device — and it logs in to an ordinary OpenSSH server. | 在 Secure Enclave 里生成密钥，私钥无法离开这台设备——照样登录标准 OpenSSH 服务器。 | `SecureEnclaveKeyTests` — only the public half is placed in a real `sshd`'s `authorized_keys`; the test asserts `sshd`'s own log line `Accepted publickey … ECDSA <fingerprint>`; a control case proves the same key is refused where unauthorised | SS-7, security page, press |
| **C3** | A real terminal: true colour, sixel pictures, mouse reporting, correct CJK widths, and full-screen programs that put your shell back exactly as it was. | 真正的终端：真彩色、sixel 图像、鼠标上报、正确的中日韩字宽，全屏程序退出后 shell 原样还在。 | `TerminalEmulatorTests`, `TUIIntegrationTests` (vim and less over a real PTY), `CharacterWidthTests` (UCD 17.0.0), `SixelTests`, `MouseReportingTests`, the fuzz suite shown to catch a deliberately broken invariant | SS-1, SS-3, website |
| **C4** | Your server's files, in the Files app — and in the app, several folders at once. | 服务器上的文件，直接出现在"文件"App 里；应用内还能同时打开多个远程目录。 | `FileProviderDomainTests`, the SFTP suite (list/read/write/mkdir/move/delete against a real server), the interrupted-upload test that lands the file whole and leaves no temporary behind | SS-4, website |
| **C5** | No account, no back end, nothing measured. | 没有账号，没有后台服务，不采集任何使用数据。 | Proven as an absence by grep: no StoreKit/IAP/subscription symbol, no analytics/telemetry/crash-reporter SDK, no project-operated server anywhere in `App/`, `Packages/…/Sources`, `FileProvider/` | SS-7, privacy page, press |

---

## Supporting claims, approved

| # | Claim | Status behind it | Notes for the writer |
| --- | --- | --- | --- |
| C6 | Local, remote and dynamic (SOCKS5) port forwarding, saved on a connection and started with it | Verified | Live byte and connection counters per rule are real and photographable |
| C7 | A forward that cannot start says why, naming the port | Verified | "Port 8080 on this device is already in use", not an error code |
| C8 | tmux over its own control protocol — detach, and reattach to find the panes still there | Verified | Say "tmux control mode"; do **not** say "your session never dies" |
| C9 | Remote desktop over VNC, in the same app, reachable through the SSH connection | Verified | Encodings, VNC auth and the SSH route are Verified. macOS Screen Sharing sign-in is **not** (H-3) |
| C10 | Split panes on iPad, each with its own toolbar, and a second window | Verified | Divider has a minimum size and a VoiceOver-adjustable action |
| C11 | Several live sessions at once; typing follows the session you are looking at | Verified | |
| C12 | ProxyJump / bastion chains, with the far server's host key checked as its own | Verified | |
| C13 | OpenSSH user **and** host certificates, and trusted certificate authorities | Verified | A certificate that fails validation is refused, not turned into a prompt |
| C14 | Agent forwarding with the device as the agent — including an enclave key | Verified | Pairs strongly with C2 |
| C15 | Servers with PAM, expired passwords or a one-time code prompt log in | Verified | Say "servers with 2FA work". **Never** "2FA built in" — no code is generated or stored |
| C16 | Post-quantum hybrid key exchange (`mlkem768x25519-sha256`), with fallback | Verified | Say "on servers that support it" |
| C17 | Host key checked on first connection; a changed key is a hard stop | Verified | |
| C18 | A remote program can write your clipboard only after you allow it, and can never read it | Verified | OSC 52; the read request is refused and not even reported back |
| C19 | Encrypted backup sealed with a password, and a restore that previews before it writes | Verified | Unexportable enclave keys are **named**, not silently dropped |
| C20 | Any monospaced font on the device, with size and line height | Verified | The server is told the new grid size |
| C21 | An `ssh://` link shows the exact command and runs it only if you agree | Verified | Good security-story material |
| C22 | Sessions come back on their own after the network drops, scrollback intact | Verified | The new shell is marked as fresh |
| C23 | App lock: a passcode of the app's own, with backoff and a grace period | Verified | Separate from the device passcode |
| C24 | One app for iPhone and iPad, iOS/iPadOS 17 and later | Verified | |

---

## Claims deliberately withheld

Each of these is in the binary and works as far as it has been taken. None may be
advertised. All are disclosed to App Review, as guideline 2.3.1 requires.

| Claim withheld | Status | What would release it |
| --- | --- | --- |
| Connecting through Cloudflare Access / Tunnel | Implemented but Unverified | H-4 — a Cloudflare tenant, tunnel, Access application and service token |
| Browser SSO sign-in to Cloudflare Access | Implemented but Unverified | H-4 |
| iCloud / CloudKit sync between devices | Implemented but Unverified | H-5 — production CloudKit schema, two signed devices |
| Typing Chinese, Japanese or Korean into the terminal | Implemented but Unverified | H-1 — a real device and a real input method |
| macOS Screen Sharing sign-in, VeNCrypt | Implemented but Unverified | H-3 — a real Mac, a real VeNCrypt server |
| Running on Mac (Catalyst) | Implemented but Unverified | H-8 — a Mac Catalyst signing identity |
| Running on Vision Pro | Implemented but Unverified | H-9 — the visionOS simulator runtime; never run |
| watchOS | Planned | Not started |
| Kitty and iTerm2 inline images | See matrix | Sixel is Verified; state only what the matrix allows |
| The assistant | Implemented but Unverified | Needs a provider key or an Apple Intelligence device |

---

## Wording rules that apply everywhere

1. **"SSH client", never "SSH server".** Commands run on the customer's own remote machine.
   Every long description says this explicitly.
2. **No superlatives** — no *fastest*, *most secure*, *only*, *first*, *#1*.
3. **No background-connection promise.** iOS does not guarantee it.
4. **Numbers are quoted only where measured**, and the measurement is named. Throughput and
   frame-time figures come from `docs/RELEASE_EVIDENCE.md` on the date it names.
5. **No competitor is named** in any customer-facing text.
6. **Cloudflare** — see [`../strategy/POSITIONING.md`](../strategy/POSITIONING.md) §6.
7. **Absences are provable and are worth stating**: no account, no telemetry, no purchase.
8. **"Verified" is not a marketing word.** It never appears in customer copy; it is this
   project's internal gate.
