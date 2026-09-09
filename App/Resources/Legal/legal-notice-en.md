# Apex Terminal — User Notice

This is what the app does with your keys, in plain words. It is not the Privacy Policy or the Terms; it is the page to read before you trust the app with anything.

## What the app does

- Opens SSH sessions to servers you add, directly or through a Cloudflare Tunnel.
- For tunnelled hosts, signs you in to Cloudflare Access in a system browser and uses the resulting token to open the tunnel on your behalf — or, if you gave the connection an Access service token, presents that instead, with no browser. The app never sees your Cloudflare password.
- Stores your connections, keys, passwords, Access tokens, host keys and snippets on your device so you do not re-enter them.
- Browses and transfers files over SFTP on the same connection, and — for connections you mark — publishes that server in the Files app.
- Forwards ports in either direction, and offers a SOCKS5 proxy, over a connection you have already made.
- Opens remote screens over VNC, on their own or inside an SSH connection.
- Reuses one SSH connection for everything that matches it: a shell, a second shell, a file browser and a forward on the same server share one authentication rather than each making their own.

## What the app does not do

- It has no account, no server, no analytics, no crash reporter and no telemetry. Nothing is sent to the developer.
- It never sends a credential anywhere except to the server you are authenticating to, or an Access token back to Cloudflare.
- It never weakens a TLS check or a host-key check. There is no setting, hidden or otherwise, that accepts an invalid certificate or a changed host key without asking you.
- It never writes your terminal output to disk. Scrollback is memory only.
- It does not record what you type unless you turn command history on. Turning it off deletes the record, not hides it.
- It does not filter secrets out of command history, because a filter that mostly works would be worse than none. If you turn history on and type a password on a command line, it is recorded, as your shell would record it.
- It does not sync anything. iCloud sync is not available in this version; everything stays on the device it was created on.

## Where your keys live

- **On the device:** in Apple's Keychain, readable only while the device is unlocked. With iCloud sync off, every item is marked this-device-only and cannot travel in iCloud Keychain or in a backup restored to another device. You can additionally lock a key behind Face ID or Touch ID. A key locked this way is tied to the biometrics enrolled now; enrolling a new face or finger makes it unusable, so someone who learns your passcode cannot add themselves and read it.
- **In the Secure Enclave:** a key generated there has no copy anywhere. The private half is created inside the chip and cannot be read out of it — not by this app, not by any app, not by Apple. Signing happens inside the Enclave and the app receives only the signature. Such a key can be set to require Face ID or Touch ID for every signature. It cannot be backed up, exported or moved to another device, which is the point and also the risk: lose the device and the key is gone.
- **Not in iCloud.** Sync is not available in this version, so nothing — no key, no connection, no host key — leaves this device through it.
- **Nowhere else.** A private key is never sent to a server; the server sees a signature made with it.

## What is protected, and how

**Someone impersonating your server.** Every connection verifies the server's host key. A server you have never connected to must be confirmed by you, with its SHA-256 fingerprint on screen. A server whose key has changed since last time is refused; the app shows both fingerprints and waits. A reconnection after a dropped link goes through the same check.

**Someone between you and Cloudflare.** TLS is validated by the operating system. The app contains no way to accept a bad certificate.

**Someone steering the Cloudflare sign-in.** The app accepts only sign-in details that Cloudflare has signed, and only for a login domain under `cloudflareaccess.com`. A server cannot point you at a fake login page through the app.

**Someone stealing or reusing an Access token.** Tokens are checked for signature, audience, issuer and expiry before they are sent. A token for one Access application cannot be used against another.

**Your logs.** Nothing you type and nothing the server prints is ever logged. Hostnames and tokens are redacted as each log line is written, not scrubbed afterwards, so the diagnostics export is a copy of what was logged. Redaction keeps only the last two labels of a server name (`<host:…>.example.com`); IP addresses become `<ip>`.

**Questions the server asks.** Some servers ask instead of taking a password: a one-time code, a token, a password that has expired. The app shows what the server sent, word for word, without rewriting it, and sends back exactly what you typed. Those answers are never stored, never logged and never offered again — the next connection asks again.

**A server borrowing your key.** Agent forwarding is off unless you turn it on for a connection. When it is on, and only while that session is open, programs on that server can ask this device to sign with the one key that connection uses. They cannot read the key, they cannot reach any other key on the device, and signing stops the moment you disconnect. Anything running as root on that server can do this, so turn it on for machines you control and leave it off for shared ones.

**Forwarded ports.** A forward carries bytes between a listener and a destination; the app does not read, record or store what goes through one. A local or dynamic forward listens on this device only. A remote forward listens on the server, where its reach is the server's `sshd` configuration, not this app's choice.

**Retries.** Only network and tunnel failures are retried automatically. A refused host key, a failed certificate check, a rejected password or a refused Access sign-in stops and shows you the error. The app will not retry past a security check.

**Encryption in transit.** SSH uses authenticated ciphers only: AES-GCM, ChaCha20-Poly1305, or AES-CTR with encrypt-then-MAC. No CBC, no RC4, no unauthenticated mode. The app implements no cryptography of its own; every primitive comes from Apple's CryptoKit, swift-crypto, libsodium or OpenBSD's bcrypt_pbkdf.

**Pasting.** A multi-line paste asks for confirmation before it is sent, unless you turn that off in Settings.

**The App Switcher.** With "Hide content in the App Switcher" on, which it is by default, the app's logo covers the terminal whenever the app is not in front, so the system's app-switcher snapshot shows no terminal content.

## What you have to check

The first time you connect to a server, the app shows the server's key fingerprint and asks you to confirm it. Compare it with what the server itself reports (`ssh-keygen -lf` on the host key file, or ask whoever administers it). If you confirm a fingerprint without checking, you are trusting whoever answered; the app cannot tell the difference on a first connection. After that, a changed key is refused until you look at both fingerprints and decide. The app will not retry past that prompt.

## Automatic reconnection

If a connection drops because of the network or the tunnel, the app reconnects. It does not retry a rejected password, a changed host key or a failed certificate check; those stop and wait for you. After a reconnection the shell is new: different working directory, nothing running. The app draws a line in the terminal, labelled with its own name, so you can see where the break was.

## iCloud, in one paragraph

There is no sync in this version. Settings shows the switch and says why it is unavailable rather than hiding it, because someone looking for sync deserves to find out where it stands. Nothing is uploaded to iCloud by this app: not connections, not keys, not host keys, not snippets. Everything is on the device you created it on, and a backup file you make yourself is the only way to move it. If sync is offered in a later version, it will be off until you turn it on, and this notice will say what it carries before it carries anything.

## Files in the Files app

A connection you mark with **Show in the Files app** appears there like any other file provider, so any app that can open a document can open one from your server. The extension that does this signs in as the connection does, using the same credentials from the same Keychain access group; it is not given a copy of them, and it can reach nothing the app itself cannot. A server you have not marked is not visible there at all.

## What you have to do yourself

1. **Verify the first fingerprint.** If you confirm an attacker's fingerprint, every later connection to that identity is compromised, and the app cannot tell.
2. **Take a changed key seriously.** If the app says the key changed and you did not reinstall or rekey the server, stop and ask the administrator.
3. **Keep a device passcode.** Every protection above assumes the device is locked when you are not using it.
4. **Use Face ID or Touch ID for keys that matter.** It costs one glance per connection and means a stolen passcode is not enough.
5. **Turn agent forwarding on deliberately, and off again.** It is per connection and off by default. A server you do not administer should not have it.
6. **Do not type secrets on a command line with history on.** What you type is what is stored.
7. **Revoke on the server, not just on the phone.** Deleting a key from the app does not remove the public key from the server's `authorized_keys`. Losing a device means revoking there, and revoking the Access session in your Cloudflare dashboard.
8. **Do not install root certificates you do not trust.** The app trusts the operating system's trust store.

## What the app cannot protect you from

- A device that is already compromised, or a trusted root certificate someone else installed on it.
- A first-connection fingerprint you confirmed without checking.
- Whoever runs your network seeing which hostnames you connect to. The content is encrypted; the destination is not hidden.
- Someone who can unlock your device and open the app. They can use any stored connection whose key is not biometric-protected.
- Anything running as root on a server you turned agent forwarding on for, while that session is open.
- Whatever reaches a port you forwarded. A local or dynamic forward is reachable by other apps on this device; a remote forward is reachable by whatever the server's configuration allows.
- Anything you copy from the terminal stays on the clipboard for one minute by default, after which iOS removes it; Settings → Security changes the interval or turns this off. Public keys copied from the key list stay until replaced.
- One dependency, libsodium, is included as a prebuilt binary from its maintainer rather than built from source. Its role is limited to opening the sealed Cloudflare sign-in result, which is independently verified afterwards, and to the ChaCha20-Poly1305 SSH cipher.
- Cloudflare's FedRAMP endpoints are not supported.

## Wiping it

**Settings → Delete all data** closes every session and removes every connection, key, password, Cloudflare sign-in, snippet, history entry, the list of recently open sessions and every known host key from the device, and the app's data from iCloud if sync was on. Single host keys can also be removed in **Settings → Known hosts**. Deleting the app removes its files, but iOS does not promise to remove Keychain items with it, so run Delete all data first. Neither touches your servers or your Cloudflare account; remove the public key from `authorized_keys` or revoke the Access session there.

## Open source

The app includes code under Apache-2.0 (the swift-nio family, swift-crypto, and a fork of swift-nio-ssh maintained in this project), ISC (swift-sodium, bcrypt_pbkdf), BSD-3-Clause (Blowfish) and BoringSSL's combination of ISC and OpenSSL terms, vendored inside swift-crypto and swift-nio-ssl. Their notices are in the app under Settings → Legal → Open-source licences. Cloudflare, Cloudflare Tunnel and Cloudflare Access are trademarks of Cloudflare, Inc.; Apex Terminal is not affiliated with Cloudflare.
