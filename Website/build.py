#!/usr/bin/env python3
"""Build the Apex Terminal site.

Nine pages: home, privacy and support, in English, Simplified Chinese and
Traditional Chinese. No JavaScript anywhere, no analytics, nothing to consent
to — the site is not allowed to contradict the product's own claim.

    python3 Website/build.py            # writes Website/dist/
"""

from __future__ import annotations

import html
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
DIST = ROOT / "dist"
LEGAL = REPO / "App" / "Resources" / "Legal"

SITE = "https://apexterminal.lucian-dev.com"
EMAIL = "support@lucian-dev.com"
NAME = "Apex Terminal"

sys.path.insert(0, str(ROOT / "content"))
import en, zh_hans, zh_hant  # noqa: E402

LANGS = [en.C, zh_hans.C, zh_hant.C]
BY_CODE = {c["code"]: c for c in LANGS}

# The policy shipped in the app, per language. Reproduced in full on /privacy.
POLICY_FILE = {
    "en": "legal-privacy-en.md",
    "zh-hans": "legal-privacy-zh-Hans.md",
    "zh-hant": "legal-privacy-zh-Hant.md",
}

LANG_NAMES = [("en", "English"), ("zh-hans", "简体中文"), ("zh-hant", "繁體中文")]


# --------------------------------------------------------------------------
# text
# --------------------------------------------------------------------------

def esc(s: str) -> str:
    return html.escape(s, quote=False)


def inline(s: str) -> str:
    """Escape, then honour **bold**, *italic* and `code`."""
    s = html.escape(s, quote=False)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", r"<em>\1</em>", s)
    return s


def with_email(template: str) -> str:
    """Render a sentence containing the {email} slot, linking the address."""
    link = f'<a href="mailto:{EMAIL}">{EMAIL}</a>'
    return link.join(inline(part) for part in template.split("{email}"))


def markdown(text: str) -> str:
    """Enough Markdown for the shipped legal texts: headings, tables, lists,
    paragraphs and inline emphasis. The h1 is dropped — the page supplies it."""
    out: list[str] = []
    lines = text.splitlines()
    i = 0
    seen_h1 = False

    while i < len(lines):
        line = lines[i].rstrip()

        if not line.strip():
            i += 1
            continue

        if line.startswith("#"):
            level = len(line) - len(line.lstrip("#"))
            body = line[level:].strip()
            if level == 1 and not seen_h1:
                seen_h1 = True          # the page heading already says this
                i += 1
                continue
            tag = f"h{min(level + 1, 4)}"
            out.append(f"<{tag}>{inline(body)}</{tag}>")
            i += 1
            continue

        # table: a header row, a separator row, then body rows
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|[\s:|-]+\|$", lines[i + 1].strip()):
            header = [c.strip() for c in line.strip().strip("|").split("|")]
            i += 2
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            th = "".join(f"<th>{inline(c)}</th>" for c in header)
            trs = "".join(
                "<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in rows
            )
            out.append(
                '<div class="table-scroll"><table><thead><tr>'
                + th + "</tr></thead><tbody>" + trs + "</tbody></table></div>"
            )
            continue

        if line.lstrip().startswith(("- ", "* ")):
            items = []
            while i < len(lines) and lines[i].lstrip().startswith(("- ", "* ")):
                items.append(inline(lines[i].lstrip()[2:].strip()))
                i += 1
            out.append("<ul>" + "".join(f"<li>{x}</li>" for x in items) + "</ul>")
            continue

        # paragraph: consume until a blank line or a block starter
        para = [line]
        i += 1
        while i < len(lines) and lines[i].strip() and not lines[i].startswith(("#", "|", "- ", "* ")):
            para.append(lines[i].rstrip())
            i += 1
        out.append(f"<p>{inline(' '.join(para))}</p>")

    return "\n".join(out)


# --------------------------------------------------------------------------
# shell
# --------------------------------------------------------------------------

def url(code: str, page: str) -> str:
    """Absolute path for a page in a language tree."""
    prefix = BY_CODE[code]["prefix"]
    return f"{prefix}/" if page == "home" else f"{prefix}/{page}/"


def head(c: dict, page: str, meta: dict) -> str:
    canonical = SITE + url(c["code"], page)
    alts = "\n    ".join(
        f'<link rel="alternate" hreflang="{BY_CODE[code]["html_lang"]}" href="{SITE}{url(code, page)}">'
        for code, _ in LANG_NAMES
    )
    others = "\n    ".join(
        f'<meta property="og:locale:alternate" content="{BY_CODE[code]["og_locale"]}">'
        for code, _ in LANG_NAMES if code != c["code"]
    )
    return f"""<!doctype html>
<html lang="{c['html_lang']}">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{esc(meta['title'])}</title>
    <meta name="description" content="{html.escape(meta['description'])}">
    <link rel="canonical" href="{canonical}">
    {alts}
    <link rel="alternate" hreflang="x-default" href="{SITE}{url('en', page)}">
    <meta property="og:site_name" content="{NAME}">
    <meta property="og:type" content="website">
    <meta property="og:url" content="{canonical}">
    <meta property="og:locale" content="{c['og_locale']}">
    {others}
    <meta property="og:title" content="{html.escape(meta['og_title'])}">
    <meta property="og:description" content="{html.escape(meta['og_description'])}">
    <meta name="twitter:card" content="summary">
    <meta name="twitter:title" content="{html.escape(meta['og_title'])}">
    <meta name="twitter:description" content="{html.escape(meta['og_description'])}">
    <link rel="icon" href="/assets/img/icon-light.png" media="(prefers-color-scheme: light)">
    <link rel="icon" href="/assets/img/icon-dark.png" media="(prefers-color-scheme: dark)">
    <link rel="apple-touch-icon" href="/assets/img/icon-light.png">
    <link rel="stylesheet" href="/assets/style.css">
  </head>
  <body lang="{c['html_lang']}">
    <a class="skip" href="#content">{esc(c['skip'])}</a>"""


def header(c: dict, page: str) -> str:
    def item(target: str, label: str) -> str:
        cur = ' aria-current="page"' if target == page else ""
        return f'<a href="{url(c["code"], target)}"{cur}>{esc(label)}</a>'

    return f"""
    <header class="site-head">
      <div class="wrap">
        <a class="brand" href="{url(c['code'], 'home')}">
          <picture>
            <source srcset="/assets/img/icon-dark.png" media="(prefers-color-scheme: dark)">
            <img src="/assets/img/icon-light.png" alt="" width="30" height="30">
          </picture>
          <span>{NAME}</span>
        </a>
        <nav class="site-nav" aria-label="{esc(c['nav_home'])}">
          {item('privacy', c['nav_privacy'])}
          {item('support', c['nav_support'])}
        </nav>
      </div>
    </header>
    <main id="content">"""


def footer(c: dict, page: str) -> str:
    f = c["footer"]
    langs = "".join(
        '<li><a href="{href}" lang="{hl}"{cur}>{label}</a></li>'.format(
            href=url(code, page),
            hl=BY_CODE[code]["html_lang"],
            cur=' aria-current="true"' if code == c["code"] else "",
            label=esc(label),
        )
        for code, label in LANG_NAMES
    )
    legal = "\n          ".join(f"<p>{inline(p)}</p>" for p in f["legal"])
    return f"""
    </main>
    <footer class="site-foot">
      <div class="wrap">
        <div class="foot-top">
          <div>
            <a class="brand" href="{url(c['code'], 'home')}">
              <picture>
                <source srcset="/assets/img/icon-dark.png" media="(prefers-color-scheme: dark)">
                <img src="/assets/img/icon-light.png" alt="" width="30" height="30">
              </picture>
              <span>{NAME}</span>
            </a>
            <p class="foot-line">{esc(f['line'])}</p>
          </div>
          <div class="foot-col">
            <h2>{esc(f['col_get'])}</h2>
            <ul>
              <li><a href="{url(c['code'], 'privacy')}">{esc(c['nav_privacy'])}</a></li>
              <li><a href="{url(c['code'], 'support')}">{esc(c['nav_support'])}</a></li>
              <li><a href="mailto:{EMAIL}">{EMAIL}</a></li>
            </ul>
          </div>
          <div class="foot-col">
            <h2>{esc(c['lang_label'])}</h2>
            <ul>{langs}</ul>
          </div>
        </div>
        <div class="legal">
          {legal}
        </div>
      </div>
    </footer>
  </body>
</html>
"""


def page(c: dict, key: str, meta: dict, body: str) -> str:
    return head(c, key, meta) + header(c, key) + body + footer(c, key)


# --------------------------------------------------------------------------
# pages
# --------------------------------------------------------------------------

def home(c: dict) -> str:
    h = c["home"]
    shot = f"/assets/img/{c['code']}/01-terminal.png"

    pillars = "".join(
        f'<article class="card" id="{pid}"><h3>{esc(title)}</h3><p>{esc(body)}</p></article>'
        for pid, title, body in h["pillars"]
    )

    features = []
    for title, body, img, alt in h["teasers"]:
        if img:
            features.append(
                f'<article class="feature"><div><h3>{esc(title)}</h3><p>{esc(body)}</p></div>'
                f'<img class="shot" src="/assets/img/{c["code"]}/{img}" alt="{html.escape(alt)}" loading="lazy" width="720" height="1564"></article>'
            )
        else:
            features.append(
                f'<article class="feature no-shot"><div><h3>{esc(title)}</h3><p>{esc(body)}</p></div></article>'
            )

    pricing = "".join(f"<p>{esc(p)}</p>" for p in h["pricing"])

    ld = (
        '{"@context":"https://schema.org","@type":"SoftwareApplication",'
        f'"name":"{NAME}","operatingSystem":"iOS, iPadOS",'
        '"applicationCategory":"DeveloperApplication",'
        f'"description":{json_str(h["description"])},'
        f'"url":"{SITE}{url(c["code"], "home")}",'
        '"offers":{"@type":"Offer","price":"0","priceCurrency":"USD"}}'
    )

    body = f"""
      <section class="hero">
        <div class="wrap hero-grid">
          <div>
            <h1>{esc(h['h1'])}</h1>
            <p class="sub">{esc(h['sub'])}</p>
            <p class="holding">{esc(c['holding'])}</p>
            <div class="cta-row">
              <a class="btn btn-quiet" href="#keys">{esc(h['secondary_cta'])}</a>
            </div>
            <p class="under">{esc(h['under'])}</p>
          </div>
          <img class="shot hero-shot" src="{shot}" alt="{html.escape(h['hero_alt'])}" width="720" height="1564">
        </div>
      </section>

      <section>
        <div class="wrap">
          <p class="section-label">{esc(h['pillars_heading'])}</p>
          <div class="cards">{pillars}</div>
        </div>
      </section>

      <section class="proof">
        <div class="wrap">
          <p class="section-label">{esc(h['proof_label'])}</p>
          <p>{esc(h['proof'])}</p>
        </div>
      </section>

      <section>
        <div class="wrap">
          <p class="section-label">{esc(h['teasers_heading'])}</p>
          <div class="features">{''.join(features)}</div>
        </div>
      </section>

      <section>
        <div class="wrap narrow">
          <h2>{esc(h['pricing_h'])}</h2>
          {pricing}
        </div>
      </section>

      <section>
        <div class="wrap narrow">
          <h2>{esc(h['closing_h'])}</h2>
          <p>{esc(h['closing_body'])}</p>
          <p class="holding">{esc(c['holding'])}</p>
          <div class="cta-row">
            <a class="btn btn-quiet" href="{url(c['code'], 'privacy')}">{esc(h['closing_secondary'])}</a>
          </div>
        </div>
      </section>
      <script type="application/ld+json">{ld}</script>"""
    return page(c, "home", h, body)


def json_str(s: str) -> str:
    import json
    return json.dumps(s, ensure_ascii=False)


def privacy(c: dict) -> str:
    p = c["privacy"]

    sections = []
    for title, paras in p["sections"]:
        inner = "".join(f"<p>{inline(x)}</p>" for x in paras)
        sections.append(f"<h2>{esc(title)}</h2>{inner}")

    policy_md = (LEGAL / POLICY_FILE[c["code"]]).read_text(encoding="utf-8")

    body = f"""
      <div class="page-head">
        <div class="wrap narrow">
          <h1>{esc(p['h1'])}</h1>
          <p class="lede">{esc(p['lede'])}</p>
        </div>
      </div>
      <div class="prose">
        <div class="wrap narrow">
          {''.join(sections)}
          <div class="contact-box">
            <h2>{esc(p['contact_h'])}</h2>
            <p>{with_email(p['contact_body'])}</p>
          </div>
          <hr>
          <h2>{esc(p['full_h'])}</h2>
          <p class="note">{esc(p['full_lede'])}</p>
          {markdown(policy_md)}
        </div>
      </div>"""
    return page(c, "privacy", p, body)


def support(c: dict) -> str:
    s = c["support"]

    tries = "".join(
        f'<div class="faq-item"><h3>{inline(q)}</h3><p>{inline(a)}</p></div>'
        for q, a in s["try"]
    )
    items = "".join(f"<li>{inline(x)}</li>" for x in s["report_items"])
    also = "".join(f"<p>{inline(x)}</p>" for x in s["also"])

    body = f"""
      <div class="page-head">
        <div class="wrap narrow">
          <h1>{esc(s['h1'])}</h1>
          <p class="lede">{esc(s['standfirst'])}</p>
        </div>
      </div>
      <div class="prose">
        <div class="wrap narrow">
          <div class="contact-box">
            <h2>{esc(s['contact_h'])}</h2>
            <p><a class="btn" href="mailto:{EMAIL}">{esc(s['contact_button'])}</a></p>
            <p><a href="mailto:{EMAIL}">{EMAIL}</a> — {esc(s['contact_note'])}</p>
          </div>

          <h2>{esc(s['try_h'])}</h2>
          {tries}

          <h2>{esc(s['report_h'])}</h2>
          <p>{esc(s['report_lede'])}</p>
          <ul>{items}</ul>
          <p class="note">{inline(s['report_warn'])}</p>

          <h2>{esc(s['cannot_h'])}</h2>
          <p>{esc(s['cannot'])}</p>

          <h2>{esc(s['also_h'])}</h2>
          {also}
        </div>
      </div>"""
    return page(c, "support", s, body)


# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------

def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main() -> None:
    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)

    shutil.copytree(ROOT / "assets", DIST / "assets")

    built = []
    for c in LANGS:
        base = DIST / c["prefix"].lstrip("/") if c["prefix"] else DIST
        write(base / "index.html", home(c))
        write(base / "privacy" / "index.html", privacy(c))
        write(base / "support" / "index.html", support(c))
        built += [url(c["code"], k) for k in ("home", "privacy", "support")]

    # robots.txt — allows everything, names the sitemap
    write(DIST / "robots.txt", f"User-agent: *\nAllow: /\n\nSitemap: {SITE}/sitemap.xml\n")

    # sitemap.xml, every URL carrying its hreflang alternates
    entries = []
    for page_key in ("home", "privacy", "support"):
        for code, _ in LANG_NAMES:
            alts = "".join(
                f'\n    <xhtml:link rel="alternate" hreflang="{BY_CODE[o]["html_lang"]}" href="{SITE}{url(o, page_key)}"/>'
                for o, _ in LANG_NAMES
            )
            alts += f'\n    <xhtml:link rel="alternate" hreflang="x-default" href="{SITE}{url("en", page_key)}"/>'
            entries.append(f"  <url>\n    <loc>{SITE}{url(code, page_key)}</loc>{alts}\n  </url>")
    write(
        DIST / "sitemap.xml",
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"\n'
        '        xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
        + "\n".join(entries)
        + "\n</urlset>\n",
    )

    write(
        DIST / ".well-known" / "security.txt",
        f"Contact: mailto:{EMAIL}\nPreferred-Languages: en, zh-Hans, zh-Hant\n"
        f"Canonical: {SITE}/.well-known/security.txt\n",
    )

    # 404, in English with the other two a click away
    c = en.C
    body = """
      <div class="page-head">
        <div class="wrap narrow">
          <h1>Not found</h1>
          <p class="lede">There is no page at this address.</p>
        </div>
      </div>
      <div class="prose"><div class="wrap narrow">
        <p><a href="/">Apex Terminal home</a> · <a href="/privacy/">Privacy</a> · <a href="/support/">Support</a></p>
      </div></div>"""
    meta = {
        "title": "Not found — Apex Terminal",
        "description": "There is no page at this address.",
        "og_title": "Not found",
        "og_description": "There is no page at this address.",
    }
    write(DIST / "404.html", page(c, "home", meta, body))

    print(f"built {len(built)} pages into {DIST}")
    for u in built:
        print("  ", u)


if __name__ == "__main__":
    main()
