# SQLite receipt-bound acknowledgement

> **Implementation note:** Execute this plan task-by-task only in the dedicated
> fork worktree. This change adds an opt-in SQLite storage capability; it does
> not activate that capability in `.agents` or rewire any existing inbox,
> watcher, hook, delivery, or JSONL path.

**Goal:** Add a SQLite-only, receipt-bound acknowledgement operation that can
mark only the exact consecutive unread prefix which a bounded read completed,
with nonce consumption and every read-state transition in one durable commit.

**Source of truth:** `cattyneo/.agents#211`, especially the direct owner
decisions recorded on 2026-08-24 and 2026-08-25. Parent context is
`cattyneo/.agents#116`; bounded reads were established by
`cattyneo/.agents#203` and fork PR `cattyneo/agmsg#2`. Shared maintenance-lock
follow-up `cattyneo/.agents#220` is mandatory before downstream activation, but
does not block this fork-local PR or merge.

**Observable success criteria:**

- SQLite exposes an optional receipt capability without changing the required
  cross-driver ABI or the behavior of existing `storage_*`, `inbox.sh`,
  `check-inbox.sh`, watcher, history, and mark-read callers.
- Receipt state and the Ed25519 key pair are created only by an explicit
  `storage_receipt_init <team>` control operation. A read, receipt issue, ack,
  or status check never repairs or silently replaces missing or suspect state.
- `storage_list_unread_bounded ... --issue-receipt` emits the existing message
  and result records followed by one final `bounded_unread_receipt` record when
  at least one row was selected. `storage_get_message_bounded ...
  --issue-receipt` can issue a receipt only when the target is the current first
  unread row. The token is complete only in that final record.
- Issuance is stateless and binds schema version, per-store generation, public
  key fingerprint, SQLite driver, team, recipient, selected count, issuance and
  expiry epochs, a 16-byte nonce, the owner-required ordered batch digest over
  length-prefixed `(opaque ID, SHA-256(raw body bytes))`, and an additional
  ordered frame digest over the displayed sender/team/recipient/timestamp and
  private source identity. The extra digest closes the approved cross-sender
  and displayed-metadata mutation cases without changing the opaque ID
  transport contract.
- `storage_ack_receipt <team> <recipient> --receipt <token>` returns exit 0 and
  stdout 0 bytes only after commit. It evaluates the same closed claim
  predicate at operation start and again with one `.bail on` /
  `BEGIN IMMEDIATE` transaction open, immediately before `COMMIT`; within that
  transaction it also rechecks the valid time window, SQLite claim interlock, unused nonce,
  exact current consecutive prefix, both digests, and issuance frontier; then
  records the nonce, inserts `message_read` events, mirrors only the matching
  legacy rows, and advances the cursor without crossing a gap or the issuance
  frontier.
- Every malformed, forged, expired, clock-rollback, replayed, stale, non-prefix,
  cross-store/team/recipient/sender, key/runtime, filesystem-integrity, busy,
  statement, or commit failure returns non-zero, stdout 0 bytes, bounded stderr,
  and no partial durable transition. A retry after an unobserved successful
  commit returns a distinct bounded `already_committed` diagnostic and directs
  the caller to unread summary reconciliation.
- Known `fujibee/agmsg#373` capability is a hard interlock. One shared predicate
  used by status, issue, and ack rejects the exact `scripts/lib/claims.sh` file,
  known claim functions, SQLite `claims` table, or a `message-claim-*` token in
  the storage driver's versioned capability list. Malformed/duplicate tokens or
  an unknown `message-claim-*` version also reject; unrelated uses of the word
  "lease" do not. A future rebase that changes these authority sources
  invalidates the acceptance and requires a new owner decision.
- External claim/install/update maintenance MUST NOT run concurrently with
  receipt init, issue, or ack. Repository files, loaded functions, and
  capability metadata are outside SQLite's atomic domain, so the final
  pre-commit recheck narrows but does not eliminate a residual TOCTOU. This
  plan does not claim hard cross-domain atomicity; `cattyneo/.agents#220` must
  add the shared maintenance lock before any downstream pin or activation.
- Focused RED/GREEN and controlled mutation evidence covers every owner-listed
  historical failure class, Bash 3.2, Linux/macOS, Git Bash fail-closed behavior,
  WAL and DELETE journal modes, existing official gates, and independent exact
  head review with Blocker/Major=0.

**Key constraints:**

- Worktree `/private/tmp/agmsg-211-worktree`, branch
  `codex/agents-211-sqlite-receipt`, base/fork main
  `2d12dd6e599c84d72977c2b6c0fd2430d001b5f8`; upstream comparison
  `3d06318de3aff9929cfaf87c092fef6709d2cc8b`.
- SQLite-only. JSONL receipt state, intent/composite commit, crash recovery,
  old-reader rollback, public ID encoding/maximum, downstream use/pin,
  activation, upstream proposal, claim implementation, and claim precedence are
  out of scope.
- Do not copy Board's decimal-ID grammar. Opaque IDs never appear as public
  command arguments or inside the receipt payload; only selected count and
  digests cross that boundary.
- Reuse Board's deterministic OpenSSL 3 Ed25519/SHA-256 plus `xxd` capability
  probe, private temporary-file cleanup, explicit owner-only key lifecycle,
  fingerprint verification, 15-minute receipt lifetime, and transaction-time
  expiry/nonce pattern. Names and storage remain agmsg-specific.
- POSIX receipt state requires a non-symlink owner-owned `0700` receipt
  directory and regular owner-owned single-link `0600` key files. The SQLite DB
  itself must be a non-symlink regular owner-owned single-link file, with no
  group/world write bit, under a non-symlink owner-owned non-group/world-writable
  storage directory. Status, issue, and ack check these identities before use;
  ack repeats them under the per-store operation lock immediately before opening
  SQLite. A half-key state, hard link, symlink, owner/mode mismatch, fingerprint
  mismatch, or generation mismatch fails closed and is never automatically
  rotated. Same-owner path replacement outside that lock is outside the threat
  model and is documented rather than overclaimed. Git Bash remains explicitly
  unsupported for receipt init/issue/ack until owner-only ACL equivalence can be
  proven, while all legacy and bounded read-only behavior remains supported.
- A full store-directory copy can preserve generation and keys; this change
  guarantees cross-store rejection for independently initialized stores, not
  clone detection. This Issue does **not** bind canonical physical path into the
  receipt. Moving a complete intact store therefore preserves unconsumed
  receipts; copy/clone resistance is explicitly not claimed.
- Wall-clock rollback before `issued_at` fails closed, and expiry is rechecked
  inside the write transaction. Stateless receipts do not prove permanent
  historical expiry after an arbitrary system-clock rollback; document that
  limitation.
- Use Bash 3.2-compatible shell, no `RETURNING`, no public SQL output from the
  ack transaction, no test weakening, and no live `~/.agents/skills/agmsg` or
  live database access.

**Relevant skills/tools:** `implementation-workflow`,
`superpowers:test-driven-development`, `superpowers:subagent-driven-development`,
`superpowers:requesting-code-review`, `superpowers:receiving-code-review`,
`superpowers:verification-before-completion`,
`superpowers:finishing-a-development-branch`, `general-review`, Bats, sqlite3,
OpenSSL 3, `xxd`, and the existing storage facade.

## Task 1: Freeze the optional ABI, wire format, and key/runtime behavior

**Files:**

- Add `tests/test_sqlite_receipt_keys.bats`.
- Add `tests/fixtures/receipt-v1-vectors.txt` containing public, non-sensitive
  fixed canonicalization vectors and expected digests.
- Add the first contract section to `docs/adr/0005-sqlite-receipt-ack.md`.
- Do not modify production shell in this task.

**Steps:**

1. Specify the optional functions exactly:
   `storage_receipt_init <team>`, `storage_receipt_status <team>`, receipt issue
   only through the existing bounded functions' `--issue-receipt` flag, and
   `storage_ack_receipt <team> <recipient> --receipt <token>`. SQLite advertises
   the exact `sqlite-receipt-ack-v1` token in the single comma-separated
   `capabilities=` line of `storage_describe`; capability tokens match
   `[a-z0-9][a-z0-9-]*`, are unique, and are compared as whole tokens. Presence
   means the optional ABI exists, not that a store is initialized; callers must
   then call status. JSONL does not advertise or define the optional functions.
2. Classify `storage_receipt_init` and `storage_receipt_status` as control ops
   without extending the required cross-driver §1.4 vocabulary. They emit only
   existing statuses: `ok`/0 when ready; `missing_deps`/10 only when OpenSSL 3 or
   `xxd` is unavailable; `corrupt_state`/12 for invalid filesystem, key, schema,
   generation, capability metadata, or nonce state; and `runtime_error`/13 for
   not-initialized, unsupported-platform, claim-conflict, lock/busy, or other
   operational refusal. Bounded stderr carries the specific optional-capability
   reason. Issue and ack remain record-returning/data operations: every failure
   is non-zero with stdout 0. All status outcomes are mutation-free.
3. Freeze the v1 canonical bytes before production code:

   - Batch material begins with ASCII `agmsg-batch-v1\n`. Each ordered row adds
     ASCII `id_len=<decimal-byte-count>\n`, `id_hex=<lowercase-even-hex>\n`, and
     `body_sha256=<64-lower-hex>\n`. Decimal values are canonical (zero or no
     leading zero). The ID length is checked against the decoded bytes; no raw
     ID enters the token or argv.
   - Frame material begins with ASCII `agmsg-frame-v1\n`. Each row adds, in this
     order, `index`, `team_len/team_hex`, `from_len/from_hex`, `to_len/to_hex`,
     `at_len/at_hex`, `source=event|legacy`, and canonical decimal `source_ord`,
     one `name=value\n` field per line. Lengths count decoded bytes. This binds
     displayed scope/metadata and the private source used for legacy updates.
   - The signed payload is exactly these newline-terminated fields in order:
     `v=1`, `driver=sqlite`, 32-lower-hex `store_generation`, 64-lower-hex
     `key_sha256`, even-lower-hex `team_hex` and `recipient_hex`, canonical
     decimal `selected_count` (1..10), 64-lower-hex `batch_sha256` and
     `frame_sha256`, canonical decimal `issuance_frontier`, `issued_at`, and
     `expires_at`, then 32-lower-hex `nonce`. Lifetime is exactly 900 seconds.
     There is one trailing newline and no extra field.
   - The token is unpadded canonical base64url(payload), one literal `.`, then
     unpadded canonical base64url(signature), at most 2,048 bytes. The final
     record is compact JSON
     `{"type":"bounded_unread_receipt","receipt_version":1,"selected_count":N,"issued_at":I,"expires_at":E,"receipt":"TOKEN"}`
     and must also satisfy the existing completed-record cap. Empty selection
     emits no receipt. A later-row show with `--issue-receipt` fails before any
     stdout; the same show without the flag remains unchanged.
   - `issuance_frontier` is the `events` AUTOINCREMENT high-water observed in
     the same read snapshot. It limits cursor advancement but does not invalidate
     a receipt merely because later events append after issuance.

4. Add fixed vectors that make field-boundary, sender, timestamp, source kind,
   source ordinal, ID bytes, and body bytes independently change the expected
   material/digests. Require issue and ack to use one shared canonicalization
   helper; implementations with parallel concatenation logic are noncompliant.
5. Freeze source/mirror semantics that resolve the existing spec conflict:
   event rows use private `(source=event, events.seq)` identity and mirror only
   `messages.id=events.legacy_id` for that exact event; direct legacy rows use
   `(source=legacy, messages.rowid)` and update only that exact row. Team,
   recipient, and identity mismatch rolls back. Task 6 must correct the current
   English/Japanese statement that new read progress never changes `read_at`.
6. Freeze the claim predicate authority. It reads only: the repo-relative exact
   `scripts/lib/claims.sh` path; loaded exact functions `agmsg_claim_next`,
   `agmsg_ack_claim`, `agmsg_release_claim`; exact SQLite table `claims`; and the
   parsed `storage_describe` capability tokens. `message-claim-v1` and every
   unknown `message-claim-*` token reject. Invalid/duplicate capability metadata
   rejects. No ad-hoc substring scan of unrelated paths, functions, tables, or
   words is allowed. Status, issue, and ack call the same helper.
7. Freeze the init-lock lifecycle. Build a complete regular owner-owned `0600`
   staging file adjacent to the receipt state, then acquire the lock with one
   atomic hard-link creation from that closed file to the fixed lock path;
   `link(2)` succeeds only when the lock path is absent, so no empty/recordless
   lock can be observed. The record is exactly
   `pid=<decimal>\nowner_nonce=<32-lower-hex>\ncreated_at=<epoch>\n`. Contenders
   wait at most 100 × 50 ms. A valid live PID is never reclaimed, regardless of
   age. The acquirer immediately unlinks its staging name; during that bounded
   interval link-count 2 is valid only when the exact staging sibling has the
   same device/inode and record. A crash before link leaves no lock; a crash
   after link may leave the validated two-link pair. A valid record whose PID no
   longer exists may have both validated names removed and be reacquired.
   Malformed, unexpected-linked, misowned, mis-moded, or inode-mismatched lock
   state returns `corrupt_state` and is never deleted automatically. PID reuse
   may conservatively block until operator recovery. After every acquisition or
   dead-owner reclaim, init rechecks the complete DB/schema/generation/key state
   before writing. Signal traps remove only names whose inode and owner nonce
   still match the current owner; SIGKILL/host crash is handled by the next
   validated dead-owner reclaim. Dead pre-link staging files never grant the
   lock and may be removed only after the same record/inode/dead-PID checks.
8. Freeze nonce retention. A committed nonce row includes the payload digest,
   store generation, team/recipient digests, batch/frame digests, receipt expiry,
   and commit time. Successful ack prunes, in the same transaction, only rows
   with `expires_at < transaction_now - 86400`; clock rollback therefore delays
   rather than accelerates pruning. Until prune, an exact retry returns bounded
   `already_committed` even after receipt expiry. After prune, the same token
   returns bounded `stale_or_replayed`; it never becomes valid again because the
   current consecutive prefix no longer matches. Rollback/failure never prunes.
9. Add RED tests for explicit init/status, stable and concurrent re-init identity,
   crash boundaries around directory/private/public/schema/generation creation,
   SIGKILL immediately before atomic link, after link but before staging unlink,
   and after acquisition, dead-owner-only reclaim, live-owner refusal, malformed
   or inode-mismatched lock refusal, bounded lock timeout,
   15-minute metadata, no preview-side initialization, missing/half/replaced key
   states, fingerprint/pair/generation mismatch, private temp cleanup, DB,
   receipt directory, and key symlink/hardlink/owner/mode failures, unsupported
   OpenSSL/xxd, and no key bytes or tokens in diagnostics. Init recovery may
   complete only a provably staged same-attempt state; pre-existing half state is
   degraded and never auto-rotated.
10. Add JSONL negative RED cases: list and show with `--issue-receipt` return
   non-zero, stdout 0, and mutation 0; the same calls without the flag preserve
   phase-1 output. Keep flag recognition SQLite driver-local; do not make the
   shared parser silently accept it.
11. Add Git Bash/Windows tests that prove the receipt capability fails closed as
   unsupported while existing bounded and legacy storage tests still run. Do
   not equate POSIX `chmod` output on NTFS with owner-only ACL proof.
12. Run `rtk bats tests/test_sqlite_receipt_keys.bats`; confirm failure is caused
   by the missing optional functions, not fixture or syntax errors. Record the
   RED command and failure reason before production changes.

## Task 2: Implement explicit SQLite receipt state and deterministic runtime

**Files:**

- Add `scripts/lib/receipt-runtime.sh`.
- Add `scripts/lib/receipt.sh`.
- Modify `scripts/drivers/storage/sqlite.sh`.
- Modify `scripts/lib/storage.sh` only for the exact capability parser/shared
  claim predicate support that cannot remain driver-local. Keep
  `--issue-receipt` parsing driver-local.
- Do not change `scripts/internal/init-db.sh` or any live caller.

**Steps:**

1. Port the Board runtime probe under agmsg names: deterministic absolute
   candidates, OpenSSL major 3, actual Ed25519 sign/verify and SHA-256 probes,
   exact 258-byte `xxd` round-trip, private `mktemp` directory, child/signal
   cleanup, and bounded diagnostics. Preserve the Board-equivalent optional
   `AGMSG_RECEIPT_OPENSSL` / `AGMSG_RECEIPT_XXD` absolute-executable overrides;
   an override is accepted only after the same full capability probe and never
   becomes a PATH fallback. Receipt operations alone invoke this runtime.
2. Implement `storage_receipt_init` as the only schema/key writer. Serialize
   concurrent initializers with the exact Task 1 lock/owner/reclaim protocol and
   recheck all state after taking or reclaiming it. Preflight the
   SQLite store and runtime before mutation; create an owner-only receipt state
   directory, key pair, random store generation, receipt metadata and durable
   nonce table. Re-init preserves identity. Partial creation is cleaned or
   reported as degraded; it never rotates a valid existing identity.
3. Implement `storage_receipt_status` with the exact Task 1 control framing. It
   checks DB/schema version, store generation, DB/parent/key filesystem identity,
   key pair, fingerprint, runtime, and the shared claim interlock without
   creating or repairing anything.
4. Implement the exact Task 1 capability grammar and shared closed claim
   predicate. Do not invent a second registry or ad-hoc grep.
5. Split the Task 1 RED guards by the smallest operation under test: init/status
   cases require only the state ABI, issuance cases require the issue surface,
   and acknowledgement cases require `storage_ack_receipt`. This keeps later
   tasks genuinely RED without forcing placeholder issue/ack implementations or
   premature capability advertisement. Run the Task 2 state/runtime subset
   GREEN, keep Task 3/4 cases RED for their missing operation, run `/bin/bash -n`
   on new/changed shell, and run existing bounded/storage suites to prove
   initialization remains opt-in. Advertise the complete receipt capability
   only after Tasks 3 and 4 are implemented and green.

## Task 3: Add stateless receipt issuance to bounded SQLite reads

**Files:**

- Add issuance cases to `tests/test_sqlite_receipt_ack.bats`.
- Modify `scripts/lib/receipt.sh` and
  `scripts/drivers/storage/sqlite.sh`.

**Steps:**

1. Add RED tests for list receipt record order, no receipt for an empty
   selection, show receipt only for the first unread row, complete-token
   framing, token/record byte caps, no output on signing/key/claim failure, and
   zero store/read/nonce mutation during issuance.
2. Have one SQLite snapshot produce both the existing public records and
   private canonical hex material. Preserve the established total order
   `(timestamp, source kind, source ordinal)` and reject duplicates or malformed
   values before any output.
3. Use the single Task 1 canonicalization helper and fixed vectors to build the
   exact batch material, frame material, and signed payload. Keep raw IDs and
   bodies out of the signed payload, arguments, logs, and durable nonce row.
4. Validate the canonical payload before signing and enforce the frozen
   separator/base64url/token/record limits. Do not add or reorder wire fields.
5. Append the receipt as the last completed JSON record, then pass the entire
   candidate stream through the existing all-record preflight and one final
   emitter. Never use SQLite `RETURNING`; a partial write can expose bodies but
   cannot expose a complete earlier receipt.
6. Run the focused issuance tests RED then GREEN and re-run phase-1 record-size,
   opaque-ID, ordering, partial-emitter, and no-mutation tests.

## Task 4: Implement one-commit receipt acknowledgement

**Files:**

- Complete `tests/test_sqlite_receipt_ack.bats`.
- Modify `scripts/lib/receipt.sh` and
  `scripts/drivers/storage/sqlite.sh`.

**Steps:**

1. Add RED tests for malformed/forged receipts; wrong key/generation/store/team/
   recipient and sender-as-recipient; expired, future-issued and lifetime-over-
   900 tokens; replay; backdated/earlier late row; prefix gap; changed body or
   displayed metadata; unrelated later row; direct legacy row and event-linked
   legacy mirror; decimal-ID collision; cursor gap/frontier; known/unknown claim
   markers; busy timeout; and bounded diagnostics with stdout 0.
2. Add WAL and DELETE mode concurrency tests. Two simultaneous acks of the same
   token must produce one commit and one exact `already_committed`; nonce,
   read-event, legacy mirror, and cursor counts must show one transition.
   Add expiry+86,400-second retention boundaries, prune-before/after, clock
   rollback, and long-run bounded-row-count cases; pruned retries return exactly
   `stale_or_replayed`.
3. Verify signature, canonical syntax, key/store identity, and team/recipient
   scope before opening a write transaction. Treat this as token authentication,
   distinct from time validity. Build expected prefix material in private temp
   files; do not place opaque IDs or bodies in argv or diagnostics. For every
   subsequent refusal, including coarse-time expiry before SQLite, read the
   durable nonce metadata without mutation: an exact retained match returns
   `already_committed`; a missing/mismatched row continues to the applicable
   expired/stale/invalid failure.
4. Load the private expected material as a TEMP table in the same sqlite3
   invocation. Execute `.bail on`, silent pragmas,
   `BEGIN IMMEDIATE`, transaction-time `issued_at <= now < expires_at`, claim
   interlock and unused-nonce checks. After the transaction begins, compare the
   TEMP rows with the exact current consecutive prefix: `hex(actual id)`,
   `hex(actual body)`, every displayed metadata field, private source kind/
   ordinal, order, and count. Recompute the canonical-equivalent equality from
   these exact bytes; an OpenSSL digest calculated before `BEGIN IMMEDIATE` is
   never the transaction-time assertion. A row
   arriving after the selected prefix may remain; any row entering before or
   within it invalidates the receipt.
5. Within that same transaction prune only Task 1-eligible expired nonce rows,
   then insert the durable nonce record (including
   receipt/payload digest and committed scope for reconciliation), insert exact
   `message_read` events, update only the corresponding legacy rows by private
   source identity, and advance the cursor no farther than the receipt issuance
   frontier and no farther than the first unread gap. Finish with COMMIT and no
   SELECT/RETURNING/public transaction output.
6. Buffer all sqlite stdout/stderr internally and publish no success output.
   After authenticated token parsing, every non-success exit path—pre-SQLite
   time refusal, transaction failure, or post-commit response ambiguity—performs
   the same read-only exact nonce-metadata reconciliation. A retained exact row
   yields bounded `already_committed`; missing/mismatched or pruned state reports
   the original bounded failure, with an authenticated pruned retry reported as
   `stale_or_replayed`. Never convert a rollback or ambiguous mismatch into
   success.
7. Force each middle statement and commit boundary to fail, and place a barrier
   between outer verification and `BEGIN IMMEDIATE` that changes body, sender,
   timestamp, or source identity. Assert complete
   rollback of nonce, events, legacy `read_at`, and cursor. Add a process-death
   harness immediately after commit and prove retry reconciliation.
8. Run the focused ack suite RED then GREEN under both journal modes and run
   existing cursor, legacy mirror, inbox late-row, and storage contract tests.

## Task 5: Prove historical-failure and mutation coverage

**Files:**

- Add `tests/test_sqlite_receipt_mutations.bats` or a deterministic helper under
  `tests/helpers/` that operates only on a temporary repository copy.
- Modify `.github/scripts/check-enforced-assertions.sh` if the new security
  assertions need protected pattern enforcement.

**Steps:**

1. In a private temporary copy, apply one mutation at a time and run the narrow
   named regression. The original worktree must stay clean. Required mutants:
   move nonce or a read transition outside the transaction; remove `.bail on`
   or commit-result handling; remove prefix reconstruction; remove in-transaction
   expiry; remove team/recipient/frame/store binding; remove TEMP-table exact
   body/metadata/source comparison; remove `BEGIN IMMEDIATE`
   or nonce uniqueness; weaken direct-legacy/event-linked identity; remove each
   DB/receipt/key/init-lock filesystem-integrity or dead-owner check; remove
   nonce retention/prune bounds, claim interlock, or JSONL flag rejection; and
   place the receipt before message records.
2. Each mutant must make at least one focused test fail for the intended reason;
   a mutant that survives is a Major gap, not evidence to waive. Save only
   command/result summaries, never raw messages, key bytes, or receipt tokens.
3. Add non-mutation regressions for `RETURNING` absence, complete stdout
   buffering, WAL/DELETE behavior, commit failure, later-row acceptance,
   backdated-row rejection, replay, expiry TOCTOU, clock rollback, and Git Bash
   unsupported framing.
4. Run the mutation gate and focused suites from a clean source head. Confirm
   the implementation checkout has no temporary mutation residue.

## Task 6: Document one unambiguous Claude/Codex operating contract

**Files:**

- Complete `docs/adr/0005-sqlite-receipt-ack.md`.
- Modify `docs/spec/driver-interface.md` and
  `docs/spec/driver-interface.ja.md` with normative parity.
- Update `README.md` only for the optional fork capability and maintenance
  lifecycle, and make the same boundary explicit in `README.ja.md`; do not
  advertise downstream activation.

**Steps:**

1. Publish the already-frozen Task 1 optional ABI, final-record framing, digest
   definitions/vectors, 15-minute validity, key/status lifecycle, one-commit
   transition, replay reconciliation, errors, limits, and exact unsupported/
   fail-closed conditions. Documentation must not create a new wire decision.
2. State the single source of truth: existing legacy auto-inbox remains the only
   behavior of current callers; receipt ack is a separate opt-in storage facade
   and must not be combined with legacy auto-mark or a claim/lease path. The
   receipt nonce is replay state, not a second delivery state.
3. State update/rollback rules: no implicit migration; explicit init before use;
   pin only a separately verified merge commit; rollback means stop calling the
   optional ABI and retain nonce/key/schema evidence, not delete it. A future
   upstream rebase must rerun the claim predicate and full compatibility gates.
4. State removal criteria: an accepted upstream equivalent must preserve the
   bounded read and one-commit receipt contracts, pass the same tests, and have
   an owner-approved migration/precedence plan before the fork delta is removed.
5. State limitations without overclaiming: no JSONL parity, no arbitrary clone
   detection, no physical-path binding, no permanent-expiry proof across
   arbitrary clock rollback, no
   exactly-once guarantee for existing inbox/watch flows, and no live `.agents`
   activation in this Issue.
6. Correct `driver-interface.md` / `.ja.md` legacy compatibility text: receipt
   ack mirrors only the exact direct-legacy or event-linked row identified by
   Task 1, while all other new event-log reads preserve the existing behavior.
7. Explain to both Claude and Codex that fork PR merge alone changes no running
   thread. Any later dependency pin/install/activation is a separate Issue and
   owner decision and requires targeted advance notice to lanes using agmsg.

## Task 7: Local gates, independent review, PR, CI, merge and reflection

**Files:** no source changes unless a gate or verified review finding requires
them.

**Steps:**

1. Run focused key/ack/mutation tests, both journal modes, SQLite and JSONL
   bounded/storage contracts, legacy mirror, inbox, CI sharding, all official
   Bats tests, shell syntax, assertion enforcement, and `git diff --check`.
   Confirm the exact commands and results are fresh and retain only bounded
   evidence.
2. Review the full diff against Issue #211 and this plan. Confirm excluded ID
   transport, JSONL receipt/recovery, existing caller rewiring, downstream pin/
   activation, claim implementation, upstream proposal, and main rewrite are
   absent.
3. Commit and push without force. Verify local HEAD, fork remote branch SHA,
   and PR `headRefOid` separately. Open one fork PR with Issue/ADR traceability,
   scope/out-of-scope, security/compatibility risks, test evidence, update/
   rollback, and reviewer focus.
4. Create a separate clean detached worktree at the exact PR head and dispatch
   an independent Codex reviewer. Record reviewer model/classification,
   worktree, exact SHA, commands, P0-P3 findings, and mutation evidence. Fix all
   Blocker/Major findings in the implementation worktree, push a new head, and
   repeat exact-head review until Blocker/Major=0.
5. Monitor head-specific official CI and review threads until all runs are
   completed/success, merge state is clean, and unresolved comments are zero.
   Keep CI, review, mergeability, remote HEAD, and PR head evidence separate.
6. Merge only under the repository merge criteria and without force/reset or
   direct fork-main writes. Verify merge commit, fork-main containment, and
   post-merge files/tests separately.
7. Update Issue #211, parent #116 and Board with fork commit/PR/CI/review/merge,
   upstream proposal state, remaining fork risk, and removable delta. Release
   the canonical claim. Do not pin or activate the fork in `.agents`.
