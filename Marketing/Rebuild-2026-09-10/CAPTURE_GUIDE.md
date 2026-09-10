# Capture guide — how the screenshots are made, and how to make them again

**Written:** 2026-09-10

Everything in `app-store/screenshots/` is a photograph of the real app doing real work.
This document is how to reproduce it, and — more usefully — what goes wrong and why.

## The one-line version

```bash
Marketing/Rebuild-2026-09-10/automation/capture.sh \
  && swift Marketing/Rebuild-2026-09-10/automation/Render.swift Marketing/Rebuild-2026-09-10 \
  && python3 Marketing/Rebuild-2026-09-10/automation/validate.py
```

Roughly 55 minutes: nine capture passes, then a render, then the checks.

## What is required

| | |
| --- | --- |
| macOS | 26.5 or later |
| Xcode | 26.6 or later, with the iOS 26.5 simulator runtime |
| Docker | running — the four servers are containers |
| Simulators | iPhone 17 Pro Max, iPad Air 13-inch (M4). The iPhone 14 Plus is **created by the script** if absent |
| Disk | about 2 GB for the result bundles under `automation/build/` |

Nothing else. No account, no network beyond pulling the Alpine base image once.

## What it does, in order

1. **Builds the app** for the simulator (`build-for-testing`).
2. **Builds one fixture image** and starts four containers from it:

   | Container | Address | What it runs |
   | --- | --- | --- |
   | `cap-edge-01` | `edge-01.localhost:22` | sshd + the SFTP subsystem, a real X desktop on `:5901`, an HTTP service on `:8080` |
   | `cap-db-primary` | `db-primary.localhost:2201` | sshd |
   | `cap-build-runner` | `build-runner.localhost:2202` | sshd |
   | `cap-ops-box` | `ops-box.localhost:2203` | sshd + tmux |

3. **Prepares each simulator**: boots it, uninstalls any previous build, forces the light
   interface, pins the status bar to 9:41 with a full battery and no carrier, and marks
   the keyboard tutorials as already seen.
4. **Runs `RebuildCaptureTests`** — eight captures, driving the real interface.
5. **Exports the attachments** to `app-store/raw-screenshots/<device>/<locale>/`, rotating
   the iPad's a lossless quarter-turn.
6. Repeats for three devices × three locales.

## What is real, and what is invented

**Real:** every SSH session (a real key exchange with a real `sshd`), every file listing (a
real SFTP listing), the port forward (which carries a real SSH session of its own, so its
counters are real numbers), the tmux panes (a real tmux server, over its own control
protocol), and the desktop (a real X session decoded from real RFB).

**Invented:** the identities only. The account is `deploy`, the machines are `edge-01`,
`db-primary`, `build-runner` and `ops-box`, their addresses are under `*.localhost`
(reserved by RFC 6761), and every file in the home directory was written for this purpose.
Nothing belonging to the person running the capture can reach an image.

**Never:** a mocked server, a stubbed result, a screenshot-only code path, a fabricated
success state, or an interface element drawn on top of a capture.

## Things that went wrong, and the fix

Kept because each one cost time to find and would cost it again.

| Symptom | Cause | Fix |
| --- | --- | --- |
| The file browser opened and listed nothing | Alpine ships `sftp-server` **separately** from `openssh-server` | `apk add openssh-sftp-server` |
| The terminal never printed a prompt | `*.localhost` resolves to `::1` as well as `127.0.0.1`, and a v6-only publish gap makes the first attempt hang instead of failing over | Publish on both stacks |
| `git log` produced nothing on screen | Git paged into `less`, which holds output on the alternate screen where a screenshot cannot see it | `git config --global core.pager cat` in the fixture |
| A tmux connection "never connected" | tmux draws its own view; `terminal-grid` never appears | Accept either `terminal-grid` or tmux's own toolbar as arrival |
| The desktop was a black rectangle with a spinner | The VNC view exists the moment the screen opens, long before a framebuffer arrives | Wait for the **connecting indicator to go away**, not for the view to exist |
| The desktop connected and then showed nothing at all | The app's RFB client stalls against **TigerVNC's Xvnc** — the server accepts and then exchanges zero framebuffer updates | Serve the same X display through **x11vnc**, which is built on LibVNCServer, the implementation the app's own VNC suite is tested against. Worth a bug report; not something a capture should be blocked on |
| A keyboard tutorial card covered the app | A freshly created simulator has never dismissed iOS's "slide to type" introduction | Set the `com.apple.keyboard.preferences` flags before launch |
| The forward showed "Start" and zero counters | Returning via the *connection* row opens a **second** session, and a forward belongs to the session that started it | Return via the "Open sessions" row |
| `test07Security` failed on iPad in Chinese but passed in English | The scroll helper only searched downward, and on a sheet a row's centre can sit under the navigation bar while `isHittable` still says yes. Row heights differ by language | Search both directions and require the centre to clear the bar |
| The script aborted after one pass | macOS ships bash 3.2, where an empty array under `set -u` is an unbound variable | Spell the branch out instead of expanding an array |

## Running part of it

```bash
# One language, all three devices
ST_SHOT_LOCALES="zh-Hant" Marketing/Rebuild-2026-09-10/automation/capture.sh

# One capture, everywhere — note this WIPES the other seven in each raw directory,
# because a pass clears its own output before it writes
Marketing/Rebuild-2026-09-10/automation/capture.sh test05Forwards
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `ST_SHOT_LOCALES` | `en-US zh-Hans zh-Hant` | Which localisations to capture |
| `ST_SHOT_IPHONE69` | `iPhone 17 Pro Max` | The 6.9" device |
| `ST_SHOT_IPHONE65` | `iPhone 14 Plus` | The 6.5" device; created if absent |
| `ST_SHOT_IPAD` | `iPad Air 13-inch (M4)` | The 13" device |
| `ST_SHOT_THEME` | `midnight` | The terminal theme, set through the app's own preference |

## When the app changes

A screenshot is only accurate for the build it came from, and Apple requires it to reflect
the current version (2.3). Re-capture when any of these move:

* the connection list, terminal, file browser, forwards, tmux, keys or screen views;
* the app's name or icon;
* `MARKETING_VERSION`;
* any string in a language being shipped.

`app-store/SCREENSHOT_MANIFEST.json` records the commit and build each image came from, so
a stale set can be recognised rather than guessed at.

## The changes this needed in the app

Small, additive, and none of it changes shipped behaviour.

* **Accessibility identifiers.** `settings-open`, `settings-keys`, `add-key`,
  `generate-key`, `key-name`, `key-generate`, `key-dismiss`, `key-storage-keychain`,
  `key-storage-enclave`, `prompt-trust`, `prompt-howto`, and four on the terminal's
  Session menu. Identifiers only — no layout, no behaviour.
* **`UITestSeeding`** (already `#if DEBUG`) gained optional display-name overrides and a
  terminal-theme preference, so a capture does not photograph a row called "Test Screen".

Both are compiled out of Release. `RebuildCaptureTests` skips unless `ST_REBUILD_CAPTURE=1`,
so an ordinary `xcodebuild test` never runs it.

## Cleaning up

`capture.sh` removes its containers on exit, including on failure. If a run was killed
harder than that:

```bash
docker rm -f cap-edge-01 cap-db-primary cap-build-runner cap-ops-box
```

The generated SSH key lives in `automation/build/shots_key`, is made fresh each run, and is
git-ignored. It authorises nothing but those four throwaway containers.
