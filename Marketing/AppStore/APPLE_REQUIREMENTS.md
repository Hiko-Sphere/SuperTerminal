# Apple's requirements, as they stand today

Checked against Apple's own pages on **2026-09-06**. Every number below was read off the
source named beside it, not from memory. Re-check before each submission: Apple changes
these without notice, and a stale number here is a rejection there.

## Sources

| What | Where |
| --- | --- |
| Screenshot sizes, counts, formats | [App Store Connect Help — Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/) |
| Accurate Metadata, screenshots, names | [App Review Guidelines § 2.3](https://developer.apple.com/app-store/review/guidelines/) |
| Third-party intellectual property | [App Review Guidelines § 5.2.1](https://developer.apple.com/app-store/review/guidelines/) |
| Metadata field limits | App Store Connect's own field counters, cross-checked against published references (see "Field limits" below) |

## Screenshots

**Count.** 1 to 10 per display size, per localization.

**iPhone 6.9-inch display** — required for iPhone apps.

| Orientation | Accepted pixel sizes |
| --- | --- |
| Portrait | 1260 × 2736 · 1290 × 2796 · **1320 × 2868** |
| Landscape | 2736 × 1260 · 2796 × 1290 · 2868 × 1320 |

**iPhone 6.5-inch display.** App Store Connect still presents this slot, and it accepts a
6.7-inch image in it. When the slot is the one being filled, its own error message names
the sizes it will take:

| Orientation | Accepted pixel sizes |
| --- | --- |
| Portrait | 1242 × 2688 · **1284 × 2778** |
| Landscape | 2688 × 1242 · 2778 × 1284 |

A 6.9-inch capture cannot be resized into this slot: 1320 × 2868 is 0.4603 : 1 and
1284 × 2778 is 0.4622 : 1, so reaching one from the other means stretching one axis more
than the other. The set is captured again on a device that produces 1284 × 2778 natively
instead.

**iPad 13-inch display** — required for iPad apps.

| Orientation | Accepted pixel sizes |
| --- | --- |
| Portrait | **2064 × 2752** · 2048 × 2732 |
| Landscape | 2752 × 2064 · **2732 × 2048** |

**Format.** `.png`, `.jpg` or `.jpeg`.

**Transparency.** Apple's page states it plainly: *"Images can't include alpha channels or
transparencies."* Every file this project exports is therefore 8-bit RGB with no alpha,
and `scripts/validate.sh` fails the build if one slips through.

### What this project uses, and why

The sizes in bold are what the simulators used here produce **natively**, at 1:1 with
no resampling:

| Device | `xcrun simctl io … screenshot` output | Apple size it matches |
| --- | --- | --- |
| iPhone 17 Pro Max (iOS 26.5) | 1320 × 2868 | iPhone 6.9" portrait |
| iPhone 14 Plus (iOS 26.5) | 1284 × 2778 | iPhone 6.5" slot, portrait |
| iPad Air 13-inch (M4) (iOS 26.5) | 2048 × 2732 | iPad 13" portrait |
| iPad Air 13-inch (M4), landscape | 2732 × 2048 | iPad 13" landscape |

Choosing a size the hardware does not produce would mean scaling a screenshot to reach it,
and a rescaled screenshot of a terminal is a blurred screenshot of a terminal — the text is
the product. Nothing here is stretched: the app's own pixels are composited into a canvas
of exactly the size above.

## Accurate Metadata — the rules this project is bound by

**2.3.** Metadata — description, screenshots, previews, privacy information — must
accurately reflect the app's core experience and stay current with each version.

**2.3.1.** No hidden or undocumented features. Every new feature must be described
specifically in the Notes for Review; a generic note is grounds for rejection. No
misleading marketing — no promoting content or services the app does not offer.

**2.3.3.** *Screenshots must show the app in use* — not title art, not a login page, not a
splash screen. Text and image overlays are allowed.

**2.3.7.** App name at most 30 characters. Keywords must accurately describe the app.
No trademarked terms, other apps' names, pricing, or irrelevant phrases stuffed in to game
search. Subtitles must make only **verifiable** claims.

**2.3.8.** Icons, screenshots and previews must suit a 4+ audience regardless of the app's
own rating.

**5.2.1.** No third-party trademarks or copyrighted material without permission, and
nothing that implies an affiliation that does not exist.

### How each rule is honoured here

| Rule | What was done |
| --- | --- |
| 2.3 / 2.3.1 | Every claim is traced to running code and a passing test in [`FEATURE_AUDIT.md`](FEATURE_AUDIT.md). Anything not proven end to end is marked *not advertisable* and appears nowhere in the copy, the keywords or the screenshots. |
| 2.3.3 | Every screenshot is a real capture of the running app, mid-session, against a real OpenSSH server. No mock-ups, no redrawn interfaces, no composited fake output. The capture script is in `scripts/capture.sh` and is repeatable. |
| 2.3.7 | Name 25 characters (`Apex Terminal: SSH Client`), subtitle 25; keywords carry no competitor names, no trademarks, no prices. Claims in the subtitle are ones a reviewer can reproduce in the app. |
| 2.3.8 | Nothing beyond a terminal, a connection list and a settings form appears in any image. |
| 5.2.1 | No Cloudflare logo, no third-party marks, no Apple hardware imagery, no App Store badges. The word "Cloudflare" is absent from the shipped copy — see [`FEATURE_AUDIT.md`](FEATURE_AUDIT.md) for why. |

## Field limits

Counted by `scripts/validate.sh` on the actual files, so a copy edit cannot quietly break
one.

| Field | Limit | Counted as |
| --- | --- | --- |
| App Name | 30 | characters |
| Subtitle | 30 | characters |
| Promotional Text | 170 | characters |
| Description | 4 000 | characters |
| Keywords | 100 | bytes (UTF-8) — a Chinese keyword costs three, not one |
| What's New | 4 000 | characters |

Sources for the numbers, cross-checked 2026-09-06:
[AppStyle](https://www.appstyle.dev/blog/app-store-character-limits/) ·
[AppLaunchFlow](https://www.applaunchflow.com/blog/app-store-metadata-character-limits-2026) ·
[AppConnectTranslate](https://www.appconnecttranslate.com/tools/app-store-character-limits/).
App Store Connect's own field counters are authoritative; these agree with them, and the
validator leaves headroom rather than sitting on the boundary.

Keywords are counted in **bytes** here rather than characters. Apple's field is documented
as 100 characters, but the safe reading for a non-Latin localization is bytes, and the
Simplified Chinese keyword list is built to fit either way.

## Localizations

Screenshots are per display size **and** per localization. A localization with no
screenshots of its own falls back to the primary language's. This project ships a distinct
set for each of the two languages it publishes — `en-US` and `zh-Hans` — because the
caption text on every image is part of the image.

Both localizations carry the **same number of screenshots in the same order**, so the two
store listings tell the same story; `scripts/validate.sh` asserts that.

## What is deliberately absent

* **No price, no discount, no "Free"** anywhere in an image (2.3.7 forbids pricing in
  metadata used for search, and a price in an image goes stale the day it changes).
* **No App Store badge, no other platform's logo, no device bezel art.**
* **No third-party logo of any kind**, Cloudflare's included.
* **No superlatives that cannot be tested** — no "fastest", no "most secure", no "zero
  latency", no "never drops". Where a number appears in the copy it is one that was
  measured, and the measurement is named in `FEATURE_AUDIT.md`.
