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
  [ "$(printf '%s\n' "$output" | tail -1)" = "$expected_output" ]
}

# The v1 state paths are deliberately fixed rather than discovered by a glob:
# a status check cannot prove symlink/hard-link rejection if the test follows a
# replacement chosen by the implementation. They stay inside the isolated
# AGMSG_STORAGE_PATH created by setup_test_env.
receipt_dir() { printf '%s/receipt-v1' "$(dirname "$(agmsg_db_path "${1:-receipts}")")"; }
receipt_private_key() { printf '%s/private.pem' "$(receipt_dir "${1:-receipts}")"; }
receipt_public_key() { printf '%s/public.pem' "$(receipt_dir "${1:-receipts}")"; }
receipt_lock() { printf '%s/init.lock' "$(receipt_dir "${1:-receipts}")"; }
receipt_stage() {
  local nonce="$1" team="${2:-receipts}"
  printf '%s/.init-stage.%s' "$(receipt_dir "$team")" "$nonce"
}

file_links() {
  case "$(uname -s)" in
    Darwin*) stat -f '%l' "$1" ;;
    *) stat -c '%h' "$1" ;;
  esac
}

status_value() {
  local key="$1"
  printf '%s\n' "$output" | awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2) }'
}

assert_ready_identity() {
  run --separate-stderr storage_receipt_status receipts
  assert_status 0 ok
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = receipt_schema=1 ]
  [[ "$(printf '%s\n' "$output" | sed -n '2p')" =~ ^store_generation=[0-9a-f]{32}$ ]]
  [[ "$(printf '%s\n' "$output" | sed -n '3p')" =~ ^key_sha256=[0-9a-f]{64}$ ]]
  [ "$(printf '%s\n' "$output" | sed -n '4p')" = ok ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 4 ]
  [ "$("$(command -v openssl)" dgst -sha256 -r "$(receipt_public_key)" | awk '{print $1}')" = "$(status_value key_sha256)" ]
  RECEIPT_IDENTITY="$(status_value receipt_schema):$(status_value store_generation):$(status_value key_sha256)"
}

init_ready() {
  assert_receipt_abi
  run --separate-stderr storage_receipt_init receipts
  assert_status 0 ok
  assert_ready_identity
}

assert_corrupt_status() {
  run --separate-stderr storage_receipt_status receipts
  assert_status 12 corrupt_state
}

dead_pid() {
  ( exit 0 ) &
  local pid=$!
  wait "$pid"
  printf '%s' "$pid"
}

write_lock_record() {
  local path="$1" pid="$2" nonce="$3" created_at="${4:-1700000000}"
  ( umask 077; printf 'pid=%s\nowner_nonce=%s\ncreated_at=%s\n' "$pid" "$nonce" "$created_at" >"$path" )
  chmod 600 "$path"
}

make_ed25519_pair() {
  local private="$1" public="$2"
  local openssl="${AGMSG_RECEIPT_OPENSSL:-$(receipt_test_openssl)}"
  "$openssl" genpkey -algorithm ED25519 -out "$private" >/dev/null 2>&1
  chmod 600 "$private"
  "$openssl" pkey -in "$private" -pubout -out "$public" >/dev/null 2>&1
  chmod 600 "$public"
}

receipt_test_openssl() {
  local candidate version
  for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl /usr/bin/openssl; do
    [ -x "$candidate" ] || continue
    version="$("$candidate" version 2>/dev/null || true)"
    case "$version" in OpenSSL\ 3.*) printf '%s' "$candidate"; return 0 ;; esac
  done
  return 1
}

@test "receipt vectors are complete, byte-stable, and distinguish each bound field" {
  local vector material expected actual
  for vector in batch-base batch-id-boundary batch-id-changed batch-body-changed \
    frame-base frame-sender-changed frame-timestamp-changed \
    frame-source-legacy frame-source-ord-changed frame-payload-base payload-base; do
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

  local payload
  payload="$(fixture_field payload-base material_hex | xxd -r -p)"
  [ "$(printf '%s\n' "$payload" | sed -n '1,13p' | cut -d= -f1 | tr '\n' ',')" = \
    'v,driver,store_generation,key_sha256,team_hex,recipient_hex,selected_count,batch_sha256,frame_sha256,issuance_frontier,issued_at,expires_at,nonce,' ]
  [ "$(printf '%s\n' "$payload" | sed -n '8p')" = "batch_sha256=$(fixture_field batch-base sha256)" ]
  [ "$(printf '%s\n' "$payload" | sed -n '9p')" = "frame_sha256=$(fixture_field frame-payload-base sha256)" ]
  local issued expires
  issued="$(printf '%s\n' "$payload" | awk -F= '$1 == "issued_at" { print $2 }')"
  expires="$(printf '%s\n' "$payload" | awk -F= '$1 == "expires_at" { print $2 }')"
  [ $((expires - issued)) -eq 900 ]
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
  init_ready
  local before="$RECEIPT_IDENTITY"
  [[ "$output" != *"BEGIN"* ]]
  [[ "$output" != *"PRIVATE"* ]]

  run --separate-stderr storage_receipt_init receipts
  assert_status 0 ok
  assert_ready_identity
  [ "$RECEIPT_IDENTITY" = "$before" ]
}

@test "concurrent receipt init is serialized and leaves a ready identity" {
  init_ready
  local before="$RECEIPT_IDENTITY"
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
  assert_ready_identity
  [ "$RECEIPT_IDENTITY" = "$before" ]
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

@test "ordinary bounded reads never initialize receipt state" {
  storage_send receipts alice bob ordinary >/dev/null
  local id before after
  id="$(storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 | jq -r 'select(.type == "message_sent") | .id')"
  before="$(store_fingerprint)"
  run storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  run storage_get_message_bounded receipts bob "$id" --max-body-bytes 4096
  [ "$status" -eq 0 ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
  [ ! -e "$(receipt_dir)" ]
}

@test "receipt init creates exactly owner-only state paths and no runtime temporary residue" {
  export TMPDIR="$BATS_TEST_TMPDIR/receipt-runtime-tmp"
  mkdir -p "$TMPDIR"
  init_ready
  [ -d "$(receipt_dir)" ]
  [ ! -L "$(receipt_dir)" ]
  [ "$(file_mode "$(receipt_dir)")" = 700 ]
  [ -f "$(receipt_private_key)" ]
  [ -f "$(receipt_public_key)" ]
  [ "$(file_mode "$(receipt_private_key)")" = 600 ]
  [ "$(file_mode "$(receipt_public_key)")" = 600 ]
  [ "$(file_links "$(receipt_private_key)")" = 1 ]
  [ "$(file_links "$(receipt_public_key)")" = 1 ]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "missing full key pair is corrupt state and is never regenerated by status" {
  init_ready
  rm -f "$(receipt_private_key)" "$(receipt_public_key)"
  assert_corrupt_status
  [ ! -e "$(receipt_private_key)" ]
  [ ! -e "$(receipt_public_key)" ]
}

@test "half key state is corrupt and is never auto-repaired" {
  init_ready
  rm -f "$(receipt_private_key)"
  assert_corrupt_status
  [ ! -e "$(receipt_private_key)" ]
  [ -f "$(receipt_public_key)" ]
}

@test "replaced unparsable key is corrupt state" {
  init_ready
  printf 'not an Ed25519 key\n' >"$(receipt_public_key)"
  chmod 600 "$(receipt_public_key)"
  assert_corrupt_status
}

@test "private and public key pair mismatch is corrupt state" {
  init_ready
  local replacement="$BATS_TEST_TMPDIR/replacement-public.pem"
  local replacement_private="$BATS_TEST_TMPDIR/replacement-private.pem"
  make_ed25519_pair "$replacement_private" "$replacement"
  cp "$replacement" "$(receipt_public_key)"
  chmod 600 "$(receipt_public_key)"
  assert_corrupt_status
}

@test "matching replacement key pair still fails the stored fingerprint check" {
  init_ready
  local replacement="$BATS_TEST_TMPDIR/replacement-public.pem"
  local replacement_private="$BATS_TEST_TMPDIR/replacement-private.pem"
  make_ed25519_pair "$replacement_private" "$replacement"
  cp "$replacement_private" "$(receipt_private_key)"
  cp "$replacement" "$(receipt_public_key)"
  chmod 600 "$(receipt_private_key)" "$(receipt_public_key)"
  assert_corrupt_status
}

@test "receipt state copied from another initialized store fails generation validation" {
  init_ready
  local original="$AGMSG_STORAGE_PATH" foreign="$BATS_TEST_TMPDIR/foreign-store"
  export AGMSG_STORAGE_PATH="$foreign"
  storage_init receipts >/dev/null
  storage_receipt_init receipts >/dev/null
  local foreign_state; foreign_state="$(receipt_dir)"
  export AGMSG_STORAGE_PATH="$original"
  rm -rf "$(receipt_dir)"
  cp -R "$foreign_state" "$(receipt_dir)"
  assert_corrupt_status
}

@test "status rejects a SQLite DB symlink without following it" {
  init_ready
  local db; db="$(agmsg_db_path receipts)"
  mv "$db" "$db.real"
  ln -s "$db.real" "$db"
  assert_corrupt_status
}

@test "status rejects a symlinked parent storage directory" {
  init_ready
  local parent; parent="$(store_dir)"
  local real="$BATS_TEST_TMPDIR/store-real"
  mv "$parent" "$real"
  ln -s "$real" "$parent"
  assert_corrupt_status
}

@test "status rejects a receipt directory symlink without following it" {
  init_ready
  local dir; dir="$(receipt_dir)"
  mv "$dir" "$dir.real"
  ln -s "$dir.real" "$dir"
  assert_corrupt_status
}

@test "status rejects a private key symlink without following it" {
  init_ready
  local key; key="$(receipt_private_key)"
  mv "$key" "$key.real"
  ln -s "$key.real" "$key"
  assert_corrupt_status
}

@test "status rejects a public key symlink without following it" {
  init_ready
  local key; key="$(receipt_public_key)"
  mv "$key" "$key.real"
  ln -s "$key.real" "$key"
  assert_corrupt_status
}

@test "status rejects a hard-linked private key" {
  init_ready
  ln "$(receipt_private_key)" "$(receipt_private_key).extra"
  [ "$(file_links "$(receipt_private_key)")" -eq 2 ]
  assert_corrupt_status
}

@test "status rejects a hard-linked public key" {
  init_ready
  ln "$(receipt_public_key)" "$(receipt_public_key).extra"
  [ "$(file_links "$(receipt_public_key)")" -eq 2 ]
  assert_corrupt_status
}

@test "status rejects a hard-linked SQLite DB" {
  init_ready
  local db; db="$(agmsg_db_path receipts)"
  ln "$db" "$db.extra"
  [ "$(file_links "$db")" -eq 2 ]
  assert_corrupt_status
}

@test "status rejects writable SQLite DB mode" {
  init_ready
  chmod 660 "$(agmsg_db_path receipts)"
  assert_corrupt_status
}

@test "status rejects group-writable storage parent mode" {
  init_ready
  chmod 770 "$(store_dir)"
  assert_corrupt_status
}

@test "status rejects receipt directory mode other than 0700" {
  init_ready
  chmod 755 "$(receipt_dir)"
  assert_corrupt_status
}

@test "status rejects key mode other than 0600" {
  init_ready
  chmod 644 "$(receipt_private_key)"
  assert_corrupt_status
}

@test "status rejects public key mode other than 0600" {
  init_ready
  chmod 644 "$(receipt_public_key)"
  assert_corrupt_status
}

@test "status rejects a different owner when the test runner can change ownership" {
  init_ready
  if [ "$(id -u)" -ne 0 ]; then
    skip "owner mismatch requires a privileged isolated test runner"
  fi
  chown 1 "$(receipt_private_key)"
  assert_corrupt_status
}

@test "status rejects SQLite DB owner mismatch when testable" {
  init_ready
  if [ "$(id -u)" -ne 0 ]; then
    skip "owner mismatch requires a privileged isolated test runner"
  fi
  chown 1 "$(agmsg_db_path receipts)"
  assert_corrupt_status
}

@test "status rejects storage-parent owner mismatch when testable" {
  init_ready
  if [ "$(id -u)" -ne 0 ]; then
    skip "owner mismatch requires a privileged isolated test runner"
  fi
  chown 1 "$(store_dir)"
  assert_corrupt_status
}

@test "status rejects receipt-directory owner mismatch when testable" {
  init_ready
  if [ "$(id -u)" -ne 0 ]; then
    skip "owner mismatch requires a privileged isolated test runner"
  fi
  chown 1 "$(receipt_dir)"
  assert_corrupt_status
}

@test "status rejects public-key owner mismatch when testable" {
  init_ready
  if [ "$(id -u)" -ne 0 ]; then
    skip "owner mismatch requires a privileged isolated test runner"
  fi
  chown 1 "$(receipt_public_key)"
  assert_corrupt_status
}

@test "init rejects an unsafe lock mode without deleting it" {
  init_ready
  local nonce=01112233445566778899aabbccddeeff lock
  lock="$(receipt_lock)"
  write_lock_record "$lock" "$(dead_pid)" "$nonce"
  chmod 644 "$lock"
  run --separate-stderr storage_receipt_init receipts
  assert_status 12 corrupt_state
  [ -f "$lock" ]
  [ "$(file_mode "$lock")" = 644 ]
}

@test "OpenSSL major-version refusal uses missing_deps without mutating state" {
  init_ready
  local fake="$BATS_TEST_TMPDIR/openssl-major2" before after
  before="$(store_fingerprint)"
  printf '#!/bin/bash\nif [ "${1:-}" = version ]; then echo "OpenSSL 2.9 fixture"; exit 0; fi\nexec "%s" "$@"\n' \
    "$(command -v openssl)" >"$fake"
  chmod 700 "$fake"
  export AGMSG_RECEIPT_OPENSSL="$fake"
  run --separate-stderr storage_receipt_status receipts
  assert_status 10 missing_deps
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "xxd capability refusal uses missing_deps without mutating state" {
  init_ready
  local fake="$BATS_TEST_TMPDIR/xxd-fail" before after
  before="$(store_fingerprint)"
  printf '#!/bin/bash\nexit 1\n' >"$fake"
  chmod 700 "$fake"
  export AGMSG_RECEIPT_XXD="$fake"
  run --separate-stderr storage_receipt_status receipts
  assert_status 10 missing_deps
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "Git Bash rejects receipt initialization as unsupported while legacy storage stays available" {
  assert_receipt_abi
  skip_unless_windows "requires native Git Bash"
  storage_send receipts alice bob still-works >/dev/null
  run --separate-stderr storage_receipt_init receipts
  assert_status 13 runtime_error
  run storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r 'select(.type == "message_sent") | .body')" = still-works ]
}

@test "dead valid init lock is reclaimed only after its staging link is validated" {
  init_ready
  local nonce=00112233445566778899aabbccddeeff stage lock
  stage="$(receipt_stage "$nonce")"; lock="$(receipt_lock)"
  write_lock_record "$stage" "$(dead_pid)" "$nonce"
  ln "$stage" "$lock"
  [ "$(file_links "$stage")" -eq 2 ]
  run --separate-stderr storage_receipt_init receipts
  assert_status 0 ok
  [ ! -e "$stage" ]
  [ ! -e "$lock" ]
  assert_ready_identity
}

@test "live init lock is refused and never removed" {
  init_ready
  local nonce=10112233445566778899aabbccddeeff lock
  lock="$(receipt_lock)"
  sleep 30 &
  local owner_pid=$!
  write_lock_record "$lock" "$owner_pid" "$nonce"
  run --separate-stderr storage_receipt_init receipts
  assert_status 13 runtime_error
  [ -f "$lock" ]
  kill "$owner_pid" 2>/dev/null || true
  wait "$owner_pid" 2>/dev/null || true
}

@test "malformed init lock is corrupt state and is never removed" {
  init_ready
  local lock; lock="$(receipt_lock)"
  printf 'pid=not-a-number\n' >"$lock"
  chmod 600 "$lock"
  run --separate-stderr storage_receipt_init receipts
  assert_status 12 corrupt_state
  [ -f "$lock" ]
}

@test "inode-mismatched staging and init lock are corrupt state" {
  init_ready
  local nonce=20112233445566778899aabbccddeeff stage lock
  stage="$(receipt_stage "$nonce")"; lock="$(receipt_lock)"
  write_lock_record "$stage" "$(dead_pid)" "$nonce"
  ln "$stage" "$lock"
  cp "$stage" "$stage.replaced"
  mv "$stage.replaced" "$stage"
  [ "$(file_links "$lock")" -eq 1 ]
  run --separate-stderr storage_receipt_init receipts
  assert_status 12 corrupt_state
  [ -f "$lock" ]
  [ -f "$stage" ]
}

@test "live init lock refusal is bounded to the documented retry window" {
  init_ready
  local nonce=30112233445566778899aabbccddeeff lock started elapsed
  lock="$(receipt_lock)"
  sleep 30 &
  local owner_pid=$!
  write_lock_record "$lock" "$owner_pid" "$nonce"
  started="$(date +%s)"
  run --separate-stderr storage_receipt_init receipts
  elapsed=$(( $(date +%s) - started ))
  assert_status 13 runtime_error
  [ "$elapsed" -le 7 ]
  [ -f "$lock" ]
  kill "$owner_pid" 2>/dev/null || true
  wait "$owner_pid" 2>/dev/null || true
}

@test "SIGKILL pre-link residue is removed only when its dead staging record validates" {
  init_ready
  local nonce=40112233445566778899aabbccddeeff stage
  stage="$(receipt_stage "$nonce")"
  write_lock_record "$stage" "$(dead_pid)" "$nonce"
  [ ! -e "$(receipt_lock)" ]
  run --separate-stderr storage_receipt_init receipts
  assert_status 0 ok
  [ ! -e "$stage" ]
}

@test "SIGKILL post-link pre-unlink residue reclaims the exact two-link record" {
  init_ready
  local nonce=50112233445566778899aabbccddeeff stage lock
  stage="$(receipt_stage "$nonce")"; lock="$(receipt_lock)"
  write_lock_record "$stage" "$(dead_pid)" "$nonce"
  ln "$stage" "$lock"
  run --separate-stderr storage_receipt_init receipts
  assert_status 0 ok
  [ ! -e "$stage" ]
  [ ! -e "$lock" ]
}

@test "SIGKILL after staging unlink reclaims a valid dead fixed lock" {
  init_ready
  local nonce=60112233445566778899aabbccddeeff lock
  lock="$(receipt_lock)"
  write_lock_record "$lock" "$(dead_pid)" "$nonce"
  [ "$(file_links "$lock")" -eq 1 ]
  run --separate-stderr storage_receipt_init receipts
  assert_status 0 ok
  [ ! -e "$lock" ]
}

@test "PID reuse remains a conservative manual-recovery block" {
  assert_receipt_abi
  skip "PID reuse cannot be induced safely without a PID namespace; v1 must refuse it conservatively"
}

@test "JSONL has no receipt ABI and rejects issue requests with zero stdout and mutation" {
  export AGMSG_STORAGE_DRIVER=jsonl
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init receipts >/dev/null
  storage_send receipts alice bob jsonl >/dev/null
  local log before after id stdout="$BATS_TEST_TMPDIR/jsonl-list.stdout"
  local phase1_list phase1_show
  log="$(dirname "$(agmsg_db_path receipts)")/events.jsonl"
  run env AGMSG_STORAGE_DRIVER=jsonl AGMSG_STORAGE_PATH="$AGMSG_STORAGE_PATH" SKILL_DIR="$SKILL_DIR" \
    /bin/bash -c '
      source "$SKILL_DIR/scripts/lib/storage.sh"
      agmsg_storage_load
      for fn in storage_receipt_init storage_receipt_status storage_ack_receipt; do
        declare -F "$fn" >/dev/null && exit 1
      done
      storage_describe
    '
  [ "$status" -eq 0 ]
  [[ "$output" != *"sqlite-receipt-ack-v1"* ]]

  phase1_list="$(storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096)"
  id="$(printf '%s\n' "$phase1_list" | jq -r 'select(.type == "message_sent") | .id')"
  phase1_show="$(storage_get_message_bounded receipts bob "$id" --max-body-bytes 4096)"
  before="$(shasum "$log")"
  if storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt >"$stdout" 2>/dev/null; then
    false
  fi
  [ ! -s "$stdout" ]
  after="$(shasum "$log")"
  [ "$after" = "$before" ]

  if storage_get_message_bounded receipts bob "$id" --max-body-bytes 4096 --issue-receipt >"$stdout" 2>/dev/null; then
    false
  fi
  [ ! -s "$stdout" ]
  after="$(shasum "$log")"
  [ "$after" = "$before" ]
  [ "$(storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096)" = "$phase1_list" ]
  [ "$(storage_get_message_bounded receipts bob "$id" --max-body-bytes 4096)" = "$phase1_show" ]
}
