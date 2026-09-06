# Release checklist

Everything here is a check someone can actually perform, with the command that performs
it. A checklist of intentions is not a checklist.

## Before a build is worth submitting

### Gates that must be green

```bash
cd Packages/SuperTerminalKit && swift test
cd ../swift-nio-ssh-rsa && swift test
cd ../.. && ./scripts/app-integration-e2e.sh
./scripts/ui-terminal-e2e.sh
./scripts/live-e2e.sh          # needs the Cloudflare test environment
```

- [ ] Zero errors and zero warnings from project code, in Debug **and** Release
- [ ] Every suite passes, including the live Cloudflare run
- [ ] `patches/niossh-rsa.patch` still applies to the pinned upstream tag
- [ ] No placeholder implementations, no committed credentials (both gated in CI)
- [ ] `scripts/localization-audit.sh` reports every string translated
- [ ] The bundled `THIRD_PARTY_NOTICES.md` matches the repository copy (gated in CI)

### Verified on hardware, not only in a simulator

- [ ] Plain SSH connects on a physical iPhone and iPad
- [ ] Cloudflare Access sign-in completes on device, including the MFA step
- [ ] A Cloudflare-tunnelled host reaches an interactive PTY on device
- [ ] Token expiry triggers re-authentication rather than a dead session
- [ ] A changed host key is refused on device
- [ ] `vim` and `tmux` render and respond correctly
- [ ] External keyboard shortcuts work, including Control and Option; Control-arrow moves by word in a shell, Shift-arrow selects in an editor, F-keys reach `htop`
- [ ] Hardware keyboard, in the command palette: Escape closes it, ↑/↓ move the highlight, Return runs it
- [ ] App lock: on a device with Face ID or Touch ID, turn the lock on with a passcode; relaunch — the system prompt appears over the lock screen; cancel it and the passcode field takes over; accept it and the app opens; turn "Unlock with Face ID" off and confirm no prompt appears; change and then turn off the passcode, each asking for the current one
- [ ] iPad with a Magic Keyboard, no software keyboard anywhere: open a connection whose host key is unknown, accept it, and type — the shell receives it; press ⌘F, close the find bar, type again; ⌘K, dismiss, type again; open a second session and confirm typing goes to the one on screen; ⌘1 and ⌘2 switch without the terminal being replaced by "Open in another window"
- [ ] iPad with a mouse and with the Magic Keyboard trackpad: the wheel scrolls the scrollback and reaches `less`; click-drag selects from the exact character clicked; secondary click shows the menu; middle click pastes; the pointer is a beam and no second cursor is drawn over a remote screen
- [ ] Remote screen: a Mac with Screen Sharing on and "VNC viewers may control screen with password" enabled, through the SSH connection — the desktop appears, a tap clicks, touch-and-hold drags a window, two fingers scroll, the key row's Ctrl+Tab and ⌘ (Super) reach the Mac, a hardware keyboard types, an iPad mouse moves the Mac's cursor with no second pointer drawn; then a Linux desktop (x11vnc or TigerVNC) the same way, and a direct connection with the SSH option off
- [ ] Assistant: on a device eligible for Apple Intelligence the sheet says it answers on the device and does; with a provider key pasted in Settings it answers from the provider and a suggested command inserts on the prompt without running
- [ ] Siri: "Connect to <name> in SuperTerminal" opens the session; "Disconnect all sessions in SuperTerminal" closes them and says how many; both appear in the Shortcuts app
- [ ] Server platform: connect to a Linux machine and a Windows OpenSSH machine; each row comes to say Linux / Windows without anything typed into the session (macOS is proven by the UI tests against this Mac)
- [ ] With a mouse or trackpad: the wheel scrolls the scrollback and reaches `less` when it is running; a secondary click shows Copy / Paste / Select All, and reaches `tmux` when it is tracking; a middle click pastes; click-drag selects; the pointer is a beam over the terminal
- [ ] Rotation, Split View and Stage Manager resize the terminal correctly
- [ ] Backgrounding and returning does not lose a session

### Accessibility

- [ ] VoiceOver can read the terminal and reach every control
- [ ] Dynamic Type at accessibility sizes does not break any screen
- [ ] Increase Contrast selects the high-contrast terminal theme
- [ ] Reduce Transparency makes bars solid
- [ ] Reduce Motion stops the cursor blinking

### Performance

- [ ] `swift test -c release --filter TerminalThroughputTests` meets its floors
- [ ] An Instruments trace of sustained output shows no runaway allocation
- [ ] Memory is bounded under a long-running high-output session

## Legal texts and iCloud

- [ ] Every placeholder in `App/Resources/Legal/legal-*.md` is filled in all three languages: effective date, developer legal name, governing law and venue (the texts carry no contact details, by decision)
- [ ] Counsel has reviewed the Terms, Privacy Policy and User Notice; the "not legal advice" sentence is removed only when that is true
- [ ] `LegalDocument.currentVersion` is bumped if any of the three texts changed in substance, so existing users see the consent screen again
- [ ] The App Store privacy answers still read "Data not collected"; storage in the user's own CloudKit private database is not collection
- [ ] The iCloud container `iCloud.dev.superterminal.app` exists in the developer account and the profile carries the iCloud capability; the simulator build has no entitlements, so nothing about iCloud is proven until a signed build runs (B-4)
- [ ] The CloudKit schema (record type `SyncRecord`: `kind`, `payload`, `modifiedAt`; zone `SuperTerminal`) is deployed to the production environment — the development environment creates it on first use, production does not
- [ ] Two signed devices on one Apple Account sync a host, a snippet, a known host key and an opted-in private key; a held host-key disagreement appears in Settings → iCloud; "Delete all data" empties the zone and the other device stops seeing the records
- [ ] A key marked "Store private key in iCloud Keychain" appears on the second device with its secret; a biometric key appears as "not on this device"

## Signing and identifiers

- [ ] Development team set on the `SuperTerminal` target
- [ ] Bundle identifier registered (`dev.superterminal.app`, or your own)
- [ ] `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` bumped
- [ ] Distribution certificate and provisioning profile valid

```bash
xcodebuild -project SuperTerminal.xcodeproj -scheme SuperTerminal \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/SuperTerminal.xcarchive archive
```

## App Store Connect

### Privacy

- [ ] **Data collected: none.** Nothing is collected, linked or used for tracking
- [ ] **Tracking: no**
- [ ] `PrivacyInfo.xcprivacy` declares only the two required-reason APIs actually used —
      file timestamps (`C617.1`) and `UserDefaults` (`CA92.1`)

See [PRIVACY.md](PRIVACY.md) for the reasoning behind each answer.

### Export compliance

The app uses encryption: SSH, TLS, and the cryptographic primitives underneath. It uses
only standard algorithms provided by the platform and by audited libraries, and implements
none of its own — which is the ordinary case for the exemption most apps claim. Confirm
the current wording of the questions in App Store Connect rather than relying on this
paragraph, and take advice if the app will be distributed somewhere with its own rules.

### Review notes

Reviewers cannot test a Cloudflare-protected host without credentials. Provide:

- [ ] A test hostname reachable from outside your network
- [ ] A test account, with MFA disabled or a shared TOTP secret
- [ ] A short note explaining that the app speaks Cloudflare's tunnel protocol directly
      and needs no companion install — this pre-empts the obvious question

Also worth stating: the app opens sign-in in `ASWebAuthenticationSession`, which is the
supported mechanism, and it is not a web view masquerading as a terminal.

### Likely review questions

| Question | Answer |
| --- | --- |
| Does this need another app installed? | No. `cloudflared` is not required on the device |
| Is the terminal a web view? | No. It is a Core Text renderer over a native SSH implementation |
| Why does it need Keychain access? | To store SSH private keys and passwords. There is no server component |
| Does it use private API? | No |
| Does it download executable code? | No |

## TestFlight

- [ ] Build uploaded and processed
- [ ] Export compliance answered
- [ ] "What to test" names the paths that need real infrastructure — Cloudflare sign-in,
      token expiry, host key change
- [ ] Known limitations listed for testers, taken from `../PROJECT_STATUS.md` rather than
      summarised from memory

## After release

- [ ] Tag the commit
- [ ] `PROJECT_STATUS.md` and `TEST_REPORT.md` reflect what actually shipped
- [ ] Check <https://github.com/apple/swift-nio-ssh/releases> — if upstream has added RSA,
      open the work to delete the vendored fork
