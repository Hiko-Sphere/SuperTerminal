# Legacy asset audit — what happened to the 2026-08/09 material

**Written:** 2026-09-10 · **Subject:** everything under `Marketing/AppStore/`

The previous set was made against commit `cb16521`, when the product was called
SuperTerminal and had six advertisable screens. Since then the app has been renamed to
**Apex Terminal**, and D-045 through D-072 added SFTP and a file browser, a Files.app
extension, port forwarding, tmux control mode, split panes, sixel and the other graphics
protocols, shell integration, the font system, certificates, agent forwarding, Secure
Enclave keys, backup and restore, and Mac Catalyst.

**Nothing has been deleted.** `Marketing/AppStore/` is untouched and remains the record of
what was shipped then. This file says, for each part of it, what was re-checked and what
the verdict was.

## Verdicts used

| Verdict | Meaning |
| --- | --- |
| **Keep** | Still correct against the current build; carried forward or still usable as-is |
| **Rewrite** | The subject survives, the text does not |
| **Replace** | Superseded by a new artefact that does the same job better |
| **Archive** | Correct when made, kept for the record, not for use |
| **Invalid** | Wrong against the current build; must not be used |
| **Contains Unverified Claim** | Asserts something the truth matrix does not support |

---

## Images

| Asset | Verdict | What was re-checked, and the finding |
| --- | --- | --- |
| `final/en-US/**` (18) | **Invalid** | Every one draws the connection list, whose title is the app's name. They read **SuperTerminal**. Re-rendering cannot fix them: the name is inside the captured app pixels, not the canvas. Replaced by `app-store/screenshots/en-US/**` (24). |
| `final/zh-Hans/**` (18) | **Invalid** | Same cause. Replaced by `app-store/screenshots/zh-Hans/**` (24). |
| `raw/iphone/**`, `raw/iphone65/**`, `raw/ipad/**` (60) | **Archive** | Genuine captures of the app as it was on 2026-09-08. Kept as evidence of that build; unusable now for the same naming reason, and they predate every feature added since. |
| `preview/*-contact-sheet.png` (8) | **Archive** | Accurate sheets of an invalid set. |
| zh-Hant images | *(absent)* | The old set had two languages. The app ships three. This is a gap the rebuild closes rather than a defect in the old work. |

**Six subjects, re-judged.** The old plan's screens were terminal, sessions, host-key,
keys, vim, find.

| Old screen | Verdict | Reasoning |
| --- | --- | --- |
| `01-terminal` | **Keep the subject, rewrite the caption** | Still shot 1. The caption now names true colour and the alternate screen instead of "scrollback". |
| `02-sessions` | **Rewrite** | Survives as shot 3, but only on iPhone: the iPad now shows split panes, which did not exist then. |
| `03-host-key` | **Replace** | A strong security screen, but the Secure Enclave key is a stronger one and the two would compete. Host-key verification moved to the description and to `SECURITY_OVERVIEW.md`. |
| `04-keys` | **Rewrite** | Still shot 7, now showing an enclave key with its badge — the claim it can carry is much stronger than it was. |
| `05-vim` | **Replace** | Full-screen programs are proven, but a vim buffer is a weaker use of a slot than the file browser or the forwards list. Folded into shot 1's caption. |
| `06-find` | **Replace** | Real and Verified, and a lesser reason to buy than tmux or tunnels. Retained in the feature catalogue. |

## Copy

| Asset | Verdict | What was re-checked, and the finding |
| --- | --- | --- |
| `copy/en-US.md` | **Invalid** | Named the app SuperTerminal throughout. Its feature list also predates SFTP, forwarding, tmux, panes and enclave keys, so it undersells the current build badly. Replaced by `app-store/metadata/APP_STORE_METADATA_EN.md`. |
| `copy/zh-Hans.md` | **Invalid** | Same. Replaced. |
| `copy/app-review-notes.en-US.md` | **Rewrite** | The *structure* was right and is carried forward — what the app is, how to test it, permissions, what is in the binary but unadvertised, privacy, content. The content is rewritten: it disclosed four withheld features, and there are now seven. |
| `copy/app-review-notes.zh-Hans.md` | **Rewrite** | Same; the new one is a checking aid rather than a submission, which the old one also said. |
| `copy/FEATURE_OVERVIEW.md` | **Replace** | Superseded by `feature-catalog/FEATURE_CATALOG.md`, which carries evidence and a screenshot reference per feature. |

## Documents

| Asset | Verdict | What was re-checked, and the finding |
| --- | --- | --- |
| `FEATURE_AUDIT.md` | **Archive** | Honest for its build and its method was right. Superseded by `audit/PRODUCT_TRUTH_MATRIX.md`, which covers 201 capabilities against 40-odd and is generated rather than hand-written. |
| `APPLE_REQUIREMENTS.md` | **Keep, with a correction carried forward** | Its screenshot sizes were re-checked against Apple's page on 2026-09-10 and are still right, including the 6.5-inch addition made on 2026-09-08. The rebuild cites it rather than duplicating it. Its metadata field limits were re-verified and are unchanged. |
| `SCREENSHOT_PLAN.md` | **Replace** | Six screens for a product that now has eight worth showing. |
| `README.md` | **Replace** | Describes a pipeline that produces the invalid set. |
| `CAPTURE_MANIFEST.json` | **Archive** | Accurately records where each old image came from. That is exactly why it is kept. |

## Automation

The old scripts still run and still produce the old set. They are **kept working** rather
than migrated, so the record stays reproducible; the rebuild has its own copies under
`Marketing/Rebuild-2026-09-10/automation/`.

| Asset | Verdict | What was re-checked, and the finding |
| --- | --- | --- |
| `scripts/capture.sh` | **Keep (superseded)** | Runs. Renamed identifiers are current. The rebuild's version starts four servers instead of three and adds a desktop, tmux and a forward target. |
| `scripts/Render.swift` | **Keep (superseded)** | Runs. One layout, scaled between devices — which is the thing the new design brief forbids, so the rebuild has a two-layout renderer. |
| `scripts/validate.py` | **Keep (superseded)** | Runs. The rebuild's version adds a third slot, an anisotropic-scale check against recorded placements, a secret scan and a Chinese punctuation check — and is more precise about quoted prohibitions. |
| `scripts/collect_attachments.py` | **Keep — shared** | Used unchanged by both pipelines, including its landscape rotation. The only file genuinely common to both. |
| `scripts/fixture/**` | **Keep (superseded)** | The three-container fixture still builds. The rebuild's fixture adds the SFTP subsystem — **which the old one lacked**, so the old pipeline could never have photographed a file browser. |
| `scripts/shotlist.json`, `render.sh`, `validate.sh`, `write_manifest.py` | **Keep (superseded)** | Unchanged and still functional for the old set. |
| `.DS_Store` | **Invalid** | Should not be in the repository. Left alone rather than deleted, because this rebuild does not touch the old tree. |

## Two things the old set got right, and the rebuild kept

Not everything was rewritten. Rewriting what is already correct, to look thorough, is its
own kind of dishonesty.

1. **The capture method.** Driving the real app through XCUITest against real servers in
   containers, with fictional identities under RFC 6761 `*.localhost`, and exporting
   attachments — that was right, and the rebuild extends it rather than replacing it.
2. **The Cloudflare decision.** The old set withheld it for exactly the reason the new one
   does. The audit re-checked the position from scratch on 2026-09-10 by running
   `LiveCloudflareE2ETests` and watching it skip, and reached the same verdict — and found
   additionally that the entire authentication half of that module has no test at all.

## One thing it got wrong that was worth finding

The old `FEATURE_AUDIT.md` marked several capabilities advertisable on the strength of the
project's own documents. Three of those documents — `docs/RELEASE_EVIDENCE.md`,
`docs/CLOUDFLARE.md` and a comment in `CarrierIntegrationTests.swift` — refer to test
suites that **do not exist**. The rebuild's method, opening the cited test before accepting
a claim, is what caught it. That is recorded in
[`PRODUCT_TRUTH_MATRIX.md`](PRODUCT_TRUTH_MATRIX.md) under the Cloudflare area.
