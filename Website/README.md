# Website — apexterminal.lucian-dev.com

Nine static pages: **home**, **privacy** and **support**, in English, Simplified
Chinese and Traditional Chinese. Built to satisfy the two App Store Connect
fields that block a submission — the Support URL and the Privacy Policy URL —
and to be a homepage worth reading on its own.

No JavaScript, no analytics, no cookies, no consent banner. A site that measured
its readers would contradict the product's central claim in the same breath as
making it.

## The URLs to paste into App Store Connect

| Locale | Support URL | Privacy Policy URL |
| --- | --- | --- |
| English (U.S.) | `https://apexterminal.lucian-dev.com/support/` | `https://apexterminal.lucian-dev.com/privacy/` |
| 简体中文 | `https://apexterminal.lucian-dev.com/zh-hans/support/` | `https://apexterminal.lucian-dev.com/zh-hans/privacy/` |
| 繁體中文 | `https://apexterminal.lucian-dev.com/zh-hant/support/` | `https://apexterminal.lucian-dev.com/zh-hant/privacy/` |

Marketing URL: `https://apexterminal.lucian-dev.com/`

Both page kinds are reachable without JavaScript and neither redirects — nginx
resolves `/privacy` to `/privacy/index.html` directly rather than issuing a 301
to the trailing-slash form, so either spelling answers 200.

## Where the words come from

Nothing on the site is newly written marketing. Every claim is copy that was
already gated by the audit:

| On the page | Source |
| --- | --- |
| Home, privacy summary, support | `Marketing/Rebuild-2026-09-10/website/WEBSITE_COPY_{EN,ZH_HANS,ZH_HANT}.md`, sections A, B, J, K, M, O, S |
| Titles, descriptions, Open Graph | the same files' §S, and `WEBSITE_INFORMATION_ARCHITECTURE.md` §§6–7 |
| The Privacy Policy reproduced in full on `/privacy` | `App/Resources/Legal/legal-privacy-{en,zh-Hans,zh-Hant}.md` — read at build time, so the page cannot drift from the app |
| Palette, type and icon rules | `Marketing/Rebuild-2026-09-10/press-kit/MEDIA_KIT.md` §§3–5 |
| Developer legal name | `App/Resources/Legal/legal-terms-en.md` — Li Yanpei |

The three Chinese texts are the separate translations that already existed. No
Traditional page was produced by converting Simplified characters.

`/privacy` carries the approved summary first and then the shipped policy in
full, because App Review needs the actual policy at the URL, and a summary that
only points at the app would be thin.

### What is deliberately not here

The information architecture describes twelve pages. Nine are built: the three
the store requires, times three languages. The feature pages (`/terminal`,
`/files`, `/port-forwarding`, `/tmux`, `/remote-desktop`, `/ipad`, `/security`,
`/faq`, `/download`) are not built yet, so nothing links to them — their copy
lives on the home page as sections instead. The App Store and TestFlight buttons
render as the holding line from copy §A.3, because neither link exists yet.

## Building

```bash
python3 Website/build.py     # writes Website/dist/
```

`dist/` is generated and not committed.

## Deploying

```bash
Website/deploy/deploy.sh     # build, rsync to vultr_tokyo, restart the container
```

The site runs as `apexterminal-site` (nginx 1.27-alpine) on the Vultr Tokyo box,
bound to `127.0.0.1:8090`, served from `/srv/apexterminal/site`. It is not
exposed on the public interface: the Cloudflare Tunnel already running on that
host reaches it over loopback.

### The one-time routing

`Website/deploy/route.py` adds the tunnel's ingress rule. That host runs a
remotely-managed tunnel, so its rules live in Cloudflare's API rather than in a
file on the box; the script reads the live configuration, writes a timestamped
backup under `deploy/backups/`, inserts one hostname rule ahead of the catch-all
and leaves every other rule alone.

```bash
python3 Website/deploy/route.py            # dry run
python3 Website/deploy/route.py --apply
```

The DNS record is separate and was added by hand in the Cloudflare dashboard:

```
CNAME  apexterminal  ->  c7191678-a187-4675-b03b-37ee028e501d.cfargotunnel.com   (proxied)
```

The credential in `~/.cloudflared/cert.pem` is scoped to the `hiko.dev` zone, so
it cannot create records in `lucian-dev.com`; `cloudflared tunnel route dns` run
with it will silently create `apexterminal.lucian-dev.com.hiko.dev` instead.

## Changing the copy

Text lives in `content/{en,zh_hans,zh_hant}.py`, one dictionary each, parallel in
shape. The build reads nothing else, so a wording change is a one-file edit and a
rebuild. When the App Store link exists, replace the `holding` string with a real
button — the approved label is *Download on the App Store*.
