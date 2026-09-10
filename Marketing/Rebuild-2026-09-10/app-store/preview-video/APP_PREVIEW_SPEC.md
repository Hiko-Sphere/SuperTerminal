# App preview — the specification this project targets

**Written:** 2026-09-10 · **Gated by:** [`../../audit/CLAIMS_MATRIX.md`](../../audit/CLAIMS_MATRIX.md) ·
**Companion to:** [`../SCREENSHOT_PLAN.md`](../SCREENSHOT_PLAN.md)

Every number below was read off Apple's own page on the date named beside it. Nothing here
is recalled. Apple changes these without notice, so the check is repeated before each
submission and the date in this file is moved forward only when the page has actually been
re-read.

---

## 1 · Sources, and the date each was read

| What | Where | Read on |
| --- | --- | --- |
| Duration, resolutions, codec, bit rate, frame rate, audio, file size, poster frame, count | [App Store Connect Help — App preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-preview-specifications/) | 2026-09-10 |
| The same table under its second path, used to confirm the first reading | [App Store Connect Help — App information — App preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/) | 2026-09-10 |
| Screenshot sizes, for the device families this set must agree with | [App Store Connect Help — Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/) | 2026-09-06, recorded in [`../../../AppStore/APPLE_REQUIREMENTS.md`](../../../AppStore/APPLE_REQUIREMENTS.md) |

Both preview pages were read separately and returned the same figures. Where they agree,
the figure is written below once.

---

## 2 · What Apple accepts, verbatim in substance

Source: App Store Connect Help — App preview specifications. Read 2026-09-10.

### 2.1 · Length

| Property | Value |
| --- | --- |
| Minimum length | **15 seconds** |
| Maximum length | **30 seconds** |

A preview shorter than 15 seconds or longer than 30 seconds is rejected at upload. There is
no tolerance stated on either side of that range, so this project treats both ends as hard.

### 2.2 · File and container

| Property | Value |
| --- | --- |
| Maximum file size | **500 MB** |
| Accepted formats | **H.264** and **ProRes 422 (HQ only)** |
| Extensions — H.264 | `.mov`, `.m4v`, `.mp4` |
| Extensions — ProRes 422 (HQ) | `.mov` |

### 2.3 · Video

| Property | H.264 | ProRes 422 (HQ only) |
| --- | --- | --- |
| Target bit rate | **10–12 Mbps** | VBR, approximately **220 Mbps** |
| Video characteristics | Progressive, up to **High Profile Level 4.0** | Progressive, no external references |
| Maximum frame rate | **30 fps** | **30 fps** |

30 fps is a ceiling, not a target. A simulator recording can arrive above it, so the encode
step below pins the output to a constant 30 fps rather than passing the source rate through.

### 2.4 · Audio

| Property | H.264 | ProRes 422 (HQ only) |
| --- | --- | --- |
| Configuration | **Stereo** | **Stereo** |
| Codec | **256 kbps AAC** | PCM, or **256 kbps AAC** |
| Sample rate | **44.1 kHz or 48 kHz** | **44.1 kHz or 48 kHz** |
| PCM bit depth | — | 16-, 24- or 32-bit |
| Tracks | All tracks should be enabled | All tracks should be enabled |

Apple's page states what an audio track must look like. It does not state that a preview
must carry one. This project does not rely on that reading either way: the delivered file
always carries a stereo AAC track at 256 kbps, 48 kHz — silence encoded to specification if
no music is licensed, licensed music encoded to the same specification if one is. That
removes the question from the submission entirely.

### 2.5 · Poster frame

| Property | Value |
| --- | --- |
| Default poster frame | **5 seconds** |

The poster frame is the still the App Store shows before the preview plays. App Store
Connect selects the frame at the 5-second mark by default and lets the submitter move it to
any other frame of the same preview. It is not a separate image upload, and it cannot be a
frame that is not in the video — so the frame the store will show has to be *earned* by the
edit. The choice this project makes, and why, is in
[`APP_PREVIEW_STORYBOARD.md`](APP_PREVIEW_STORYBOARD.md) §5.

### 2.6 · How many, and orientation

| Property | Value |
| --- | --- |
| Number of previews | **Up to 3 per device family**, per localization |
| Orientation | Portrait or landscape (macOS and tvOS accept landscape only) |

Apple's page also notes that where previews at the accepted resolutions are not supplied for
a family, the store scales a preview down from a larger family. This project does not use
that: each family is recorded on hardware that produces its own shape (§4).

### 2.7 · Accepted resolutions, all families

Reproduced in full so that a future reader can see what was on the page, not only the rows
this project uses.

| Family | Portrait | Landscape |
| --- | --- | --- |
| iPhone 6.9" | 886 × 1920 | 1920 × 886 |
| iPhone 6.5" | 886 × 1920 | 1920 × 886 |
| iPhone 6.3" | 886 × 1920 | 1920 × 886 |
| iPhone 6.1" | 886 × 1920 | 1920 × 886 |
| iPhone 5.5" | 1080 × 1920 | 1920 × 1080 |
| iPhone 4.7" | 750 × 1334 | 1334 × 750 |
| iPhone 4" | 1080 × 1920 | 1920 × 1080 |
| iPad 13" | 1200 × 1600 | 1600 × 1200 |
| iPad 11" | 1200 × 1600 | 1600 × 1200 |
| iPad 10.5" | 1200 × 1600 | 1600 × 1200 |
| iPad 9.7" | 900 × 1200 | 1200 × 900 |
| Mac | — | 1920 × 1080 |
| Apple TV | — | 1920 × 1080 |
| Apple Vision Pro | — | 3840 × 2160 |

The Mac, Apple TV and Apple Vision Pro rows are recorded here for completeness of the
reading. This app is submitted for iPhone and iPad only, and none of those three rows is
filled.

---

## 3 · What this project will target

One preview per device family, per localization. Apple allows three; one is what there is
material for, and a second built from the same footage would be padding.

| Slot | Delivered file | Pixels | Orientation |
| --- | --- | --- | --- |
| iPhone 6.9" | `preview-iphone69-<locale>.mp4` | **886 × 1920** | portrait |
| iPhone 6.5" | `preview-iphone65-<locale>.mp4` | **886 × 1920** | portrait |
| iPad 13" | `preview-ipad-<locale>.mp4` | **1600 × 1200** | landscape |

| Property | Target |
| --- | --- |
| Container | `.mp4` |
| Video codec | H.264, High Profile, Level 4.0, progressive, `yuv420p` |
| Bit rate | 11 Mbps average, 12 Mbps ceiling — inside Apple's 10–12 Mbps band |
| Frame rate | constant 30 fps |
| Duration | **29.0 s** — inside the 15–30 s range with a second of headroom under the ceiling |
| Audio | AAC, stereo, 256 kbps, 48 kHz, one enabled track |
| Poster frame | t = 5.000 s (see the storyboard, §5) |
| Localizations | `en-US`, `zh-Hans`, `zh-Hant` |
| Files | 3 slots × 3 localizations = **9 files** |

29.0 s is chosen rather than 30.0 s deliberately. Container duration and the sum of the
edit's clip lengths can differ by a frame or two after an encode, and a file that rounds to
30.03 s is a rejected upload for no reason worth having.

---

## 4 · The device families must be the ones the screenshots already use

The screenshot set is captured for iPhone 6.9" at 1320 × 2868, iPhone 6.5" at 1284 × 2778
and iPad 13" at 2732 × 2048 landscape
([`../SCREENSHOT_PLAN.md`](../SCREENSHOT_PLAN.md) — *Sizes*). The previews fill **the same
three families**, on **the same three simulators**, so that a store page never shows a
preview from one device family sitting above screenshots from another.

The pixel counts differ, and that is Apple's doing rather than an inconsistency: App Store
Connect asks for a smaller video than it asks for a still, for the same family.

| Family | Screenshot pixels | Preview pixels | Recording device |
| --- | --- | --- | --- |
| iPhone 6.9" | 1320 × 2868 | 886 × 1920 | iPhone 17 Pro Max |
| iPhone 6.5" | 1284 × 2778 | 886 × 1920 | iPhone 14 Plus |
| iPad 13" | 2732 × 2048 | 1600 × 1200 | iPad Air 13-inch (M4) |

The three simulator names are the same ones `automation/capture.sh` uses for the stills
(`ST_SHOT_IPHONE69`, `ST_SHOT_IPHONE65`, `ST_SHOT_IPAD`), on the same runtime.

### 4.1 · Getting from a recording to an accepted size, honestly

`xcrun simctl io … recordVideo` writes the simulator's native pixels. None of the three
native shapes is exactly Apple's preview shape, so each needs one resize and, in two cases,
a crop of a few pixels. The rule applied is the same in all three cases: **scale until both
axes are at least the target, then centre-crop to the target.** Nothing is stretched on one
axis more than the other, because a stretched terminal is a terminal whose text is wrong.

| Family | Native | Native ratio | Target ratio | Scale to | Then crop | Pixels discarded |
| --- | --- | --- | --- | --- | --- | --- |
| iPhone 6.9" | 1320 × 2868 | 0.46025 | 0.46146 | 886 × 1926 | 886 × 1920 | 6 rows, 0.31 % of height |
| iPhone 6.5" | 1284 × 2778 | 0.46220 | 0.46146 | 888 × 1920 | 886 × 1920 | 2 columns, 0.23 % of width |
| iPad 13" | 2732 × 2048 | 1.33398 | 1.33333 | 1600 × 1200 | 1600 × 1200 | none |

The crops are centred, and each removes less than a third of one percent of one axis. What
is lost is background, never a caption and never a line of terminal text — checked on the
finished file, not assumed.

Both preview dimensions in every row are even numbers, which H.264 with `yuv420p` requires.

---

## 5 · Rules the content is bound by, not only the container

These are the same rules the stills are bound by, and they are restated here because a video
gives more room to break them.

1. Only capabilities marked **Verified** in
   [`../../audit/CLAIMS_MATRIX.md`](../../audit/CLAIMS_MATRIX.md) may appear. A capability
   that is implemented but unverified does not go on screen, however well it demonstrates.
2. **SSH client, never server.** Every command in the preview runs on a server the customer
   owns. The fixture makes this literal: the servers are containers, the account is
   fictional, the addresses are loopback.
3. No superlatives. No competitor named. No user counts, ratings, awards or rankings.
4. No claim of two-factor authentication built in, of sync between devices, of staying
   connected in the background, of typing Chinese, Japanese or Korean into the terminal, or
   of running on Mac or Vision Pro.
5. No exclamation marks in any caption, in any language.
6. Guideline 2.3.3 — the preview must show the app in use. Every frame is a screen recording
   of the running app. No title card built in a design tool, no compositing, no screen
   redrawn for the camera.
7. Guideline 2.3 — the preview must stay accurate to the shipping version. When the
   interface in a shot changes, the shot is re-recorded rather than re-captioned.

---

## 6 · Re-checking this file

Before each submission: open both URLs in §1, read the tables, and compare them line by line
against §2. If anything has moved, change §2 first, then §3, then the storyboard's encode
commands, then re-encode. Do not change the date at the top of this file unless the pages
were actually re-read on that date.
