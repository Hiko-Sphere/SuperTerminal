# Privacy

SuperTerminal collects nothing. This page says what that means concretely, because "we
value your privacy" is not a claim anyone can check.

## What the app stores, and where

| Data | Where | Leaves the device? |
| --- | --- | --- |
| Connection list (names, hostnames, usernames, ports) | App container, complete file protection | No |
| SSH private keys | Keychain, `WhenUnlockedThisDeviceOnly`, optionally biometric-gated | No |
| SSH passwords | Keychain, `WhenUnlockedThisDeviceOnly` | No |
| Cloudflare Access tokens | Keychain, `AfterFirstUnlockThisDeviceOnly` | Only back to Cloudflare, as the credential for your own connection |
| Known host keys | App container, complete file protection, excluded from backup | No |
| Terminal scrollback | Memory only | No |
| Command history | **Not recorded** unless you turn it on; local only | No |
| Settings | `UserDefaults` | No |

Every Keychain item is `ThisDeviceOnly` and explicitly non-synchronisable, so nothing can
travel in an iCloud Keychain sync or in a backup restored onto a different device.

## What the app sends, and to whom

Only two kinds of network traffic exist, and you choose both:

1. **To the servers you connect to.** SSH traffic, encrypted end to end. Cloudflare
   carries it when a tunnel is used but does not terminate it — host key verification
   still protects you from the tunnel itself.
2. **To Cloudflare**, for hosts you have marked as tunnelled: the metadata probe, the
   key-set fetch, the sign-in, and the token retrieval. All to Cloudflare's own endpoints,
   all on your behalf.

There is no analytics SDK, no crash reporter, no telemetry, and no server operated by this
project. Nothing is phoned home because there is nowhere for it to phone.

## Diagnostics

The exportable diagnostics report contains no commands, terminal output, passwords, keys,
tokens or full hostnames. This is structural: log records are redacted where they are
written — hostnames become a short non-reversible digest, tokens become a length and a
signature digest — so the export is a plain serialisation rather than a scrubbing pass
that might miss something.

You choose whether to share it, and with whom.

## App Store privacy disclosures

For the App Store's "App Privacy" questionnaire, the answers are:

* **Data collected: none.** Not linked to you, not used for tracking, not collected at
  all.
* **Tracking: no.** The app contains no tracking SDK and no tracking domains.

`App/Resources/PrivacyInfo.xcprivacy` declares the two required-reason APIs the app
actually uses — file timestamps (`C617.1`) for its own container, and `UserDefaults`
(`CA92.1`) for settings — and declares no collected data types and no tracking domains.

## Deleting everything

Settings → Delete all data removes every connection, every key, every saved password and
every Cloudflare session from the device. Deleting the app does the same. Neither leaves
anything behind on a server — if you want to revoke access there, remove the public key
from `authorized_keys` or revoke the Access session; see
[the Cloudflare guide](CLOUDFLARE.md#revoking-access).
