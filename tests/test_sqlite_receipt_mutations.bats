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
  local id="$1" filter="$2" source scratch rc test_file nested
  source="$(mutation_source)"
  scratch="$BATS_TEST_TMPDIR/mutant-$id"
  mkdir "$scratch"
  receipt_mutation_archive "$source" "$scratch" || return 2
  receipt_apply_mutation "$id" "$scratch" || return 2
  case "$id" in
    prune-boundary-inclusive)
      receipt_prune_boundary_probe "$scratch" "$BATS_TEST_TMPDIR/prune-boundary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 1 ] && return 0
      [ "$rc" -eq 0 ] && return 1
      return 2
      ;;
  esac
  case "$id" in
    no-db-integrity|no-receipt-dir-integrity|no-key-integrity|no-init-lock-integrity|no-dead-owner-check|jsonl-accepts-receipt)
      test_file="$scratch/tests/test_sqlite_receipt_keys.bats" ;;
    *) test_file="$scratch/tests/test_sqlite_receipt_ack.bats" ;;
  esac
  nested="$BATS_TEST_TMPDIR/nested-$id.tap"
  receipt_run_bounded 45 rtk bats --filter "$filter" "$test_file" >"$nested" 2>/dev/null
  rc=$?
  # Only an ordinary Bats assertion failure kills the mutant.  A signal,
  # timeout, command/setup error, or a surviving mutant must not become false
  # positive evidence.  Nested output may contain message bodies or signed
  # receipt material and is intentionally never re-emitted.
  if [ "$rc" -eq 1 ]; then
    grep -q '^not ok ' "$nested" && return 0
    return 2
  fi
  if [ "$rc" -eq 0 ]; then
    grep -q '^ok ' "$nested" || return 2
    grep -q '^ok .* # skip ' "$nested" && return 2
    return 1
  fi
  return 2
}

run_mutant_subset() {
  local subset="$1" spec id filter rc killed=0 survived=0 invalid=0 total
  shift
  total="$#"
  for spec in "$@"; do
    id="${spec%%|*}"; filter="${spec#*|}"
    if run_mutant_regression "$id" "$filter"; then
      rc=0
    else
      rc=$?
    fi
    case "$rc" in
      0) killed=$((killed + 1)); printf '%s: killed\n' "$id" ;;
      1) survived=$((survived + 1)); printf '%s: SURVIVED\n' "$id" >&2 ;;
      *) invalid=$((invalid + 1)); printf '%s: INVALID mutation run\n' "$id" >&2 ;;
    esac
  done
  printf 'subset=%s killed=%s/%s survived=%s invalid=%s\n' \
    "$subset" "$killed" "$total" "$survived" "$invalid"
  [ "$killed" -eq "$total" ]
}

@test "Task 5 transaction mutants are killed by narrow named regressions" {
  run_mutant_subset transaction \
    'nonce-outside-transaction|Task 4 all write-stage faults' \
    'no-bail|Task 4 all write-stage faults' \
    'ignore-commit-result|Task 4 an injected COMMIT-boundary failure' \
    'no-prefix-reconstruction|Task 4 refuses late earlier rows' \
    'no-in-transaction-expiry|Task 4 transaction-time expiry' \
    'no-recipient-binding|Task 4 rejects malformed forged wrong-scope' \
    'no-store-binding|Task 4 authenticates canonical lifetime key generation' \
    'no-frame-binding|Task 4 independently binds every displayed field' \
    'no-temp-body-comparison|Task 4 statement failure and outer-verification drift' \
    'no-begin-immediate|Task 4 ack begins one IMMEDIATE transaction' \
    'no-nonce-uniqueness|Task 4 same-token concurrency commits once' \
    'weak-legacy-identity|Task 4 transaction guards the full event-linked legacy identity' \
    'unbounded-prune|Task 4 retained expiry retries reconcile' \
    'no-claim-interlock|Task 4 claim markers and a busy writer' \
    'no-precommit-claim-interlock|Task 4 rechecks the repo claim marker after BEGIN immediately before COMMIT'
}

@test "Task 5 filesystem and lock mutants are killed by narrow named regressions" {
  run_mutant_subset filesystem \
    'no-db-integrity|status rejects a SQLite DB symlink' \
    'no-receipt-dir-integrity|status rejects a receipt directory symlink' \
    'no-key-integrity|status rejects a private key symlink' \
    'no-init-lock-integrity|init rejects an unsafe lock mode' \
    'no-dead-owner-check|live init lock is refused'
}

@test "Task 5 output and retention mutants are killed by narrow named regressions" {
  run_mutant_subset output \
    'jsonl-accepts-receipt|JSONL has no receipt ABI and rejects issue requests' \
    'receipt-before-records|receipt list appends one final compact record' \
    'prune-boundary-inclusive|prune boundary exact now-86400'
}

@test "Task 5 non-mutation regressions remain explicit and source-clean" {
  local source
  source="$(mutation_source)"
  refute grep -R -n -E '\bRETURNING\b' "$source/scripts/drivers/storage" "$source/scripts/lib/receipt.sh"
  rtk bats --filter 'Task 4 same-token concurrency commits once|Task 4 an injected COMMIT-boundary failure|Task 4 refuses late earlier rows|Task 4 retained expiry retries reconcile|Task 4 expiry|Git Bash rejects receipt initialization' \
    "$source/tests/test_sqlite_receipt_ack.bats" "$source/tests/test_sqlite_receipt_keys.bats" \
    >/dev/null 2>/dev/null
}

@test "Task 5 external claim-file atomicity mutant remains blocked" {
  skip "BLOCKED/UNRESOLVED: claims.sh is an external mutable file and cannot be committed atomically with SQLite without an owner-approved shared authority"
}
