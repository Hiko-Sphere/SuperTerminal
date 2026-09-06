# SuperTerminal — Privacy Policy

**Effective date:** [effective date]

SuperTerminal collects nothing about you. The developer runs no server, so there is nowhere for data to go. This page says concretely what the app stores, where, and what leaves your device, because "we value your privacy" is not a claim anyone can check.

## The short version

- Your keys, passwords and connections stay on your device, in Apple's Keychain and the app's own protected storage.
- The only network traffic is to the servers you connect to and, for tunnelled hosts, to Cloudflare on your behalf.
- If you turn on iCloud sync, some of your data is stored in your own iCloud account. The developer cannot read it.
- There is no analytics, no crash reporter, no telemetry, no advertising, no account.

## What the app stores on your device

| Data | Where | Protected how | Leaves the device? |
| --- | --- | --- | --- |
| Connection list (names, hostnames, usernames, ports) | App storage | Encrypted while the device is locked | Only if you turn iCloud sync on |
| SSH private keys | Keychain | Readable only while the device is unlocked; optionally locked behind Face ID or Touch ID as well | Never sent to a server; the server sees a signature, not the key. Through iCloud Keychain only if you turn sync on and choose that for the key; never when Face ID or Touch ID protected |
| SSH passwords | Keychain | Readable only while the device is unlocked | To the server you are signing in to. Not synced |
| Cloudflare Access tokens | Keychain | Readable after the device has been unlocked once since restart, so a reconnection can work from your pocket | Only back to Cloudflare, as the credential for your own connection. Not synced |
| Cloudflare Access service tokens (only if you enter one for a connection) | Keychain | Readable only while the device is unlocked | Only to Cloudflare, as the credential for that connection. Not synced; deleted with the connection |
| Known host keys | App storage | Encrypted while locked; excluded from device backups | Only if you turn iCloud sync on |
| Snippets | App storage | Encrypted while locked; included in device backups | Only if you turn iCloud sync on |
| Settings | App preferences | Standard app storage | No |
| List of recently open sessions | App storage | Connection names and times, kept for up to seven days; encrypted while locked; excluded from backups | No |
| Terminal scrollback | Memory only | Gone when the session or the app ends. Never written to disk | No |
| Command history | **Not recorded unless you turn it on.** Then: app storage, encrypted while locked, excluded from backups, last 500 commands | No. Deleted the moment you turn it off |

With iCloud sync off, every Keychain item is marked this-device-only. It cannot travel in iCloud Keychain and cannot be restored from a backup onto a different device.

Face ID and Touch ID are handled entirely by iOS. The app never sees your face or fingerprint data; it only learns whether the system's check passed. A key protected this way becomes unusable if a new face or finger is enrolled on the device, so someone who learns your passcode cannot add themselves and read it.

## What leaves your device

Only three kinds of network traffic exist, and you choose all three.

**1. To the servers you connect to.** SSH traffic, encrypted end to end between your device and the server: your username, your key's signature or your password, what you type, and what the server sends back. When a Cloudflare Tunnel carries the connection, Cloudflare relays the encrypted SSH bytes but cannot read them; host-key verification protects you from the tunnel itself. The server keeps its own login records, as any server does.

**2. To Cloudflare, for hosts you have marked as tunnelled.** The app asks the host which Access application protects it, fetches Cloudflare's signing keys, opens the sign-in page in a system browser, collects the resulting token, and presents that token to Cloudflare when opening the tunnel. Your sign-in itself happens in the browser, with Cloudflare and your identity provider; the app never sees the password you type there. All of this goes to Cloudflare's own endpoints, as it would if you used Cloudflare's own tools. What Cloudflare records about it is governed by Cloudflare's privacy policy and your agreement with them.

**3. To iCloud, only if you turn it on.** See the next section.

Nothing goes to the developer. There is no developer server, no analytics SDK, no crash reporter and no tracking domain. The app's App Store privacy label says "Data not collected" because that is true.

As with any SSH client, the operator of the network you are on can see which hostnames your device connects to. The content of the connection is encrypted.

## iCloud sync

iCloud sync is **off** until you turn it on in Settings. When it is on:

- **Your connection list, snippets and known host keys** sync through your own iCloud account, in the app's private database there, together with the non-secret details of your SSH keys (name, algorithm, public half, fingerprint, creation date, and whether the key is Face ID/Touch ID or passphrase protected or stored in iCloud Keychain) so the list makes sense on your other devices. Apple encrypts this data in transit and at rest. The developer has no access to it. Whether Apple itself can read it is a property of your iCloud account settings, not of this app.
- **An SSH private key syncs only if you choose that for the key** when you create or import it, and only if it is not protected by Face ID or Touch ID. It then travels through iCloud Keychain, Apple's end-to-end-encrypted keychain sync, if iCloud Keychain is turned on for your device. **Passwords never sync**; each device asks for them again.
- **Keys protected by Face ID or Touch ID never sync.** Apple does not allow it, and the app does not try. They exist only on the device where you created or imported them.
- **Command history, the list of recently open sessions and diagnostics never sync**, whatever the switch says.
- **Cloudflare Access tokens, service tokens and settings are not part of the sync.** Each device signs in to Access on its own, or asks for the service token again.

Sync means "the same on every device signed in to your Apple Account". A host key you trusted on one device is trusted on the others, for a host they have not met yet. If another device sends a key that differs from one this device already trusts, the app does not apply it: this device keeps the key it has, and Settings → iCloud shows the disagreement so you can choose which key to keep. A key you allowed to sync is on every device trusted for iCloud Keychain.

Because your iCloud account can then reach your connection list, your saved host keys and any keys you allowed to sync, that account becomes part of what protects your servers. Keep two-factor authentication on for your Apple Account.

Turning the switch off stops syncing; data already on each device stays there. **Delete all data** removes the app's data from iCloud as well as from this device. If another of your devices has already synced a copy, run Delete all data there as well.

## Command history

Off by default. If you turn it on, the app records the last 500 commands you typed, on this device only, encrypted while the device is locked and excluded from backups. It is not filtered for secrets: a password typed on a command line is recorded exactly as your shell's own history would record it. The app does not try to filter these out, because a filter that mostly works would be trusted more than it deserves. Turning history off deletes the file. Turning it on again later starts from nothing.

## Diagnostics

Settings can export a diagnostics report to help with a support question. It contains no commands, no terminal output, no passwords, keys or tokens, and no full hostnames. At the moment each log line is written, a hostname is replaced with a short one-way digest that keeps only the last two labels of the name (`bastion.corp.example.com` becomes `<host:…>.example.com`; IP addresses become `<ip>`), and a token with its length and a digest, so the export is a copy of what was logged, not a clean-up pass that might miss something. The report is shown on screen and is not saved anywhere unless you share it. You decide whether to share it and with whom; the app does not send it anywhere. If you send one to the developer, it is kept only as long as needed to answer your question.

## What the developer receives

Nothing from the app. Apple may show the developer aggregated App Store statistics, and, if you have chosen "Share with App Developers" in your device's Analytics settings, crash logs that iOS collects. That is Apple's mechanism, described in Apple's privacy policy; the app adds nothing to it and contains no crash reporter of its own.

## The assistant

The assistant answers questions about commands and terminal output. On a device with Apple Intelligence it runs on the device and nothing leaves it. If you configure a provider in Settings, each request sends that provider only what the assistant screen shows you first: your question, the server's platform, the last command, and the terminal text you chose to include. Your API key is kept in the device Keychain and sent to the provider in the request header. The provider's own privacy policy governs what it does with the request. The app never sends terminal text anywhere on its own.

## Screen sharing

Screen sharing (VNC) shows a remote computer's screen and sends it your touches, keys and pointer. The picture exists only while it is shown; it is not stored or sent anywhere else. The VNC protocol itself is unencrypted and its password check is weak, so unless you turn the option off in the connection's settings the screen travels inside the SSH connection and is protected by its encryption. Text the remote computer copies is offered to you and goes on your clipboard only when you say so. A VNC password is kept in this device's Keychain and does not sync.

## App lock

With App Lock on, the app asks for its own passcode — or Face ID or Touch ID, if you allow it — when it opens and when it comes back after the time you chose. The passcode is never stored: the device Keychain holds a salted PBKDF2 derivation of it, on this device only. Face ID and Touch ID are handled entirely by iOS; the app learns only whether the check passed. Wrong guesses are slowed down, never punished by deleting anything.

## Your rights over your data

Everything the app holds is on your device or in your own iCloud account, under your control. There is no copy with the developer, so there is nothing for the developer to give you, correct or delete on request. To see your data, open the app. To delete it, see below. Because the developer receives nothing, there is no request to make and no address to make it to; the controls that answer these rights are in the app itself, under Settings.

## Deleting everything

**Settings → Delete all data** closes every open session and removes every connection, SSH key, saved password, Cloudflare Access sign-in, snippet, command-history entry, the list of recently open sessions and every known host key from this device, and the app's data from iCloud if sync was on. Individual host keys can also be removed in **Settings → Known hosts**.

**Deleting the app** removes its files from the device. iOS does not promise to remove an app's Keychain items when the app is deleted, so run Delete all data first if you want keys, passwords and tokens gone as well, and to clear iCloud if sync was on.

Neither action changes anything on your servers or at Cloudflare. To revoke access there, remove the public key from the server's `authorized_keys`, or revoke the session in your Cloudflare Zero Trust dashboard.

## App Store privacy label

Data collected: none. Tracking: none. The app's privacy manifest declares the two required-reason APIs it uses (file timestamps for its own container, and standard preferences for settings), no collected data types and no tracking domains.

## Children

The app is a tool for administering servers and is rated accordingly on the App Store. It does not collect data from anyone, of any age.

## Changes

A new version of this policy ships with a new version of the app, dated at the top. If the app ever starts sending data somewhere new, that will be stated here in plain words before it happens, not after.
