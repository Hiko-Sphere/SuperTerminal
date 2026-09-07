# App Store assets

Everything needed to put ApexTerminal on the App Store: the screenshots, the copy in two
languages, the audit that decides what may be claimed, and the scripts that regenerate all
of it from scratch.

**Nothing here is a mock-up.** Every screenshot is the app from a real build, driven
through its own interface by an XCUITest, connected to real OpenSSH servers. There is no
drawn interface, no composited terminal output, no replayed session and no image that was
retouched after it was taken.

## Regenerate everything

```bash
Marketing/AppStore/scripts/capture.sh && \
Marketing/AppStore/scripts/render.sh && \
Marketing/AppStore/scripts/validate.sh
```

That builds the app, starts three containerised OpenSSH servers, boots the two simulators,
captures 10 raw screens on each of four passes (two devices × two languages), lays the
published six out on the store canvas, records what came from which build, and then checks
the result against Apple's rules and this project's own.

Prerequisites: Xcode 26.6 with the iOS 26.5 simulator runtime, and Docker running.

| Variable | Default | What it changes |
| --- | --- | --- |
| `ST_SHOT_IPHONE` | `iPhone 17 Pro Max` | The 6.9" device. Must produce an accepted size natively |
| `ST_SHOT_IPAD` | `iPad Air 13-inch (M4)` | The 13" device. The Air rather than the Pro so a second `xcodebuild test` on this machine does not fight it for the accessibility server |
| `ST_SHOT_LOCALES` | `en-US zh-Hans` | Which localizations to capture |
| `ST_SHOT_THEME` | `midnight` | The terminal theme the app is set to for the run |

To re-capture a single screen while iterating:

```bash
Marketing/AppStore/scripts/capture.sh test04Vim
```

## What is in here

```
Marketing/AppStore/
├── README.md                    this file
├── FEATURE_AUDIT.md             what may be claimed, and the evidence for each claim
├── SCREENSHOT_PLAN.md           the six images, their captions, and how each is reached
├── APPLE_REQUIREMENTS.md        Apple's current rules, checked against Apple's own pages
├── CAPTURE_MANIFEST.json        which build, commit and device each image came from
├── copy/
│   ├── en-US.md                 App Store fields, features, privacy, captions
│   ├── zh-Hans.md               the same, written in Chinese rather than translated
│   ├── FEATURE_OVERVIEW.md      a product introduction for a site or a release post
│   ├── app-review-notes.en-US.md   the block to paste into App Review Information
│   └── app-review-notes.zh-Hans.md the same content for the project's own review
├── raw/{iphone,ipad}/{en-US,zh-Hans}/    untouched captures, 10 per pass
├── final/{en-US,zh-Hans}/{iphone-6.9,ipad-13}/   the 6 images to upload, in order
├── preview/                     contact sheets, for looking at the set as a set
├── build/                       logs, result bundles, the run's throwaway SSH key
└── scripts/
    ├── capture.sh               build → fixtures → simulators → XCUITest → raw/
    ├── render.sh                raw/ → final/ + preview/ + CAPTURE_MANIFEST.json
    ├── validate.sh              sizes, alpha, field limits, forbidden claims, secrets
    ├── Render.swift             the canvas: CoreGraphics and CoreText, deterministic
    ├── shotlist.json            which shots are published, in order, with captions
    ├── collect_attachments.py   pulls the screenshots out of the .xcresult
    ├── write_manifest.py        records build, commit, device and evidence per image
    ├── validate.py              the checks
    └── fixture/                 the Dockerfile for the SSH servers the shots are taken against
```

`build/` and `raw/` are inputs to the final files, not deliverables; the files to upload
are the twenty-four PNGs under `final/`.

## How the screenshots are real

The capture test is `AppUITests/MarketingCaptureTests.swift`. It is skipped unless
`ST_CAPTURE=1`, so an ordinary `xcodebuild test` never runs it, and it does nothing an
ordinary user could not do: it taps rows, types into the terminal, opens Settings and
generates keys.

What it types goes to three containers built by `scripts/fixture/`, each running
`openssh-server` from Alpine with:

* an invented, unprivileged account — **`deploy`**;
* an invented machine name — **`edge-01`**, **`db-primary`**, **`build-runner`**;
* addresses under **`*.localhost`**, which RFC 6761 reserves and the host resolves to the
  loopback address, so no public address and no real domain can reach an image;
* a home directory of invented files: a small Go service, a git history with three commits
  by an invented author at `example.invalid`, and a three-line notes file.

Every fingerprint in the host-key screenshot is the fingerprint of a key that container
really presented. Every byte of terminal output came back over a real SSH connection. The
two keys in the keys screenshot were generated during the run, by the app, through the
sheet a user would use.

Nothing belonging to the person who ran the capture — no user name, no host name, no
command history, no key — can appear, and `scripts/validate.py` scans the copy for private
keys, tokens, JWTs and email addresses on every run.

The status bar is pinned to 9:41 with full Wi-Fi and no carrier, the way Apple's own
material sets it. One thing does not take: `simctl status_bar override --batteryState
discharging` is honoured on the iPhone runtime and ignored on the iPad one, so the iPad
images show the simulator's real battery indicator, which reads as charging. It is left
as it is. Editing a pixel of a screenshot to tidy that up would undo the only thing that
makes this set worth anything.

## Before uploading, check the manifest's commit

`CAPTURE_MANIFEST.json` records the commit and the working-tree state the images were
captured from, because a screenshot is only accurate about the build it came from. If the
app has moved on in a way that changes any of the six screens — the terminal, the
connection list, the host-key sheet, the keys screen, a full-screen program, the find bar —
re-run `capture.sh` before submitting. Changes elsewhere in the app do not invalidate these
images, and the manifest is what lets that judgement be made rather than guessed.

## What is deliberately not claimed

The one thing this listing stays silent about is the project's headline differentiator:
**SSH through a Cloudflare Tunnel to a host behind Cloudflare Access**. The protocol is
implemented and is tested against a local server that reproduces the edge, but no
connection has ever been made through a live Cloudflare account —
`PROJECT_STATUS.md` **B-2**. So:

* there is no Cloudflare screenshot, and in particular no login page shown as a success;
* the word appears in no shipped field — name, subtitle, description, keywords,
  promotional text or caption;
* `validate.sh` fails if it reappears in the copy;
* the App Review notes disclose that the capability is in the binary, as guideline 2.3.1
  requires, and say it is not being claimed.

Remote screens over VNC, the assistant, sync and Shortcuts are excluded for the same
reason and are listed with their evidence in [`FEATURE_AUDIT.md`](FEATURE_AUDIT.md) §6.
What would unblock Cloudflare is in §9 of the same file.

## Nothing here uploads anything

None of these scripts talk to App Store Connect. They produce files on this machine, for a
person to look at and then upload deliberately.
