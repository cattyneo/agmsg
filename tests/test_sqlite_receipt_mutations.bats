#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Task 5 mutation gate.  Each mutant is applied to a fresh `git archive HEAD`
# copy and exercised by one named narrow regression.  The source worktree and
# its live coordination state are never opened for mutation.

load test_helper
load helpers/sqlite_receipt_mutation.sh

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

mutation_source() {
  cd "$BATS_TEST_DIRNAME/.." && pwd
}

run_mutant_regression() {
  local id="$1" filter="$2" source scratch rc test_file
  source="$(mutation_source)"
  scratch="$BATS_TEST_TMPDIR/mutant-$id"
  mkdir "$scratch"
  receipt_mutation_archive "$source" "$scratch" || return 1
  receipt_apply_mutation "$id" "$scratch" || return 1
  case "$id" in
    no-db-integrity|no-receipt-dir-integrity|no-key-integrity|no-init-lock-integrity|no-dead-owner-check|jsonl-accepts-receipt)
      test_file="$scratch/tests/test_sqlite_receipt_keys.bats" ;;
    *) test_file="$scratch/tests/test_sqlite_receipt_ack.bats" ;;
  esac
  rtk bats --filter "$filter" "$test_file" \
    >"$BATS_TEST_TMPDIR/$id.output" 2>"$BATS_TEST_TMPDIR/$id.error"
  rc=$?
  # Only the exit code is retained.  Nested Bats output may contain message
  # bodies or signed receipt material and is intentionally never re-emitted.
  [ "$rc" -ne 0 ]
}

@test "Task 5 historical mutants are killed by narrow named regressions" {
  local killed=0 id filter
  local -a specs
  specs=(
    'nonce-outside-transaction|Task 4 all write-stage faults'
    'no-bail|Task 4 all write-stage faults'
    'ignore-commit-result|Task 4 an injected COMMIT-boundary failure'
    'no-prefix-reconstruction|Task 4 refuses late earlier rows'
    'no-in-transaction-expiry|Task 4 transaction-time expiry'
    'no-recipient-binding|Task 4 rejects malformed forged wrong-scope'
    'no-store-binding|Task 4 authenticates canonical lifetime key generation'
    'no-frame-binding|Task 4 independently binds every displayed field'
    'no-temp-body-comparison|Task 4 statement failure and outer-verification drift'
    'no-begin-immediate|Task 4 all write-stage faults'
    'no-nonce-uniqueness|Task 4 same-token concurrency commits once'
    'weak-legacy-identity|Task 4 transaction guards the full event-linked legacy identity'
    'no-db-integrity|status rejects a SQLite DB symlink'
    'no-receipt-dir-integrity|status rejects a receipt directory symlink'
    'no-key-integrity|status rejects a private key symlink'
    'no-init-lock-integrity|malformed init lock is corrupt state'
    'no-dead-owner-check|live init lock is refused'
    'unbounded-prune|Task 4 retained expiry retries reconcile'
    'no-claim-interlock|Task 4 claim markers and a busy writer'
    'jsonl-accepts-receipt|JSONL has no receipt ABI and rejects issue requests'
    'receipt-before-records|receipt list appends one final compact record'
  )
  for spec in "${specs[@]}"; do
    id="${spec%%|*}"; filter="${spec#*|}"
    if run_mutant_regression "$id" "$filter"; then
      killed=$((killed + 1))
      printf '%s: killed\n' "$id"
    else
      printf '%s: SURVIVED or mutation setup failed\n' "$id" >&2
      return 1
    fi
  done
  [ "$killed" -eq "${#specs[@]}" ]
}

@test "Task 5 non-mutation regressions remain explicit and source-clean" {
  local source
  source="$(mutation_source)"
  refute grep -R -n -E '\bRETURNING\b' "$source/scripts/drivers/storage" "$source/scripts/lib/receipt.sh"
  rtk bats --filter 'Task 4 same-token concurrency commits once|Task 4 an injected COMMIT-boundary failure|Task 4 refuses late earlier rows|Task 4 retained expiry retries reconcile|Task 4 expiry|Git Bash rejects receipt initialization' \
    "$source/tests/test_sqlite_receipt_ack.bats" "$source/tests/test_sqlite_receipt_keys.bats" \
    >"$BATS_TEST_TMPDIR/nonmutation.output" 2>"$BATS_TEST_TMPDIR/nonmutation.error"
}

@test "Task 5 external claim-file atomicity mutant remains blocked" {
  skip "BLOCKED/UNRESOLVED: claims.sh is an external mutable file and cannot be committed atomically with SQLite without an owner-approved shared authority"
}
