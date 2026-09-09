# Local development

## Requirements

| | |
| --- | --- |
| macOS | 26.5 or later |
| Xcode | 26.6 or later (Swift 6.3) |
| Deployment target | iOS / iPadOS 17.0 |
| For the integration tests | OpenSSH — `/usr/sbin/sshd` and `/usr/bin/ssh-keygen`, both present on macOS by default |

Nothing else. There is no package manager to install, no code generator to run, and no
project file to regenerate — the `.xcodeproj` is checked in and uses file-system
synchronised groups, so adding a source file needs no project edit.

## Layout

```
ApexTerminal.xcodeproj        app, unit test and UI test targets
App/                           the SwiftUI application
AppTests/                      app-hosted tests, including ones that connect to a real sshd
AppUITests/                    XCUITests that drive the real interface
Packages/ApexTerminalKit/     all the logic, testable on macOS without a simulator
Packages/swift-nio-ssh-rsa/    vendored swift-nio-ssh with RSA added (see DECISIONS.md D-007)
patches/niossh-rsa.patch       the entire difference from upstream
scripts/                       test harnesses and maintenance scripts
```

Most of the code lives in the package rather than the app target, and that is a testing
decision: `swift test` runs the SSH stack against a real `sshd` in seconds, with no
simulator in the loop.

## Building and testing

```bash
# The package: fastest feedback, no simulator
#
# `--no-parallel` is not optional. Several suites each start a real sshd, and starting one
# blocks the thread it happens to be on; run enough of them at once and Swift Concurrency's
# cooperative pool has nothing left to resume the tasks waiting on an SSH handshake, which
# then times out and blames a suite that did nothing wrong. See `OpenSSHTestServer`.
cd Packages/ApexTerminalKit
swift build
swift test --no-parallel
swift test -c release --filter TerminalThroughputTests   # the performance numbers

# Upstream's own suite against the vendored fork
cd ../swift-nio-ssh-rsa && swift test

# The app
cd ../..
xcodebuild -project ApexTerminal.xcodeproj -scheme ApexTerminal \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# App-hosted tests against a real sshd (starts and stops one for you)
./scripts/app-integration-e2e.sh

# UI tests that drive the interface against a real sshd
./scripts/ui-terminal-e2e.sh

# The live Cloudflare run — needs an account; see docs/CLOUDFLARE.md
./scripts/live-e2e.sh
```

The integration scripts start an unprivileged `sshd` on an ephemeral port with its own
host keys and `authorized_keys`, under a temporary directory. They cannot touch the
machine's real SSH configuration, and they clean up on exit.

## Quality gates

CI enforces what the project claims, and the same checks run locally:

```bash
# Zero warnings from our own code (third-party warnings are not counted, and not hidden)
cd Packages/ApexTerminalKit && swift build 2>&1 | grep -cE "Sources/.*warning:"   # must be 0

# No placeholder implementations
grep -rnE "\b(TODO|FIXME)\b|fatalError\(\"not implemented" App/Sources Packages/ApexTerminalKit/Sources --include="*.swift"

# No committed key material
git grep -nE '^-{5}BEGIN [A-Z ]*PRIVATE KEY-{5}$'
```

## Signing

The project uses automatic signing and **no development team is set**, so a fresh clone
builds for the simulator without any account. To run on a device:

1. Open `ApexTerminal.xcodeproj`.
2. Select the `ApexTerminal` target → Signing & Capabilities.
3. Choose your team. Xcode will register the bundle identifier `dev.apexterminal.app`,
   or you can change it to one of your own.

The entitlements file asks for nothing unusual — a Keychain access group and nothing else.
There is no Network Extension, no VPN and no background mode, because the Cloudflare
tunnel is an ordinary outbound TLS connection made in-process.

Archiving without a team fails with *"Signing for ApexTerminal requires a development
team"*. To check that the device build compiles without one:

```bash
xcodebuild -project ApexTerminal.xcodeproj -scheme ApexTerminal \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## Maintaining the vendored swift-nio-ssh

This is the one part of the repository with an ongoing obligation. `swift-nio-ssh`
implements no RSA, so it is vendored and patched; a vendored SSH library that falls behind
upstream is worse for security than no RSA at all.

```bash
./scripts/update-vendored-niossh.sh              # shows available tags and the current one
./scripts/update-vendored-niossh.sh 0.16.0       # re-sync and re-apply the patch
cd Packages/swift-nio-ssh-rsa && swift test      # upstream's own suite must still pass
```

The script replaces the tree wholesale and re-applies `patches/niossh-rsa.patch`, failing
loudly if it no longer applies rather than inviting a hand-merge. Check
<https://github.com/apple/swift-nio-ssh/releases> when updating dependencies — **if
upstream adds RSA, delete this package and depend on upstream directly.**

## Regenerating the Unicode width tables

`Packages/ApexTerminalKit/Sources/STTerminal/CharacterWidthTables.swift` is generated
from the Unicode Character Database and records which version it came from:

```bash
./scripts/generate-width-tables.sh
```


## Localization

The app ships in English, Simplified Chinese and Traditional Chinese. Two rules, both
learned the hard way:

**Keys come from the compiler, not from the source.** SwiftUI turns
`Text("Delete \(name)?")` into the catalog key `Delete %@?` — the interpolation becomes a
format specifier before any lookup — so a translation keyed on the source text matches
nothing, and the failure is silent: the app compiles and shows English. Build with
`SWIFT_EMIT_LOC_STRINGS=YES` and take keys from the `.stringsdata` the compiler writes.

**Nothing catches an untranslated string except a gate.** A new `Text("…")` passes every
test. `./scripts/localization-audit.sh` builds with that flag, compares each String Catalog
against the compiler's keys, and fails on any string missing a translation in any language.
CI runs it. Run it before opening a pull request that adds user-visible text.

Tools:

* `scripts/localization-audit.sh` — the gate above.
* `scripts/apply-translations.py <translations.json> <DerivedData>` — bulk-imports
  `{key, zhHans, zhHant}` rows, converting Swift interpolation in each translation to the
  specifier the compiler emitted for that expression (matched by expression text, so a
  translation that reorders arguments produces `%2$@ … %1$@`). Once a string is in a
  catalog the catalog is the source of truth — Xcode edits it directly — so this is for
  importing a batch, not for regenerating what is already there.

What is deliberately **not** translated: technical identifiers a user copies or compares
(`user@host:port`, fingerprints, algorithm names, `ssh-keygen` command lines), key-cap
labels (`esc`, `tab`, the arrows), `TERM` values, wire-format keys, log subsystem names,
`underlyingDescription` diagnostics, and anything serialised or compared. Two traps in
particular: `UIKeyCommand(input: "k")` — translating it unbinds ⌘K — and any enum raw value
that is both stored and displayed, which needs a separate `displayName` rather than a
translated raw value. Terminal output is never translated; it is a remote program's bytes.

Package modules that produce user-facing error messages (`STSSH`, `STCloudflare`) carry
their own catalogs and use `String(localized:bundle: .module)`; `Package.swift` declares
`defaultLocalization` and each catalog as a processed resource, which is what makes
`Bundle.module` exist for the target. D-014 has the reasoning.

## The File Provider extension in the simulator

**It aborts, and that is expected.** A replicated File Provider domain needs FPFS, which
the iOS Simulator does not have. `fileproviderd` logs

```
domain <NSFileProviderDomain: … (disabled,replicated,…)> was asked with FPFS,
but it's not supported, will fallback
```

and drops the `replicated` flag; the downgraded domain is then served through the older
`NSFileProviderExtension` API, which `ApexTerminalFileProvider` does not implement, so the
process aborts in `__FILEPROVIDER_V2_EXTENSION_WITHOUT_IMPL` and a crash report lands in
`~/Library/Logs/DiagnosticReports/ApexTerminalFileProvider-*.ips`.

So in the simulator: everything up to and including registering a domain works and is
tested (`FileProviderDomainTests`), and everything the extension *does* once asked is
tested against a real OpenSSH server in `STFileProviderTests` — 29 tests, none of which
need the system. What cannot be exercised is the system handing those two halves to each
other. `FileProviderEndToEndTests` does exactly that and skips itself on the simulator;
H-6 in `docs/HUMAN_ACTIONS.md` is the device run.

Two configuration details that cost a morning, in case they ever look wrong:

* `NSExtensionFileProviderDocumentGroup` is **required in `Config/FileProviderInfo.plist`**
  even for a replicated extension. Without it `fileproviderd` logs `"key not found in
  Info.plist. Skipping provider"`, never registers the extension, and every lookup answers
  "No provider found" — which surfaces as `NSFileReadNoPermissionError` from
  `getUserVisibleURL`, a message with nothing to do with the cause.
* The domain must be created with `NSFileProviderDomain(identifier:displayName:)`. The
  three-argument initialiser that also takes `pathRelativeToDocumentStorage:` creates a
  non-replicated domain and produces the same abort, on a device as well as here.

## The Secure Enclave in the simulator

**It works — the biometrics do not.** On an Apple silicon Mac, CryptoKit's
`SecureEnclave` reaches the host's enclave from the iOS Simulator, so
`SecureEnclave.isAvailable` is `true` and a P-256 signing key can be created, used and
restored there. Measured on this project:

```
SecureEnclave.isAvailable = true
created, blob bytes = 143            # 324 on the host Mac — a different SEP path, both usable
signed, valid = true
restored, same pub = true
```

That is why D-049's whole SSH path is verified automatically: `SecureEnclaveKeyTests`
(package) authenticates to a real `sshd` with an enclave key and asserts the server's own
`Accepted publickey … ECDSA SHA256:…` line, and `SecureEnclaveAuthTests` (app) does the
same through `SessionManager`.

What the Simulator does not have is LocalAuthentication. Any access-control flag implying
user presence — `.userPresence`, `.biometryAny`, `.biometryCurrentSet` — fails at key
creation with

```
Error Domain=com.apple.LocalAuthentication Code=-1020
  "This call is not supported on iOS Simulator."
```

so `SecureEnclaveSSHKey.canRequireBiometrics` is `false` there and the UI says so instead
of offering a switch that cannot work. The biometric policy is H-7 in
`docs/HUMAN_ACTIONS.md` and is not claimed as verified.

## The first modified key press a UI test sends is thrown away

Measured on 2026-09-08, on an iPhone 17 Pro simulator, with eight probes against ⌘F, each
run twice:

| what was sent | did ⌘F open the find bar |
| --- | --- |
| ⌘F, first thing after the terminal opened | no |
| ⌘F after typing a whole shell command | no |
| ⌘F after a five-second settle | no |
| ⌘F after typing one plain character | no |
| ⌘F after ⌘C | **yes** |
| ⌘F after ⌃⌥⇧⌘Z, which the app does not bind | **yes** |
| ⌘F sent twice | **yes** |
| the same command from the Session menu, no keyboard at all | **yes** |

So: it is not a race — five seconds of waiting changes nothing — it is not about ⌘F, and
it is not the app, which handles the second press and the menu row perfectly well. **The
first modifier-bearing key press XCUITest delivers to a screen is discarded.** An
unmodified key does not absorb it; any modified key does, bound or not.

Two further measurements pinned down where the press has to go:

* Sent immediately after `launch()` returns it absorbs nothing — the first real shortcut
  still goes missing. The app has to be up first.
* Sent on the host list and then followed by opening a terminal, the terminal's own first
  shortcut goes missing again. So the loss is **per screen**, not per launch.

`AppUITests/HardwareKeyboardSupport.swift` spends it: `primeModifierKeys()` for ordinary
screens, using a combination the app does not bind, and `primeModifierKeysInTerminal()`
for a terminal, which uses ⌘C. The distinction is not fussiness — a terminal forwards keys
it does not handle to the remote shell, and priming it with the unbound combination put
bytes on the wire that garbled the next line the test typed, failing a plain-typing
assertion that had always passed. ⌘C is consumed by the terminal and copies nothing when
nothing is selected.

Before this, `HardwareKeyboardUITests` covered the loss with a retry and still failed
about one run in three, and
`HardwareKeyboardStateUITests.testTypingWorksAfterEveryThingThatTakesTheKeyboardAway`
failed every run. With the press spent deliberately, both suites pass three runs out of
three, and the retry in `HardwareKeyboardUITests.press` is left to cover the rarer second
loss rather than being what every one of those tests silently depended on.

## The keyboard-interactive test server

macOS builds OpenSSH **without PAM**. Its `sshd` will offer `keyboard-interactive`, but the
exchange then falls through to BSD auth and asks for the login password of a real account —
nothing a test may know, and nothing that can be scripted. So the tests for RFC 4256
(D-051) use a container instead: stock OpenSSH on Debian, configured with

```
AuthenticationMethods keyboard-interactive
KbdInteractiveAuthentication yes
UsePAM yes
PubkeyAuthentication no
PasswordAuthentication no
```

and a PAM stack of `pam_unix` followed by `pam_google_authenticator`, so the login asks two
questions — a password, then a one-time code — and nothing else can let a client in.

`STTestSupport.KeyboardInteractiveTestServer` builds the image on first use and starts a
container per test; `scripts/app-integration-e2e.sh` starts one of its own and publishes
`ST_APP_TEST_KBDI_*` for the app-level tests. Both skip cleanly when Docker is not running,
because a missing Docker is a property of the machine and a red test that means "install
Docker" teaches nothing.

The image is real OpenSSH, not a stand-in. That is the point: a hand-written server would
prove only that this client agrees with something this project also wrote.

What the server actually sends, measured, is worth knowing before reading the tests:

```
round 1: one prompt, "Password: ",          echo false
round 2: one prompt, "Verification code: ", echo false
round 3: no prompts at all
```

The third round is RFC 4256 § 3.3's zero-prompt case, used to display a message. It must be
answered with zero responses, and it is the round an implementation that assumed "a round
means a question" gets wrong.
