# Media kit — using the Apex Terminal name and images

**Prepared:** 2026-09-10 · **Companion to:** [`PRESS_KIT.md`](PRESS_KIT.md) ·
**Name rules decided in:** [`../strategy/MESSAGING_SYSTEM.md`](../strategy/MESSAGING_SYSTEM.md) §6.1

This file is for anyone setting the name in type or placing the images in a layout: a
journalist, a picture editor, a directory maintainer, a conference programme, or whoever
builds the product page. It is short because the identity is small on purpose. There is a
name, an icon, one accent colour and a caption template made of black type on white — and
that is the whole of it.

Where a rule is stated as a boundary rather than a preference, it is because breaking it
turns a checked claim into an unchecked one, or turns a product into something it is not.

---

## 1 · The name in writing

**Apex Terminal.** Two words. Capital A, capital T. Lower case on everything else.

| Correct | Wrong | Why |
| --- | --- | --- |
| Apex Terminal | ApexTerminal | The one-word form is an identifier — a build scheme, a directory, a `User-Agent` — and never appears in prose |
| Apex Terminal | APEX TERMINAL | The name is not set in capitals, in a headline or anywhere else |
| Apex Terminal | apex terminal | Nor in lower case, including in a URL slug that is read as a name |
| Apex Terminal | Apex | The product is never called "Apex" — not on second mention, not in a headline, not in a chart label, not in a tweet that ran out of room |
| Apex Terminal | Apex Terminal™ / ® | The project uses no trademark symbol |
| Apex Terminal | Apex-Terminal, Apex.Terminal | No hyphen, no dot, no other joiner |
| Apex Terminal | SuperTerminal | A retired name. It appears in no shipped code or resource, and must not appear in writing |

**On second mention** write "Apex Terminal" again, or "the app". If a sentence cannot carry
the full name twice, rewrite the sentence.

**In Chinese text** the name stays in Latin script — **Apex Terminal** — with a space on
either side inside the Chinese line. There is no Chinese name for this product, and one may
not be coined for a headline, a subtitle or a URL.

**What to call the thing itself.** An SSH client. A terminal app for iPhone and iPad. Not a
VPN, not a service, not a web terminal, not a server. Commands run on servers the customer
already owns.

**Who makes it.** The developer is not named in any of this material, and the quote in the
press release is attributed to "the developer". Do not attach a personal name, a company
name or a location to the product on the strength of a repository, an account handle or a
bundle identifier.

---

## 2 · There is no wordmark

The name is set in type. There is no drawn logotype, no lock-up of the icon with the name,
and no locked spacing between the two.

That means:

* **Set the name in your own text face.** A publication's own typography is the correct
  setting for it.
* **Do not draw one.** Do not letterspace it into a mark, set it in a display or script
  face, add a glyph between the words, or build an icon-plus-name lock-up and present it as
  the product's identity.
* **Do not extract type from a screenshot** and reuse it as a mark.

If a layout needs a graphic beside the name, use the icon (§5) with clear space around it,
unlocked from the type.

---

## 3 · Colour

The palette is four neutrals and one accent. Nothing else belongs to this product.

| Role | Value | Where it is used |
| --- | --- | --- |
| Ground | `#FFFFFF` | The canvas of every screenshot; the ground of any page that carries this material |
| Ink | `#000000` | Titles, rules, the outline around a screen capture |
| Secondary text | `#3A3A3A` | Subtitles and captions |
| Quiet mark | `#8A8A8A` | Index marks, small ordinal labels |
| Accent, light | `#2E7AC8` | The app's own accent on a light background |
| Accent, dark | `#6FA8FF` | The app's own accent on a dark background — a lighter blue, not the light value at reduced opacity |

Rules:

* **The accent is the app's, not the layout's.** It appears inside the interface. Screenshot
  canvases and press layouts stay black on white; the accent is not a background, a heading
  colour or a highlight for a pull quote.
* **The two accent values are a pair, chosen for their own background.** Do not use the
  light value on a dark ground, and do not derive one from the other by tinting.
* **A capture keeps the app's real colours.** The black-and-white rule governs the canvas
  around a screenshot, never the screenshot itself. Do not recolour, filter, duotone or
  desaturate a capture to fit a house palette.
* **No gradients, glows or colour washes** anywhere in this material.

---

## 4 · Type

* **The screenshot template uses Apple's system fonts** — the system face for titles and
  subtitles, and a monospaced system face for the index mark. They are licensed for this use
  and they match the platform the pictures were taken on.
* **The captions are approved text.** If a caption is reproduced, reproduce it as it stands.
  Re-typesetting is fine; rewording is a new claim and is not.
* **Chinese sets are typeset separately.** Simplified and Traditional are separate
  translations, line-broken on their own, and Chinese titles are set with slightly tighter
  leading than the Latin ones because Han characters have no descenders to separate the
  lines. Do not produce a Traditional layout by converting the Simplified characters, and do
  not reflow a Chinese caption so that a full-width punctuation mark begins a line.
* **In running text**, set the product name in the publication's own face at the same weight
  and size as the surrounding prose. It does not take small caps, italics, bold or a
  different colour.
* **Terminal content in the screenshots is in English** in every language set, because that
  is what the server sent. Do not re-typeset or translate it.

---

## 5 · The icon

Three 1024 × 1024 drawings ship with the app: light, dark and tinted. Their paths are in
[`PRESS_KIT.md`](PRESS_KIT.md) §6.4.

The icon is a hexagonal outline drawn in a single line weight, enclosing a shell prompt — a
chevron and an underscore — with two further chevrons receding behind it. Black on an
off-white ground in the light version; the same drawing reversed as white on near-black in
the dark version, redrawn rather than inverted.

**Using it**

* Pick the version that matches the background: the light icon on a light page, the dark
  icon on a dark one. The tinted drawing is for the iOS home screen and is not a press
  asset.
* Keep clear space around it of at least one quarter of its width on every side. Nothing —
  no type, no rule, no other mark — enters that space.
* Reproduce it no smaller than 32 px on screen or 10 mm in print. Below that the receding
  chevrons close up and the drawing becomes a blot; use the monochrome mark (`Logo.imageset`)
  instead.
* Scale proportionally. Width and height are never scaled by different amounts.
* iOS applies its own corner mask to the icon on a device. In a layout, place the square
  artwork as it is, or apply the platform's standard rounded mask — do not invent a corner
  radius, and do not cut the artwork into a circle.

**Not using it**

* Do not recolour it, including into a publication's accent or into the app's own accent
  blue.
* Do not add a shadow, a gradient, a glow, a reflection, a bevel, an outline or a background
  plate.
* Do not rotate, skew, flip, animate or perspective-warp it.
* Do not redraw it, trace it, change its line weight, or take the chevron out of the hexagon
  and use it on its own.
* Do not crop it, or place it so that another element overlaps it.
* Do not set it on a photograph, a pattern or any ground busy enough to break the outline.
* Do not use it as a favicon, an avatar or an app-store-style tile for anything that is not
  Apex Terminal.
* Do not place it beside another company's mark in a way that suggests a partnership,
  an endorsement, a bundle or a certification.

---

## 6 · What may be altered, and what may not

**May be altered**

* The size of any supplied image, scaled proportionally.
* The surrounding layout, grid, margins and background of a page that carries the material.
* The face and size in which the product name is set in running text.
* The length of a quoted summary — by choosing a shorter approved summary from
  [`PRESS_KIT.md`](PRESS_KIT.md) §1, rather than by cutting a longer one.
* The file format of an image, where a workflow needs one, provided the pixels are not
  resampled anisotropically and no colour conversion is applied to a capture.

**May not be altered**

* The wording of the name, in any language.
* The wording of an approved summary, an approved caption, or the "About Apex Terminal"
  block. A trimmed sentence is a different claim from the one that was checked.
* The colours, line weight or proportions of the icon.
* The contents of a screenshot: nothing added, nothing removed, nothing painted out,
  nothing composited in.
* The pairing of a caption with its image. A caption belongs to the picture it was written
  for.

---

## 7 · Do not

1. Do not write "Apex" alone, "ApexTerminal", "APEX TERMINAL" or "SuperTerminal".
2. Do not invent a Chinese name, a nickname, an abbreviation or an acronym.
3. Do not attach a trademark symbol.
4. Do not draw a wordmark or an icon-and-name lock-up.
5. Do not recolour, rotate, redraw, outline, shadow or crop the icon.
6. Do not put the icon on a photograph or a busy pattern, or inside another mark.
7. Do not recolour, filter or crop a screenshot, or composite it into a device photograph.
8. Do not retype a caption in different words, or move a caption to a different picture.
9. Do not stage a Face ID or Touch ID prompt into any image. None exists in the supplied
   set, and none may be added.
10. Do not place the name or the icon next to another company's name, mark or product in a
    way that implies a partnership, an endorsement, an affiliation or a certification.
11. Do not use the name or the images in advertising, on merchandise, in a domain name, in
    an app name, or as part of another product's identity. Editorial use — press, reviews,
    round-ups, teaching material — is granted; this is not.
12. Do not present the app as available on a platform it does not ship for. It is an iPhone
    and iPad app.
13. Do not describe it as a VPN, a hosting service, a web terminal or a server.
14. Do not add a user count, a rating, an award, a ranking or a "trusted by" line. None
    exists, and an invented one would make everything else in this kit unusable along
    with it.
15. Do not quote a benchmark, a throughput figure or a comparison table. This project
    publishes none.
16. Do not name another SSH client alongside this one in material supplied by or for the
    project. What a publication writes in its own review is a publication's own business.
