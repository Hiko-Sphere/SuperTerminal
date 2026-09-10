# Apex Terminal — App Store and launch material, rebuilt 2026-09-10

Everything needed to publish **Apex Terminal**: 72 store screenshots in three languages,
the listing in three languages, website copy, social and launch posts, a press kit, a
feature catalogue, and the automation that regenerates the images from the running app.

Built from scratch against the app as it stands, not edited from the previous set. The
old material is untouched in `Marketing/AppStore/`; what happened to each piece of it is in
[`audit/LEGACY_ASSET_AUDIT.md`](audit/LEGACY_ASSET_AUDIT.md).

## Start here

| If you want to… | Read |
| --- | --- |
| upload to App Store Connect | [`app-store/metadata/`](app-store/metadata/) and [`app-store/screenshots/`](app-store/screenshots/) |
| know whether a claim is allowed | [`audit/CLAIMS_MATRIX.md`](audit/CLAIMS_MATRIX.md) |
| know what the product actually does | [`audit/PRODUCT_TRUTH_MATRIX.md`](audit/PRODUCT_TRUTH_MATRIX.md) |
| write anything new | [`strategy/MESSAGING_SYSTEM.md`](strategy/MESSAGING_SYSTEM.md) |
| regenerate the images | [`CAPTURE_GUIDE.md`](CAPTURE_GUIDE.md) |
| find a file | [`ASSET_INDEX.md`](ASSET_INDEX.md) |
| know what is still blocked | [`FINAL_VERIFICATION_REPORT.md`](FINAL_VERIFICATION_REPORT.md) |

## The rule everything follows

A capability may be advertised only at the strength the truth matrix allows. That matrix
was built by opening the source and the test for each of 201 capabilities — not by reading
the project's own prose, which in three places cites test suites that do not exist.

**99 capabilities are Verified.** Only those appear in a screenshot or a headline. The
rest are disclosed to App Review, as guideline 2.3.1 requires, and named in the catalogue
with what would unblock them.

The largest consequence: **Cloudflare appears in no public claim.** It is implemented and
carefully written, but no connection has ever been made through a live Cloudflare account,
and the entire authentication half of that module has no test. The reasoning is in
[`strategy/POSITIONING.md`](strategy/POSITIONING.md) §6; the wording that becomes available
the day it is verified is written and waiting in
[`feature-catalog/CLOUDFLARE_OVERVIEW.md`](feature-catalog/CLOUDFLARE_OVERVIEW.md).

## Regenerating everything

```bash
Marketing/Rebuild-2026-09-10/automation/capture.sh                                    # ~50 min
swift Marketing/Rebuild-2026-09-10/automation/Render.swift Marketing/Rebuild-2026-09-10
python3 Marketing/Rebuild-2026-09-10/automation/write_manifest.py
python3 Marketing/Rebuild-2026-09-10/automation/write_asset_index.py
python3 Marketing/Rebuild-2026-09-10/automation/validate.py
```

`capture.sh` builds the app, starts four OpenSSH servers in containers, boots three
simulators, and drives the real interface through eight states in each of three languages.
Every session in the output is a real key exchange with a real `sshd`; every file listing is
a real SFTP listing; the port forward carries a real SSH session of its own, which is why
its counters show real numbers; the tmux panes belong to a real tmux server; the desktop is
a real X session decoded from real RFB.

What is invented is only the identity: the account is `deploy`, the machines are `edge-01`,
`db-primary`, `build-runner` and `ops-box`, and their addresses are under `*.localhost`,
reserved by RFC 6761.

## The layout

```
Rebuild-2026-09-10/
├── audit/            truth matrix, claims matrix, competitor analysis, legacy audit
├── strategy/         positioning, messaging system, audience matrix
├── app-store/        metadata (3 languages), screenshots (72), raw captures,
│                     contact sheets, preview-video scripts, SCREENSHOT_MANIFEST.json
├── website/          information architecture + copy in 3 languages
├── social/           evergreen posts and the launch-day set
├── press-kit/        release, kit, media kit, FAQ
├── feature-catalog/  feature catalogue, security overview, internal comparisons
├── automation/       capture, render, validate, manifest and index generators
├── CAPTURE_GUIDE.md
├── ASSET_INDEX.md
└── FINAL_VERIFICATION_REPORT.md
```

## Sizes

| Slot | Pixels | Captured natively on |
| --- | --- | --- |
| iPhone 6.9" | 1320 × 2868 | iPhone 17 Pro Max |
| iPhone 6.5" | 1284 × 2778 | iPhone 14 Plus |
| iPad 13" | 2732 × 2048, landscape | iPad Air 13-inch (M4) |

Nothing is scaled into a slot — 1320 × 2868 and 1284 × 2778 are different shapes, so each
is captured on hardware that produces it. `validate.py` recomputes each capture's aspect
ratio from the placement the renderer recorded and fails on any mismatch beyond 0.5%.

## What the automation refuses to do

* Render a caption that overflows its layout — it aborts and names the file.
* Pass validation on images older than the captures they came from.
* Let a forbidden claim into a published field, while still allowing a document to *quote*
  one in order to forbid it.
* Ship an image with an alpha channel, a wrong size, or an anisotropic scale.

## Still blocked

Four things stop this being submittable, and none is a marketing task: the support,
marketing and privacy URLs are not live; the in-app legal texts still carry placeholders;
the export-compliance question is the submitter's to answer; and there is no distribution
certificate. Each is listed with what unblocks it in
[`FINAL_VERIFICATION_REPORT.md`](FINAL_VERIFICATION_REPORT.md).
