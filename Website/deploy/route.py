#!/usr/bin/env python3
"""Point apexterminal.lucian-dev.com at the site container, once.

The Vultr host runs a remotely-managed Cloudflare Tunnel, so its ingress rules
live in Cloudflare's API rather than in a file on the box. This script reads the
current configuration, backs it up, inserts one hostname rule ahead of the
catch-all, and writes it back. Credentials come from the local cloudflared
origin certificate (~/.cloudflared/cert.pem) — nothing new is stored.

    python3 Website/deploy/route.py            # show what would change
    python3 Website/deploy/route.py --apply    # make the change
"""

from __future__ import annotations

import base64
import json
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

TUNNEL = "c7191678-a187-4675-b03b-37ee028e501d"   # "Vultr Lucain"
HOSTNAME = "apexterminal.lucian-dev.com"
SERVICE = "http://127.0.0.1:8090"
API = "https://api.cloudflare.com/client/v4"
BACKUPS = Path(__file__).resolve().parent / "backups"


def credentials() -> tuple[str, str]:
    cert = Path.home() / ".cloudflared" / "cert.pem"
    block = re.search(r"-----BEGIN ARGO TUNNEL TOKEN-----(.*?)-----END", cert.read_text(), re.S)
    if not block:
        sys.exit(f"no Argo Tunnel token in {cert}")
    token = json.loads(base64.b64decode("".join(block.group(1).split())))
    return token["accountID"], token["apiToken"]


def call(method: str, path: str, api_token: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{API}{path}",
        data=data,
        method=method,
        headers={"Authorization": f"Bearer {api_token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as r:
        out = json.load(r)
    if not out.get("success"):
        sys.exit(f"{method} {path} failed: {json.dumps(out.get('errors'), ensure_ascii=False)}")
    return out["result"]


def main() -> None:
    apply = "--apply" in sys.argv
    account, api_token = credentials()
    path = f"/accounts/{account}/cfd_tunnel/{TUNNEL}/configurations"

    result = call("GET", path, api_token)
    config = result.get("config") or {}
    ingress = list(config.get("ingress") or [])

    existing = [r for r in ingress if r.get("hostname") == HOSTNAME]
    if existing:
        print(f"already routed: {HOSTNAME} -> {existing[0].get('service')}")
        if existing[0].get("service") == SERVICE:
            return

    BACKUPS.mkdir(exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = BACKUPS / f"tunnel-ingress-{stamp}.json"
    backup.write_text(json.dumps(config, indent=2, ensure_ascii=False))
    print(f"backed up {len(ingress)} rules to {backup.relative_to(Path.cwd()) if backup.is_relative_to(Path.cwd()) else backup}")

    rules = [r for r in ingress if r.get("hostname") != HOSTNAME]
    catch_all = [r for r in rules if not r.get("hostname")]
    named = [r for r in rules if r.get("hostname")]
    new_config = dict(config)
    new_config["ingress"] = named + [{"hostname": HOSTNAME, "service": SERVICE}] + catch_all

    print(f"\nadding: {HOSTNAME} -> {SERVICE}")
    print(f"rules: {len(ingress)} -> {len(new_config['ingress'])} (other rules untouched)")

    if not apply:
        print("\ndry run — pass --apply to write it")
        return

    call("PUT", path, api_token, {"config": new_config})
    print("applied")

    after = call("GET", path, api_token).get("config", {}).get("ingress", [])
    for r in after:
        if r.get("hostname") == HOSTNAME:
            print(f"confirmed: {r['hostname']} -> {r['service']}")


if __name__ == "__main__":
    main()
