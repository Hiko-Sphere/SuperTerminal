# Release evidence

Commands actually run, and what they actually printed. Numbers here are recounted after
every change rather than carried forward.

## 2026-09-09 — after D-054 (one connection, many things on it)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test --no-parallel` | **293 tests in 43 suites passed** (285 before; 8 new) |
| `bash scripts/app-integration-e2e.sh` | **269 tests in 51 suites passed** (267 before; 2 new) |
| `bash scripts/ui-terminal-e2e.sh` | **48 passed, 2 failed** — both `ZZSearchProbeUITests`, another session's uncommitted work |
| `bash scripts/localization-audit.sh` | **green**, no new strings |
| Release archive | **ARCHIVE SUCCEEDED** |

**The claim is arithmetic, so it is counted rather than asserted.** `sshd` logs a line each
time it accepts an authentication, so "four sessions should cost one handshake, not four" can
be checked by reading the server's log instead of the pool's own bookkeeping — which would
agree with itself whatever it did. Four leases, one `Accepted publickey`.

**Measured, on this machine's loopback where the network costs nothing:**

```
four sessions, separate connections: 86.8 ms, 4 authentications
four sessions, one shared transport: 20.6 ms, 1 authentication
```

Over a real network the gap is larger, because a handshake is several round trips rather
than none. The measurement prints rather than asserting a threshold: the numbers belong to
this machine, and a test that failed when the laptop was busy would teach nothing.

**The failure this design is really about** is not slowness, it is sharing the wrong thing.
A pool keyed on a host's identifier would hand a connection authenticated as one user to a
session that asked for another, and nothing would report it — it would simply be a shell
belonging to the wrong account. `SSHConnectionIdentity` therefore carries every input that
decides who the connection is and where it comes out: endpoint and port, user name, the
*identifiers* of the credentials (never their contents), the jump chain, the tunnel, and
whether the connection lends this device's agent. A test walks each of those and requires it
to produce a different key.

**Lifetime.** Sessions release rather than close, because a transport shared with two other
tabs is not theirs to close. Reference counted, with a thirty-second idle grace so closing a
tab and opening another does not pay for a fresh handshake. A transport that has died is
discarded rather than handed out — a test kills one underneath the pool and requires the next
lease to be a different object that works.

**And it is actually used.** `ConnectionReuseTests` opens a terminal and a file browser on
one connection through the app's own `SessionManager` and requires the pool to report two
users of one transport, then releases one and requires the other to keep working.

## 2026-09-09 — after D-053 (Cloudflare as a connection you choose, and a screen that says why it failed)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test --no-parallel` | **285 tests in 42 suites passed** — unchanged, and unchanged *by* this: the work is all in the app |
| `bash scripts/app-integration-e2e.sh` | **267 tests in 50 suites passed** (261 before; 6 new) |
| `bash scripts/ui-terminal-e2e.sh` | **48 passed, 2 failed** — both `ZZSearchProbeUITests`, another session's uncommitted work |
| `bash scripts/localization-audit.sh` | **green**, 28 new strings translated into both Chinese variants |
| Release archive | **ARCHIVE SUCCEEDED** |

**What changed, and what it is not.** Cloudflare was already a working transport with a
real Access sign-in (D-001, D-029); what it was not was a *choice*. The **+** menu now asks
which kind of connection is being made, and the Cloudflare entry opens the editor already
set to it. That is a small change with a specific point: setting up a hostname behind Access
and setting up an SSH server are different tasks, and a toggle two thirds of the way down
one form made the second look like an advanced option.

**The diagnostics screen measures rather than restates.** It probes the hostname when it
runs and reports what came back, in the order a connection would meet it: did the edge
answer, is there an Access application, which team domain, and what state the stored
credential is in. Three of those results are ones a record cannot tell you: a hostname with
**no** Access application (reported as something to look at — the tunnel works and nothing
is checking who uses it), a **service token that is missing** (fatal, not a warning: the
connection cannot open at all), and a stored session that is **present but will not
validate** — worse than none, because it is the state in which a connection fails with
something that looks like the server's fault. Sign-out is per application, so someone with
two organisations does not lose both to fix one.

**Where the tests are, and why there.** The reasoning is a pure function over what came back
(`AccessDiagnostics`), and it has six tests covering every state including the three above.
The probe itself is `AccessDiscovery`, which has its own; the end-to-end run against a real
tenant is `LiveCloudflareE2ETests`, which skips without one and is **H-4** — that part is not
claimed as done and the plan still says so.

**Three UI tests broke, and they were mine.** Renaming the menu item to "New SSH Connection"
broke two `LaunchUITests` and one `ServiceTokenUITests` that tapped it by name. Fixed by
giving the item a stable `accessibilityIdentifier` — the label is translated and has now been
renamed once, so matching on words was always going to break — and `ServiceTokenUITests` now
enters through the *Cloudflare* item and **asserts the toggle is already on**, which makes it
a check that the new entry does what it claims rather than something that tolerates it if it
does not.

## 2026-09-09 — after D-052 (agent forwarding, with the phone as the agent)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test --no-parallel` | **285 tests in 42 suites passed** (279 before; 6 new) |
| `cd Packages/swift-nio-ssh-rsa && swift test` | **360 tests, 0 failures**. Required: this changes the vendored fork |
| `bash scripts/app-integration-e2e.sh` | **261 tests in 49 suites passed** (260 before; 1 new) |
| `bash scripts/ui-terminal-e2e.sh` | **48 passed, 2 failed** — both `ZZSearchProbeUITests`, another session's uncommitted work |
| `bash scripts/localization-audit.sh` | **green**, 6 new strings translated into both Chinese variants |
| Release archive | **ARCHIVE SUCCEEDED** |

**The claim, and who checks it.** Not "the code runs": **OpenSSH's own `ssh-add -l`, executed
on the server, lists the key** — by the SHA-256 fingerprint the device holds and with the
comment the device set. That exercises the request, the channel the server opens back, the
length framing and the agent protocol, against the implementation people actually use. A
control test runs the same command with forwarding off and requires `ssh-add` to report no
agent at all, so the first result cannot be the *test machine's* agent leaking through.

**The bug this found, and how.** The first end-to-end attempt failed with "Could not open a
connection to your authentication agent." Rather than guess, the same server configuration
was driven with OpenSSH's **own** client and `-A`: it got a socket. That put the fault on
this side, not the server's, and the cause was specific — `SSHChannelRequestEvent` had gained
an `AgentForwardingRequest` and an inbound conversion, but nothing converted it *outbound*,
so `_actuallyTriggerOutboundEvent0` fell through to `ChannelError.operationUnsupported` and
the request was never sent. One `case` and one initialiser.

**What the fork gained, and why each piece.** `ChannelType.authAgent` and its parse/write
(an inbound `auth-agent@openssh.com` previously could not parse at all);
`ChannelRequestMessage.RequestType.authAgentReq`; the public `AgentForwardingRequest` event
with both conversions; and two deliberately narrow additions on `NIOSSHPrivateKey` —
`signOpaqueAgentRequest` and `publicKeyBlob`. The first is named for what it is: an agent
signs a blob it cannot inspect, and that is the nature of the protocol rather than a
shortcoming of the method. Nothing in ordinary authentication uses it.

**What the agent will not do.** Only `REQUEST_IDENTITIES` and `SIGN_REQUEST` are answered.
`ADD_IDENTITY`, `REMOVE_IDENTITY` and the rest are refused, and a test asserts it: a
forwarded agent that honoured `ADD_IDENTITY` would let the far side plant a key on the
phone. A channel of this type is refused outright unless this connection offered an agent,
and only the keys that connection already uses are offered — so one server cannot ask to
sign with the key another one trusts.

## 2026-09-09 — after D-051 (keyboard-interactive, RFC 4256)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test --no-parallel` | **279 tests in 41 suites passed** (275 before; 4 new) |
| `cd Packages/swift-nio-ssh-rsa && swift test` | **360 tests, 0 failures** (349 before; 11 new). Required: this changes the vendored fork |
| `bash scripts/app-integration-e2e.sh` | **260 tests in 49 suites passed** (258 before; 2 new) |
| `bash scripts/ui-terminal-e2e.sh` | **48 passed, 2 failed** — both `ZZSearchProbeUITests`, another session's uncommitted work. Unchanged by this |
| `bash scripts/localization-audit.sh` | **green**, 5 new strings translated into both Chinese variants |
| Release archive | **ARCHIVE SUCCEEDED** |

**Two failures on the way, both in the test scaffolding, both fixed rather than retried
away.** The first full run failed the package suite on
`ForwardingIntegrationTests.stoppingFreesThePort` — "Port 24433 on this device is already in
use" — and failed the app harness outright with Docker's `failed to bind host port
127.0.0.1:61174: address already in use`.

The harness one was mine and plain: it asked the kernel for a free port and then handed the
number to Docker, which is a race, and 61174 is in the ephemeral range this project already
knows to avoid. It now walks a fixed low range and lets Docker itself be the arbiter.

The forwarding one needed measuring rather than guessing. The test passed **five runs out of
five** on its own, so it was not a regression from this change. `ForwardingSession.stop`
awaits the listener's `close()`, so the port genuinely is released — which rules out the leak
the test is written to catch. What remained is that the suite drew every listener from one
9000-wide pool and makes hundreds of binds per run, so two listeners can draw the same
number in the gap. Forwards now draw from a disjoint range. A first attempt at a cleverer
fix — probing the port with a plain socket to tell a leak from a collision — was backed out:
it made a passing test fail two runs in three, because the probe was stricter than the
Network.framework listener it was meant to imitate. That is recorded here rather than
quietly deleted, because "the oracle was wrong" is the kind of thing worth not repeating.

**The verification problem, and how it was solved rather than waived.** The plan said this
could not be verified here, and gave a real reason: macOS builds OpenSSH without PAM, so its
`sshd` answers a keyboard-interactive attempt by falling through to BSD auth and asking for
a real account's login password. That is true, and it is why the item had been sitting.

It is not, however, the same as "cannot be verified". A Debian container runs stock OpenSSH
with `AuthenticationMethods keyboard-interactive`, `UsePAM yes`, and a PAM stack of
`pam_unix` then `pam_google_authenticator`. Public-key and password authentication are both
turned off, so a login there is evidence about this method and nothing else. The server is
real OpenSSH; nothing about the protocol is being asserted against something this project
also wrote.

**What the server actually does, measured.** The first run failed an assertion that there
would be two rounds. There are three:

```
round 1: one prompt, "Password: ",          echo false
round 2: one prompt, "Verification code: ", echo false
round 3: no prompts at all
```

The third is RFC 4256 § 3.3's zero-prompt round, used to display a message, and the client
must answer it with zero responses and keep waiting. It is the case an implementation that
assumed "a round means a question" gets wrong — by hanging, or by answering a question
nobody asked — so the test now asserts it by name instead of tolerating a looser count.

**The one that was hard to get right.** Message number 60 belongs to *both*
`SSH_MSG_USERAUTH_PK_OK` (RFC 4252 § 7) and `SSH_MSG_USERAUTH_INFO_REQUEST` (RFC 4256 § 3.2).
The bodies cannot be told apart from the bytes. Guessing from the payload would be a parser
a server could steer into the wrong branch, so the meaning comes from what this side sent:
`SSHPacketParser.expectsKeyboardInteractiveInfoRequest` is set as the request is written and
cleared the moment the exchange ends — on failure, on success, and on *any other* method
being offered, so one forgotten path cannot leave the parser mis-reading for the rest of the
connection. `KeyboardInteractiveMessagesTests` feeds the same bytes to both readings and
requires them to disagree.

**A hang the tests found.** Dismissing the sheet originally sent nothing and returned
nothing, which is correct — blank answers would look like a wrong password and spend one of
the server's few tries — but it left the connection sitting until `LoginGraceTime` expired:
**31.1 seconds** of an apparently-frozen spinner, measured. Cancellation now fails the
attempt immediately and is reported as a cancellation rather than as the server rejecting a
credential. The same test measures **1.1 seconds**.

**Bounds, because the peer is not trusted.** `num-prompts` and `num-responses` are capped at
1024, OpenSSH's own client limit, and the number of rounds one attempt may produce is capped
at 32. A server that exceeds either is refused rather than allocated for.

## 2026-09-08 — after D-050 (the hardware-keyboard failures, understood and fixed)

| Command | Result |
| --- | --- |
| `bash scripts/ui-terminal-e2e.sh` | **48 passed, 2 failed** — and the two are `ZZSearchProbeUITests`, another session's uncommitted work. Every hardware-keyboard test passes. It was 46/4 before |
| Release archive | **ARCHIVE SUCCEEDED** |
| `ST_ONLY_TESTING=…/HardwareKeyboardStateUITests`, three runs | **2 passed, 0 failed** each time — it had failed every run before |
| `ST_ONLY_TESTING=…/HardwareKeyboardUITests`, three runs | **6 passed, 0 failed** each time — it had failed about one run in three |

**What was actually wrong.** Not the app. `ZZFindProbeUITests`, a throwaway suite written to
find out and then deleted, ran eight probes against ⌘F twice each:

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

**The first modifier-bearing key press XCUITest delivers to a screen is discarded.** Waiting
does not help, so it is not a race; a plain key does not absorb it while any modified key
does, bound or not; and the menu row and the second press both work, so the app is fine.

Two more measurements said where the sacrificial press has to go. Sent right after
`launch()` returns it absorbs nothing and the first real shortcut still vanishes — the app
has to be up. Sent on the host list and then followed by opening a terminal, the terminal's
own first shortcut vanishes again — so the loss is **per screen**, not per launch. And
priming a terminal with the unbound combination made things worse in a way worth recording:
the terminal forwards keys it does not handle to the remote shell, so those bytes garbled
the next line the test typed and broke a plain-typing assertion that had always passed. The
terminal is primed with ⌘C, which it consumes and which copies nothing when nothing is
selected.

No assertion was weakened and no test was deleted to get this green. What changed is that
the press the simulator eats is now spent on purpose, so a test that fails afterwards failed
for a reason.

## 2026-09-08 — after D-049 (Secure Enclave SSH keys)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test --no-parallel` | **275 tests in 40 suites passed** (267 before; 8 new) |
| `cd Packages/swift-nio-ssh-rsa && swift test` | **349 tests, 0 failures** — unchanged, and unchanged *by* this: the fork was not touched |
| `bash scripts/app-integration-e2e.sh` | **258 tests in 48 suites passed** (253 before; 5 new) |
| `bash scripts/ui-terminal-e2e.sh` | **46 passed, 4 failed** — see below; none of the four is this change |
| `bash scripts/localization-audit.sh` | **green**, 32 new strings translated into both Chinese variants |
| Release archive | **ARCHIVE SUCCEEDED** |

**The four UI failures, and why none of them is this change.** Two are
`ZZSearchProbeUITests`, another session's uncommitted work, failing as they have for six
commits. The other two are hardware-keyboard tests that report the Simulator delivering no
key event at all:

* `HardwareKeyboardUITests.testCommandCommaOpensSettings` — `probe after retry: (count: 0,
  last: "-")`, meaning zero shortcuts were *performed*. Run on its own three times on this
  tree it **passed twice and failed once**: the known first-key-after-launch flake.
* `HardwareKeyboardStateUITests.testTypingWorksAfterEveryThingThatTakesTheKeyboardAway` —
  fails at `⌘F should open the find bar`, one line after an assertion that ordinary typed
  text *did* reach the shell, so input works and the modified key is what went missing.
  This one is not a flake any more: **three isolated runs, three failures.** So it was A/B'd
  against `ef8e1d6` in a detached worktree — the commit immediately before this one — where
  it also failed **three times out of three, at the same line with the same message**. It is
  a pre-existing failure this change neither caused nor fixes, and it is the next thing to
  be dealt with rather than something to leave described as "known".

**The measurement that changed the design.** The plan said Secure Enclave keys were
"verifiable only on a device" and would need NIOSSH taught to accept an external signer.
Both were wrong, and the way they were found to be wrong is the point.

The signer: `NIOSSHPrivateKey` already has `init(secureEnclaveP256Key:)` — upstream
`swift-nio-ssh`, not a fork change — so nothing in `Packages/swift-nio-ssh-rsa` was
touched for this.

The device: a probe compiled for `arm64-apple-ios18.0-simulator` and run with
`xcrun simctl spawn` reported

```
SecureEnclave.isAvailable = true
created, blob bytes = 143
signed, valid = true
restored, same pub = true
```

so the Simulator on this Apple silicon Mac has a working enclave. A second probe pinned
down exactly what it does *not* have:

```
biometry policy evaluable: false — Biometry is not enrolled.
privateKeyUsage:                    created + signed, valid = true
privateKeyUsage+userPresence:       FAILED: com.apple.LocalAuthentication Code=-1020
                                    "This call is not supported on iOS Simulator."
privateKeyUsage+biometryCurrentSet: FAILED: … Code=-1020
```

That split is what the claims below are scoped to.

**What is proven, and by whom.** The package suite's `SecureEnclaveKeyTests` generates a
key inside the enclave, puts *only its public half* in a real `sshd`'s `authorized_keys`,
authenticates, runs a command, and then reads the server's own log:

```
Accepted publickey for … ECDSA SHA256:<the enclave key's fingerprint>
```

The fingerprint in that line is the enclave key's, and it is the only credential offered —
so the test cannot pass for another reason. A companion test points the same key at a
server that was never told about it and requires the login to fail. `ssh-keygen -l` is run
on the public key line the app writes and must report the same fingerprint the app shows,
which is what makes "paste this into your server" a checkable instruction.

`SecureEnclaveAuthTests` repeats the login through the app's own stack — Keychain,
`SessionManager`, `TerminalSession` — and authorises its key by appending the public line
over SSH rather than by writing the Mac's filesystem, so the same test is meaningful on a
device. `KeyManagementUITests.testGeneratingAKeyInTheSecureEnclaveSaysItCannotBeExported`
drives the real screens and checks that the list says the key cannot be exported.

**What is not proven.** The biometric policy, for the reason measured above. It is H-7 in
`docs/HUMAN_ACTIONS.md` and is not marked done anywhere.

**What the app refuses to pretend.** An enclave key has no exportable form, so the backup
lists it by name as unexportable instead of silently omitting it; iCloud Keychain is not
offered for it at all; deleting one warns that the enclave destroys its only copy; and a
record that arrives from another device is shown as unusable *here* rather than as a
missing sync. In Files, a key whose policy is "while the device is unlocked" is published
and works — the enclave signs with nobody present — while one that asks for Face ID at
every signature is refused, because a background process cannot raise that prompt.

## 2026-09-08 — after D-048 (post-quantum key exchange)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test --no-parallel` | **267 tests in 39 suites passed** |
| `cd Packages/swift-nio-ssh-rsa && swift test` | **349 tests, 0 failures** — run because this changes what every connection negotiates |
| `bash scripts/app-integration-e2e.sh` | **253 tests in 47 suites passed** |
| `bash scripts/ui-terminal-e2e.sh` | **46 passed, 3 failed** — the same 3 as the last four commits |
| `bash scripts/localization-audit.sh` | **green**, no new strings |
| Release archive | **ARCHIVE SUCCEEDED** |

**How the hybrid was verified, and why the verification is the point.** A key exchange can
be wrong in a way that is completely invisible from inside: an implementation that encodes
the shared secret differently at both ends agrees with itself perfectly and with nothing
else. So the test does not check this code's own arithmetic. It connects to OpenSSH 10.2p1,
runs a command, and then reads **sshd's own log** for the line naming the algorithm it
chose:

```
debug1: kex: algorithm: mlkem768x25519-sha256
```

The assertion matches that line specifically, not the bare algorithm name — the log also
lists everything the client offered, and a looser check would have passed even if the
classical exchange had been selected. And the command's output is the second half of the
proof: the keys protecting it are derived from the hybrid secret, so an encoding wrong by
one length prefix fails the MAC on the next packet rather than producing wrong output.

A second test narrows the server to `KexAlgorithms curve25519-sha256` and checks the
connection still works and that sshd chose the classical exchange — a client that offers a
hybrid first must accept being told no.

**What was refactored to make room.** RFC 4253 § 7.2 key derivation moved out of
`EllipticCurveKeyExchange` into `SessionKeyDerivation`, shared by both exchanges. The two
differ only in how `K` is absorbed — an mpint for the elliptic curves, a fixed-length string
for the hybrid — and duplicating a key-derivation function would have been two chances for
one copy to drift. The vendored fork's own 349 tests cover the moved code.

## 2026-09-08 — after D-047 (jump hosts)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test --no-parallel` | **265 tests in 38 suites passed** |
| `bash scripts/app-integration-e2e.sh` | **253 tests in 47 suites passed** |
| `bash scripts/ui-terminal-e2e.sh` | **46 passed, 3 failed** — the same 3 as the last three commits |
| `bash scripts/localization-audit.sh` | **green**, 8 new strings in both Chinese variants |
| Release archive | **ARCHIVE SUCCEEDED** |

**What the jump tests prove.** Two real `sshd` processes with different host keys, and the
inner connection's recorded host key is compared with the *second* server's published key —
which is the only thing that tells "went through the bastion" apart from "never left it"
when both are on the same loopback. The app-level suite adds a second `sshd` to
`scripts/app-integration-e2e.sh` and checks the known-hosts store holds two entries after a
jumped connection: each hop is checked against its own record, so a chain is as many trust
decisions as it has hops.

Closing behaviour is tested rather than assumed: closing the session closes the bastion
behind it, and dropping the bastion's connection ends the session it carries. The second of
those was rewritten during the work — killing the harness's sshd process does *not* end an
established session, because sshd forks a child per connection, and a test relying on that
would have been testing a property of sshd rather than of this client.

**A defect this found in the previous commit.** The connection editor rebuilt a `Host` from
the fields on screen, so saving an edit erased anything the editor does not show — including
the port-forwarding rules D-045 had just added. The editor now applies its changes to the
existing record through `Host.applying(_:)`, which makes the whole class of mistake
impossible rather than something to remember, and `HostEditingTests` holds the rule.

## 2026-09-08 — after D-046 (OpenSSH certificates)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test --no-parallel` | **261 tests in 37 suites passed** |
| `cd Packages/swift-nio-ssh-rsa && swift test` | **349 tests, 0 failures** — the vendored fork's own suite, run because this change touches its host-key negotiation |
| `bash scripts/app-integration-e2e.sh` | **246 tests in 45 suites passed** |
| `bash scripts/ui-terminal-e2e.sh` | **46 passed, 3 failed** — the same 3 as the previous two commits |
| `bash scripts/localization-audit.sh` | **green**, 34 new strings in both Chinese variants |
| Release archive | **ARCHIVE SUCCEEDED** |

**What the certificate tests prove.** The key they authenticate with is deliberately not in
the server's `authorized_keys`. A login with it succeeded because sshd checked a
certificate against the authority named in its own `TrustedUserCAKeys`, and there is no
other path available — which the neighbouring test confirms by offering the same key
without its certificate and being refused. The suite also covers a certificate signed by an
authority the server does not trust, one issued for another user, and one that expired two
hours ago; each is refused, and the expired one is recognised by the app before the server
is even asked.

Host certificates are proved the same way: a server configured with `HostCertificate`
connects with an approval delegate that fails the test if it is consulted at all, and the
same server with no trusted authority configured falls back to asking. A certificate issued
for a different host name is refused outright, and the test asserts the user was *not*
asked — a certificate that fails validation must never become a prompt someone taps through.

**One line in the vendored fork.** NIOSSH understood certified keys but never advertised
them, so no server ever offered one: `supportedServerHostKeyAlgorithms` now lists the four
`*-cert-v01@openssh.com` names ahead of the bare ones, exactly as OpenSSH orders them. That
is the whole change; everything else — parsing, signature verification, validation — was
already there. The fork's own 349 tests were run because this alters what every connection
negotiates.

**A defect this found in the fallback.** With certificates now negotiated, a server that
presents one to a client with no trusted authority would have had its *certificate*
remembered in known-hosts. Certificates are reissued routinely, so every renewal would have
raised "the host key has changed" — the one warning that has to mean something. The
fallback now records the key inside the certificate, and a test reads the stored entry back
and compares it with the server's own `host_ed25519.pub`.

## 2026-09-08 — after D-045 (port forwarding)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test --no-parallel` | **249 tests in 36 suites passed**, twice in a row, 112 s |
| `bash scripts/app-integration-e2e.sh` | **243 tests in 44 suites passed** |
| `bash scripts/ui-terminal-e2e.sh` | **46 passed, 3 failed** — the same 3 the previous commit produces, see D-044's entry |
| `bash scripts/localization-audit.sh` | **green**, 40 new strings in both Chinese variants |
| Release archive | **ARCHIVE SUCCEEDED** |

**What the forwarding tests actually move.** Nine of the package's tests are a real listening
socket on this machine, through a real SSH connection to OpenSSH's own `sshd`, to a real
service — bytes in, the same bytes back, counted by the rule's own traffic counters. A local
forward carries a service's opening greeting, which is the case a splice assembled a moment
too late silently loses. A remote forward asks the server to listen, and a connection made
to the *server's* port comes back and is answered here. A dynamic forward completes a SOCKS5
handshake, tunnels, and refuses `BIND` and an authentication-only client in the protocol's
own terms. Three app tests do it again through a `TerminalSession`, with the destination set
to the test server's own SSH port so that what comes back is a real `SSH-2.0-` banner.

**`--no-parallel` is new, and it is not a workaround for a product defect.** Starting an
`OpenSSHTestServer` blocks the thread it is constructed on while it polls for sshd to
answer, and in an `async` test that thread belongs to Swift Concurrency's cooperative pool.
Enough suites doing that at once leaves nothing to resume the tasks waiting on an SSH
handshake, which then time out and blame a suite that did nothing wrong. Measured: with the
forwarding suite added, six parallel runs produced four such failures, never the same test
twice; the same suite with `--no-parallel` passed twice, and without the forwarding suite the
parallel run passed twice. The pool was already close to the edge — the new suite is what
pushed it over, not what broke it.

Two things were fixed on the way to that conclusion rather than left as folklore.
`OpenSSHTestServer` now reads the greeting on its port before declaring itself started: it
chooses a port by binding zero and letting go, and when something else won that race the old
check — "can I connect?" — was satisfied by the thief. And this suite's own listeners now
bind outside the ephemeral range (49152 and up on this machine), so they cannot be the thief.

## 2026-09-08 — after D-044 (servers in the Files app)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test` | **240 tests in 35 suites passed** — 29 of them the File Provider's, against OpenSSH's own `internal-sftp` |
| `bash scripts/app-integration-e2e.sh` | **234 tests in 42 suites passed**, 1 skipped |
| `bash scripts/ui-terminal-e2e.sh` | **44 passed, 3 failed** — see below; the same 3-of-47 as the commit before this one |
| `bash scripts/localization-audit.sh` | **green**, 17 new strings in both Chinese variants |
| Release archive | **ARCHIVE SUCCEEDED** |

**What the archive proves.** The signed extension inside the archive carries
`com.apple.security.application-groups = [group.dev.apexterminal.app]` and
`keychain-access-groups = [7CDDP73WJS.dev.apexterminal.app]` — the *app's* Keychain group,
not its own — so on a device the extension really can read the credential the app stored,
with one copy of the secret rather than two. Automatic signing registered the App Group and
the extension's App ID without a manual step in the portal.

**The one skipped test.** `FileProviderEndToEndTests` publishes a domain, asks the system
where its root is, and reads it with `FileManager` — the whole path, with nothing mocked.
It skips itself on the simulator, which has no FPFS: `fileproviderd` logs `was asked with
FPFS, but it's not supported, will fallback`, drops the `replicated` flag from the domain,
then serves it through the older API and aborts the extension. That is a property of the
simulator, and `FileProviderDomainTests` asserts the downgrade so it cannot be mistaken for
a regression. The device run is H-6.

**The three UI failures are not this change.** The same suite was run at `0622e74`, in a
detached worktree, and failed **the same 3 of 47**: `ZZSearchProbeUITests` twice — another
session's uncommitted files, known — and one hardware-keyboard test. The third differed
between runs (`HardwareKeyboardUITests.testCommandKWithTheSearchFieldFocused` here,
`HardwareKeyboardStateUITests.testTypingWorksAfterEveryThingThatTakesTheKeyboardAway` at
the baseline), both failing with *Neither element nor any descendant has keyboard focus* —
the `ConnectHardwareKeyboard` fragility already recorded. Run on its own,
`testCommandKWithTheSearchFieldFocused` passes on both trees. No test was edited to make
any of this go away.

**A defect the tests found rather than the reviewer.** `FileProviderRetryTests` severs a
real TCP connection in the middle of a real 24 MB upload. The first version of the recovery
left the dead attempt's `.apexupload-*` file on the server, because the only connection
that could have removed it was the one that had just died; the test failed on exactly that
and the upload now cleans up over the *next* connection before trying again. It also had to
be made honest twice: sampling `completedUnitCount` missed the restart often enough to pass
without proving anything, so the restart is now observed through KVO. Four consecutive runs
see the cut, the restart, the whole file byte-for-byte, and nothing left behind.

## 2026-09-08 — after D-043 (prompts, permissions, sharing, drag-and-drop)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test` | **211 tests in 32 suites passed** |
| `bash scripts/app-integration-e2e.sh` | **237 passed, 0 failed** |
| `bash scripts/ui-terminal-e2e.sh` (FileBrowserUITests) | **2 passed** against the harness's own sshd — a real listing, and a real file's real mode filled into the editor |
| `bash scripts/localization-audit.sh` | **green**, 12 new strings in both Chinese variants |
| Release archive | **ARCHIVE SUCCEEDED** |

## 2026-09-08 — after D-042 (SFTP file browser)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test` | **211 tests in 32 suites passed** |
| `bash scripts/app-integration-e2e.sh` | **236 passed, 0 failed** |
| `bash scripts/ui-terminal-e2e.sh` (FileBrowserUITests) | **1 passed** — a real listing from the harness's own sshd |
| `bash scripts/localization-audit.sh` | **green**, 53 new strings in both Chinese variants |
| Release archive | **ARCHIVE SUCCEEDED** |

The UI test was read on screen before it was trusted: the browser showed the real home
directory over the real server, with real modification dates and real permission strings
(`drwxr-xr-x`, `drwx------`), folders sorted first, and a working path bar. The first two
runs failed on the test's own locator, not on the feature.

## 2026-09-08 — after D-041 (SFTP protocol)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test` | **211 tests in 32 suites passed** |
| `swift test --filter SFTPIntegrationTests` | **7 passed** against OpenSSH `internal-sftp` |
| `bash scripts/app-integration-e2e.sh` | **229 passed, 0 failed** |

What the integration tests actually prove, since a hand-written server would have agreed
with whatever the client did: a file written through the protocol is on the real
filesystem byte for byte and readable without the client; a 100,000-byte payload survives
being split across 32 KiB chunks with a partial last write and read; a 400-entry directory
is listed in full, which needs more than one READDIR page; version 3's RENAME refuses to
clobber, which is what makes it usable as the commit step of an atomic upload; `lstat` and
`stat` disagree about a symlink in the way they must; and a missing path comes back as
`noSuchFile` rather than a generic failure.

## 2026-09-08 — after D-040 (backup, restore and recovery)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test` | **199 tests in 30 suites passed** |
| `bash scripts/app-integration-e2e.sh` | **229 passed, 0 failed** |
| `bash scripts/ui-terminal-e2e.sh` (BackupUITests) | **2 passed** |
| `bash scripts/localization-audit.sh` | **green**, 32 new strings translated into both Chinese variants |
| `xcodebuild … -configuration Release -destination 'generic/platform=iOS' … archive` | **ARCHIVE SUCCEEDED** |

The backup file type `dev.apexterminal.backup` is present in the built `Info.plist`,
verified with `plutil -p`.

## 2026-09-08 — after D-038 (export compliance) and D-039 (input-method composition)

| Command | Result |
| --- | --- |
| `cd Packages/ApexTerminalKit && swift test` | **199 tests in 30 suites passed** |
| `bash scripts/app-integration-e2e.sh` | **217 passed, 0 failed** |
| `bash scripts/localization-audit.sh` | **green** — every string translated in zh-Hans and zh-Hant; the product-name check passes |
| `xcodebuild … -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` | **BUILD SUCCEEDED** |
| `xcodebuild … -configuration Release -destination 'generic/platform=iOS' … archive` | **ARCHIVE SUCCEEDED** (before D-039; re-run pending) |

### Counts, recounted

| What | Number | How |
| --- | --- | --- |
| Package tests | 199 in 30 suites | `swift test` output |
| App unit tests | 217 | `grep -c "' passed on"` |
| Tests against a real LibVNCServer | **5** | `grep -c "@Test" Tests/STVNCTests/VNCClientTests.swift`, suite "VNC client against LibVNCServer" |
| Localisation entries, shipped catalogs | **738** across 6 files | counted from the `.xcstrings` JSON |
| … of which the audit gates | 731 across 3 files | `Localizable` 641 + `STSSH` 49 + `STCloudflare` 41 |

### Verified by watching it fail

* The product-name check in `scripts/localization-audit.sh`: the compact spelling was
  reintroduced into `INFOPLIST_KEY_NSFaceIDUsageDescription`, the audit exited 1 and named
  both lines; removing it again returned exit 0.
* The DES replacement: FIPS 46-3 known-answer vectors pass, and the LibVNCServer
  authentication test still passes, which is what proves the swap is byte-identical where
  it matters.

### Not yet evidence

* Input methods on hardware (H-1). The `UITextInput` calls are covered; a real Pinyin,
  Kana or Hangul keyboard is not.
* Archive after D-039.
