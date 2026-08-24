#!/usr/bin/env bats

# Contract RED tests for Issue #211. This file deliberately uses only public
# storage functions and isolated test stores; it must not add a test-only seam
# to the receipt implementation.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_STORAGE_DRIVER=sqlite
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init receipts >/dev/null
}

teardown() { teardown_test_env; }

store_dir() { dirname "$(agmsg_db_path receipts)"; }

store_fingerprint() {
  find "$(store_dir)" -type f ! -name 'messages.db-shm' -exec shasum {} \; \
    2>/dev/null | LC_ALL=C sort
}

fixture_field() {
  local section="$1" field="$2"
  awk -v section="[$section]" -v field="$field" '
    $0 == section { in_section=1; next }
    in_section && /^\[/ { exit }
    in_section && index($0, field "=") == 1 {
      print substr($0, length(field) + 2); exit
    }
  ' "$BATS_TEST_DIRNAME/fixtures/receipt-v1-vectors.txt"
}

receipt_abi_required() {
  local fn
  for fn in storage_receipt_init storage_receipt_status storage_ack_receipt; do
    declare -F "$fn" >/dev/null || {
      printf 'missing optional receipt function: %s\n' "$fn" >&2
      return 1
    }
  done
}

assert_receipt_abi() {
  receipt_abi_required
}

assert_status() {
  local expected_status="$1" expected_output="$2"
  [ "$status" -eq "$expected_status" ]
  [ "$output" = "$expected_output" ]
}

@test "receipt vectors are complete, byte-stable, and distinguish each bound field" {
  local vector material expected actual
  for vector in batch-base batch-id-boundary batch-id-changed batch-body-changed \
    frame-base frame-sender-changed frame-timestamp-changed \
    frame-source-legacy frame-source-ord-changed payload-base; do
    material="$(fixture_field "$vector" material_hex)"
    expected="$(fixture_field "$vector" sha256)"
    [[ "$material" =~ ^[0-9a-f]+$ ]]
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]]
    actual="$(printf '%s' "$material" | xxd -r -p | shasum -a 256 | awk '{print $1}')"
    [ "$actual" = "$expected" ]
  done

  [ "$(fixture_field batch-base sha256)" != "$(fixture_field batch-id-boundary sha256)" ]
  [ "$(fixture_field batch-base sha256)" != "$(fixture_field batch-id-changed sha256)" ]
  [ "$(fixture_field batch-base sha256)" != "$(fixture_field batch-body-changed sha256)" ]
  [ "$(fixture_field frame-base sha256)" != "$(fixture_field frame-sender-changed sha256)" ]
  [ "$(fixture_field frame-base sha256)" != "$(fixture_field frame-timestamp-changed sha256)" ]
  [ "$(fixture_field frame-base sha256)" != "$(fixture_field frame-source-legacy sha256)" ]
  [ "$(fixture_field frame-base sha256)" != "$(fixture_field frame-source-ord-changed sha256)" ]
}

@test "SQLite exposes the complete optional receipt ABI and exact capability token" {
  assert_receipt_abi

  run storage_describe
  [ "$status" -eq 0 ]
  local capability_line
  capability_line="$(printf '%s\n' "$output" | awk -F= '$1 == "capabilities" { print; count++ } END { exit count == 1 ? 0 : 1 }')"
  [[ ",${capability_line#capabilities=}," == *",sqlite-receipt-ack-v1,"* ]]
  [ "$(printf '%s' "${capability_line#capabilities=}" | tr ',' '\n' | sort | uniq -d | wc -l | tr -d ' ')" = 0 ]
}

@test "receipt status is non-mutating and reports uninitialized state through the existing vocabulary" {
  assert_receipt_abi
  local before after
  before="$(store_fingerprint)"
  run --separate-stderr storage_receipt_status receipts
  assert_status 13 runtime_error
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "receipt init makes status ready, preserves identity on re-init, and emits no key material" {
  assert_receipt_abi
  run --separate-stderr storage_receipt_init receipts
  assert_status 0 ok
  [[ "$output" != *"BEGIN"* ]]
  [[ "$output" != *"PRIVATE"* ]]

  run --separate-stderr storage_receipt_status receipts
  assert_status 0 ok

  run --separate-stderr storage_receipt_init receipts
  assert_status 0 ok
  run --separate-stderr storage_receipt_status receipts
  assert_status 0 ok
}

@test "concurrent receipt init is serialized and leaves a ready identity" {
  assert_receipt_abi
  local first="$BATS_TEST_TMPDIR/first" second="$BATS_TEST_TMPDIR/second"
  storage_receipt_init receipts >"$first" 2>&1 &
  local first_pid=$!
  storage_receipt_init receipts >"$second" 2>&1 &
  local second_pid=$!
  wait "$first_pid"
  [ "$?" -eq 0 ]
  wait "$second_pid"
  [ "$?" -eq 0 ]
  [ "$(cat "$first")" = ok ]
  [ "$(cat "$second")" = ok ]
  run --separate-stderr storage_receipt_status receipts
  assert_status 0 ok
}

@test "receipt status fails closed when the exact claim functions are loaded" {
  assert_receipt_abi
  storage_receipt_init receipts >/dev/null
  agmsg_claim_next() { :; }
  agmsg_ack_claim() { :; }
  agmsg_release_claim() { :; }

  run --separate-stderr storage_receipt_status receipts
  assert_status 13 runtime_error
}

@test "SQLite receipt issuance is opt-in, final, bounded, and read-only" {
  assert_receipt_abi
  storage_receipt_init receipts >/dev/null
  storage_send receipts alice bob first >/dev/null
  local before after receipt
  before="$(store_fingerprint)"
  run storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r .type)" = bounded_unread_receipt ]
  receipt="$(printf '%s\n' "$output" | tail -1 | jq -r .receipt)"
  [[ "$receipt" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]
  [ "${#receipt}" -le 2048 ]
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r .receipt_version)" = 1 ]
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r .selected_count)" = 1 ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "empty list has no receipt and later-row show with a receipt fails without stdout" {
  assert_receipt_abi
  storage_receipt_init receipts >/dev/null
  run storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -s '[.[] | select(.type == "bounded_unread_receipt")] | length')" = 0 ]

  storage_send receipts alice bob first >/dev/null
  local later; later="$(storage_send receipts alice bob later)"
  run storage_get_message_bounded receipts bob "$later" --max-body-bytes 4096 --issue-receipt
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "ack validates through the optional operation and never writes stdout on failure" {
  assert_receipt_abi
  storage_receipt_init receipts >/dev/null
  local before after
  before="$(store_fingerprint)"
  run storage_ack_receipt receipts bob --receipt not-a-receipt
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "JSONL has no receipt ABI and rejects issue requests with zero stdout and mutation" {
  export AGMSG_STORAGE_DRIVER=jsonl
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init receipts >/dev/null
  storage_send receipts alice bob jsonl >/dev/null
  local log before after id stdout="$BATS_TEST_TMPDIR/jsonl-list.stdout"
  log="$(dirname "$(agmsg_db_path receipts)")/events.jsonl"
  before="$(shasum "$log")"
  if storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt >"$stdout" 2>/dev/null; then
    false
  fi
  [ ! -s "$stdout" ]
  after="$(shasum "$log")"
  [ "$after" = "$before" ]

  id="$(storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 | jq -r 'select(.type == "message_sent") | .id')"
  if storage_get_message_bounded receipts bob "$id" --max-body-bytes 4096 --issue-receipt >"$stdout" 2>/dev/null; then
    false
  fi
  [ ! -s "$stdout" ]
}
