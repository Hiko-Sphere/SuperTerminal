# App preview script — English (en-US)

**Written:** 2026-09-10 · **Spec:** [`APP_PREVIEW_SPEC.md`](APP_PREVIEW_SPEC.md) ·
**Claims:** [`../../audit/CLAIMS_MATRIX.md`](../../audit/CLAIMS_MATRIX.md) ·
**Storyboard:** [`APP_PREVIEW_STORYBOARD.md`](APP_PREVIEW_STORYBOARD.md)

Eight shots, 29.0 seconds, inside Apple's 30-second ceiling established in the spec. Every
shot is a Verified capability, driven in the running app against the four servers
`automation/capture.sh` starts. Nothing is staged, redrawn or composited.

---

## Before anything else: what this preview does not have

* **No voice-over.** There is no narrator, no script to read, no one speaking. The captions
  carry every word the viewer receives, and the preview must be fully legible with the sound
  off — which is how most store visitors will see it.
* **Music is optional, and if it is used it must be licensed** for commercial distribution
  inside an App Store preview, with the licence filed alongside the delivered files. No
  specific track is named here, and none should be chosen by whoever edits without that
  licence in hand. Where no licence exists, the delivered file carries a silent stereo AAC
  track encoded to the spec in `APP_PREVIEW_SPEC.md` §2.4.
* **No sound effects, no keyboard clicks, no interface sounds.** The recording is silent at
  source and stays that way.

---

## The line the eight shots draw

Connect → work → work on two things at once → the files → the tunnel → work that outlives
the session → the machine's own screen → the key that makes all of it safe to do from a
phone.

The last shot is the one the viewer leaves with, which is why the key is there and not
first.

---

## Timing at a glance

| Shot | Start | End | Length | Subject | Claim |
| --- | --- | --- | --- | --- | --- |
| 1 | 0.0 | 3.5 | 3.5 s | A saved connection opens to a shell | C1 |
| 2 | 3.5 | 8.0 | 4.5 s | The shell doing real work | C3 |
| 3 | 8.0 | 11.5 | 3.5 s | Splitting a pane on iPad | C10, C11 |
| 4 | 11.5 | 15.0 | 3.5 s | The server's files | C4 |
| 5 | 15.0 | 19.0 | 4.0 s | A port forward, counters moving | C6 |
| 6 | 19.0 | 23.5 | 4.5 s | tmux — detach, reattach, panes intact | C8 |
| 7 | 23.5 | 26.0 | 2.5 s | A remote desktop | C9 |
| 8 | 26.0 | 29.0 | 3.0 s | A key in the Secure Enclave | C2 |
| | | | **29.0 s** | | |

---

## Shot 1 — a saved connection, and a shell

* **Number:** 1
* **Duration:** 3.5 s (0.0 → 3.5)
* **On screen:** the connection list, four saved connections showing name, user and host —
  `edge-01`, `db-primary`, `build-runner`, `ops-box`. A finger-free tap lands on `edge-01`.
  The session screen pushes in, the connecting indicator shows for well under a second, and
  the prompt `deploy@edge-01:~$` appears with the shell's own banner above it. On iPad the
  list stays in the sidebar and the session opens beside it; on iPhone the list is replaced.
* **Caption:** `A saved connection, and a real shell.`
* **What the viewer should understand:** this is a genuine SSH login to a machine they own,
  reached in one tap from a list they set up once. Not a web console, not a relay.
* **How to produce it:** launch the app on a simulator seeded by the capture harness. Tap
  the `host-row` whose label begins `edge-01`. Wait until `terminal-grid` reports a value
  containing `deploy@edge-01` — the same condition `RebuildCaptureTests.openTerminal` waits
  on. Trim the clip so the tap is at 0.4 s and the prompt has been on screen for at least
  0.8 s before the cut.
* **Notes:** do not trim away the connecting indicator entirely. A login that appears to
  take zero time reads as a mock-up. Roughly half a second of it is the honest picture and
  the more convincing one.

## Shot 2 — the shell doing real work

* **Number:** 2
* **Duration:** 4.5 s (3.5 → 8.0)
* **On screen:** the terminal, dark theme, filling the frame. In sequence, without pauses
  long enough to read as dead air: `cd services/api`, `ls -la` (a real listing with
  `Makefile`, `README.md`, `config`, `src`), `git status -sb` (branch line, `metrics.go`
  untracked, `queue.go` modified), `git log --oneline -3` (three real commit subjects),
  `cat config/api.yaml` (five lines of YAML, syntax-coloured by the server's own tooling),
  `uptime` (a load average). The accessory key row sits above the keyboard on iPhone.
* **Caption:** `True colour. A real PTY. Output as the server sent it.`
* **What the viewer should understand:** the terminal is the product, not a text view
  bolted to a socket. Colour is right, alignment is right, and the output is a real
  machine's, not a recording of one.
* **How to produce it:** the command sequence and the strings to wait on are exactly
  `RebuildCaptureTests.test01Terminal` — `cd services/api` awaiting `api$`, `ls -la`
  awaiting `Makefile`, `git status -sb` awaiting `metrics.go`, `git log --oneline -3`
  awaiting `initial service`, `cat config/api.yaml` awaiting `workers`, `uptime` awaiting
  `load average`. Type them from a hardware keyboard attached to the simulator so the
  software keyboard does not cover the grid, or type into the app and let the software
  keyboard show — but pick one and keep it for the whole shot.
* **Notes:** the fixture sets `core.pager cat`, so `git log` prints into the main screen and
  stays visible. That is deliberate and must not be undone: with a pager, the output leaves
  with the alternate screen and the shot has nothing in it.

## Shot 3 — two terminals, one screen

* **Number:** 3
* **Duration:** 3.5 s (8.0 → 11.5)
* **On screen — iPad:** the `edge-01` session with `tail -f logs/health.log` running in it.
  The session menu opens, **Split Right** is chosen, the target picker appears, `db-primary`
  is picked, and the screen becomes two live panes with the divider between them. The left
  pane keeps printing while the right one connects and reaches its own prompt. The divider is
  dragged a short distance and both panes reflow.
* **On screen — iPhone:** the connection list with three live sessions under **Open
  sessions** — `edge-01`, `db-primary`, `build-runner`. Two taps switch between two of them,
  and each returns to its own scrollback exactly as it was left.
* **Caption:** `Split a pane. Two full sessions, each with its own controls.` (iPad)
  · `Several live sessions. Typing follows the one you are looking at.` (iPhone)
* **What the viewer should understand:** an iPad is a workstation here, not a phone with a
  larger screen; and on a phone, several sessions are a real thing rather than a tab bar
  that reconnects.
* **How to produce it:** iPad — `terminal-menu` → `terminal-menu-split-right`, then the
  `split-target-picker` and the `host-row` beginning `db-primary`, as
  `RebuildCaptureTests.test03Panes` does. Wait until two `terminal-grid` elements exist
  before recording the divider drag. iPhone — open `edge-01`, `db-primary` and
  `build-runner` in turn, run `uptime` in each, return to the list, then switch.
* **Notes:** this is the one shot that is a **different subject** per device rather than the
  same footage in a different shape, matching the screenshot plan. Do not scale the iPad
  split into the iPhone file.

## Shot 4 — the server's files

* **Number:** 4
* **Duration:** 3.5 s (11.5 → 15.0)
* **On screen:** the file browser opened from the `edge-01` connection's own menu. The
  breadcrumb reads `/home/deploy`, the rows show real names, sizes, dates and permission
  strings. A tap into `services`, a tap into `api`, and the listing becomes the project
  directory — `Makefile`, `README.md`, `config`, `src`. A short scroll shows the rows are
  live, not a picture.
* **Caption:** `Your server's files, over the same connection.`
* **What the viewer should understand:** transferring a file is not a second app and not a
  second login. It is the connection they already have.
* **How to produce it:** long-press the `host-row` for `edge-01`, choose `host-files`, wait
  for the first `file-row`, then `services` → `api`, exactly as
  `RebuildCaptureTests.test04Files` does. Let the listing settle before the cut so no row is
  mid-fade.
* **Notes:** the Files-app half of claim C4 is **not** shown. A recording of Apple's Files
  app is a recording of Apple's Files app, and guideline 2.3.3 asks for this app in use. The
  Files-app capability is described in the store description instead.

## Shot 5 — a tunnel with numbers on it

* **Number:** 5
* **Duration:** 4.0 s (15.0 → 19.0)
* **On screen:** the port forwards screen for the `edge-01` session, one saved rule listed —
  a local forward to the service inside the server. **Start** is tapped. The row changes to
  running. Then traffic goes through it and the byte and connection counters on the row
  climb, visibly, while the shot is held.
* **Caption:** `Forwards saved with a connection. Live bytes, live connections.`
* **What the viewer should understand:** a tunnel here is a managed object with a state and
  a meter, not a command line they retype and then hope about.
* **How to produce it:** `terminal-menu` → `terminal-menu-forwards` → `start-port-forward`
  on the saved rule. Then drive real traffic through it the way
  `RebuildCaptureTests.test05Forwards` does: open the seeded connection named
  `edge-01 via tunnel`, whose address is the forward's own listening port on the device, so
  that opening it is a genuine SSH session carried by the tunnel. Return to the forwards
  screen **through the open-session row**, not by tapping the connection again — tapping the
  connection opens a second session, and a forward belongs to the session it was started
  from, so the new one would show the rule stopped.
* **Notes:** the counters must be non-zero and must be seen to change within the shot. A
  still number is a screenshot; this shot exists because the number moves. If the numbers
  are not moving on the take, the traffic did not go through the tunnel — fix that rather
  than cutting around it.

## Shot 6 — detach, come back, still there

* **Number:** 6
* **Duration:** 4.5 s (19.0 → 23.5)
* **On screen:** the `ops-box` connection opens straight into an attached tmux session —
  tmux's own toolbar appears with it, and tmux's arrangement is drawn rather than scraped. A
  command runs in the active pane. tmux's own **Split Right** makes a second pane, and the
  second pane starts its own work. Then the session is left: back to the connection list,
  one beat there, and the same connection is opened again — and both panes come back with
  their output already on screen, not replayed and not re-run.
* **Caption:** `tmux control mode. Detach, come back, the panes are where you left them.`
* **What the viewer should understand:** the phone or iPad is a second seat at a long job.
  Closing the app is not the same as killing the work.
* **How to produce it:** open the `ops-box` connection (`ST_UITEST_TMUX_*` in the capture
  harness points it at the tmux container on port 2203). Wait for `tmux-menu`. Tap a
  `tmux-pane-*`, type a command. `tmux-menu` → `tmux-split-right`, wait until two
  `tmux-pane-*` elements exist — the same sequence as `RebuildCaptureTests.test06Tmux`. Then
  navigate back to the list and reopen the connection, and hold the shot on the restored
  panes for at least a second.
* **Notes:** say *tmux control mode*. Do not caption this as a session that never dies, or as
  staying connected in the background — neither is a claim this project makes, and the second
  is one iOS would not honour.

## Shot 7 — the machine's own desktop

* **Number:** 7
* **Duration:** 2.5 s (23.5 → 26.0)
* **On screen:** the saved screen for `edge-01` opens and the remote desktop draws in — a
  real X session with a terminal window running a live process monitor, its bars and figures
  updating. A one-finger pan moves the view, and the on-screen modifier row for the remote
  keyboard is visible along the edge.
* **Caption:** `A remote desktop, through the same SSH connection.`
* **What the viewer should understand:** breadth. The app is a terminal and a file browser
  and a tunnel manager and this, on one connection, with nothing published to the internet
  to make it work.
* **How to produce it:** tap the `screen-row` for the seeded screen. Wait for `vnc-screen`
  to exist **and** `vnc-connecting` to be gone, then hold two or three seconds more so the
  first incremental updates land — a frame taken earlier is a black rectangle with a spinner
  on it. This is what `RebuildCaptureTests.waitForDesktop` waits for.
* **Notes:** the desktop's VNC server listens on the container's loopback address only, and
  the app reaches it through a channel on the SSH connection. That is the whole point of the
  shot, and it is why the caption says *through the same SSH connection*. Nothing may be
  captioned about signing in to a Mac's screen sharing.

## Shot 8 — a key that cannot leave

* **Number:** 8
* **Duration:** 3.0 s (26.0 → 29.0)
* **On screen:** the key list in Settings. The add-key sheet, **Generate**, a name typed in,
  and the storage choice moved to the Secure Enclave. **Generate** is tapped, and the new
  key appears in the list with its real SHA-256 fingerprint and the enclave badge beside it.
  The final second holds still on that row.
* **Caption:** `Generated in the Secure Enclave. The private half never leaves the device —
  and it logs in to an ordinary OpenSSH server.`
* **What the viewer should understand:** the strongest reason to keep working this way. Not
  "the key file is encrypted" — there is no key file.
* **How to produce it:** `settings-open` → `settings-keys` → `add-key` → `generate-key` →
  type the name into `key-name` → `key-storage-enclave` → `key-generate` → `key-dismiss`,
  the sequence `RebuildCaptureTests.generateKey` performs. Use a fictional key name; `On
  call` is the one the stills use.
* **Notes:** the simulator's Secure Enclave is a software emulation. The key, the
  fingerprint and the badge are all real app behaviour and are what is on screen; the
  hardware property belongs in the description, and the caption above claims only what the
  app does. Nothing in this shot may suggest sync, backup to another device, or a second
  factor.

---

## Caption rules

* Two lines maximum, set in the same face as the screenshot template, over a plain ground
  with the app's own frame beneath it. No animated text, no motion typography.
* Each caption is on screen for its shot's length less 0.3 s at each end, so it lands after
  the cut and leaves before the next one.
* No exclamation marks. No superlatives. No competitor named. No number that is not
  measured.
* The captions are English because the app in this recording is in English. The
  Simplified Chinese preview is a separate recording with the app in Chinese, scripted in
  [`APP_PREVIEW_SCRIPT_ZH_HANS.md`](APP_PREVIEW_SCRIPT_ZH_HANS.md). Terminal output stays as
  the server sent it, in English, in every localization, because that is what the server
  sent.
* Traditional Chinese is out of scope for this file and its companion; it is recorded from
  the same shot list with the app in `zh-Hant`, and its captions are written where the
  `zh-Hant` metadata is written.

## What may not appear in any frame

Anything not marked Verified in the claims matrix. In particular, no frame may show or
imply: a second factor generated by the app, sync between devices, a session held open in
the background, Chinese, Japanese or Korean typed into the terminal, a Mac or a Vision Pro,
an account or a sign-up, a price or a purchase, a real person's data, a real host name, a
real address, or any address that is not loopback.
