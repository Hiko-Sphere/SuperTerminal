# Using ApexTerminal with a plain SSH server

Everything here applies whether the server is reached directly or through a Cloudflare
Tunnel — the SSH layer is the same code either way.

## Adding a connection

Settings are minimal on purpose:

| Field | Notes |
| --- | --- |
| Name | What you will see in the list |
| Hostname | A hostname, an IPv4 address, or an IPv6 address in brackets |
| Username | The account on the server |
| Port | Direct connections only. Cloudflare hosts are always reached on 443 |
| Through Cloudflare Tunnel | See [the Cloudflare guide](CLOUDFLARE.md) |
| Private key | Chosen from the keys you have generated or imported |
| Offer a password | Leave the password blank to be asked each time rather than storing it |

Credentials are offered in the order they are listed, and the app skips any method the
server has already refused — so a server with `MaxAuthTries 2` is not locked out by
offering keys it will never accept.

## Keys

**Generating one** — Settings → Keys → Generate. Ed25519 is the default and the right
choice unless a policy demands otherwise. The app shows the public key as an
`authorized_keys` line; add it to the server:

```bash
# On the server
echo 'ssh-ed25519 AAAA... phone@apexterminal' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Keys are written in the same `openssh-key-v1` format `ssh-keygen` produces, so one
generated on the phone can be exported and used from a laptop.

**Importing one** — paste the private key or choose a file. Passphrase-protected keys are
supported; the passphrase unlocks the key and is not stored.

**Biometric protection** — a key can require Face ID or Touch ID at every use. It is
per-key rather than global, because a key for a production jump host deserves the prompt
and one for a scratch VM does not. Enrolling a new face or finger invalidates the key,
which is deliberate: someone who learns the passcode still cannot add a biometric and use
your key.

### When the server asks its own questions

Some servers do not want a password; they want to ask. A one-time code, an expired password
that must be changed, a challenge from a hardware token — all of these arrive as RFC 4256
*keyboard-interactive* authentication, where the server sends questions and the client puts
them to you.

Apex Terminal offers this automatically. There is nothing to configure and nothing to save:
if a connection's stored credentials do not get in and the server says it will ask
questions, a sheet appears with them. What it shows is the server's own wording, never
rewritten — the difference between "Password" and "Verification code" is the difference
between typing the right secret and the wrong one, and RFC 4256 § 3.3 requires the client to
leave it alone. A question the server marks as secret gets a secure field; one it marks as
visible does not.

A server may ask more than once — a password, then a code — and each round is its own sheet.
It may also send a round with no questions at all, which the protocol uses to display a
message; that one is answered without interrupting you.

Dismissing a sheet cancels the sign-in immediately, and nothing is sent. That matters: blank
answers would look to the server like a wrong password and would spend one of the few
attempts `MaxAuthTries` allows.

### Secure Enclave keys

Settings → Keys → Generate offers a second choice: **where the private key lives**. The
default is the Keychain, which is what everything above describes. The other option is the
**Secure Enclave**, and it is a different kind of key.

The private half is created inside the Enclave and never exists outside it. There is no
file, no PEM, no Keychain item holding key material — only a wrapped reference that this
device's Enclave can unwrap and nothing else can. Signing happens inside the Enclave; the
app sends it the bytes to sign and receives a signature back. Apple states the guarantee
plainly: *"you can't extract the private key from the Secure Enclave"*
([Storing Keys in the Secure Enclave](https://developer.apple.com/documentation/security/storing-keys-in-the-secure-enclave)).

What that buys you: someone who takes the phone and defeats its Keychain still cannot walk
away with a key that works anywhere else. What it costs you:

* The key is **ECDSA P-256** — the only signing curve the Enclave holds. Every current
  OpenSSH server accepts it; the app states the algorithm rather than offering a picker.
* It **cannot be exported, backed up, synced, or moved.** The export sheet lists it by name
  as unexportable rather than quietly leaving it out, and the key list marks it. If the
  device is lost or erased, the key is gone: remove its public key from your servers and
  generate a new one.
* Restoring a backup onto a new device brings the key's *record* but not the key. The list
  says so on that device, in those words.

The Face ID toggle still applies and means something stronger here: with it on, the Enclave
itself demands a biometric check before **every signature**, and destroys the key if the
device's biometric enrolment changes. With it off, the key needs only an unlocked device —
which is also what lets such a key serve a Files.app folder, where nobody is present to
answer a prompt.

The check is asked for when you tap Connect, before the connection is opened, rather than
part-way through the handshake. That is deliberate: the Enclave signs on the networking
thread, and a prompt raised there would hold up every other session while it waited. It
also means cancelling the prompt says you cancelled, instead of reporting a connection
failure.

Adding one to a server is the same as any other key:

```bash
# On the server
echo 'ecdsa-sha2-nistp256 AAAA... phone@apexterminal' >> ~/.ssh/authorized_keys
```

`ssh-keygen -l` reads the line and reports the same SHA-256 fingerprint the app shows, so
you can check you pasted the right key.

## Host keys

The first time you connect, the app shows the server's SHA-256 fingerprint and asks you to
confirm it. Check it against the server:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

A fingerprint nobody checks is decoration, so the sheet is written to be read.

If the key later **changes**, the app refuses to connect and shows both fingerprints. That
happens when a server is rebuilt or rekeyed — and it is also exactly what an interception
attack looks like. Continuing is possible but deliberately not the obvious action.

Settings → Known hosts lists everything remembered, with the option to forget an entry.

## Algorithm support

The SSH implementation is built on `swift-nio-ssh`, with RSA added
(see `../DECISIONS.md` D-007).

| | Supported |
| --- | --- |
| Key exchange | `curve25519-sha256`, `curve25519-sha256@libssh.org`, `ecdh-sha2-nistp256/384/521` |
| Host keys | `ssh-ed25519`, `ecdsa-sha2-nistp256/384/521`, `rsa-sha2-512`, `rsa-sha2-256` |
| User keys | `ssh-ed25519`, `ecdsa-sha2-nistp256` (including keys held in the Secure Enclave), `rsa-sha2-512`, `rsa-sha2-256` |
| Authentication methods | `publickey` (including OpenSSH certificates), `keyboard-interactive` (RFC 4256), `password`, `none` |

A P-384 or P-521 **host** key is accepted, but a P-384 or P-521 **user** key cannot be
imported: the key-file parser handles Ed25519, ECDSA P-256 and RSA. If you have one, the
import fails with a message saying so rather than a generic error.
| Ciphers | `aes128-gcm@openssh.com`, `aes256-gcm@openssh.com`, `aes256-ctr` with `hmac-sha2-256-etm@openssh.com` |

**Not supported, deliberately:**

* `ssh-rsa` — this names SHA-1, which OpenSSH disabled by default in 8.8 because
  chosen-prefix collisions are practical. Supporting it would ship a downgrade a server
  could ask for. Use `rsa-sha2-256` or `rsa-sha2-512`; any OpenSSH from 7.2 onwards offers
  them for the same key, so no new key is needed.
* DSA — removed from OpenSSH entirely in 10.0.
* `hmac-sha2-256` without `-etm` — AES-CTR is supported only with encrypt-then-MAC. SSH's
  original construction authenticates the plaintext and encrypts the length, so a receiver
  must decrypt before it can authenticate; the ETM variant rejects a forged packet before
  the cipher touches it. Every server that offers CTR with the plain MAC also offers it
  with the ETM one, so nothing is lost by declining the weaker option.
* `chacha20-poly1305@openssh.com` — not implemented. A server offering only ChaCha20
  cannot be reached; in practice such a configuration is rare, since disabling both AES
  families is unusual.

If a handshake fails on algorithms, the app says so specifically rather than reporting a
generic failure.

## The terminal

**On iPhone**, the accessory row above the keyboard carries the keys a phone keyboard
lacks: Escape, Tab, arrows, Home, End, Page Up/Down, and a **latching Control** — tap
`ctrl` then `c` to send ^C. Latching rather than chording, because holding a modifier
while tapping is awkward on glass.

**With a hardware keyboard**, keys map as you would expect, including Option as Meta and
the application-cursor mode that makes arrows work in `vim`. ⌘ is reserved for the app and
the system, so ⌘C copies rather than being sent to the remote host. Hold ⌘ on iPad to see
the shortcuts.

**Selecting text** — long-press and drag, or double-tap to select a whole line. A line
that wrapped is treated as one line, and copying it gives back the text *without* the
wrap's newline; pasting a newline into a shell would run half a command.

**Pasting** — multi-line pastes ask for confirmation first, for the same reason. The
confirmation can be turned off in Settings. Bracketed paste is used when the remote
program asks for it.

**Searching** — Session menu → Find searches the whole scrollback, including text that
wrapped across lines.

**Scrolling** — two fingers. One finger is reserved for selection so the two gestures
cannot fight. When a program has enabled mouse reporting, two-finger scrolling becomes
wheel events for that program instead.

## Post-quantum key exchange

Where the system provides ML-KEM — iOS 26 and macOS 26 and later — the app offers
`mlkem768x25519-sha256` ahead of the classical exchanges, and OpenSSH 9.x and newer will
take it (D-048).

A hybrid is no weaker than either half: an attacker has to break X25519 *and* ML-KEM-768 to
recover the session key. The reason to adopt it now rather than later is that SSH traffic
captured today can be decrypted whenever a quantum computer arrives, and a session recorded
this year is still worth reading in ten.

There is nothing to configure and nothing to see: the exchange is chosen during the
handshake, and a server that does not offer it gets the classical one exactly as before.
The ML-KEM implementation is Apple's, from CryptoKit; what this project added is the SSH
plumbing around it.

## Jump hosts

Edit a connection → *Jump hosts*, and pick saved connections to hop through, in order —
the equivalent of `ssh -J` (D-047).

A chain is built from saved connections rather than typed addresses, and that is the point:
each hop is a connection in its own right, with its own credentials and its own host key
checked against its own record. A chain is therefore not one trust decision, it is as many
as it has hops.

What the bastion can and cannot do is worth being clear about. It makes the TCP connection
to the next hop on your behalf and carries the bytes, so it knows *where* you are going. It
cannot read what you send: the SSH session is encrypted between this device and the far
server, and the bastion is carrying an opaque stream. It can drop the connection — and when
it does, the session it carries ends rather than appearing to survive.

Two rules the app enforces quietly:

* A connection cannot jump through itself, and a hop named twice is used once. Following
  either would recurse until something ran out.
* A hop naming a connection that has since been deleted is skipped, and the editor shows
  it as *A deleted connection* rather than dropping it from the list — a chain silently
  getting shorter changes where the traffic goes.

When a hop fails, the message names it: *Could not connect through Bastion*, with the
underlying reason beneath. Which hop failed is the whole question when a chain does not
come up.

## Certificates

OpenSSH certificates are supported in both directions (D-046).

**Your key, certified.** Settings → Keys → a key → *Add a certificate*, and paste the file
`ssh-keygen -s` produced for it — the one ending in `-cert.pub`. The app checks it was
issued for that key and refuses it otherwise, because a certificate for a different key
authenticates nothing and the server's refusal would not say so. From then on the key is
offered together with its certificate, and a server that trusts the issuing authority lets
it in without the key appearing in any `authorized_keys` file.

A certificate that is outside its validity window is not offered at all — the bare key
still is. Being told "your certificate expired on Tuesday" beats being told "permission
denied".

**The server's key, certified.** Settings → Trusted authorities. Give the authority's own
public key and the host patterns it may vouch for, in OpenSSH's style: `*.example.com`
matches anything under it, `?` matches one character. A server whose host key carries a
certificate from a trusted authority connects with no fingerprint to compare — which is a
security improvement rather than a shortcut, because comparing fingerprints is the step
people skip.

Three rules worth knowing:

* An authority is trusted only for the hosts its patterns match. `*` trusts it for every
  server in the world, and the interface colours that pattern as a warning.
* A certificate that fails validation — expired, wrong host name, unknown authority — is
  refused outright. It never becomes a fingerprint prompt, because a prompt is something
  people tap through.
* When a server presents a certificate and no trusted authority applies, the ordinary
  fingerprint prompt appears — and what gets remembered is the key *inside* the
  certificate. Certificates are reissued routinely, and remembering one would turn every
  renewal into "the host key has changed", which is the warning that has to mean something.

Set up on the server side, briefly:

```bash
# On the machine holding the authority
ssh-keygen -t ed25519 -f ca -C "example-ca"
ssh-keygen -s ca -I alice -n alice -V +52w alice_key.pub   # a user certificate
ssh-keygen -s ca -h -I web1 -n web1.example.com -V +52w /etc/ssh/ssh_host_ed25519_key.pub

# On the server
TrustedUserCAKeys /etc/ssh/ca.pub                          # trust the CA for logins
HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub     # present its own certificate
```

## Port forwarding

Session menu → **Port Forwards**. Three kinds, the same three `ssh` offers:

* **Local** (`ssh -L`) — this device listens; anything that connects is carried through the
  server to a destination the *server* can reach. This is how you reach a database bound to
  the server's own loopback: point the rule at `127.0.0.1:5432` and connect your client to
  `127.0.0.1:<the port you chose>`.
* **Remote** (`ssh -R`) — the server listens; anything that connects to it *there* is
  carried back to a destination this device can reach. The server has to allow it
  (`AllowTcpForwarding`, on by default), and binding anything other than its own loopback
  additionally needs `GatewayPorts`, which most configurations leave off. Port 0 asks the
  server to choose a port and it reports which one it took.
* **Dynamic** (`ssh -D`) — this device listens as a SOCKS5 proxy and each client names its
  own destination, which the server then connects to. One rule instead of one per address.
  `CONNECT` only, no authentication: the proxy is bound to `127.0.0.1`, where a password
  would protect against nothing that reaching `127.0.0.1` has not already defeated, and
  `BIND`/`UDP ASSOCIATE` would require listening on the network for a peer to call back,
  which is exactly what a forward on a phone must not do.

A rule is saved with the connection, can be named, and can be set to start with it.

Two limits worth knowing before you rely on one:

* **A forward lives as long as the app does.** iOS suspends an app that is not on screen,
  and a suspended app's sockets stop being served. Nothing here keeps a tunnel alive in the
  background, and the screen says so rather than letting you find out later.
* **Local and dynamic forwards listen on `127.0.0.1` only.** A phone that listened on its
  Wi-Fi address would be offering a tunnel into your server to everything on whatever
  network it has joined.

## Diagnostics

Settings → Export diagnostics produces a report that contains **no** commands, terminal
output, hostnames, passwords, keys or tokens. That is a property of how records are
written rather than of a scrubbing pass: values are redacted at the point they are logged,
so there is nothing sensitive to remove afterwards.
