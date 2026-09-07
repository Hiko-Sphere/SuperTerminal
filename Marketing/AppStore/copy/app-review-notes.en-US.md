# App Review notes — draft (en-US)

Paste the block below into **App Review Information → Notes** in App Store Connect. The
commentary after it is for whoever is submitting, not for the reviewer.

---

```
WHAT THE APP IS

ApexTerminal is an SSH client. It opens an interactive SSH session on a server the user
already owns, allocates a PTY, and renders the output with a terminal emulator built into
the app. Everything a user sees in a session comes from their own remote machine; the app
runs nothing itself and relays nothing through any server of ours.

There is no account, no sign-in, no registration and no server-side component. There is
nothing to purchase: no in-app items, no tiers, no trial. Every feature described in the
listing is present in the binary you have.

HOW TO TEST IT

You will need any SSH server you can reach and a credential for it. On a Mac, System
Settings > General > Sharing > Remote Login is enough, and the app will connect to it over
the local network.

1. Launch the app and accept the terms screen (it appears once).
2. Tap + > New Connection. Enter the hostname, the port if it is not 22, and a user name.
   The port and the user name may be left blank; blank means "ask me" or "use the default".
3. Choose how to authenticate:
   - Password: pick Password, and the app will prompt during the connection.
   - Key: Settings > Keys > + > Generate. Copy the public key it shows into
     ~/.ssh/authorized_keys on the server, then select that key on the connection.
4. Tap the connection. The app will show the server's host key fingerprint and wait for
   you to accept it. This prompt is deliberate and is one of the screenshots.
5. After accepting, a shell prompt appears. Type any command. Try vim or top to see a
   full-screen program.

The key row above the keyboard supplies Escape, Tab, Control, arrows and page keys.
Tapping ctrl then a letter sends the control character, so ctrl then c interrupts.

PERMISSIONS

- Face ID / Touch ID (NSFaceIDUsageDescription): used only for two optional things the
  user turns on: unlocking the app when App Lock is enabled, and using a private key the
  user chose to protect biometrically. Neither is required to use the app.
- Local network: iOS may ask for local-network permission the first time the app connects
  to a server on the same network. This is the SSH connection itself.

WHAT IS IN THE BINARY BUT NOT ADVERTISED

Per guideline 2.3.1, these are working features present in the build. They are absent from
the screenshots, the description and the keywords because they have not yet been verified
along the path a reviewer would take, and we did not want to claim them until they are:

- Connecting through a Cloudflare Tunnel to a host behind Cloudflare Access. The protocol
  is implemented and tested against a local server that reproduces the edge, but no
  connection has yet been made through a live Cloudflare account. Nothing in the listing
  mentions Cloudflare, and the app is not affiliated with or endorsed by Cloudflare.
- Viewing a remote screen over VNC, reached through an SSH connection or directly. Tested
  against LibVNCServer; not yet run against macOS Screen Sharing or a Linux desktop.
- An assistant that explains commands and output. It runs on the device's own model where
  the device supports one, and otherwise on a provider endpoint and API key the user
  supplies in Settings. The app never ships a key and sends nothing without one. It shows
  the user exactly what it will send before sending it, and a suggested command is
  inserted into the command line, never executed.
- Optional sync of connections, snippets, known hosts and public key metadata through the
  user's own private CloudKit database. Off by default.
- Shortcuts / Siri intents for opening a saved connection.
- A short first-run tour, which can be replayed from Settings.

PRIVACY

No analytics, no telemetry, no advertising identifiers, no third-party SDKs that collect
anything. Connections, keys, snippets and known hosts are stored on the device; private
keys are in the Keychain with explicit protection classes and are never displayed or
transmitted by the app. Command history is off unless the user turns it on, and turning it
off deletes the stored file.

CONTENT

The app displays whatever the user's own server sends. It has no content of its own beyond
its interface, and no way to browse, search or discover third-party content.
```

---

## For the submitter, not the reviewer

* **Screenshots.** All twenty-four final images were captured from this build running in
  the simulator, driven through the app's own interface against three isolated OpenSSH
  servers in containers. The accounts and machine names on screen (`deploy`, `edge-01`,
  `db-primary`, `build-runner`) are invented, and the addresses are under `*.localhost`,
  which RFC 6761 reserves. See [`FEATURE_AUDIT.md`](../FEATURE_AUDIT.md) §7.
* **Export compliance.** The project does **not** set `ITSAppUsesNonExemptEncryption` in
  its Info.plist, so App Store Connect will ask at submission. The app uses SSH — standard
  cryptography, not proprietary, used for authentication and for protecting a connection —
  which is normally the exempt case, but the answer is the submitter's to give, and a
  year's self-classification report may be required depending on jurisdiction. Decide it
  deliberately rather than clicking through.
* **Age rating.** Nothing in the app suggests anything above 4+. The interface is a
  terminal; the *content* is whatever the user's server prints, which is the same position
  every SSH client is in.
* **The legal texts still carry placeholders** — effective date, developer legal name,
  governing law and venue — in all three languages under `App/Resources/Legal/`, and have
  not been reviewed by a lawyer. See `PROJECT_STATUS.md` B-5. They must be filled before
  submission; the consent screen shows them on first launch and a reviewer will read them.
* **Version.** The build audited here is `0.1.0 (1)`. Submitting as 1.0 means bumping
  `MARKETING_VERSION` and recapturing — `scripts/capture.sh` re-runs the whole thing, and
  `CAPTURE_MANIFEST.json` records which build each image came from.
