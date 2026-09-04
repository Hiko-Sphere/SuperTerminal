# swift-nio-ssh-rsa

A vendored copy of [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh) with
support for `rsa-sha2-256` and `rsa-sha2-512` added.

**Upstream commit:** see `UPSTREAM_COMMIT` (tag `0.15.0`).
**Licence:** Apache-2.0, unchanged — see `LICENSE.txt`.

## Why this exists

`swift-nio-ssh` implements no RSA key type. That leaves two real gaps for an SSH client:
RSA user keys, which remain common, cannot authenticate; and a server configured with only
RSA host keys cannot be reached at all.

Adding a key algorithm means touching internal enums, so it cannot be done from outside
the module. The full rationale, including the alternatives weighed, is in
`DECISIONS.md` (D-007).

## The maintenance obligation this creates

Vendoring security-critical code means upstream fixes no longer arrive on their own. That
is a real cost, and the mitigation is that the change is kept as a **patch**, not as edits
merged into the tree:

* `patches/niossh-rsa.patch` at the repository root is the complete difference from
  upstream.
* `scripts/update-vendored-niossh.sh` re-fetches upstream at a given tag, re-applies the
  patch, and **fails loudly** if it no longer applies cleanly.
* Upstream's own test suite is vendored alongside the source and runs in CI, so a re-sync
  that breaks something is caught rather than assumed safe.

Check <https://github.com/apple/swift-nio-ssh/releases> when updating dependencies. If
upstream adds RSA, this package should be deleted and the dependency pointed back at it.
