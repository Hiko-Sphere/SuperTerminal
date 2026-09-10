# App preview — storyboard, recording checklist and encode

**Written:** 2026-09-10 · **Spec:** [`APP_PREVIEW_SPEC.md`](APP_PREVIEW_SPEC.md) ·
**Scripts:** [`APP_PREVIEW_SCRIPT_EN.md`](APP_PREVIEW_SCRIPT_EN.md) ·
[`APP_PREVIEW_SCRIPT_ZH_HANS.md`](APP_PREVIEW_SCRIPT_ZH_HANS.md)

---

## 0 · Status, stated plainly

**The video has not been produced.** No frame of it has been recorded, and nothing in
`preview-video/` is a rendered file. This document, the spec and the two scripts are the
complete instructions for producing it; they are not a record of it having been produced.

What is missing is not a decision — every decision is made below — but the run itself. It
needs a machine with the simulators installed, a container runtime, roughly forty minutes of
someone driving the app by hand, and the encode. §7 is the checklist for that person, in
order, with the commands.

Nothing in this file may be quoted as though the video exists. When it does exist, the
person who produced it records the date and the ffprobe output of each delivered file in §9,
and only then is this line replaced.

---

## 1 · The timeline

29.0 seconds. All timestamps are in seconds from the first frame of the delivered file, at
30 fps constant, so frame *n* is at *n* ÷ 30.

| # | Start | End | Length | Frames | Shot | On screen at the cut in | On screen at the cut out |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 0.000 | 3.500 | 3.500 | 0 – 104 | Open a saved connection | The connection list, at rest | The prompt `deploy@edge-01:~$`, settled |
| 2 | 3.500 | 8.000 | 4.500 | 105 – 239 | The shell doing real work | `cd services/api` being typed | `uptime` output, load average visible |
| 3 | 8.000 | 11.500 | 3.500 | 240 – 344 | Split a pane (iPad) / several sessions (iPhone) | The single session, `tail -f` running | Two live panes, divider settled |
| 4 | 11.500 | 15.000 | 3.500 | 345 – 449 | The server's files | The connection's context menu open | The `services/api` listing, still |
| 5 | 15.000 | 19.000 | 4.000 | 450 – 569 | A port forward with live counters | The forwards list, rule stopped | Counters non-zero and still climbing |
| 6 | 19.000 | 23.500 | 4.500 | 570 – 704 | tmux — detach and reattach | tmux's toolbar appearing on attach | Both panes restored, output intact |
| 7 | 23.500 | 26.000 | 2.500 | 705 – 779 | The remote desktop | The desktop's first full frame | The desktop after a short pan |
| 8 | 26.000 | 29.000 | 3.000 | 780 – 869 | The Secure Enclave key | The add-key sheet | The key row, fingerprint and badge, held |

Total: 870 frames, 29.000 s.

### 1.1 · Frame-by-frame within each shot

Each shot is cut so that the meaningful event sits in the middle third and both ends are
still. A cut on motion reads as a glitch at this length.

| # | 0 → +0.4 s | middle | last 0.6 s |
| --- | --- | --- | --- |
| 1 | The list at rest, four connections legible | Tap on `edge-01`, push transition, connecting indicator for ~0.5 s | The prompt on screen, nothing moving |
| 2 | First command already being typed | Five commands and their output, no dead air over 0.4 s | `uptime`'s line, cursor blinking |
| 3 | The single session, log printing | Menu → Split Right → target picker → second pane connects | Both panes live, divider just released |
| 4 | Context menu open on the connection | Browse Files, first listing, tap into `services`, then `api` | The project listing, no row mid-fade |
| 5 | The rule listed, stopped | Start tapped, state changes, traffic begins | Counters climbing, visibly, at the cut |
| 6 | tmux's toolbar arriving | A command in one pane, tmux's own split, second pane working | Back to the list, reopen, panes restored |
| 7 | The first complete framebuffer | A one-finger pan; the process monitor updating | The desktop still, monitor still moving |
| 8 | The add-key sheet | Name, enclave chosen, Generate, the new row appears | The key row alone on screen, held still |

---

## 2 · Captions — in and out points

Each caption fades in 0.3 s after its shot's cut in and fades out 0.3 s before its cut out.
The fade itself is 0.2 s at each end and is included in those windows, so the caption is
fully opaque for the shot's length less 1.0 s.

| # | Caption in | Caption out | On screen | EN text | ZH-Hans text |
| --- | --- | --- | --- | --- | --- |
| 1 | 0.300 | 3.200 | 2.900 s | A saved connection, and a real shell. | 一个保存好的连接，一个真正的 shell。 |
| 2 | 3.800 | 7.700 | 3.900 s | True colour. A real PTY. Output as the server sent it. | 真彩色，真实 PTY，输出就是服务器发来的样子。 |
| 3 | 8.300 | 11.200 | 2.900 s | Split a pane. Two full sessions, each with its own controls. *(iPad)* · Several live sessions. Typing follows the one you are looking at. *(iPhone)* | 分屏，两个完整会话，各有各的控制。*(iPad)* · 同时开着几个会话，输入跟着你正在看的那个。*(iPhone)* |
| 4 | 11.800 | 14.700 | 2.900 s | Your server's files, over the same connection. | 服务器上的文件，走的是同一条连接。 |
| 5 | 15.300 | 18.700 | 3.400 s | Forwards saved with a connection. Live bytes, live connections. | 转发随连接保存，字节数和连接数实时在跳。 |
| 6 | 19.300 | 23.200 | 3.900 s | tmux control mode. Detach, come back, the panes are where you left them. | tmux 控制模式。断开再回来，窗格还在原处。 |
| 7 | 23.800 | 25.700 | 1.900 s | A remote desktop, through the same SSH connection. | 远程桌面，走的是同一条 SSH 连接。 |
| 8 | 26.300 | 28.700 | 2.400 s | Generated in the Secure Enclave. The private half never leaves the device — and it logs in to an ordinary OpenSSH server. | 在 Secure Enclave 里生成，私钥不离开这台设备——照样登录标准 OpenSSH 服务器。 |

Caption 8 is the longest line in the film and has the shortest window for its length. Set it
in two lines and check it can be read at 2.4 s by someone who has not read it before; if it
cannot, shorten the second half rather than lengthening the shot, because the 29.0 s total
is what keeps the file inside Apple's ceiling.

No caption is on screen at 0.000, at 29.000, or across a cut. There is no title card and no
end card: guideline 2.3.3 asks for the app in use, and a card is not the app.

---

## 3 · Transitions

Seven transitions, and one rule behind all of them: **the app's own motion is the
transition wherever the app provides one.**

| Between | Transition | Length | Why |
| --- | --- | --- | --- |
| 1 → 2 | None — a straight cut inside one continuous take | 0 | Shots 1 and 2 are the same recording; the "cut" is only a caption change |
| 2 → 3 | Straight cut | 0 | Different take, same screen; a dissolve here would look like a rendering error |
| 3 → 4 | Cross dissolve | 6 frames (0.200 s) | Different part of the app; the dissolve says "and also this" |
| 4 → 5 | Cross dissolve | 6 frames | As above |
| 5 → 6 | Cross dissolve | 6 frames | As above |
| 6 → 7 | Cross dissolve | 6 frames | As above |
| 7 → 8 | Cross dissolve | 12 frames (0.400 s) | The one deliberate breath in the film, before the closing claim |

Dissolves are centred on the timestamps in §1 — a 6-frame dissolve at 15.000 s runs from
14.900 s to 15.100 s — so the timeline arithmetic is unaffected.

No wipes, no push, no zoom, no speed ramp, no added camera move. Where the app pushes a view
in, that push is in the recording and is left alone.

---

## 4 · Sound

One stereo AAC track, 256 kbps, 48 kHz, enabled, for the whole 29.0 s. Either silence
encoded to that specification, or licensed music encoded to that specification. There is no
voice-over: no narrator, no read script, no spoken word anywhere in the file. No interface
sounds and no keyboard clicks — the simulator recording is silent at source and the encode
does not add anything.

If music is used, the licence must cover commercial distribution in an App Store preview and
must be filed with the delivered files. No track is named in this document, and none should
be chosen without that licence in hand.

---

## 5 · The poster frame

**Chosen: t = 5.000 s.** That frame falls inside shot 2, roughly a second and a half into
the shell sequence: the terminal filling the frame, `ls -la` output above and `git status -sb`
either printing or just printed, with the caption *True colour. A real PTY. Output as the
server sent it.* fully opaque.

Four reasons, in order of weight:

1. **It reads at thumbnail size.** A store visitor decides in about three seconds, and a
   dense, correctly coloured terminal says *professional SSH client* at any size. The
   connection list does not — a list of four rows is legible but generic, and it is what
   every app in this category would show.
2. **It agrees with the screenshot set.** Screenshot 1 is a live shell for the same reason
   ([`../SCREENSHOT_PLAN.md`](../SCREENSHOT_PLAN.md) §1). A poster frame that matches the
   first still makes the product page read as one thing rather than two.
3. **It is a still frame that is still.** Nothing in it is mid-transition, mid-scroll or
   mid-fade. A poster frame taken during motion is a blurred poster frame forever.
4. **It is Apple's own default.** App Store Connect selects the 5-second mark unless the
   submitter moves it. Choosing the frame that is already there means one less thing that can
   silently revert, and the edit is built so that the default is the right answer rather than
   the edit being built and the default then worked around.

Rejected alternatives, recorded so the choice is not relitigated: the Secure Enclave key row
at 28.5 s is the strongest *claim* but the weakest *picture* — a settings row does not read
at thumbnail size; the two-pane iPad frame at 11.0 s is handsome but is meaningless on the
iPhone slots and would make the three files inconsistent; the desktop at 25.0 s is the least
representative frame in the film, since the app is a terminal first.

The same timestamp is used for all three device families and all three localizations.

---

## 6 · What to record on

The same three simulators the stills come from, on the same runtime, so that previews and
screenshots on the product page are the same device families
([`APP_PREVIEW_SPEC.md`](APP_PREVIEW_SPEC.md) §4).

| Slot | Simulator | `capture.sh` variable | Native recording | Orientation |
| --- | --- | --- | --- | --- |
| iPhone 6.9" | iPhone 17 Pro Max | `ST_SHOT_IPHONE69` | 1320 × 2868 | portrait |
| iPhone 6.5" | iPhone 14 Plus | `ST_SHOT_IPHONE65` | 1284 × 2778 | portrait |
| iPad 13" | iPad Air 13-inch (M4) | `ST_SHOT_IPAD` | 2732 × 2048 | landscape |

Runtime: `com.apple.CoreSimulator.SimRuntime.iOS-26-5` (`ST_SHOT_RUNTIME`). The iPhone 14
Plus is not part of a default Xcode install; `capture.sh` creates it if it is missing, and
so should the person recording.

Find a UDID with the same query `capture.sh` uses:

```sh
xcrun simctl list devices available | grep -E 'iPhone 17 Pro Max|iPhone 14 Plus|iPad Air 13-inch'
```

Prepare each device exactly as the stills are prepared, so the status bar and appearance
match:

```sh
UDID=<the udid>
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode notSupported --batteryState discharging --batteryLevel 100
```

The keyboard tutorial cards ("slide to type…") land on top of the app on a simulator that
has never shown them, and they will land in the middle of a take. Suppress them the way
`capture.sh` does:

```sh
for key in DidShowContinuousPathIntroduction DidShowGestureKeyboardIntroduction \
           KeyboardDidShowProductivityTutorial DidShowGestureKeyboardIntroductionOnPad; do
  xcrun simctl spawn "$UDID" defaults write com.apple.keyboard.preferences "$key" -bool true
done
xcrun simctl spawn "$UDID" defaults write com.apple.Preferences \
  UIKeyboardDidShowInternationalInfoIntroduction -bool true
```

---

## 7 · The recording checklist, in order

### 7.1 · Start the servers

`Marketing/Rebuild-2026-09-10/automation/capture.sh` starts the same four containers this
film needs — `cap-edge-01`, `cap-db-primary`, `cap-build-runner` and `cap-ops-box`, all built
from `automation/fixture/` — and `edge-01` additionally runs the desktop on 5901 and the HTTP
service on 8080 that the forward points at.

One thing to know before relying on it: `capture.sh` installs `trap 'cleanup_containers' EXIT`
and removes all four containers when it finishes. That is right for an unattended screenshot
run and wrong for a recording session, where the containers must outlive the script. So a
recording session starts them itself, with the same commands `capture.sh` uses:

```sh
ROOT=/Users/<you>/repo/superterminal
OUT="$ROOT/Marketing/Rebuild-2026-09-10"
WORK="$OUT/automation/build"; mkdir -p "$WORK"
IMAGE=apexterminal-capture:2
PASSWORD=capture-only-pw

docker build -t "$IMAGE" "$OUT/automation/fixture"

rm -f "$WORK/shots_key" "$WORK/shots_key.pub"
ssh-keygen -t ed25519 -f "$WORK/shots_key" -N '' -q -C apexterminal-capture
KEY="$(cat "$WORK/shots_key.pub")"

for n in cap-edge-01 cap-db-primary cap-build-runner cap-ops-box; do docker rm -f "$n" 2>/dev/null; done
docker run -d --name cap-edge-01      --hostname edge-01      -e WITH_DESKTOP=1 -e DEPLOY_PASSWORD="$PASSWORD" \
  -p 127.0.0.1:22:22   -p '[::1]:22:22'   -e AUTHORIZED_KEY="$KEY" "$IMAGE"
docker run -d --name cap-db-primary   --hostname db-primary   -e DEPLOY_PASSWORD="$PASSWORD" \
  -p 127.0.0.1:2201:22 -p '[::1]:2201:22' -e AUTHORIZED_KEY="$KEY" "$IMAGE"
docker run -d --name cap-build-runner --hostname build-runner -e DEPLOY_PASSWORD="$PASSWORD" \
  -p 127.0.0.1:2202:22 -p '[::1]:2202:22' -e AUTHORIZED_KEY="$KEY" "$IMAGE"
docker run -d --name cap-ops-box      --hostname ops-box      -e DEPLOY_PASSWORD="$PASSWORD" \
  -p 127.0.0.1:2203:22 -p '[::1]:2203:22' -e AUTHORIZED_KEY="$KEY" "$IMAGE"
```

Both stacks are published on purpose: `*.localhost` resolves to `::1` as well as to
`127.0.0.1`, and a gap on one of them makes the app's first attempt hang rather than fail
over. Every address here is loopback; nothing is reachable from outside the machine.

Wait until each answers before recording anything:

```sh
for port in 22 2201 2202 2203; do
  ssh -i "$WORK/shots_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -p "$port" deploy@127.0.0.1 true && echo "$port ok"
done
```

Tear them down when the whole session is finished, not between takes:

```sh
for n in cap-edge-01 cap-db-primary cap-build-runner cap-ops-box; do docker rm -f "$n"; done
```

### 7.2 · Put the app on the simulator with its connections in place

Build and install the app, then set up the connection list. Two routes, and the choice is
worth making deliberately:

* **By hand.** Add four connections in the app: `edge-01` at `edge-01.localhost:22`,
  `db-primary` at `db-primary.localhost:2201`, `build-runner` at `build-runner.localhost:2202`,
  `ops-box` at `ops-box.localhost:2203`, all as user `deploy` with the fixture password
  `capture-only-pw`. Then add: a saved local forward on `edge-01` pointing at the container's
  own `8080`; a fifth connection named `edge-01 via tunnel` addressed at that forward's
  listening port on the device, which is what makes shot 5's counters real; a saved screen on
  `edge-01` for the desktop on `5901`; and tmux turned on for `ops-box`. This is the route
  that produces a recording of the app as a customer would have set it up, and it is the
  recommended one.
* **Through the harness.** The `ST_UITEST_*` launch environment in `capture.sh` seeds all of
  the above, but it is read only when the app is launched by the UI test runner, and that
  runner drives the app itself. It is useful for confirming the fixture is healthy before a
  hand-driven session; it is not a way to record one.

Whichever route, check before recording: every host key is already trusted (a first-connection
prompt mid-take is a lost take), the terminal theme is the one the stills use
(`ST_SHOT_THEME`, default `midnight`), and the app's language matches the localization being
recorded.

### 7.3 · Record

Record each shot as its own file, longer than it needs to be at both ends, and cut it down
later. One long take that has to be perfect is a take that will be repeated twenty times.

```sh
xcrun simctl io <udid> recordVideo --codec h264 --mask ignored shot-01.mp4
```

Stop with Control-C. `--mask ignored` keeps the full rectangle rather than rounding the
corners or punching out the sensor housing, which is what the App Store expects.

Filenames, one directory per slot and locale — for example
`raw/iphone69/en-US/shot-01.mp4` through `shot-08.mp4`.

| Shot | Record until | The take is good when |
| --- | --- | --- |
| 1 | 2 s after the prompt settles | The connecting indicator is visible and brief; the prompt is `deploy@edge-01:~$` |
| 2 | 2 s after `uptime` prints | All six commands ran; no output is cut off at the top; nothing is mid-scroll at the end |
| 3 | 2 s after the divider is released | Two `terminal-grid` panes are live at once; the left pane is still printing |
| 4 | 2 s after the `api` listing settles | Real sizes, dates and permission strings are legible; no row is mid-fade |
| 5 | 4 s after traffic starts | The byte and connection counters are non-zero **and** change during the take |
| 6 | 2 s after the reattach | Both panes come back with their previous output already on screen |
| 7 | 4 s after the first full frame | No spinner, no black rectangle; the process monitor is updating |
| 8 | 2 s after the key row appears | A real `SHA256:` fingerprint and the enclave badge are legible |

Re-record rather than repair. Every one of the eight conditions above is a property of the
app doing its work; none of them may be produced in an editor.

### 7.4 · Assemble

Cut to the timeline in §1, apply the transitions in §3, add the captions at the in and out
points in §2. Then encode once, from the assembled edit, to each slot's target size.

iPhone 6.9" — 1320 × 2868 source, 886 × 1920 target:

```sh
ffmpeg -i edit-iphone69-en-US.mov \
  -vf "scale=886:-2:flags=lanczos,crop=886:1920" \
  -r 30 -c:v libx264 -profile:v high -level:v 4.0 -pix_fmt yuv420p \
  -b:v 11M -maxrate 12M -bufsize 24M \
  -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 -shortest \
  -c:a aac -b:a 256k -ar 48000 -ac 2 \
  -movflags +faststart preview-iphone69-en-US.mp4
```

iPhone 6.5" — 1284 × 2778 source, 886 × 1920 target. Only the filter changes:

```sh
  -vf "scale=-2:1920:flags=lanczos,crop=886:1920"
```

iPad 13" — 2732 × 2048 source, 1600 × 1200 target:

```sh
  -vf "scale=-2:1200:flags=lanczos,crop=1600:1200"
```

The `anullsrc` input is the silent stereo track. If licensed music is used, replace that
input with the audio file and drop `anullsrc`; keep every other flag as it is.

Nine files: three slots × `en-US`, `zh-Hans`, `zh-Hant`.

### 7.5 · Verify every delivered file

Do not eyeball this. Read it off the file.

```sh
# Duration — must be 15.000 to 30.000, and this project targets 29.0
ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 preview-iphone69-en-US.mp4

# Resolution, frame rate, codec, profile, level
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,r_frame_rate,avg_frame_rate,codec_name,profile,level,pix_fmt,bit_rate \
  -of default=nw=1 preview-iphone69-en-US.mp4

# Audio — stereo AAC, 48 kHz, 256 kbps, one enabled track
ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,channels,channel_layout,sample_rate,bit_rate \
  -of default=nw=1 preview-iphone69-en-US.mp4

# File size — must be under 500 MB
ls -lh preview-iphone69-en-US.mp4
```

What each must say:

| Field | iPhone 6.9" / 6.5" | iPad 13" |
| --- | --- | --- |
| `format=duration` | ≈ 29.0 (and between 15 and 30) | ≈ 29.0 |
| `width` × `height` | 886 × 1920 | 1600 × 1200 |
| `r_frame_rate` / `avg_frame_rate` | `30/1` | `30/1` |
| `codec_name` | `h264` | `h264` |
| `profile` / `level` | `High` / `40` | `High` / `40` |
| `pix_fmt` | `yuv420p` | `yuv420p` |
| video `bit_rate` | 10 000 000 – 12 000 000 | 10 000 000 – 12 000 000 |
| audio `codec_name` | `aac` | `aac` |
| `channels` / `channel_layout` | `2` / `stereo` | `2` / `stereo` |
| audio `sample_rate` | `48000` | `48000` |
| size | well under 500 MB | well under 500 MB |

`level` is reported as an integer: `40` is Level 4.0. If a file reports `41` or higher, the
bit rate or the resolution went past what was asked for; re-encode rather than uploading it.

Last, look at the poster frame itself before uploading, so the store's thumbnail is not a
surprise:

```sh
ffmpeg -ss 5.0 -i preview-iphone69-en-US.mp4 -frames:v 1 poster-check-iphone69-en-US.png
```

### 7.6 · Upload

Upload each file to its own device family and localization in App Store Connect. Confirm the
poster frame is on the 5-second mark for every one of the nine; App Store Connect's default
puts it there, but confirm rather than assume. Then check the product page preview: previews
and screenshots must be the same three device families, or the page will show a preview
scaled from a family that was not recorded.

---

## 8 · What must be true of the finished file

A checklist for whoever signs off, phrased so each line can be answered yes or no by looking:

1. Every second of it is a screen recording of the running app. No card, no composite, no
   redrawn interface.
2. Every capability shown is Verified in
   [`../../audit/CLAIMS_MATRIX.md`](../../audit/CLAIMS_MATRIX.md).
3. No caption contains a superlative, a competitor's name, an exclamation mark, or a number
   that was not measured.
4. Nothing claims a second factor generated by the app, sync between devices, staying
   connected in the background, typing Chinese, Japanese or Korean into the terminal, or
   running on Mac or Vision Pro.
5. Every host name is fictional and every address is loopback. No real person's data, no real
   machine, no address that anyone outside the recording machine could reach.
6. There is no voice-over. If there is music, its licence is filed with the file.
7. The duration, resolution, frame rate, codec, profile, level and audio all match §7.5, read
   off the file with ffprobe.
8. It is obvious with the sound off what the app does.

---

## 9 · Production record

Filled in by the person who produces the video, not before.

| File | Recorded on | Duration | Resolution | Frame rate | ffprobe checked |
| --- | --- | --- | --- | --- | --- |
| `preview-iphone69-en-US.mp4` | not produced | — | — | — | — |
| `preview-iphone65-en-US.mp4` | not produced | — | — | — | — |
| `preview-ipad-en-US.mp4` | not produced | — | — | — | — |
| `preview-iphone69-zh-Hans.mp4` | not produced | — | — | — | — |
| `preview-iphone65-zh-Hans.mp4` | not produced | — | — | — | — |
| `preview-ipad-zh-Hans.mp4` | not produced | — | — | — | — |
| `preview-iphone69-zh-Hant.mp4` | not produced | — | — | — | — |
| `preview-iphone65-zh-Hant.mp4` | not produced | — | — | — | — |
| `preview-ipad-zh-Hant.mp4` | not produced | — | — | — | — |
