# ADR 0005: SQLite receipt-bound acknowledgement

**Status:** proposed
**Date:** 2026-08-24
**Deciders:** cattyneo fork owner (`cattyneo/.agents#211`)

This fork-local proposed decision is not an upstream acceptance or approval.

## Context

Bounded reads are deliberately read-only observations. A consumer that has
displayed a bounded unread prefix needs a separate, explicit acknowledgement
that cannot mark a different row, cross a concurrent gap, or be replayed.
This ADR adds that capability only to the bundled SQLite driver. It neither
changes the required storage ABI nor activates a receipt path in existing
inbox, watcher, hook, delivery, or JSONL callers.

## Decision

### Optional ABI and status framing

SQLite alone exposes these optional functions:

```
storage_receipt_init <team>
storage_receipt_status <team>
storage_ack_receipt <team> <recipient> --receipt <token>
```

Receipt issuance is available only as the SQLite-local
`--issue-receipt` argument of the existing bounded list and exact-show
functions. It is not a new required cross-driver function. SQLite advertises
the exact whole capability token `sqlite-receipt-ack-v1` in the single
comma-separated `capabilities=` line emitted by `storage_describe`. Tokens
match `[a-z0-9][a-z0-9-]*`, are unique, and are compared as whole tokens.
Advertisement establishes that the optional ABI exists; it does not establish
that a given store is initialized, so callers must use status.

JSONL neither advertises nor defines this ABI. Its bounded list/show reject
`--issue-receipt` non-zero with zero stdout and no mutation. Existing calls
without that flag remain unchanged.

`storage_receipt_init` and `storage_receipt_status` are control operations but
do not extend the required §1.4 vocabulary:

| Exit | stdout | Receipt meaning |
|---:|---|---|
| 0 | `ok` | ready / init succeeded |
| 10 | `missing_deps` | only OpenSSL 3 or `xxd` is unavailable |
| 12 | `corrupt_state` | filesystem, keys, schema, generation, capability metadata, or nonce state is invalid |
| 13 | `runtime_error` | not initialized, unsupported platform, claim conflict, busy/lock, or other operational refusal |

Status outcomes are mutation-free. Bounded issue and ack are data operations:
all failures are non-zero with zero stdout and a bounded, non-sensitive stderr.
No diagnostic contains key bytes or a receipt token.

For a ready store, `storage_receipt_status` stdout is exactly `ok`. Every
non-ready result likewise emits only its final §1.4 status name on stdout.
Status deliberately has no public identity projection; callers must not parse
private receipt state through this optional control ABI.

### Receipt v1 canonical bytes

Issue and ack use one shared canonicalization implementation. Parallel,
independently maintained concatenation is noncompliant. All decimal fields are
canonical (`0` or no leading zero); all hex is lowercase and has even length.

The ordered batch material is ASCII:

```
agmsg-batch-v1\n
id_len=<decoded-byte-count>\n
id_hex=<decoded-id-as-hex>\n
body_sha256=<sha256-of-raw-body-bytes>\n
```

The last three lines repeat once per selected row, in display order. Raw IDs
and raw bodies never enter the signed payload or argv.

The ordered frame material is ASCII:

```
agmsg-frame-v1\n
index=<zero-based-canonical-decimal>\n
team_len=<decoded-byte-count>\n
team_hex=<decoded-team-as-hex>\n
from_len=<decoded-byte-count>\n
from_hex=<decoded-sender-as-hex>\n
to_len=<decoded-byte-count>\n
to_hex=<decoded-recipient-as-hex>\n
at_len=<decoded-byte-count>\n
at_hex=<decoded-timestamp-as-hex>\n
source=event|legacy\n
source_ord=<canonical-decimal>\n
```

The signed payload consists of exactly these newline-terminated fields, in this
order, with one final trailing newline and no extra field:

```
v=1
driver=sqlite
store_generation=<32 lower hex>
key_sha256=<64 lower hex>
team_hex=<lower even hex>
recipient_hex=<lower even hex>
selected_count=<1..10 canonical decimal>
batch_sha256=<64 lower hex>
frame_sha256=<64 lower hex>
issuance_frontier=<canonical decimal>
issued_at=<epoch>
expires_at=<issued_at + 900>
nonce=<32 lower hex>
```

The token is unpadded canonical base64url(payload), one literal `.`, then
unpadded canonical base64url(signature), no more than 2,048 bytes. The final
completed JSON record is compact and exactly shaped as:

```json
{"type":"bounded_unread_receipt","receipt_version":1,"selected_count":N,"issued_at":I,"expires_at":E,"receipt":"TOKEN"}
```

It is subject to the existing bounded-record cap. Empty selections emit no
receipt. Exact show may issue only for the current first unread row; a later
row with the flag fails before writing stdout. `issuance_frontier` is the
`events` AUTOINCREMENT high-water observed in the issuance snapshot. It limits
ack cursor movement, but later appended events do not by themselves invalidate
the receipt.

`tests/fixtures/receipt-v1-vectors.txt` is the public fixed-vector source for
the byte encodings and SHA-256 values. Its boundary and mutation pairs must be
used by both issuing and acknowledging tests.

### Identity, claims, and acknowledgement

An event row binds private source `(event, events.seq)` and mirrors only the
exact `messages.id = events.legacy_id` row. A direct legacy row binds
`(legacy, messages.rowid)` and updates only that exact row. Any team,
recipient, or source identity mismatch rolls back.

The receipt capability is disabled when the shared predicate finds any of:
the repo-relative exact `scripts/lib/claims.sh` path, a loaded exact
`agmsg_claim_next`, `agmsg_ack_claim`, or `agmsg_release_claim` function, the
exact SQLite `claims` table, or parsed capability token `message-claim-v1` or
any `message-claim-*` token. Malformed or duplicate capability metadata also
rejects. The predicate must not use substring scans of unrelated paths,
functions, tables, or words, and status, issue, and ack use the same predicate.

`storage_ack_receipt` verifies the signed canonical payload, its 15-minute
time window, current consecutive unread prefix, generation/key/team/recipient,
both digests, issuance frontier, claim interlock, and nonce inside one SQLite
`.bail on` / `BEGIN IMMEDIATE` transaction. Only after all checks pass does it
record the nonce, insert the matching `message_read` events, perform exact
legacy mirrors, and advance the cursor. It exits 0 with zero stdout only after
commit; every failure rolls back and emits zero stdout.

Each committed nonce row stores the payload digest, store generation,
team digest, recipient digest, batch digest, frame digest, receipt expiry, and
commit time. Successful acknowledgement prunes in the same transaction only
rows whose `expires_at < transaction_now - 86400`. Before pruning, only an
exact all-field match reports bounded `already_committed`, including after
receipt expiry; any mismatch is a refusal. Once pruned, it reports
`stale_or_replayed`; it never becomes valid again. Rollback or any failed
acknowledgement never prunes. Clock rollback delays pruning rather than
accelerating it.

### Initialization, filesystem, and platform boundaries

Only explicit `storage_receipt_init` creates receipt state, key pair, store
generation, schema, or nonce state. Read, issue, ack, and status never repair,
rotate, or initialize absent/suspect state. Re-init preserves a complete valid
identity.

The receipt state layout is fixed under the selected SQLite storage directory:
`receipt-v1/private.pem`, `receipt-v1/public.pem`, and `receipt-v1/init.lock`.
The SQLite-private metadata schema is fixed as
`receipt_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)` with exactly these
required keys: `schema_version` (the decimal `1`), `store_generation` (32
lowercase hex), and `public_key_sha256` (the 64 lowercase-hex SHA-256 of the
exact `public.pem` bytes). This schema is state-validation data, not a public
storage ABI or a status output format. Isolated storage validation may query it
read-only together with the public-key file hash; production callers use only
the `ok`/existing-error status vocabulary. Init creates the `receipt_meta`
schema and commits all three required rows in one SQLite transaction. A crash
may expose neither metadata nor this complete committed set; it must not expose
or accept a partially committed identity.
The receipt directory is non-symlink, owner-owned, and `0700`. The parent
storage directory itself is also non-symlink and owner-owned, with no
group/world write bit. Key files and the SQLite DB are non-symlink, regular,
owner-owned, single-link files; keys are `0600`, and the DB has no
group/world write bit. Half keys, replacement, hard link, symlink, owner/mode,
fingerprint, or generation mismatch fails closed. Status, issue, and ack check
all identities before use; ack repeats them under its operation lock immediately
before opening SQLite. Same-owner replacement outside that lock and complete-store
clone detection are not claimed.

POSIX does not permit unprivileged hard links to directories, so the hard-link
requirement applies to regular DB/key/lock records; directory hard-link
attempts are not a meaningful portable test case. Directory symlink, owner,
and mode checks remain mandatory.

Init creates a complete `0600` `receipt-v1/.init-stage.<owner_nonce>` staging
record before linking it to the fixed `receipt-v1/init.lock` name:

```
pid=<decimal>
owner_nonce=<32 lower hex>
created_at=<epoch>
```

It atomically hard-links that closed file to the fixed lock name, then
immediately unlinks its exact staging pathname. Contenders wait at most
100 × 50 ms. A valid live PID is never reclaimed, regardless of apparent age.
While the acquirer has not yet removed the staging name, link count two is
valid only if that sibling has the same device/inode and exact record. A valid
dead owner may have both validated names removed and the lock reacquired;
malformed, misowned, mis-moded, unexpectedly linked, or inode-mismatched state
is `corrupt_state` and is never automatically removed. Dead pre-link staging
files may be removed only after the same exact-record, same-inode, dead-PID
validation; they never grant a lock. PID reuse is conservatively treated as
live/unknown and requires manual recovery. Traps remove only the caller's
still-matching inode/nonce names. SIGKILL or host crash is recovered only by
the next validated dead-owner reclaim: pre-link leaves a validated staging
record, post-link/pre-unlink leaves the validated two-link pair, and
post-acquisition leaves the valid fixed lock. After acquiring or reclaiming,
init rechecks complete state before writing.

The crash matrix runs on a POSIX runner with shell command-shadowing, SQLite,
and OpenSSL 3, and requires a usable `ps` identity containing process start
time and command before it spawns a background process. A runner without that
identity proof skips the crash/lock process cases rather than risking a signal
to a recycled PID. It launches a real initializer and test-side wrappers for
`ln`, OpenSSL, and `sqlite3` pause only at observed filesystem/metadata
milestones before `SIGKILL`: receipt directory, private key, public key, the
single atomic `receipt_meta` commit (schema plus all three required rows),
pre-link, post-link/pre-unlink, and post-acquisition. Each marker records its
exact point, receipt path, and paused wrapper PID; the harness kills and checks
both initializer and wrapper before asserting the residual state. Native Git
Bash cannot provide these POSIX process and path semantics, so its unsupported
receipt behavior is tested on a native Git Bash runner instead. PID reuse
likewise needs a PID namespace to induce safely; its conservative refusal
requires such a runner, and is otherwise a documented platform-conditional
test.

OpenSSL 3 and `xxd` are mandatory runtime dependencies. The receipt-only
`AGMSG_RECEIPT_OPENSSL` and `AGMSG_RECEIPT_XXD` overrides, when set, must each
be an absolute executable path and receive the same capability probes as the
platform candidates; an unavailable, non-v3, or incapable override is
`missing_deps` and cannot fall back. Git Bash/Windows is unsupported for
receipt init, issue, and ack until owner-only ACL equivalence is proven; those
receipt operations fail closed while legacy and bounded read-only behavior
remains supported. Receipt lifetime depends on wall clock: rollback before
`issued_at` fails closed, but stateless receipts do not prove permanent
historical expiry after arbitrary clock rollback.

## Consequences

SQLite gets an opt-in, receipt-bound acknowledgement without broadening the
storage driver ABI or silently changing read behavior. The safety cost is a
runtime dependency, strict filesystem requirements, and explicit unsupported
platform behavior. JSONL keeps its existing behavior and has no composite
receipt transaction in this issue.

## References

- Issue: `cattyneo/.agents#211`
- Parent issue: `cattyneo/.agents#116`
- Bounded read contract: `docs/spec/driver-interface.md` §2.1.1
- Storage ABI: `docs/spec/driver-interface.md` §§1.4 and 2.1
