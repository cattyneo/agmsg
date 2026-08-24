#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Task 3 TDD coverage for the fork-local SQLite receipt issuer. Every test uses
# an isolated store; no installed agmsg path or live coordination DB is opened.

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
  storage_receipt_init receipts >/dev/null
}

teardown() { teardown_test_env; }

receipt_dir() { printf '%s/receipt-v1' "$(dirname "$(agmsg_db_path receipts)")"; }
receipt_public_key() { printf '%s/public.pem' "$(receipt_dir)"; }
receipt_private_key() { printf '%s/private.pem' "$(receipt_dir)"; }

hex_of() { LC_ALL=C printf '%s' "$1" | xxd -p -c 1000000 | tr -d '\n'; }

sql_event() {
  local id="$1" sender="$2" recipient="$3" body="$4" at="$5"
  sqlite3 "$(agmsg_db_path receipts)" "
    INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    VALUES('message_sent',CAST(X'$(hex_of "$id")' AS TEXT),'receipts',
      CAST(X'$(hex_of "$sender")' AS TEXT),CAST(X'$(hex_of "$recipient")' AS TEXT),
      CAST(X'$(hex_of "$body")' AS TEXT),CAST(X'$(hex_of "$at")' AS TEXT));" >/dev/null
}

durable_state() {
  local db; db="$(agmsg_db_path receipts)"
  sqlite3 "$db" "
    SELECT 'read=' || COUNT(*) FROM events WHERE type='message_read';
    SELECT 'cursor=' || COUNT(*) || ':' || COALESCE(group_concat(team || ':' || agent || ':' || local_position), '') FROM read_cursors;
    SELECT 'nonce=' || COUNT(*) FROM receipt_nonces;
    SELECT 'meta=' || group_concat(key || ':' || value, ',') FROM (SELECT key,value FROM receipt_meta ORDER BY key);" | tr -d '\r'
}

receipt_record() { printf '%s\n' "$1" | jq -ce 'select(.type == "bounded_unread_receipt")'; }
receipt_token() { receipt_record "$1" | jq -r '.receipt'; }

base64url_decode_to() {
  local value="$1" out="$2" padded remainder
  padded="$(printf '%s' "$value" | tr '_-' '/+')"
  remainder=$(( ${#padded} % 4 ))
  case "$remainder" in
    0) ;;
    2) padded="${padded}==" ;;
    3) padded="${padded}=" ;;
    *) return 1 ;;
  esac
  printf '%s' "$padded" | openssl base64 -d -A >"$out"
}

decode_receipt() {
  local token="$1" payload_part signature_part
  payload_part="${token%%.*}"
  signature_part="${token#*.}"
  [ "$payload_part" != "$token" ]
  [ -n "$payload_part" ] && [ -n "$signature_part" ]
  [ "${signature_part#*.}" = "$signature_part" ]
  base64url_decode_to "$payload_part" "$BATS_TEST_TMPDIR/payload.bin"
  base64url_decode_to "$signature_part" "$BATS_TEST_TMPDIR/signature.bin"
  RECEIPT_PAYLOAD="$(cat "$BATS_TEST_TMPDIR/payload.bin")"
  openssl pkeyutl -verify -pubin -inkey "$(receipt_public_key)" -rawin \
    -in "$BATS_TEST_TMPDIR/payload.bin" -sigfile "$BATS_TEST_TMPDIR/signature.bin" >/dev/null
}

assert_zero_stdout_failure() {
  local name="$1"
  shift
  local out="$BATS_TEST_TMPDIR/$name.stdout" err="$BATS_TEST_TMPDIR/$name.stderr" rc
  if "$@" >"$out" 2>"$err"; then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ]
  [ ! -s "$out" ]
  [ -s "$err" ]
  [ "$(wc -c <"$err" | tr -d ' ')" -le 4096 ]
  ! grep -Eq -- 'BEGIN (PRIVATE|PUBLIC) KEY|receipt=[A-Za-z0-9_-]+' "$err"
}

@test "receipt list appends one final compact record after messages and result" {
  sql_event opaque/a alice bob first 2026-01-01T00:00:02Z
  sql_event opaque/b carol bob second 2026-01-01T00:00:03Z
  local before output token payload
  before="$(durable_state)"
  run storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt
  [ "$status" -eq 0 ]
  output="$output"
  [ "$(printf '%s\n' "$output" | jq -r '.type' | paste -sd, -)" = \
    message_sent,message_sent,bounded_unread_result,bounded_unread_receipt ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "$(printf '%s\n' "$output" | tail -1 | jq -c .)" ]
  [ "$(receipt_record "$output" | jq -r '.receipt_version,.selected_count' | paste -sd: -)" = 1:2 ]
  token="$(receipt_token "$output")"
  [ "${#token}" -le 2048 ]
  [[ "$token" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]
  decode_receipt "$token"
  payload="$RECEIPT_PAYLOAD"
  [ "$(printf '%s\n' "$payload" | sed -n '1p;2p;7p' | paste -sd: -)" = v=1:driver=sqlite:selected_count=2 ]
  [ "$(printf '%s\n' "$payload" | tail -1)" != '' ]
  [ "$(durable_state)" = "$before" ]
}

@test "empty receipt list emits the unchanged result and no receipt" {
  local before
  before="$(durable_state)"
  run storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.type')" = bounded_unread_result ]
  [ "$(printf '%s\n' "$output" | jq -r '.selected_count')" = 0 ]
  [ "$(durable_state)" = "$before" ]
}

@test "receipt show issues only for the current first unread row" {
  sql_event first-id alice bob first 2026-01-01T00:00:00Z
  sql_event later-id alice bob later 2026-01-01T00:00:01Z
  run storage_get_message_bounded receipts bob first-id --max-body-bytes 4096 --issue-receipt
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.type' | paste -sd, -)" = message_sent,bounded_unread_receipt ]
  [ "$(receipt_record "$output" | jq -r '.selected_count')" = 1 ]
  assert_zero_stdout_failure later-show storage_get_message_bounded receipts bob later-id --max-body-bytes 4096 --issue-receipt

  run storage_get_message_bounded receipts bob later-id --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.id')" = later-id ]
}

@test "receipt payload is canonical, signed, bounded, and binds the 900 second window" {
  sql_event id-a alice bob body-a 2026-01-01T00:00:05Z
  local output record token issued expires lines
  output="$(storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 --issue-receipt)"
  record="$(receipt_record "$output")"
  token="$(printf '%s' "$record" | jq -r '.receipt')"
  issued="$(printf '%s' "$record" | jq -r '.issued_at')"
  expires="$(printf '%s' "$record" | jq -r '.expires_at')"
  [ "$expires" -eq $((issued + 900)) ]
  [ "${#token}" -le 2048 ]
  decode_receipt "$token"
  lines="$(printf '%s\n' "$RECEIPT_PAYLOAD" | wc -l | tr -d ' ')"
  [ "$lines" -eq 14 ]
  printf '%s\n' "$RECEIPT_PAYLOAD" | grep -Eq '^store_generation=[0-9a-f]{32}$'
  printf '%s\n' "$RECEIPT_PAYLOAD" | grep -Eq '^key_sha256=[0-9a-f]{64}$'
  printf '%s\n' "$RECEIPT_PAYLOAD" | grep -Eq '^team_hex=[0-9a-f]+$'
  printf '%s\n' "$RECEIPT_PAYLOAD" | grep -Eq '^recipient_hex=[0-9a-f]+$'
  printf '%s\n' "$RECEIPT_PAYLOAD" | grep -Eq '^batch_sha256=[0-9a-f]{64}$'
  printf '%s\n' "$RECEIPT_PAYLOAD" | grep -Eq '^frame_sha256=[0-9a-f]{64}$'
  printf '%s\n' "$RECEIPT_PAYLOAD" | grep -Eq '^issuance_frontier=[0-9]+$'
  printf '%s\n' "$RECEIPT_PAYLOAD" | grep -Eq '^nonce=[0-9a-f]{32}$'
  [ "$(printf '%s\n' "$RECEIPT_PAYLOAD" | cut -d= -f1 | paste -sd, -)" = \
    v,driver,store_generation,key_sha256,team_hex,recipient_hex,selected_count,batch_sha256,frame_sha256,issuance_frontier,issued_at,expires_at,nonce ]
}

@test "receipt binds opaque IDs and raw bodies only through canonical digests" {
  local opaque='opaque/id:秘密?x=1' body='private-body-sentinel-91bc4e72' output token
  sql_event "$opaque" alice bob "$body" 2026-01-01T00:00:00Z
  output="$(storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 --issue-receipt)"
  token="$(receipt_token "$output")"
  decode_receipt "$token"
  [[ "$output" == *"$opaque"* ]]
  [[ "$output" == *"$body"* ]]
  [[ "$RECEIPT_PAYLOAD" != *"$opaque"* ]]
  [[ "$RECEIPT_PAYLOAD" != *"$body"* ]]
  [[ "$token" != *"$opaque"* ]]
  [[ "$token" != *"$body"* ]]
}

@test "receipt token and completed-record caps fail before any stdout" {
  local long_recipient
  sql_event baseline-cap alice bob baseline 2025-12-31T23:59:59Z
  run storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 --issue-receipt
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r '.type')" = bounded_unread_receipt ]
  long_recipient="$(printf '%1800s' '' | tr ' ' r)"
  sql_event token-cap alice "$long_recipient" body 2026-01-01T00:00:00Z
  assert_zero_stdout_failure token-cap storage_list_unread_bounded receipts "$long_recipient" --limit-items 1 --max-body-bytes 4096 --issue-receipt

  sql_event record-cap alice bob body 2026-01-01T00:00:01Z
  export AGMSG_BOUNDED_MAX_RECORD_BYTES=256
  assert_zero_stdout_failure record-cap storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 --issue-receipt
}

@test "signing, key, and claim failures emit zero stdout and do not mutate read state" {
  sql_event guarded-id alice bob guarded-body 2026-01-01T00:00:00Z
  local before wrapper
  run storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 --issue-receipt
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r '.type')" = bounded_unread_receipt ]
  before="$(durable_state)"
  wrapper="$BATS_TEST_TMPDIR/openssl-refuse-receipt-sign"
  cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' pkeyutl -sign '*'receipt-v1/private.pem'*) exit 71 ;;
esac
exec "$REAL_RECEIPT_OPENSSL" "$@"
SH
  chmod 755 "$wrapper"
  export REAL_RECEIPT_OPENSSL="$(command -v openssl)"
  export AGMSG_RECEIPT_OPENSSL="$wrapper"
  assert_zero_stdout_failure sign-failure storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 --issue-receipt
  [ "$(durable_state)" = "$before" ]

  unset AGMSG_RECEIPT_OPENSSL AGMSG_RECEIPT_OPENSSL_RESOLVED AGMSG_RECEIPT_XXD_RESOLVED
  chmod 644 "$(receipt_private_key)"
  assert_zero_stdout_failure key-failure storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 --issue-receipt
  chmod 600 "$(receipt_private_key)"
  sqlite3 "$(agmsg_db_path receipts)" 'CREATE TABLE claims(id INTEGER);'
  before="$(durable_state)"
  assert_zero_stdout_failure claim-failure storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 --issue-receipt
  [ "$(durable_state)" = "$before" ]
}

@test "duplicate and malformed snapshot rows fail before stdout" {
  sql_event duplicate alice bob first 2026-01-01T00:00:00Z
  run storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 --issue-receipt
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r '.type')" = bounded_unread_receipt ]
  sql_event duplicate carol bob second 2026-01-01T00:00:01Z
  assert_zero_stdout_failure duplicate storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt

  sqlite3 "$(agmsg_db_path receipts)" "DELETE FROM events WHERE type='message_sent';
    INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    VALUES('message_sent','malformed','receipts',NULL,'bob','body','2026-01-01T00:00:00Z');" >/dev/null
  assert_zero_stdout_failure malformed storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt
}

@test "receipt snapshot preserves total order and its issuance frontier ignores later append" {
  sql_event later alice bob later 2026-01-01T00:00:03Z
  sql_event early alice bob early 2026-01-01T00:00:00Z
  sql_event tie-a alice bob tie-a 2026-01-01T00:00:01Z
  sql_event tie-b alice bob tie-b 2026-01-01T00:00:01Z
  local output token frontier old_frontier
  old_frontier="$(sqlite3 "$(agmsg_db_path receipts)" "SELECT seq FROM sqlite_sequence WHERE name='events';")"
  output="$(storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt)"
  [ "$(printf '%s\n' "$output" | jq -r 'select(.type=="message_sent") | .id' | paste -sd, -)" = early,tie-a,tie-b,later ]
  token="$(receipt_token "$output")"
  decode_receipt "$token"
  frontier="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^issuance_frontier=//p')"
  [ "$frontier" = "$old_frontier" ]
  sql_event appended alice bob appended 2026-01-01T00:00:04Z
  [ "$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^issuance_frontier=//p')" = "$old_frontier" ]
}

@test "ordinary bounded paths remain byte-for-byte unchanged and do not require receipt state" {
  sql_event ordinary alice bob ordinary-body 2026-01-01T00:00:00Z
  local before after
  before="$(storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096)"
  rm -rf "$(receipt_dir)"
  sqlite3 "$(agmsg_db_path receipts)" 'DROP TABLE receipt_nonces; DROP TABLE receipt_meta;'
  after="$(storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096)"
  [ "$after" = "$before" ]
}

# Task 4 remains intentionally RED until its own TDD cycle; Task 3 runs use
# `--negative-filter 'Task 4'` so issuance cannot be made green by a placeholder.
@test "Task 4 acknowledgement remains RED only because the ack operation is missing" {
  declare -F storage_ack_receipt >/dev/null || {
    printf 'missing optional receipt acknowledgement function: storage_ack_receipt\n' >&2
    return 1
  }
  storage_ack_receipt receipts bob --receipt not-a-token
}
