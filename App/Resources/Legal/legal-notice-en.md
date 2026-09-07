# Apex Terminal — User Notice

This is what the app does with your keys, in plain words. It is not the Privacy Policy or the Terms; it is the page to read before you trust the app with anything.

## What the app does

- Opens SSH sessions to servers you add, directly or through a Cloudflare Tunnel.
- For tunnelled hosts, signs you in to Cloudflare Access in a system browser and uses the resulting token to open the tunnel on your behalf — or, if you gave the connection an Access service token, presents that instead, with no browser. The app never sees your Cloudflare password.
- Stores your connections, keys, passwords, Access tokens, host keys and snippets on your device so you do not re-enter them.
- Optionally syncs connections, snippets, host keys and the private keys you choose across your own devices through your own iCloud account. Passwords never sync.

## What the app does not do

- It has no account, no server, no analytics, no crash reporter and no telemetry. Nothing is sent to the developer.
- It never sends a credential anywhere except to the server you are authenticating to, or an Access token back to Cloudflare.
- It never weakens a TLS check or a host-key check. There is no setting, hidden or otherwise, that accepts an invalid certificate or a changed host key without asking you.
- It never writes your terminal output to disk. Scrollback is memory only.
- It does not record what you type unless you turn command history on. Turning it off deletes the record, not hides it.
- It does not filter secrets out of command history, because a filter that mostly works would be worse than none. If you turn history on and type a password on a command line, it is recorded, as your shell would record it.
- It does not sync anything unless you turn iCloud sync on.

## Where your keys live

- **On the device:** in Apple's Keychain, readable only while the device is unlocked. With iCloud sync off, every item is marked this-device-only and cannot travel in iCloud Keychain or in a backup restored to another device. You can additionally lock a key behind Face ID or Touch ID. A key locked this way is tied to the biometrics enrolled now; enrolling a new face or finger makes it unusable, so someone who learns your passcode cannot add themselves and read it.
- **In iCloud, only if you turn sync on:** a private key syncs only if you chose that for it, and only if it is *not* Face ID/Touch ID protected. It goes through iCloud Keychain, which Apple encrypts end to end. Passwords never sync. Biometric-protected keys never leave the device. Apple does not allow it and the app does not try.
- **Nowhere else.** A private key is never sent to a server; the server sees a signature made with it.

## What is protected, and how

**Someone impersonating your server.** Every connection verifies the server's host key. A server you have never connected to must be confirmed by you, with its SHA-256 fingerprint on screen. A server whose key has changed since last time is refused; the app shows both fingerprints and waits. A reconnection after a dropped link goes through the same check.

**Someone between you and Cloudflare.** TLS is validated by the operating system. The app contains no way to accept a bad certificate.

**Someone steering the Cloudflare sign-in.** The app accepts only sign-in details that Cloudflare has signed, and only for a login domain under `cloudflareaccess.com`. A server cannot point you at a fake login page through the app.

**Someone stealing or reusing an Access token.** Tokens are checked for signature, audience, issuer and expiry before they are sent. A token for one Access application cannot be used against another.

**Your logs.** Nothing you type and nothing the server prints is ever logged. Hostnames and tokens are redacted as each log line is written, not scrubbed afterwards, so the diagnostics export is a copy of what was logged. Redaction keeps only the last two labels of a server name (`<host:…>.example.com`); IP addresses become `<ip>`.

**Retries.** Only network and tunnel failures are retried automatically. A refused host key, a failed certificate check, a rejected password or a refused Access sign-in stops and shows you the error. The app will not retry past a security check.

**Encryption in transit.** SSH uses authenticated ciphers only: AES-GCM, ChaCha20-Poly1305, or AES-CTR with encrypt-then-MAC. No CBC, no RC4, no unauthenticated mode. The app implements no cryptography of its own; every primitive comes from Apple's CryptoKit, swift-crypto, libsodium or OpenBSD's bcrypt_pbkdf.

**Pasting.** A multi-line paste asks for confirmation before it is sent, unless you turn that off in Settings.

**The App Switcher.** With "Hide content in the App Switcher" on, which it is by default, the app's logo covers the terminal whenever the app is not in front, so the system's app-switcher snapshot shows no terminal content.

## What you have to check

The first time you connect to a server, the app shows the server's key fingerprint and asks you to confirm it. Compare it with what the server itself reports (`ssh-keygen -lf` on the host key file, or ask whoever administers it). If you confirm a fingerprint without checking, you are trusting whoever answered; the app cannot tell the difference on a first connection. After that, a changed key is refused until you look at both fingerprints and decide. The app will not retry past that prompt.

## Automatic reconnection

If a connection drops because of the network or the tunnel, the app reconnects. It does not retry a rejected password, a changed host key or a failed certificate check; those stop and wait for you. After a reconnection the shell is new: different working directory, nothing running. The app draws a line in the terminal, labelled with its own name, so you can see where the break was.

## iCloud, in one paragraph

The switch is off until you turn it on. On: connection list, snippets, known host keys and the non-secret details of your keys go to your iCloud private database; private keys you chose for it, if not biometric, go through iCloud Keychain; passwords never do. Never: biometric keys, command history, the list of recently open sessions, diagnostics. Access tokens stay on the device that signed in. The developer cannot read any of it; whether Apple can is a property of your iCloud account settings, not of this app. Off stops syncing. "Delete all data" clears iCloud too. A host key synced from another device is trusted here for a host this device has not met, the same as one you confirmed here, so someone who controls your iCloud account could plant one; a synced key that differs from one this device already trusts is not applied; Settings → iCloud shows the disagreement and you choose which key to keep. Because your Apple Account can now reach your connection list and host keys, keep two-factor authentication on for it.

## What you have to do yourself

1. **Verify the first fingerprint.** If you confirm an attacker's fingerprint, every later connection to that identity is compromised, and the app cannot tell.
2. **Take a changed key seriously.** If the app says the key changed and you did not reinstall or rekey the server, stop and ask the administrator.
3. **Keep a device passcode.** Every protection above assumes the device is locked when you are not using it.
4. **Use Face ID or Touch ID for keys that matter.** It costs one glance per connection and means a stolen passcode is not enough.
5. **If you turn iCloud sync on, secure the iCloud account.** Two-factor authentication on the Apple Account is the minimum.
6. **Do not type secrets on a command line with history on.** What you type is what is stored.
7. **Revoke on the server, not just on the phone.** Deleting a key from the app does not remove the public key from the server's `authorized_keys`. Losing a device means revoking there, and revoking the Access session in your Cloudflare dashboard.
8. **Do not install root certificates you do not trust.** The app trusts the operating system's trust store.

## What the app cannot protect you from

- A device that is already compromised, or a trusted root certificate someone else installed on it.
- A first-connection fingerprint you confirmed without checking.
- Whoever runs your network seeing which hostnames you connect to. The content is encrypted; the destination is not hidden.
- Someone who can unlock your device and open the app. They can use any stored connection whose key is not biometric-protected.
- Someone who controls your Apple Account, if iCloud sync is on.
- Anything you copy from the terminal stays on the clipboard for one minute by default, after which iOS removes it; Settings → Security changes the interval or turns this off. Public keys copied from the key list stay until replaced.
- One dependency, libsodium, is included as a prebuilt binary from its maintainer rather than built from source. Its role is limited to opening the sealed Cloudflare sign-in result, which is independently verified afterwards, and to the ChaCha20-Poly1305 SSH cipher.
- Cloudflare's FedRAMP endpoints are not supported.

## Wiping it

**Settings → Delete all data** closes every session and removes every connection, key, password, Cloudflare sign-in, snippet, history entry, the list of recently open sessions and every known host key from the device, and the app's data from iCloud if sync was on. Single host keys can also be removed in **Settings → Known hosts**. Deleting the app removes its files, but iOS does not promise to remove Keychain items with it, so run Delete all data first. Neither touches your servers or your Cloudflare account; remove the public key from `authorized_keys` or revoke the Access session there.

## Open source

The app includes code under Apache-2.0 (swift-nio family, swift-crypto), ISC (swift-sodium, bcrypt_pbkdf) and BSD-3-Clause (Blowfish). Their notices are in the app under Settings → Legal → Open-source licences. Cloudflare, Cloudflare Tunnel and Cloudflare Access are trademarks of Cloudflare, Inc.; Apex Terminal is not affiliated with Cloudflare.
