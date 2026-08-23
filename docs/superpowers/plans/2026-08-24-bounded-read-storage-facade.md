# Bounded read-only storage facade

> **Implementation note:** Execute this plan task-by-task in the dedicated
> worktree. Keep the upstream ID, receipt, JSONL recovery, and claim-precedence
> contracts out of this change until their separate decisions are recorded.

**Goal:** Add the first fork-first order 2b unit: read-only bounded unread
summary/list/show operations with SQLite/JSONL parity.

**Observable success criteria:**

- `storage_unread_summary`, `storage_list_unread_bounded`, and
  `storage_get_message_bounded` are available through the storage facade for
  both bundled drivers.
- Empty/nonexistent stores are reported as empty without creating files,
  schemas, read events, cursors, locks, claims, receipts, or keys.
- Bounded list output is a consecutive delivery-order prefix, never truncates a
  body, emits a final count/byte summary, and fails closed on malformed input or
  a first-row body that exceeds the requested bound.
- Exact show is recipient-scoped, unread-only, body-bounded, and does not alter
  the unread frontier.
- Focused tests prove opaque IDs, legacy SQLite IDs, byte/item boundaries,
  multibyte/control-like bodies, later-row inspection, failure framing, and
  SQLite/JSONL parity.
- Driver-interface documentation records the lower-level contract and the
  unresolved upper-layer contracts remain explicitly out of scope.

**Key constraints:**

- Base is upstream `fujibee/agmsg` `3d06318de3aff9929cfaf87c092fef6709d2cc8b`.
- Do not synchronize, reset, force-push, or rewrite fork `main`.
- Preserve the existing `storage_*` ABI, stdout framing, legacy behavior, and
  opaque stored IDs. Do not define an ID transport grammar or new ID maximum.
- The operation must not call existing initialization/migration helpers on a
  read path. Capture and validate the complete candidate snapshot before any
  stdout is emitted.
- Use Bash 3.2-compatible code and `rtk bats ...` for test execution.

**Relevant skills/tools:** `implementation-workflow`,
`superpowers:writing-plans`, `superpowers:test-driven-development`,
`superpowers:using-git-worktrees`, `superpowers:requesting-code-review`,
`superpowers:finishing-a-development-branch`, and
`superpowers:verification-before-completion`; Bats, jq, sqlite3, and the
existing storage driver facade.

## Task 1: Add a shared focused RED suite

**Files:**

- Add `tests/test_bounded_storage.bats`.
- Keep all setup through `tests/test_helper` and the storage facade; do not read
  driver paths from production callers.

**Steps:**

1. Add driver-agnostic tests for empty/nonexistent stores, summary shape and
   newest ID, list limits `0/1/10`, cumulative body-byte boundaries `0/1/4096`
   and a `4097`-byte first row, multibyte/empty/control-like bodies, a later
   unread row inspected by exact show, and no-store mutation.
2. Add tests for invalid bounds, malformed/corrupt driver data, pure JSONL
   framing, and zero stdout on validation/driver failures.
3. Add SQLite-only coverage for a legacy decimal ID and JSONL-only coverage for
   malformed metadata/nested-event projection where the backing formats differ.
4. Run `rtk bats tests/test_bounded_storage.bats` and the same command with
   `AGMSG_STORAGE_DRIVER=jsonl`; confirm the new tests fail because the three
   functions do not yet exist (RED), while the existing storage contract remains
   green.

## Task 2: Implement the SQLite read-only facade

**Files:**

- Modify `scripts/drivers/storage/sqlite.sh`.
- Modify `docs/spec/driver-interface.md` and
  `docs/spec/driver-interface.ja.md` for the new operations.

**Steps:**

1. Add a private unread-source query that reuses the existing event/legacy
   ordering, cursor frontier, recipient-scoped read exceptions, and legacy
   deduplication without calling `storage_init`.
2. Implement `storage_unread_summary` with one snapshot query that returns only
   count and newest ID (never a body field), and treats a missing store as the
   empty result without creating it.
3. Implement `storage_list_unread_bounded` with defaults of 10 items and 4096
   body bytes, hard validation of `0..10` and `0..4096` arguments, one snapshot,
   full-candidate validation, UTF-8 byte accounting via jq, whole-body output,
   and a final `bounded_unread_result` record. A first-row overflow emits only a
   bounded error record with no body and exits non-zero.
4. Implement `storage_get_message_bounded` as an exact unread row lookup scoped
   to `(team, agent)`, validating one unambiguous candidate before output and
   emitting bounded metadata/non-zero on body overflow without acknowledging it.
5. Run the focused SQLite suite (GREEN), then the existing SQLite storage
   contract suite.

## Task 3: Implement the JSONL read-only facade

**Files:**

- Modify `scripts/drivers/storage/jsonl.sh`.

**Steps:**

1. Add read-only helpers that inspect the existing log and cursor file without
   `_jsonl_init_file`, migration, lock creation, or other durable writes.
2. Project flat and imported `sync_pull_commit` logical events in one jq
   snapshot, preserving delivery order and the existing logical cursor/read
   exception semantics.
3. Implement the same three operations, record shapes, bounds, validation,
   overflow behavior, and empty-store behavior as SQLite.
4. Run the focused JSONL suite and existing JSONL storage contract suite; compare
   parsed outputs for equivalent fixtures against SQLite.

## Task 4: Document and gate the bounded contract

**Files:**

- The two driver-interface spec files from Task 2.
- This plan file.
- Add/update focused test comments only where they explain observable contract.

**Steps:**

1. Document operation signatures, defaults, result/error record fields, exit
   framing, no-mutation guarantee, and snapshot/validation behavior.
2. Explicitly list public CLI framing, ID transport/maximum, receipt/ack,
   JSONL crash recovery, and `#373` precedence as later decisions.
3. Run `bash -n` on changed shell scripts, focused suites for both drivers,
   existing storage suites for both drivers, and the repository’s full
   `rtk bats tests/` gate. Record sandbox-caused failures separately from code
   failures; do not claim a green full gate when it cannot run.

## Task 5: Prepare reviewable delivery

**Files:** no further source changes unless a gate exposes a defect.

**Steps:**

1. Review the complete diff against the Issue and this plan; confirm no
   unresolved ID/receipt/JSONL recovery contract leaked into code.
2. Commit the bounded implementation on `codex/agents-203-bounded-read`, push
   the branch to the fork without force, and record the exact head SHA.
3. Use a separate clean detached worktree at that exact SHA for the independent
   Codex review. Address Blocker/Major findings, rerun affected tests, and
   preserve review provenance.
4. Open the fork PR only after local gates and independent review. Keep fork
   PR CI/review/merge evidence separate from any optional upstream proposal.
