# Screenshot visual system

**Written:** 2026-09-10 · Implemented by [`../automation/Render.swift`](../automation/Render.swift)

A new template. The 2026-08 set stacked a caption above a capture and used the same
portrait layout on both devices, scaled. This one has **two layouts**, because a phone and
a 13-inch landscape iPad are not the same picture at different sizes.

## Principles

1. **The app is the subject.** The capture gets the majority of the canvas. Everything else
   is a caption.
2. **Line, not decoration.** One hairline rule. No shadow, no gradient, no glow, no 3-D, no
   device bezel art, no floating UI fragments.
3. **One idea per image.** A title, a subtitle, and the screen that proves it.
4. **White ground, black type.** `#FFFFFF` and `#000000`, plus one grey for the subtitle
   (`#3A3A3A`) and one for the index mark (`#8A8A8A`). Nothing else. The capture keeps the
   app's own real colours — the black-and-white rule governs the canvas, never the app.
5. **Nothing overlaps the app.** No text, no mark, no ornament crosses the capture.

## Type

Apple system fonts only, which are licensed for this use and match the platform.

| Role | Face | Size (iPhone 6.9") | Size (iPad 13") |
| --- | --- | --- | --- |
| Index mark | SF Mono-ish system, tracked +8% | 32 | 34 |
| Title | System, bold (w 0.62) | 86 | 96 |
| Subtitle | System, regular (w 0.0) | 38 | 42 |

Sizes for the 6.5-inch canvas are the 6.9-inch values scaled by 2778⁄2868 and rounded, so
the two phone sets read as one piece of work rather than two.

Chinese sets use the same sizes. Simplified and Traditional are typeset separately: they
are different translations, not one string rendered twice, and each is line-broken on its
own. Chinese titles are given a slightly tighter leading (0.92 of the Latin value) because
Han characters have no descenders to separate lines.

## Layout — iPhone, portrait

A vertical stack. The reader's eye goes down: what it is, why it matters, the proof.

```
┌──────────────────────────────┐
│  ▏margin                     │
│  01 / 08                     │   index mark
│                              │
│  Title, up to two lines      │   86pt bold
│                              │
│  Subtitle, up to three       │   38pt regular
│  lines of it.                │
│  ────────────────────────    │   hairline, content width
│                              │
│  ┌────────────────────────┐  │
│  │                        │  │   the capture, content width,
│  │      the app           │  │   corner radius 48, 1px outline,
│  │                        │  │   bleeding off the bottom edge
│  └────────────────────────┘  │
└──────────────────────────────┘
```

Margin is 10.6% of canvas width. The capture is the full content width and is anchored
below the rule; where it is taller than the space left, it runs off the bottom of the
canvas rather than being shrunk — the top of a phone screen is where the information is,
and shrinking it to fit would cost legibility at store-thumbnail size.

## Layout — iPad, landscape

Two columns, because a landscape canvas read as a portrait stack wastes two thirds of it.

```
┌───────────────────────────────────────────────────────┐
│  ▏margin                                              │
│  01 / 08              ┌─────────────────────────────┐ │
│                       │                             │ │
│  Title, up to         │                             │ │
│  two lines            │          the app            │ │
│                       │                             │ │
│  Subtitle, up to      │                             │ │
│  four lines of it.    │                             │ │
│  ──────────────       └─────────────────────────────┘ │
│  ◀── 30% ──▶          ◀────────── 62% ──────────────▶ │
└───────────────────────────────────────────────────────┘
```

The caption column is 30% of the canvas width, left-aligned, vertically centred as a block.
The capture takes the remaining width, is vertically centred, and is scaled to fit **whole**
— an iPad screenshot is wide, and cropping it would remove the split that the picture is
there to show.

## The capture itself

* Placed at its **native pixel size** or scaled **proportionally**. Width and height are
  never scaled by different factors; `automation/validate.py` recomputes the aspect ratio
  from the placement recorded in the manifest and fails on a mismatch beyond 0.5%.
* Corner radius 48 px (iPhone) / 40 px (iPad), clipped.
* A 1 px `#000000` outline on the same rounded path — the only line the template draws
  besides the rule.
* No shadow. A shadow on white is a grey smear at thumbnail size.

## Colour and file rules

* Canvas is opaque `#FFFFFF`. Output is 8-bit RGB, **no alpha channel** — PNG colour type
  2, asserted per file by the validator.
* sRGB throughout. The capture arrives sRGB from the simulator and is composited without a
  colour-space conversion.
* File names carry the display order: `01-terminal.png` … `08-desktop.png`.

## Checks the template must pass

Run by `automation/validate.py` on every export, and by eye once per language:

* Exact pixel size for the slot, and no alpha.
* No text overflow: the renderer measures each string and fails the build if a title needs
  more than two lines or a subtitle more than three (iPhone) or four (iPad).
* Title legible at 25% scale, which is roughly the store's browse size.
* Chinese punctuation is full-width and never begins a line.
* The capture is never overlapped by type, and never scaled anisotropically.
* iPhone and iPad differ in layout, not merely in scale — asserted by the two distinct
  layout constants and checked by eye on the contact sheets.
