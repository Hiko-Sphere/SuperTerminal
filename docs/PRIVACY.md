# Privacy

The user-facing Privacy Policy is `App/Resources/Legal/legal-privacy-*.md`, shown in the
app under Settings → Legal and on the consent screen. This page is the engineering view of
the same facts: where each piece of data is, under which protection class, and what the
code does to keep the policy true. If the two disagree, the code is wrong or this page is.

## What the app stores, and where

| Data | Where | Leaves the device? |
| --- | --- | --- |
| Connection list (names, hostnames, usernames, ports) | App container, complete file protection | Only through iCloud sync, if on |
| SSH private keys | Keychain, `WhenUnlockedThisDeviceOnly`, optionally biometric-gated | Only through iCloud Keychain, and only for a key the user put there (`WhenUnlocked` + `kSecAttrSynchronizable`); never a biometric key |
| Key metadata (name, algorithm, public key, fingerprint, flags) | App container, complete file protection | Only through iCloud sync, if on |
| SSH passwords | Keychain, `WhenUnlockedThisDeviceOnly` | No — never synced |
| Cloudflare Access tokens | Keychain, `AfterFirstUnlockThisDeviceOnly` | Only back to Cloudflare, as the credential for your own connection. Never synced |
| Cloudflare Access service tokens (only if entered for a connection) | Keychain, `WhenUnlockedThisDeviceOnly` | Only to Cloudflare, as that connection's credential. Never synced; deleted with the connection |
| Known host keys | App container, complete file protection, excluded from backup | Only through iCloud sync, if on; a key that differs from a trusted one is held, not applied |
| Snippets | App container, complete file protection | Only through iCloud sync, if on |
| Terminal scrollback | Memory only | No |
| Command history | **Not recorded** unless turned on. Then: app container, complete file protection, excluded from backup, last 500 commands, deleted the moment it is turned off | No — never synced |
| List of recently open sessions | App container, complete file protection, excluded from backup, seven days | No — never synced |
| Settings | `UserDefaults` | No |
| Sync tombstones (ids of deleted records, 30 days) | App container | Only through iCloud sync, if on |

With iCloud sync off, every Keychain item is `ThisDeviceOnly`. Queries use
`kSecAttrSynchronizableAny` so that "Delete all data" and the key list see synchronisable
items too. The vault refuses to store a key that is both biometric-gated and synchronisable
(Apple forbids access control on synchronisable items) with a typed error rather than
dropping either property.

## What the app sends, and to whom

Three kinds of network traffic exist, and the user chooses all three:

1. **To the servers you connect to.** SSH traffic, encrypted end to end. Cloudflare carries
   it when a tunnel is used but does not terminate it — host key verification still
   protects you from the tunnel itself.
2. **To Cloudflare**, for hosts marked as tunnelled: the metadata probe, the key-set fetch,
   the sign-in, and the token retrieval. All to Cloudflare's own endpoints, on your behalf.
3. **To iCloud, only if sync is on.** The app's private CloudKit database for records, and
   iCloud Keychain for the private keys the user chose. `SyncCoordinator` creates the
   CloudKit transport only when the switch goes on, so an app whose user never opens the
   setting never talks to CloudKit at all. See `SECURITY.md` T-13 and `DECISIONS.md` D-015.

There is no analytics SDK, no crash reporter, no telemetry, and no server operated by this
project.

## Diagnostics

The diagnostics report is shown on screen and shared only through the system share sheet;
it is not written to disk by the app. It contains no commands, terminal output, passwords,
keys, tokens or full hostnames. Redaction happens where the record is written
(`Redactor` in `STCore`): a hostname becomes `<host:digest>` plus its last two labels
(`bastion.corp.example.com` → `<host:…>.example.com`), an IP address becomes `<ip>`, a
token becomes its length and a digest. The export is a plain serialisation of already
redacted records, not a scrubbing pass.

## App Store privacy disclosures

* **Data collected: none.** Storage in the user's own CloudKit private database, which the
  developer cannot read, is not collection.
* **Tracking: no.**

`App/Resources/PrivacyInfo.xcprivacy` declares the two required-reason APIs the app uses —
file timestamps (`C617.1`) for its own container and `UserDefaults` (`CA92.1`) for
settings — and declares no collected data types and no tracking domains.

## Deleting everything

Settings → Delete all data closes every session and removes every connection, key, key
record, saved password, Cloudflare session, snippet, history entry, restoration entry and
**every known host key** from the device; if sync is on it also purges the app's CloudKit
zone, forgets the local tombstones and switches sync off. Deleting the app removes its
files, but iOS does not promise to remove Keychain items with it, so the documents tell the
user to run Delete all data first. Neither touches a server or a Cloudflare account — see
[the Cloudflare guide](CLOUDFLARE.md#revoking-access).
