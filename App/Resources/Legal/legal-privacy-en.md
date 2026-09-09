# Apex Terminal — Privacy Policy

**Effective date:** 9 September 2026

Apex Terminal collects nothing about you. The developer runs no server, so there is nowhere for data to go. This page says concretely what the app stores, where, and what leaves your device, because "we value your privacy" is not a claim anyone can check.

## The short version

- Your keys, passwords and connections stay on your device, in Apple's Keychain and the app's own protected storage.
- The only network traffic is to the servers you connect to and, for tunnelled hosts, to Cloudflare on your behalf.
- Nothing is stored anywhere else. iCloud sync is not available in this version, so this device is the only copy.
- Spotlight is off until you turn it on; Handoff carries which connection a session is for, and nothing else.
- There is no analytics, no crash reporter, no telemetry, no advertising, no account.

## What the app stores on your device

| Data | Where | Protected how | Leaves the device? |
| --- | --- | --- | --- |
| Connection list (names, hostnames, usernames, ports, jump hosts, port forwards) | App storage | Encrypted while the device is locked | No |
| SSH private keys | Keychain | Readable only while the device is unlocked; optionally locked behind Face ID or Touch ID as well | Never sent to a server; the server sees a signature, not the key |
| SSH keys generated in the Secure Enclave | Inside the Secure Enclave; the app stores only a reference to it | The private half never exists outside the chip and cannot be read by any software, including this app. Optionally requires Face ID or Touch ID for every signature | Never. It cannot leave the device even in a backup |
| OpenSSH certificates for your keys | App storage | Encrypted while the device is locked | Offered to servers that trust the issuing authority, as the certificate is meant to be |
| SSH passwords | Keychain | Readable only while the device is unlocked | To the server you are signing in to. Not synced |
| Cloudflare Access tokens | Keychain | Readable after the device has been unlocked once since restart, so a reconnection can work from your pocket | Only back to Cloudflare, as the credential for your own connection. Not synced |
| Cloudflare Access service tokens (only if you enter one for a connection) | Keychain | Readable only while the device is unlocked | Only to Cloudflare, as the credential for that connection. Not synced; deleted with the connection |
| Known host keys and trusted certificate authorities | App storage | Encrypted while locked; excluded from device backups | No |
| Snippets | App storage | Encrypted while locked; included in device backups | No |
| Settings | App preferences | Standard app storage | No |
| List of recently open sessions | App storage | Connection names and times, kept for up to seven days; encrypted while locked; excluded from backups | No |
| Terminal scrollback | Memory only | Gone when the session or the app ends. Never written to disk | No |
| Command history | **Not recorded unless you turn it on.** Then: app storage, encrypted while locked, excluded from backups, last 500 commands | No. Deleted the moment you turn it off |
| Answers to a server's own questions (one-time codes, tokens, expired-password prompts) | Nowhere | Held in memory for the moment it takes to answer the server | To that server only. Never stored, never logged, never offered again |
| VNC passwords | Keychain | Readable only while the device is unlocked | To the screen you are opening |
| Assistant API key, if you configure a provider | Keychain | Readable only while the device is unlocked | To the provider you chose, as the request's credential |

Every Keychain item is marked this-device-only. It cannot travel in iCloud Keychain and cannot be restored from a backup onto a different device. The one way anything moves to another device is a backup file you export yourself, and a backup that includes private keys is encrypted with a password you type and which is stored nowhere.

Face ID and Touch ID are handled entirely by iOS. The app never sees your face or fingerprint data; it only learns whether the system's check passed. A key protected this way becomes unusable if a new face or finger is enrolled on the device, so someone who learns your passcode cannot add themselves and read it.

## What leaves your device

Only three kinds of network traffic exist, and you choose all three.

**1. To the servers you connect to.** SSH traffic, encrypted end to end between your device and the server: your username, your key's signature or your password, what you type, and what the server sends back. When a Cloudflare Tunnel carries the connection, Cloudflare relays the encrypted SSH bytes but cannot read them; host-key verification protects you from the tunnel itself. The server keeps its own login records, as any server does.

**2. To Cloudflare, for hosts you have marked as tunnelled.** The app asks the host which Access application protects it, fetches Cloudflare's signing keys, opens the sign-in page in a system browser, collects the resulting token, and presents that token to Cloudflare when opening the tunnel. Your sign-in itself happens in the browser, with Cloudflare and your identity provider; the app never sees the password you type there. All of this goes to Cloudflare's own endpoints, as it would if you used Cloudflare's own tools. What Cloudflare records about it is governed by Cloudflare's privacy policy and your agreement with them.

**3. To a provider you configure for the assistant, and only when you ask it a question.** See *The assistant* below. There is no provider until you enter one.

Two things route other people's traffic rather than the app's own, and the app reads none of it:

- **Port forwards** move bytes between a listener and a destination you specified. Nothing that passes through a forward is inspected, recorded or stored.
- **Agent forwarding**, when you turn it on for a connection, lets programs on that server ask this device to sign a challenge with the one key that connection uses. The key is not sent; a signature is. It works only while that session is open.

Nothing goes to the developer. There is no developer server, no analytics SDK, no crash reporter and no tracking domain. The app's App Store privacy label says "Data not collected" because that is true.

As with any SSH client, the operator of the network you are on can see which hostnames your device connects to. The content of the connection is encrypted.

## iCloud sync

**There is no iCloud sync in this version.** The switch is shown in Settings, disabled, with the reason next to it, because someone looking for sync should be told where it stands rather than left wondering. Nothing this app holds is uploaded to iCloud: not your connection list, not your keys, not your host keys, not your snippets, not your settings.

That means this device is the only copy. To move to a new device, export a backup from **Settings → Backup** and restore it there; a backup that includes private keys is encrypted with a password you type and which is stored nowhere, so losing it loses the backup.

If sync is offered in a future version it will be off until you turn it on, and this policy will describe exactly what it carries before it carries anything.

## Files in the Files app

A connection you mark with **Show in the Files app** is published there through a File Provider extension, so other apps can open documents from that server. The extension runs separately from the app and authenticates the same way, reading the same credentials from the same Keychain access group — it holds no second copy of anything and can reach no server you have not marked. File contents pass between the server and the app that asked for them; nothing is retained beyond the cache iOS itself manages for the Files app.

## Reused connections

Opening a second thing on a server you are already connected to reuses the connection that is already open, when everything about it matches: the same host and port, the same user, the same key or password, the same jump hosts, the same tunnel and the same agent-forwarding choice. This means one authentication instead of several. It never merges two different identities: change any of those and a separate connection is made, because a connection authenticated as somebody else is not the same connection. Reuse stores nothing new.

## Spotlight and Handoff

Two ways the system can carry something outside this app. Both are described here because
"nothing leaves the device" has to mean it.

**Spotlight is off until you turn it on.** With it on, the app gives this device's search
index the name and address of each saved connection — the same two lines the connection
list shows — so they can be found from the home screen. Nothing else is indexed: no
passwords, no keys, no host keys, no command history. The index is on the device, but it
can be read without opening this app, which is why the switch exists and why it starts off.
Turning it off removes what was indexed.

**Handoff carries which connection, and nothing more.** While a session is on screen the
app publishes an activity saying which saved connection it is, so another of your devices
can offer to continue there. An SSH session cannot be moved — the connection and its keys
are on this device — so continuing opens a new session to the same server. The activity
holds an identifier and a name; it never holds a hostname, a user name, a password or a
key. iOS advertises it to devices signed in to your Apple Account, and it is Apple's
mechanism, described in Apple's privacy policy.

## Links from outside the app

A link — `ssh://` or `apexterminal://` — can ask the app to open a connection or to run a
command. Nothing arrives with any authority: a link that names a server this device has not
saved, and *any* link that carries a command, is shown to you first, with the server and the
command spelled out, and nothing happens until you allow it. A link is never allowed to add
a connection to your list; it can only fill in the fields and leave the saving to you.

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

Everything the app holds is on this device, under your control. There is no copy with the developer, so there is nothing for the developer to give you, correct or delete on request. To see your data, open the app. To delete it, see below. Because the developer receives nothing, there is no request to make and no address to make it to; the controls that answer these rights are in the app itself, under Settings.

## Deleting everything

**Settings → Delete all data** closes every open session and removes every connection, SSH key, saved password, Cloudflare Access sign-in, snippet, command-history entry, the list of recently open sessions and every known host key from this device. A key held in the Secure Enclave is destroyed with it. Individual host keys can also be removed in **Settings → Known hosts**.

**Deleting the app** removes its files from the device. iOS does not promise to remove an app's Keychain items when the app is deleted, so run Delete all data first if you want keys, passwords and tokens gone as well.

Neither action changes anything on your servers or at Cloudflare. To revoke access there, remove the public key from the server's `authorized_keys`, or revoke the session in your Cloudflare Zero Trust dashboard.

## App Store privacy label

Data collected: none. Tracking: none. The app's privacy manifest declares the two required-reason APIs it uses (file timestamps for its own container, and standard preferences for settings), no collected data types and no tracking domains.

## Children

The app is a tool for administering servers and is rated accordingly on the App Store. It does not collect data from anyone, of any age.

## Changes

A new version of this policy ships with a new version of the app, dated at the top. If the app ever starts sending data somewhere new, that will be stated here in plain words before it happens, not after.
