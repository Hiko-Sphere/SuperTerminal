# Connecting through Cloudflare Tunnel and Access

This is the guide for the administrator who publishes an SSH server, and for anyone
setting up the test environment the app's live end-to-end run needs.

ApexTerminal speaks Cloudflare's carrier protocol directly. Nothing needs to be
installed on the iPhone or iPad — no `cloudflared`, no VPN profile, no Network Extension.
What has to exist is on the *server* side, and that is what this page covers.

---

## What the app actually does

Understanding the shape of it makes the configuration below make sense, and makes
diagnosing a failure much faster.

1. The app sends `HEAD https://<hostname>/` with the header
   `cf-access-metadata-request: true`. Cloudflare answers with a signed JWT in the
   `cf-access-metadata` header naming your team's auth domain and the application's
   audience tag.
2. That JWT's signature is verified against `https://<auth-domain>/cdn-cgi/access/certs`.
   The auth domain must end in `.cloudflareaccess.com`, and the hostname in the JWT must
   match the host actually requested — so a server that is not really behind Access
   cannot send the app to a login page of its choosing.
3. If no valid token is stored, the app opens
   `https://<hostname>/cdn-cgi/access/cli?…` in a system browser sheet. You sign in
   normally, including any SSO redirect and MFA step.
4. Cloudflare seals the resulting token to an ephemeral key the app generated for that one
   sign-in and posts it to `https://login.cloudflareaccess.org/`, where the app collects
   and decrypts it. **The app never reads a cookie out of the browser** — iOS does not
   permit that, and this is why it does not need to.
5. The app opens a WebSocket to `wss://<hostname>/` carrying
   `Cf-Access-Token: <token>`. Every binary frame on that socket is raw TCP for your SSH
   server.
6. A normal SSH handshake runs over those bytes: host key verification, user
   authentication, a PTY, a shell.

Two consequences worth knowing:

* **Port 443 is the only port involved.** Your SSH server's port is a detail between
  `cloudflared` and the origin; the device never connects to it.
* **The tunnel does not weaken SSH.** Cloudflare carries encrypted SSH traffic; it does
  not terminate it. Host key verification still protects you from the tunnel itself.

---

## Server setup

### 1. Run an SSH server

Anything OpenSSH-compatible. Nothing special is required, but note the algorithm support
in [the SSH guide](SSH.md#algorithm-support) — in particular that a host with **only**
`ssh-rsa` (SHA-1) host keys cannot be reached, because that algorithm is refused by
design.

### 2. Create a tunnel

Install `cloudflared` on the origin host and authenticate it:

```bash
cloudflared tunnel login
cloudflared tunnel create apexterminal-test
```

### 3. Route a hostname to the SSH service

Create `~/.cloudflared/config.yml` on the origin:

```yaml
tunnel: apexterminal-test
credentials-file: /root/.cloudflared/<tunnel-uuid>.json

ingress:
  - hostname: ssh-test.example.com
    service: ssh://localhost:22
  - service: http_status:404
```

Then publish the hostname and run the tunnel:

```bash
cloudflared tunnel route dns apexterminal-test ssh-test.example.com
cloudflared tunnel run apexterminal-test
```

At this point the hostname works **without** authentication. That is a legitimate
configuration and ApexTerminal supports it — the app detects the absence of an Access
application and connects straight through. It is also, for most people, not what you
want, so continue.

### 4. Put Cloudflare Access in front of it

In the Zero Trust dashboard, add a **self-hosted** application:

| Field | Value |
| --- | --- |
| Application domain | `ssh-test.example.com` |
| Session duration | Whatever suits you; the app handles expiry and re-authentication |
| Policy | Allow, with whatever identity rule you use — an email list is fine for testing |

Leave "Browser rendering" **off**. ApexTerminal opens a native SSH session; the
browser-rendered terminal is a different product and the app does not use it.

### 5. Optional: bastion mode

If one tunnel should reach several servers, configure the ingress as a bastion:

```yaml
ingress:
  - hostname: bastion.example.com
    service: bastion
  - service: http_status:404
```

In the app, turn on "Through Cloudflare Tunnel" and fill in the **bastion destination**
(`internal-host:22`). The app sends it as `Cf-Access-Jump-Destination`. Host keys are
remembered per destination, so two servers behind one bastion do not share an entry.

### 6. A remote screen through a tunnel of its own

A screen can ride the SSH connection — that is the default, and it needs no Cloudflare
configuration beyond the above, because the `direct-tcpip` channel travels inside the SSH
session. A screen can also be published as **its own** Access-protected hostname, with no
SSH connection in the way (D-029). Add a second ingress rule pointing at the VNC port:

```yaml
ingress:
  - hostname: ssh-test.example.com
    service: ssh://localhost:22
  - hostname: screen-test.example.com
    service: tcp://localhost:5900
  - service: http_status:404
```

```bash
cloudflared tunnel route dns apexterminal-test screen-test.example.com
```

Then add a second self-hosted Access application for `screen-test.example.com`, exactly
as in step 4. The desktop `cloudflared access tcp --hostname screen-test.example.com --url
localhost:5900` is the equivalent command for a laptop; the app needs no such helper — it
opens the same WebSocket carrier itself.

In the app: **New Connection → Screen**, set *How it connects* to **Cloudflare**, and put
`screen-test.example.com` in the **Hostname** field. Leave the port empty —
blank means the Cloudflare edge's 443 for this route, not 5900. The address is the
hostname the tunnel publishes; where the VNC server actually is behind the tunnel is the
tunnel's own business, exactly as for SSH.

**The screen's own sign-in is separate from Access** (D-031). Getting past Access proves
you may reach the port; the VNC server then authenticates you itself, and some of them
want a user name as well as a password:

| The server | What to put in the screen's editor |
| --- | --- |
| macOS Screen Sharing, signing in to an account | User name and password of a macOS account allowed in Screen Sharing settings |
| macOS with "VNC viewers may control screen with password" | Password only; leave the user name empty |
| x11vnc / TigerVNC with a classic VNC password | Password only; leave the user name empty |
| A VeNCrypt server | User name and password |
| A server with no authentication | Leave both empty |

Both fields may be left empty; a blank password is asked for when the screen opens. A
VeNCrypt server offering only its `Plain` sub-type — the user name and password with
nothing over them — is accepted through a Cloudflare tunnel or SSH, because the carrier is
already encrypted, and refused on a direct connection.

---

## Service tokens, for automation

**In the app:** edit a tunnelled connection, set *Sign in with* to *Service token* and enter
the client ID and secret. They are stored in that device's Keychain only — never synced —
and deleted with the connection. A connection whose record arrived by iCloud sync asks
for the token again rather than failing silently.

A service token authenticates without a browser, which is what makes the app's live test
suite runnable in CI.

Create one in Zero Trust → Access → Service Auth, then add a policy on the application
with the **Service Auth** action including that token. A service token cannot satisfy an
`Allow` policy — it needs its own.

You will get a client ID ending in `.access` and a client secret shown once.

---

## Running the app's live end-to-end test

This is the run that turns "Cloudflare support is implemented" into "Cloudflare support is
verified". Everything else in the test suite runs without an account; this cannot.

**Do not paste these values into a chat window or commit them.** Put them in a file
outside the repository:

```bash
# ~/.apexterminal-live.env  — chmod 600
export ST_LIVE_CF_HOSTNAME=ssh-test.example.com
export ST_LIVE_CF_SERVICE_TOKEN_ID=<id>.access
export ST_LIVE_CF_SERVICE_TOKEN_SECRET=<secret>
export ST_LIVE_SSH_USER=youruser
export ST_LIVE_SSH_KEY_PATH=/path/to/a/test/key
# Optional
export ST_LIVE_CF_JUMP_DESTINATION=internal-host:22
export ST_LIVE_SSH_HOST_FINGERPRINT=SHA256:...
```

Then:

```bash
set -a; source ~/.apexterminal-live.env; set +a
./scripts/live-e2e.sh
```

The suite checks four things: that the hostname is discovered as an Access application
with a Cloudflare-hosted auth domain; that a service token opens the carrier and reaches a
real interactive PTY whose geometry the remote confirms; that a token for the wrong
audience is refused; and that an unauthenticated connection is refused. The last two
matter as much as the first — an Access-protected host that accepts either is worse than
one that fails.

---

## Diagnosing failures

The app classifies edge responses rather than reporting "connection failed", so the error
you see narrows things considerably.

| What the app says | What it means | Where to look |
| --- | --- | --- |
| "No Cloudflare Access application was found for this hostname" | The `HEAD` probe returned no `cf-access-metadata` header | The hostname is not behind Access, or is not published at all. Turn off the Cloudflare option if this host is a plain SSH server. |
| "Could not verify that this hostname is genuinely protected by your Cloudflare team" | The metadata JWT failed signature, hostname or freshness checks | Usually a wildcard application whose hostname claim does not match, or a badly wrong device clock |
| "Cloudflare Access denied this connection" | 403, or a redirect to the login page | The identity is not allowed by any policy. For a service token, check it has its own **Service Auth** policy — an `Allow` policy will not accept it |
| "Cloudflare has no route for this hostname" | 404 from the edge | The DNS route or the ingress rule is missing. `cloudflared tunnel route dns …` |
| "The Cloudflare Tunnel could not reach the SSH service" | 502/503/504 | `cloudflared` is running but the origin refused. Check the `service:` URL and that sshd is listening |
| "Cloudflare could not connect to the origin (error 1033)" | 530 | The tunnel is not connected. Start `cloudflared` on the origin |
| "Your Cloudflare Access session has expired" | The stored token is past `exp` | Sign in again; the app does this automatically on the next attempt |

To compare against a known-good client, the desktop equivalent of what the app does is:

```bash
ssh -o "ProxyCommand=cloudflared access ssh --hostname %h" youruser@ssh-test.example.com
```

If that fails too, the problem is in the Cloudflare configuration rather than in the app.

---

## Revoking access

* **One device** — Zero Trust → Logs → Access, find the session and revoke it. The app's
  next connection fails with an Access error and offers to sign in again.
* **A service token** — delete it in Access → Service Auth. It stops working immediately.
* **Everything on the device** — in the app, Settings → "Sign out of all Cloudflare Access
  apps" deletes every stored token from the Keychain. "Delete all data" removes those plus
  every key and connection.

---

## Keeping test and production apart

Use a separate hostname, a separate Access application and a separate service token for
testing. The app stores tokens per `(hostname, audience)` pair and validates the audience
before use, so a test token cannot be used against production even by accident — but
separate credentials mean revoking one does not disturb the other.
