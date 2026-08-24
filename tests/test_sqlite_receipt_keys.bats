#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Contract RED tests for Issue #211. This file deliberately uses only public
# storage functions and isolated test stores; it must not add a test-only seam
# to the receipt implementation.

load test_helper

setup() {
  setup_test_env
  TEST_OWNED_PIDS=''
  SQLITE_LOCK_PID=''
  DIAGNOSTIC_SENTINEL='eyJ2IjoxLCJ0eXBlIjoicmVjZWlwdCJ9.c2lnbmF0dXJlX3NlbnRpbmVs'
  DIAGNOSTIC_SECRET_FRAGMENT='headerless-secret-fragment-91bc4e72'
  export DIAGNOSTIC_SENTINEL DIAGNOSTIC_SECRET_FRAGMENT
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_STORAGE_DRIVER=sqlite
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init receipts >/dev/null
}

test_process_identity() {
  ps -p "$1" -o lstart= -o command= 2>/dev/null | sed 's/^ *//'
}

skip_unless_process_identity() {
  command -v ps >/dev/null 2>&1 || skip "requires ps process identity before background spawn"
  [ -n "$(test_process_identity "$$")" ] || skip "requires ps lstart and command identity before background spawn"
}

register_test_pid() {
  local pid="$1" identity
  identity="$(test_process_identity "$pid")"
  # A process that has already exited needs no cleanup entry; an extant one
  # must have a recorded start-time/command identity before the test proceeds.
  if [ -z "$identity" ]; then
    kill -0 "$pid" 2>/dev/null && return 1
    return 0
  fi
  TEST_OWNED_PIDS="${TEST_OWNED_PIDS}${pid}"$'\t'"${identity}"$'\n'
}

unregister_test_pid() {
  local pid="$1"
  TEST_OWNED_PIDS="$(printf '%s' "$TEST_OWNED_PIDS" | awk -F '\t' -v pid="$pid" '$1 != pid')"
  [ -z "$TEST_OWNED_PIDS" ] || TEST_OWNED_PIDS="${TEST_OWNED_PIDS}"$'\n'
}

registered_pid_matches() {
  local target="$1" pid identity current
  while IFS=$'\t' read -r pid identity; do
    [ "$pid" = "$target" ] || continue
    current="$(test_process_identity "$pid")"
    [ "$current" = "$identity" ] && return 0
  done <<EOF
$TEST_OWNED_PIDS
EOF
  return 1
}

wait_for_test_owned_exit() {
  local pid="$1" kind="$2" deadline
  case "$kind" in
    child)
      wait "$pid" 2>/dev/null || true
      ! registered_pid_matches "$pid"
      ;;
    orphan)
      deadline=$(( $(date +%s) + 2 ))
      while kill -0 "$pid" 2>/dev/null && registered_pid_matches "$pid"; do
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 0.05
      done
      ;;
    *) return 2 ;;
  esac
}

release_test_waiters() {
  [ -n "${RECEIPT_CRASH_RELEASE:-}" ] && : >"$RECEIPT_CRASH_RELEASE"
}

cleanup_test_processes() {
  local pid identity current
  release_test_waiters
  while IFS=$'\t' read -r pid identity; do
    [ -n "$pid" ] || continue
    current="$(test_process_identity "$pid")"
    [ "$current" = "$identity" ] || continue
    kill "$pid" 2>/dev/null || true
  done <<EOF
$TEST_OWNED_PIDS
EOF
  while IFS=$'\t' read -r pid identity; do
    [ -n "$pid" ] || continue
    current="$(test_process_identity "$pid")"
    [ "$current" = "$identity" ] || continue
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done <<EOF
$TEST_OWNED_PIDS
EOF
  TEST_OWNED_PIDS=''
}

teardown() {
  stop_sqlite_read_lock
  cleanup_test_processes
  teardown_test_env
}

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

receipt_state_abi_required() {
  local fn
  for fn in storage_receipt_init storage_receipt_status; do
    declare -F "$fn" >/dev/null || {
      printf 'missing optional receipt state function: %s\n' "$fn" >&2
      return 1
    }
  done
}

receipt_ack_abi_required() {
  declare -F storage_ack_receipt >/dev/null || {
    printf 'missing optional receipt acknowledgement function: storage_ack_receipt\n' >&2
    return 1
  }
}

assert_receipt_state_abi() {
  receipt_state_abi_required
}

assert_receipt_complete_abi() {
  receipt_state_abi_required
  receipt_ack_abi_required
}

assert_status() {
  local expected_status="$1" expected_output="$2"
  [ "$status" -eq "$expected_status" ]
  [ "$output" = "$expected_output" ]
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

receipt_meta_value() {
  local key="$1"
  sqlite3 "$(agmsg_db_path receipts)" \
    "SELECT value FROM receipt_meta WHERE key = '$key';" | tr -d '\r'
}

read_receipt_identity() {
  [ "$(sqlite3 "$(agmsg_db_path receipts)" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'receipt_meta';" | tr -d '\r')" = 1 ]
  [ "$(receipt_meta_value schema_version)" = 1 ]
  [[ "$(receipt_meta_value store_generation)" =~ ^[0-9a-f]{32}$ ]]
  [[ "$(receipt_meta_value public_key_sha256)" =~ ^[0-9a-f]{64}$ ]]
  [ "$(shasum -a 256 "$(receipt_public_key)" | awk '{print $1}')" = \
    "$(receipt_meta_value public_key_sha256)" ]
  RECEIPT_IDENTITY="$(receipt_meta_value schema_version):$(receipt_meta_value store_generation):$(receipt_meta_value public_key_sha256)"
}

assert_ready_identity() {
  run --separate-stderr storage_receipt_status receipts
  assert_status 0 ok
  read_receipt_identity
}

init_ready() {
  assert_receipt_state_abi
  run --separate-stderr storage_receipt_init receipts
  assert_status 0 ok
  assert_ready_identity
}

assert_corrupt_status() {
  run --separate-stderr storage_receipt_status receipts
  assert_status 12 corrupt_state
}

assert_corrupt_init() {
  run --separate-stderr storage_receipt_init receipts
  assert_status 12 corrupt_state
}

capture_receipt_command() {
  local label="$1"
  shift
  CAPTURE_STDOUT="$BATS_TEST_TMPDIR/${label}.stdout"
  CAPTURE_STDERR="$BATS_TEST_TMPDIR/${label}.stderr"
  if "$@" >"$CAPTURE_STDOUT" 2>"$CAPTURE_STDERR"; then
    CAPTURE_STATUS=0
  else
    CAPTURE_STATUS=$?
  fi
}

assert_safe_diagnostics() {
  local forbidden="${1:-}"
  [ "$(wc -c <"$CAPTURE_STDOUT" | tr -d ' ')" -le 4096 ]
  [ "$(wc -c <"$CAPTURE_STDERR" | tr -d ' ')" -le 4096 ]
  ! grep -Eq -- '-----BEGIN|PRIVATE KEY|PUBLIC KEY' "$CAPTURE_STDOUT" "$CAPTURE_STDERR"
  ! grep -Fq -- "$DIAGNOSTIC_SENTINEL" "$CAPTURE_STDOUT" "$CAPTURE_STDERR"
  ! grep -Fq -- "$DIAGNOSTIC_SECRET_FRAGMENT" "$CAPTURE_STDOUT" "$CAPTURE_STDERR"
  if [ -n "$forbidden" ]; then
    ! grep -Fq -- "$forbidden" "$CAPTURE_STDOUT" "$CAPTURE_STDERR"
  fi
}

start_sqlite_read_lock() {
  local journal="$1" db fifo attempt
  db="$(agmsg_db_path receipts)"
  fifo="$BATS_TEST_TMPDIR/sqlite-lock.fifo"
  sqlite3 "$db" "PRAGMA journal_mode=$journal;" >/dev/null
  mkfifo "$fifo"
  sqlite3 "$db" <"$fifo" >"$BATS_TEST_TMPDIR/sqlite-lock.stdout" \
    2>"$BATS_TEST_TMPDIR/sqlite-lock.stderr" &
  SQLITE_LOCK_PID=$!
  exec 9>"$fifo"
  if [ "$journal" = WAL ]; then
    printf '%s\n' 'PRAGMA locking_mode=EXCLUSIVE;' >&9
  fi
  printf '%s\n' 'BEGIN EXCLUSIVE;' \
    'UPDATE messages SET body=body WHERE 0;' >&9

  for attempt in $(seq 1 100); do
    if ! sqlite3 -cmd '.timeout 1' "$db" 'SELECT COUNT(*) FROM messages;' \
        >/dev/null 2>&1; then
      return 0
    fi
    kill -0 "$SQLITE_LOCK_PID" 2>/dev/null || break
    sleep 0.02
  done
  return 1
}

stop_sqlite_read_lock() {
  [ -n "${SQLITE_LOCK_PID:-}" ] || return 0
  printf '%s\n' 'ROLLBACK;' >&9 2>/dev/null || true
  exec 9>&-
  wait "$SQLITE_LOCK_PID" 2>/dev/null || true
  SQLITE_LOCK_PID=''
}

dead_pid() {
  skip_unless_process_identity
  sleep 1 &
  local pid=$!
  register_test_pid "$pid"
  registered_pid_matches "$pid" && kill "$pid" 2>/dev/null || true
  wait "$pid"
  unregister_test_pid "$pid"
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

# These wrappers exercise actual initializer processes at crash boundaries. They
# are test-side PATH/override commands, not production hooks. A marker names
# the paused wrapper PID, exact point, and exact receipt path; no probe command
# can create one. `read -t` keeps the wrapper paused without spawning a sleep
# child that could outlive the killed initializer.
make_crash_wrappers() {
  local wrapper_dir="$BATS_TEST_TMPDIR/receipt-crash-bin"
  mkdir -p "$wrapper_dir"
  export RECEIPT_CRASH_MARKER="$BATS_TEST_TMPDIR/receipt-crash.marker"
  export RECEIPT_CRASH_RELEASE="$BATS_TEST_TMPDIR/receipt-crash.release"
  export RECEIPT_PRIVATE_PATH="$(receipt_private_key)"
  export RECEIPT_PUBLIC_PATH="$(receipt_public_key)"
  export RECEIPT_LOCK_PATH="$(receipt_lock)"
  export RECEIPT_DB_PATH="$(agmsg_db_path receipts)"
  export RECEIPT_REAL_LN="$(command -v ln)"
  export RECEIPT_REAL_OPENSSL="$(receipt_test_openssl)"
  export RECEIPT_REAL_SQLITE="$(command -v sqlite3)"

  printf '%s\n' '#!/bin/bash' \
    'pause() { umask 077; printf "point=%s\nwrapper_pid=%s\ntarget=%s\n" "$1" "$$" "$2" >"$RECEIPT_CRASH_MARKER"; while [ ! -e "$RECEIPT_CRASH_RELEASE" ]; do read -r -t 1 _ </dev/null || true; done; }' \
    'target="${!#}"' \
    'if [ "${RECEIPT_CRASH_POINT:-}" = pre-link ] && [ "$target" = "$RECEIPT_LOCK_PATH" ]; then pause pre-link "$target"; fi' \
    '"$RECEIPT_REAL_LN" "$@"' \
    'rc=$?' \
    'if [ "$rc" -eq 0 ] && [ "${RECEIPT_CRASH_POINT:-}" = post-link-before-unlink ] && [ "$target" = "$RECEIPT_LOCK_PATH" ]; then pause post-link-before-unlink "$target"; fi' \
    'exit "$rc"' >"$wrapper_dir/ln"
  printf '%s\n' '#!/bin/bash' \
    'pause() { umask 077; printf "point=%s\nwrapper_pid=%s\ntarget=%s\n" "$1" "$$" "$2" >"$RECEIPT_CRASH_MARKER"; while [ ! -e "$RECEIPT_CRASH_RELEASE" ]; do read -r -t 1 _ </dev/null || true; done; }' \
    'args=("$@"); command="$1"; out=; in=; is_public=no; shift || true' \
    'while [ "$#" -gt 0 ]; do case "$1" in -out) shift; out="${1:-}" ;; -in) shift; in="${1:-}" ;; -pubout) is_public=yes ;; esac; shift || true; done' \
    'is_private=no; [ "$command" = genpkey ] && [ "$out" = "$RECEIPT_PRIVATE_PATH" ] && is_private=yes' \
    'is_exact_public=no; [ "$command" = pkey ] && [ "$in" = "$RECEIPT_PRIVATE_PATH" ] && [ "$out" = "$RECEIPT_PUBLIC_PATH" ] && [ "$is_public" = yes ] && is_exact_public=yes' \
    'if [ "$is_private" = yes ] && { [ "${RECEIPT_CRASH_POINT:-}" = directory-created ] || [ "${RECEIPT_CRASH_POINT:-}" = after-acquisition ]; }; then pause "${RECEIPT_CRASH_POINT}" "$out"; fi' \
    '"$RECEIPT_REAL_OPENSSL" "${args[@]}"' \
    'rc=$?' \
    'if [ "$rc" -eq 0 ] && [ "$is_private" = yes ] && [ "${RECEIPT_CRASH_POINT:-}" = private-created ]; then pause private-created "$out"; fi' \
    'if [ "$rc" -eq 0 ] && [ "$is_exact_public" = yes ] && [ "${RECEIPT_CRASH_POINT:-}" = public-created ]; then pause public-created "$out"; fi' \
    'exit "$rc"' >"$wrapper_dir/openssl"
  printf '%s\n' '#!/bin/bash' \
    'pause() { umask 077; printf "point=%s\nwrapper_pid=%s\ntarget=%s\n" "$1" "$$" "$2" >"$RECEIPT_CRASH_MARKER"; while [ ! -e "$RECEIPT_CRASH_RELEASE" ]; do read -r -t 1 _ </dev/null || true; done; }' \
    '"$RECEIPT_REAL_SQLITE" "$@"' \
    'rc=$?' \
    'rows="$("$RECEIPT_REAL_SQLITE" "$RECEIPT_DB_PATH" "SELECT COUNT(*) FROM receipt_meta WHERE key IN (char(115)||char(99)||char(104)||char(101)||char(109)||char(97)||char(95)||char(118)||char(101)||char(114)||char(115)||char(105)||char(111)||char(110), char(115)||char(116)||char(111)||char(114)||char(101)||char(95)||char(103)||char(101)||char(110)||char(101)||char(114)||char(97)||char(116)||char(105)||char(111)||char(110), char(112)||char(117)||char(98)||char(108)||char(105)||char(99)||char(95)||char(107)||char(101)||char(121)||char(95)||char(115)||char(104)||char(97)||char(50)||char(53)||char(54));" 2>/dev/null)"' \
    'if [ "$rc" -eq 0 ] && [ "${RECEIPT_CRASH_POINT:-}" = metadata-committed ] && [ "$rows" = 3 ]; then pause metadata-committed "$RECEIPT_DB_PATH"; fi' \
    'exit "$rc"' >"$wrapper_dir/sqlite3"
  chmod 700 "$wrapper_dir/ln" "$wrapper_dir/openssl" "$wrapper_dir/sqlite3"
  RECEIPT_CRASH_BIN="$wrapper_dir"
}

start_crashable_init() {
  local point="$1"
  assert_receipt_state_abi
  make_crash_wrappers
  RECEIPT_CRASH_POINT="$point" PATH="$RECEIPT_CRASH_BIN:$PATH" \
    AGMSG_RECEIPT_OPENSSL="$RECEIPT_CRASH_BIN/openssl" \
    AGMSG_RECEIPT_XXD="$(command -v xxd)" \
    storage_receipt_init receipts >"$BATS_TEST_TMPDIR/crash-init.stdout" \
    2>"$BATS_TEST_TMPDIR/crash-init.stderr" &
  RECEIPT_INIT_PID=$!
  register_test_pid "$RECEIPT_INIT_PID"
  local attempt
  for attempt in $(seq 1 100); do
    if [ -s "$RECEIPT_CRASH_MARKER" ]; then
      CRASH_WRAPPER_PID="$(awk -F= '$1 == "wrapper_pid" { print $2 }' "$RECEIPT_CRASH_MARKER")"
      if [ -n "$CRASH_WRAPPER_PID" ] && kill -0 "$CRASH_WRAPPER_PID" 2>/dev/null; then
        register_test_pid "$CRASH_WRAPPER_PID"
        return 0
      fi
    fi
    kill -0 "$RECEIPT_INIT_PID" 2>/dev/null || break
    sleep 0.05
  done
  registered_pid_matches "$RECEIPT_INIT_PID" && kill -9 "$RECEIPT_INIT_PID" 2>/dev/null || true
  wait_for_test_owned_exit "$RECEIPT_INIT_PID" child
  unregister_test_pid "$RECEIPT_INIT_PID"
  false
}

kill_crashable_init() {
  [ -s "$RECEIPT_CRASH_MARKER" ]
  registered_pid_matches "$RECEIPT_INIT_PID" && kill -9 "$RECEIPT_INIT_PID" 2>/dev/null || true
  registered_pid_matches "$CRASH_WRAPPER_PID" && kill -9 "$CRASH_WRAPPER_PID" 2>/dev/null || true
  wait_for_test_owned_exit "$RECEIPT_INIT_PID" child
  wait_for_test_owned_exit "$CRASH_WRAPPER_PID" orphan
  unregister_test_pid "$RECEIPT_INIT_PID"
  unregister_test_pid "$CRASH_WRAPPER_PID"
}

assert_crash_marker() {
  local expected_point="$1" expected_target="$2"
  [ "$(awk -F= '$1 == "point" { print $2 }' "$RECEIPT_CRASH_MARKER")" = "$expected_point" ]
  [ "$(awk -F= '$1 == "target" { print $2 }' "$RECEIPT_CRASH_MARKER")" = "$expected_target" ]
  [[ "$CRASH_WRAPPER_PID" =~ ^[0-9]+$ ]]
  kill -0 "$CRASH_WRAPPER_PID" 2>/dev/null
}

@test "receipt vectors are complete, byte-stable, and distinguish each bound field" {
  local vector material expected actual rows batch payload
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

  agmsg_receipt_resolve_runtime
  rows="$BATS_TEST_TMPDIR/vector.rows"
  batch="$BATS_TEST_TMPDIR/vector.batch"
  for vector in batch-base batch-id-boundary batch-id-changed batch-body-changed; do
    printf '0|74|61|72|323032362d30312d30325430333a30343a30355a|event|7|%s|%s\n' \
      "$(fixture_field "$vector" input_id_hex)" \
      "$(fixture_field "$vector" input_body_hex)" >"$rows"
    _agmsg_receipt_canonicalize batch "$rows" "$batch"
    [ "$(xxd -p -c 1000000 "$batch" | tr -d '\n')" = "$(fixture_field "$vector" material_hex)" ]
    [ "$(shasum -a 256 "$batch" | awk '{print $1}')" = "$(fixture_field "$vector" sha256)" ]
  done

  payload="$BATS_TEST_TMPDIR/vector.payload"
  _agmsg_receipt_canonicalize payload "$payload" \
    0123456789abcdef0123456789abcdef \
    abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789 \
    7465616d2d61 626f62 1 \
    "$(fixture_field batch-base sha256)" "$(fixture_field frame-payload-base sha256)" \
    42 1700000000 1700000900 00112233445566778899aabbccddeeff
  [ "$(xxd -p -c 1000000 "$payload" | tr -d '\n')" = "$(fixture_field payload-base material_hex)" ]
}

@test "SQLite exposes the complete optional receipt ABI and exact capability token" {
  assert_receipt_complete_abi

  run storage_describe
  [ "$status" -eq 0 ]
  local capability_line
  capability_line="$(printf '%s\n' "$output" | awk -F= '$1 == "capabilities" { print; count++ } END { exit count == 1 ? 0 : 1 }')"
  [[ ",${capability_line#capabilities=}," == *",sqlite-receipt-ack-v1,"* ]]
  [ "$(printf '%s' "${capability_line#capabilities=}" | tr ',' '\n' | sort | uniq -d | wc -l | tr -d ' ')" = 0 ]
}

@test "receipt status is non-mutating and reports uninitialized state through the existing vocabulary" {
  assert_receipt_state_abi
  local before after
  before="$(store_fingerprint)"
  run --separate-stderr storage_receipt_status receipts
  assert_status 13 runtime_error
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "receipt init makes exact-ok status, preserves private identity on re-init, and emits no key material" {
  init_ready
  local before="$RECEIPT_IDENTITY"
  [ "$(sqlite3 "$(agmsg_db_path receipts)" \
    "SELECT COUNT(*) FROM receipt_meta;")" = 3 ]
  [ "$(sqlite3 "$(agmsg_db_path receipts)" \
    "SELECT group_concat(name, ',') FROM (SELECT name FROM pragma_table_info('receipt_nonces') ORDER BY cid);")" = \
    nonce,payload_sha256,store_generation,team_sha256,recipient_sha256,batch_sha256,frame_sha256,expires_at,committed_at ]
  [[ "$output" != *"BEGIN"* ]]
  [[ "$output" != *"PRIVATE"* ]]

  run --separate-stderr storage_receipt_init receipts
  assert_status 0 ok
  assert_ready_identity
  [ "$RECEIPT_IDENTITY" = "$before" ]
}

@test "concurrent receipt init is serialized and leaves a ready identity" {
  skip_unless_process_identity
  init_ready
  local before="$RECEIPT_IDENTITY"
  local first="$BATS_TEST_TMPDIR/first" second="$BATS_TEST_TMPDIR/second"
  storage_receipt_init receipts >"$first" 2>&1 &
  local first_pid=$!
  register_test_pid "$first_pid"
  storage_receipt_init receipts >"$second" 2>&1 &
  local second_pid=$!
  register_test_pid "$second_pid"
  wait "$first_pid"
  [ "$?" -eq 0 ]
  unregister_test_pid "$first_pid"
  wait "$second_pid"
  [ "$?" -eq 0 ]
  unregister_test_pid "$second_pid"
  [ "$(cat "$first")" = ok ]
  [ "$(cat "$second")" = ok ]
  assert_ready_identity
  [ "$RECEIPT_IDENTITY" = "$before" ]
}

@test "receipt status fails closed when the exact claim functions are loaded" {
  assert_receipt_state_abi
  storage_receipt_init receipts >/dev/null
  agmsg_claim_next() { :; }
  agmsg_ack_claim() { :; }
  agmsg_release_claim() { :; }

  run --separate-stderr storage_receipt_status receipts
  assert_status 13 runtime_error
}

@test "receipt status fails closed when the exact SQLite claims table exists" {
  init_ready
  sqlite3 "$(agmsg_db_path receipts)" \
    "CREATE TABLE claims(scope TEXT, task_id TEXT, holder TEXT);"

  run --separate-stderr storage_receipt_status receipts
  assert_status 13 runtime_error
}

@test "receipt status rejects claim capability tokens and malformed capability metadata" {
  init_ready
  storage_describe() {
    printf '%s\n' 'name=sqlite' 'capabilities=stage1-sync,message-claim-v2'
  }
  run --separate-stderr storage_receipt_status receipts
  assert_status 13 runtime_error

  storage_describe() {
    printf '%s\n' 'name=sqlite' 'capabilities=stage1-sync,stage1-sync'
  }
  run --separate-stderr storage_receipt_status receipts
  assert_status 12 corrupt_state
}

@test "unrelated lease capability does not trip the closed claim predicate" {
  init_ready
  storage_describe() {
    printf '%s\n' 'name=sqlite' 'capabilities=stage1-sync,lease-audit'
  }
  run --separate-stderr storage_receipt_status receipts
  assert_status 0 ok
}

@test "repo-relative exact claims library marker disables receipt status" {
  init_ready
  local copy="$BATS_TEST_TMPDIR/skill-copy"
  mkdir -p "$copy"
  cp -R "$TEST_SKILL_DIR/scripts" "$copy/"
  : >"$copy/scripts/lib/claims.sh"

  run --separate-stderr env AGMSG_STORAGE_DRIVER=sqlite AGMSG_STORAGE_PATH="$AGMSG_STORAGE_PATH" \
    AGMSG_CONFIG="$AGMSG_CONFIG" SKILL_DIR="$copy" /bin/bash -c '
      source "$SKILL_DIR/scripts/lib/storage.sh"
      agmsg_storage_load
      storage_receipt_status receipts
    '
  assert_status 13 runtime_error
}

@test "SQLite receipt issuance is opt-in, final, bounded, and read-only" {
  assert_receipt_state_abi
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
  assert_receipt_state_abi
  storage_receipt_init receipts >/dev/null
  run storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -s '[.[] | select(.type == "bounded_unread_receipt")] | length')" = 0 ]

  storage_send receipts alice bob first >/dev/null
  local later; later="$(storage_send receipts alice bob later)"
  run --separate-stderr storage_get_message_bounded receipts bob "$later" --max-body-bytes 4096 --issue-receipt
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
  [ "$(printf '%s' "$stderr" | wc -c | tr -d ' ')" -le 4096 ]
}

@test "ack validates through the optional operation and never writes stdout on failure" {
  assert_receipt_state_abi
  receipt_ack_abi_required
  storage_receipt_init receipts >/dev/null
  local before after
  before="$(store_fingerprint)"
  run storage_ack_receipt receipts bob --receipt not-a-receipt
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "receipt state diagnostics keep init and status bounded and non-sensitive" {
  assert_receipt_state_abi
  capture_receipt_command init storage_receipt_init receipts
  [ "$CAPTURE_STATUS" -eq 0 ]
  [ "$(cat "$CAPTURE_STDOUT")" = ok ]
  [ ! -s "$CAPTURE_STDERR" ]
  assert_safe_diagnostics

  capture_receipt_command status storage_receipt_status receipts
  [ "$CAPTURE_STATUS" -eq 0 ]
  [ "$(cat "$CAPTURE_STDOUT")" = ok ]
  [ ! -s "$CAPTURE_STDERR" ]
  assert_safe_diagnostics
}

@test "receipt issue and ack refusals keep stdout empty and diagnostics bounded" {
  assert_receipt_state_abi
  receipt_ack_abi_required
  storage_receipt_init receipts >/dev/null
  storage_send receipts alice bob first >/dev/null
  local later forbidden_receipt="$DIAGNOSTIC_SENTINEL"
  later="$(storage_send receipts alice bob later)"
  capture_receipt_command issue-refusal storage_get_message_bounded receipts bob "$later" \
    --max-body-bytes 4096 --issue-receipt
  [ "$CAPTURE_STATUS" -ne 0 ]
  [ ! -s "$CAPTURE_STDOUT" ]
  assert_safe_diagnostics

  capture_receipt_command ack-refusal storage_ack_receipt receipts bob --receipt "$forbidden_receipt"
  [ "$CAPTURE_STATUS" -ne 0 ]
  [ ! -s "$CAPTURE_STDOUT" ]
  assert_safe_diagnostics "$forbidden_receipt"
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
  local before="$RECEIPT_IDENTITY"
  rm -f "$(receipt_private_key)" "$(receipt_public_key)"
  assert_corrupt_status
  assert_corrupt_init
  [ ! -e "$(receipt_private_key)" ]
  [ ! -e "$(receipt_public_key)" ]
  [ "$(receipt_meta_value schema_version):$(receipt_meta_value store_generation):$(receipt_meta_value public_key_sha256)" = "$before" ]
}

@test "half key state is corrupt and is never auto-repaired" {
  init_ready
  local before="$RECEIPT_IDENTITY"
  rm -f "$(receipt_private_key)"
  assert_corrupt_status
  assert_corrupt_init
  [ ! -e "$(receipt_private_key)" ]
  [ -f "$(receipt_public_key)" ]
  [ "$(receipt_meta_value schema_version):$(receipt_meta_value store_generation):$(receipt_meta_value public_key_sha256)" = "$before" ]
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
  skip_unless_process_identity
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

@test "OpenSSL major-version refusal sanitizes underlying stderr and leaves state unchanged" {
  init_ready
  local fake="$BATS_TEST_TMPDIR/openssl-major2" before after
  before="$(store_fingerprint)"
  printf '#!/bin/bash\nprintf "%%s\\n" "$DIAGNOSTIC_SECRET_FRAGMENT" >&2\nif [ "${1:-}" = version ]; then echo "OpenSSL 2.9 fixture"; exit 0; fi\nexit 1\n' >"$fake"
  chmod 700 "$fake"
  export AGMSG_RECEIPT_OPENSSL="$fake"
  capture_receipt_command openssl-refusal storage_receipt_status receipts
  [ "$CAPTURE_STATUS" -eq 10 ]
  [ "$(cat "$CAPTURE_STDOUT")" = missing_deps ]
  assert_safe_diagnostics
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "malformed OpenSSL probe output is runtime_error rather than missing_deps" {
  init_ready
  local fake="$BATS_TEST_TMPDIR/openssl-empty-version" before after
  before="$(store_fingerprint)"
  printf '%s\n' '#!/bin/bash' \
    'printf "%s\n" "$DIAGNOSTIC_SECRET_FRAGMENT" >&2' \
    'if [ "${1:-}" = version ]; then printf "\n"; exit 0; fi' \
    'exit 1' >"$fake"
  chmod 700 "$fake"
  export AGMSG_RECEIPT_OPENSSL="$fake"

  capture_receipt_command malformed-openssl-output storage_receipt_status receipts
  [ "$CAPTURE_STATUS" -eq 13 ]
  [ "$(cat "$CAPTURE_STDOUT")" = runtime_error ]
  assert_safe_diagnostics
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "xxd capability refusal sanitizes underlying stderr and leaves state unchanged" {
  init_ready
  local fake="$BATS_TEST_TMPDIR/xxd-fail" before after
  before="$(store_fingerprint)"
  printf '#!/bin/bash\nprintf "%%s\\n" "$DIAGNOSTIC_SECRET_FRAGMENT" >&2\nexit 1\n' >"$fake"
  chmod 700 "$fake"
  export AGMSG_RECEIPT_XXD="$fake"
  capture_receipt_command xxd-refusal storage_receipt_status receipts
  [ "$CAPTURE_STATUS" -eq 10 ]
  [ "$(cat "$CAPTURE_STDOUT")" = missing_deps ]
  assert_safe_diagnostics
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "relative runtime overrides fail without falling back to platform candidates" {
  init_ready
  export AGMSG_RECEIPT_OPENSSL=openssl
  capture_receipt_command relative-openssl storage_receipt_status receipts
  [ "$CAPTURE_STATUS" -eq 10 ]
  [ "$(cat "$CAPTURE_STDOUT")" = missing_deps ]
  assert_safe_diagnostics

  unset AGMSG_RECEIPT_OPENSSL
  export AGMSG_RECEIPT_XXD=xxd
  capture_receipt_command relative-xxd storage_receipt_status receipts
  [ "$CAPTURE_STATUS" -eq 10 ]
  [ "$(cat "$CAPTURE_STDOUT")" = missing_deps ]
  assert_safe_diagnostics
}

@test "OpenSSL 3 branding without Ed25519 capability is rejected" {
  init_ready
  local fake="$BATS_TEST_TMPDIR/openssl-no-ed25519"
  export REAL_RECEIPT_OPENSSL="$(receipt_test_openssl)"
  printf '%s\n' '#!/bin/bash' \
    'if [ "${1:-}" = genpkey ]; then printf "%s\n" "$DIAGNOSTIC_SECRET_FRAGMENT" >&2; exit 1; fi' \
    'exec "$REAL_RECEIPT_OPENSSL" "$@"' >"$fake"
  chmod 700 "$fake"
  export AGMSG_RECEIPT_OPENSSL="$fake"

  capture_receipt_command no-ed25519 storage_receipt_status receipts
  [ "$CAPTURE_STATUS" -eq 10 ]
  [ "$(cat "$CAPTURE_STDOUT")" = missing_deps ]
  assert_safe_diagnostics
}

@test "xxd override that corrupts the 258-byte round trip is rejected" {
  init_ready
  local fake="$BATS_TEST_TMPDIR/xxd-corrupt"
  export REAL_RECEIPT_XXD="$(command -v xxd)"
  printf '%s\n' '#!/bin/bash' \
    'if [ "${1:-}" = -r ] && [ "${2:-}" = -p ]; then' \
    '  "$REAL_RECEIPT_XXD" "$@" || exit' \
    '  for argument in "$@"; do output="$argument"; done' \
    '  printf x >>"$output"' \
    '  exit 0' \
    'fi' \
    'exec "$REAL_RECEIPT_XXD" "$@"' >"$fake"
  chmod 700 "$fake"
  export AGMSG_RECEIPT_XXD="$fake"

  capture_receipt_command corrupt-xxd storage_receipt_status receipts
  [ "$CAPTURE_STATUS" -eq 10 ]
  [ "$(cat "$CAPTURE_STDOUT")" = missing_deps ]
  assert_safe_diagnostics
}

@test "runtime setup failure is runtime_error and never reveals a secret TMPDIR" {
  init_ready
  local before after secret_tmp
  before="$(store_fingerprint)"
  secret_tmp="$BATS_TEST_TMPDIR/$DIAGNOSTIC_SECRET_FRAGMENT/nonexistent"
  export TMPDIR="$secret_tmp"

  capture_receipt_command runtime-setup-refusal storage_receipt_status receipts
  [ "$CAPTURE_STATUS" -eq 13 ]
  [ "$(cat "$CAPTURE_STDOUT")" = runtime_error ]
  assert_safe_diagnostics "$secret_tmp"
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "DELETE exclusive lock is runtime_error without a claim diagnostic" {
  init_ready
  start_sqlite_read_lock DELETE
  export AGMSG_BUSY_TIMEOUT=50

  capture_receipt_command delete-busy storage_receipt_status receipts
  [ "$CAPTURE_STATUS" -eq 13 ]
  [ "$(cat "$CAPTURE_STDOUT")" = runtime_error ]
  assert_safe_diagnostics
  ! grep -Fqi -- claim "$CAPTURE_STDERR"
}

@test "WAL exclusive locking mode is runtime_error without a claim diagnostic" {
  init_ready
  start_sqlite_read_lock WAL
  export AGMSG_BUSY_TIMEOUT=50

  capture_receipt_command wal-busy storage_receipt_status receipts
  [ "$CAPTURE_STATUS" -eq 13 ]
  [ "$(cat "$CAPTURE_STDOUT")" = runtime_error ]
  assert_safe_diagnostics
  ! grep -Fqi -- claim "$CAPTURE_STDERR"
}

@test "Git Bash rejects receipt initialization as unsupported while legacy storage stays available" {
  assert_receipt_state_abi
  skip_unless_windows "requires native Git Bash"
  storage_send receipts alice bob still-works >/dev/null
  run --separate-stderr storage_receipt_init receipts
  assert_status 13 runtime_error
  run storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r 'select(.type == "message_sent") | .body')" = still-works ]
}

@test "dead valid init lock is reclaimed only after its staging link is validated" {
  skip_unless_process_identity
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
  skip_unless_process_identity
  init_ready
  local nonce=10112233445566778899aabbccddeeff lock
  lock="$(receipt_lock)"
  sleep 30 &
  local owner_pid=$!
  register_test_pid "$owner_pid"
  write_lock_record "$lock" "$owner_pid" "$nonce"
  run --separate-stderr storage_receipt_init receipts
  assert_status 13 runtime_error
  [ -f "$lock" ]
  registered_pid_matches "$owner_pid" && kill "$owner_pid" 2>/dev/null || true
  wait "$owner_pid" 2>/dev/null || true
  unregister_test_pid "$owner_pid"
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
  skip_unless_process_identity
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
  skip_unless_process_identity
  init_ready
  local nonce=30112233445566778899aabbccddeeff lock started elapsed
  lock="$(receipt_lock)"
  sleep 30 &
  local owner_pid=$!
  register_test_pid "$owner_pid"
  write_lock_record "$lock" "$owner_pid" "$nonce"
  started="$(date +%s)"
  run --separate-stderr storage_receipt_init receipts
  elapsed=$(( $(date +%s) - started ))
  assert_status 13 runtime_error
  [ "$elapsed" -le 7 ]
  [ -f "$lock" ]
  registered_pid_matches "$owner_pid" && kill "$owner_pid" 2>/dev/null || true
  wait "$owner_pid" 2>/dev/null || true
  unregister_test_pid "$owner_pid"
}

# These require a POSIX runner with executable command-shadowing semantics;
# native Git Bash has its own unsupported receipt boundary and is covered below.
skip_unless_posix_crash_runner() {
  skip_unless_process_identity
  case "$(uname -s)" in
    Darwin*|Linux*) command -v sqlite3 >/dev/null && receipt_test_openssl >/dev/null || skip "requires POSIX sqlite3 and OpenSSL 3 runner" ;;
    *) skip "requires a POSIX runner; native Git Bash is covered separately" ;;
  esac
}

@test "real SIGKILL before lock hard-link leaves only an initializer staging record" {
  skip_unless_posix_crash_runner
  assert_receipt_state_abi
  start_crashable_init pre-link
  assert_crash_marker pre-link "$(receipt_lock)"
  kill_crashable_init
  [ -d "$(receipt_dir)" ]
  [ -n "$(find "$(receipt_dir)" -maxdepth 1 -name '.init-stage.*' -print -quit)" ]
  [ ! -e "$(receipt_lock)" ]
}

@test "real SIGKILL after lock hard-link preserves the exact two-link crash residue" {
  skip_unless_posix_crash_runner
  assert_receipt_state_abi
  start_crashable_init post-link-before-unlink
  assert_crash_marker post-link-before-unlink "$(receipt_lock)"
  kill_crashable_init
  local stage
  stage="$(find "$(receipt_dir)" -maxdepth 1 -name '.init-stage.*' -print -quit)"
  [ -n "$stage" ]
  [ -f "$(receipt_lock)" ]
  [ "$(file_links "$stage")" -eq 2 ]
  [ "$(file_links "$(receipt_lock)")" -eq 2 ]
}

@test "real SIGKILL after acquisition leaves only the fixed lock before key generation" {
  skip_unless_posix_crash_runner
  assert_receipt_state_abi
  start_crashable_init after-acquisition
  assert_crash_marker after-acquisition "$(receipt_private_key)"
  kill_crashable_init
  [ -d "$(receipt_dir)" ]
  [ -f "$(receipt_lock)" ]
  [ "$(file_links "$(receipt_lock)")" -eq 1 ]
  [ -z "$(find "$(receipt_dir)" -maxdepth 1 -name '.init-stage.*' -print -quit)" ]
}

@test "real SIGKILL after receipt directory creation leaves no key material" {
  skip_unless_posix_crash_runner
  assert_receipt_state_abi
  start_crashable_init directory-created
  assert_crash_marker directory-created "$(receipt_private_key)"
  kill_crashable_init
  [ -d "$(receipt_dir)" ]
  [ ! -e "$(receipt_private_key)" ]
  [ ! -e "$(receipt_public_key)" ]
}

@test "real SIGKILL after private-key generation leaves no public key" {
  skip_unless_posix_crash_runner
  assert_receipt_state_abi
  start_crashable_init private-created
  assert_crash_marker private-created "$(receipt_private_key)"
  kill_crashable_init
  [ -f "$(receipt_private_key)" ]
  [ ! -e "$(receipt_public_key)" ]
}

@test "real SIGKILL after public-key generation leaves the generated key pair" {
  skip_unless_posix_crash_runner
  assert_receipt_state_abi
  start_crashable_init public-created
  assert_crash_marker public-created "$(receipt_public_key)"
  kill_crashable_init
  [ -f "$(receipt_private_key)" ]
  [ -f "$(receipt_public_key)" ]
}

@test "real SIGKILL after atomic receipt metadata commit leaves schema and all identity rows" {
  skip_unless_posix_crash_runner
  assert_receipt_state_abi
  start_crashable_init metadata-committed
  assert_crash_marker metadata-committed "$(agmsg_db_path receipts)"
  kill_crashable_init
  read_receipt_identity
}

@test "SIGKILL pre-link residue is removed only when its dead staging record validates" {
  skip_unless_process_identity
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
  skip_unless_process_identity
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
  skip_unless_process_identity
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
  assert_receipt_state_abi
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
