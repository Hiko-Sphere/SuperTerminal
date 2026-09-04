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
SuperTerminal.xcodeproj        app, unit test and UI test targets
App/                           the SwiftUI application
AppTests/                      app-hosted tests, including ones that connect to a real sshd
AppUITests/                    XCUITests that drive the real interface
Packages/SuperTerminalKit/     all the logic, testable on macOS without a simulator
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
cd Packages/SuperTerminalKit
swift build
swift test
swift test -c release --filter TerminalThroughputTests   # the performance numbers

# Upstream's own suite against the vendored fork
cd ../swift-nio-ssh-rsa && swift test

# The app
cd ../..
xcodebuild -project SuperTerminal.xcodeproj -scheme SuperTerminal \
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
cd Packages/SuperTerminalKit && swift build 2>&1 | grep -cE "Sources/.*warning:"   # must be 0

# No placeholder implementations
grep -rnE "\b(TODO|FIXME)\b|fatalError\(\"not implemented" App/Sources Packages/SuperTerminalKit/Sources --include="*.swift"

# No committed key material
git grep -nE '^-{5}BEGIN [A-Z ]*PRIVATE KEY-{5}$'
```

## Signing

The project uses automatic signing and **no development team is set**, so a fresh clone
builds for the simulator without any account. To run on a device:

1. Open `SuperTerminal.xcodeproj`.
2. Select the `SuperTerminal` target → Signing & Capabilities.
3. Choose your team. Xcode will register the bundle identifier `dev.superterminal.app`,
   or you can change it to one of your own.

The entitlements file asks for nothing unusual — a Keychain access group and nothing else.
There is no Network Extension, no VPN and no background mode, because the Cloudflare
tunnel is an ordinary outbound TLS connection made in-process.

Archiving without a team fails with *"Signing for SuperTerminal requires a development
team"*. To check that the device build compiles without one:

```bash
xcodebuild -project SuperTerminal.xcodeproj -scheme SuperTerminal \
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

`Packages/SuperTerminalKit/Sources/STTerminal/CharacterWidthTables.swift` is generated
from the Unicode Character Database and records which version it came from:

```bash
./scripts/generate-width-tables.sh
```
