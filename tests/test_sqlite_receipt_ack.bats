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

fixture_field() {
  local section="$1" field="$2"
  awk -v section="[$section]" -v field="$field" '
    $0 == section { active=1; next }
    active && /^\[/ { exit }
    active && index($0, field "=") == 1 {
      print substr($0, length(field) + 2); exit
    }
  ' "$BATS_TEST_DIRNAME/fixtures/receipt-v1-vectors.txt"
}

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
  case "$token" in
    *[!A-Za-z0-9_.-]*|.*|*.|*.*.*) return 1 ;;
    *.*) ;;
    *) return 1 ;;
  esac
  decode_receipt "$token"
  payload="$RECEIPT_PAYLOAD"
  [ "$(printf '%s\n' "$payload" | sed -n '1p;2p;7p' | paste -sd: -)" = v=1:driver=sqlite:selected_count=2 ]
  [ "$(printf '%s\n' "$payload" | tail -1)" != '' ]
  [ "$(durable_state)" = "$before" ]
}

@test "receipt selection honors the existing item and cumulative body bounds" {
  sql_event bounded-a alice bob aa 2026-01-01T00:00:00Z
  sql_event bounded-b alice bob bbb 2026-01-01T00:00:01Z
  sql_event bounded-c alice bob c 2026-01-01T00:00:02Z
  run storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4 --issue-receipt
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r 'select(.type=="message_sent") | .id')" = bounded-a ]
  [ "$(printf '%s\n' "$output" | jq -r 'select(.type=="bounded_unread_result") | [.selected_count,.selected_body_bytes,.remaining_count,.remaining_body_bytes] | join(":")')" = 1:2:2:4 ]
  [ "$(receipt_record "$output" | jq -r '.selected_count')" = 1 ]

  run storage_list_unread_bounded receipts bob --limit-items 2 --max-body-bytes 4096 --issue-receipt
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r 'select(.type=="message_sent") | .id' | paste -sd, -)" = bounded-a,bounded-b ]
  [ "$(receipt_record "$output" | jq -r '.selected_count')" = 2 ]
}

@test "empty receipt list emits the unchanged result and no receipt" {
  local before ordinary
  before="$(durable_state)"
  ordinary="$(storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096)"
  run storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt
  [ "$status" -eq 0 ]
  [ "$output" = "$ordinary" ]
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
  [ "$lines" -eq 13 ]
  [ "$(tail -c 1 "$BATS_TEST_TMPDIR/payload.bin" | od -An -tu1 | tr -d ' ')" = 10 ]
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

@test "the shared canonicalizer matches fixed frame and payload vectors and hashes each raw body independently" {
  agmsg_receipt_resolve_runtime
  local rows="$BATS_TEST_TMPDIR/vector.rows" frame="$BATS_TEST_TMPDIR/frame"
  local payload="$BATS_TEST_TMPDIR/payload" batch_rows="$BATS_TEST_TMPDIR/batch.rows"
  local batch="$BATS_TEST_TMPDIR/batch" expected="$BATS_TEST_TMPDIR/batch.expected" vector
  printf '0|7465616d2d61|616c696365|626f62|323032362d30312d30325430333a30343a30355a|event|42|61|78\n' >"$rows"
  _agmsg_receipt_canonicalize frame "$rows" "$frame"
  [ "$(xxd -p -c 1000000 "$frame" | tr -d '\n')" = "$(fixture_field frame-payload-base material_hex)" ]
  _agmsg_receipt_canonicalize payload "$payload" \
    0123456789abcdef0123456789abcdef \
    abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789 \
    7465616d2d61 626f62 1 \
    "$(fixture_field batch-base sha256)" "$(fixture_field frame-payload-base sha256)" \
    42 1700000000 1700000900 00112233445566778899aabbccddeeff
  [ "$(xxd -p -c 1000000 "$payload" | tr -d '\n')" = "$(fixture_field payload-base material_hex)" ]

  for vector in batch-base batch-id-boundary batch-id-changed batch-body-changed; do
    printf '0|74|61|72|323032362d30312d30325430333a30343a30355a|event|7|%s|%s\n' \
      "$(fixture_field "$vector" input_id_hex)" \
      "$(fixture_field "$vector" input_body_hex)" >"$batch_rows"
    _agmsg_receipt_canonicalize batch "$batch_rows" "$batch"
    [ "$(xxd -p -c 1000000 "$batch" | tr -d '\n')" = "$(fixture_field "$vector" material_hex)" ]
    [ "$(shasum -a 256 "$batch" | awk '{print $1}')" = "$(fixture_field "$vector" sha256)" ]
  done

  printf '0|74|61|72|323032362d30312d30325430333a30343a30355a|event|7|696431|6162636465666768\n1|74|61|72|323032362d30312d30325430333a30343a30365a|event|8|696432|78\n' >"$batch_rows"
  _agmsg_receipt_canonicalize batch "$batch_rows" "$batch"
  {
    printf 'agmsg-batch-v1\n'
    printf 'id_len=3\nid_hex=696431\nbody_sha256=%s\n' "$(printf abcdefgh | shasum -a 256 | awk '{print $1}')"
    printf 'id_len=3\nid_hex=696432\nbody_sha256=%s\n' "$(printf x | shasum -a 256 | awk '{print $1}')"
  } >"$expected"
  cmp -s "$batch" "$expected"
}

@test "receipt binds opaque IDs and raw bodies only through canonical digests" {
  local opaque='opaque/id:秘密?x=1' body='private-body-sentinel-91bc4e72' output token wrapper
  sql_event "$opaque" alice bob "$body" 2026-01-01T00:00:00Z
  wrapper="$BATS_TEST_TMPDIR/openssl-argv-log"
  cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RECEIPT_ARGV_LOG"
exec "$REAL_RECEIPT_OPENSSL" "$@"
SH
  chmod 755 "$wrapper"
  export REAL_RECEIPT_OPENSSL="$(command -v openssl)"
  export RECEIPT_ARGV_LOG="$BATS_TEST_TMPDIR/openssl.argv"
  export AGMSG_RECEIPT_OPENSSL="$wrapper"
  output="$(storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 --issue-receipt)"
  token="$(receipt_token "$output")"
  decode_receipt "$token"
  printf '%s' "$output" | grep -Fq -- "$opaque"
  printf '%s' "$output" | grep -Fq -- "$body"
  refute grep -Fq -- "$opaque" <<<"$RECEIPT_PAYLOAD"
  refute grep -Fq -- "$body" <<<"$RECEIPT_PAYLOAD"
  refute grep -Fq -- "$opaque" <<<"$token"
  refute grep -Fq -- "$body" <<<"$token"
  refute grep -Fq -- "$opaque" "$RECEIPT_ARGV_LOG"
  refute grep -Fq -- "$body" "$RECEIPT_ARGV_LOG"
}

@test "receipt show keeps its opaque selector out of sqlite3 process arguments" {
  local opaque='opaque/show:秘密?private=1' wrapper_dir="$BATS_TEST_TMPDIR/sqlite-wrapper"
  sql_event "$opaque" alice bob body 2026-01-01T00:00:00Z
  mkdir "$wrapper_dir"
  export REAL_RECEIPT_SQLITE="$(command -v sqlite3)"
  export RECEIPT_SQLITE_ARGV_LOG="$BATS_TEST_TMPDIR/sqlite.argv"
  cat >"$wrapper_dir/sqlite3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RECEIPT_SQLITE_ARGV_LOG"
exec "$REAL_RECEIPT_SQLITE" "$@"
SH
  chmod 755 "$wrapper_dir/sqlite3"
  PATH="$wrapper_dir:$PATH"
  export PATH
  run storage_get_message_bounded receipts bob "$opaque" --max-body-bytes 4096 --issue-receipt
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n '1p' | jq -r '.id')" = "$opaque" ]
  refute grep -Fq -- "$opaque" "$RECEIPT_SQLITE_ARGV_LOG"
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

@test "a base64 encoder that prints a valid-looking prefix then fails cannot issue a receipt" {
  sql_event base64-failure alice bob body 2026-01-01T00:00:00Z
  local before wrapper="$BATS_TEST_TMPDIR/openssl-base64-partial" secret='base64-secret-stderr-91bc4e72'
  before="$(durable_state)"
  cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = base64 ]; then
  printf '%s' YWJj
  printf '%s\n' "$BASE64_FAILURE_SECRET" >&2
  exit 71
fi
exec "$REAL_RECEIPT_OPENSSL" "$@"
SH
  chmod 755 "$wrapper"
  export REAL_RECEIPT_OPENSSL="$(command -v openssl)"
  export BASE64_FAILURE_SECRET="$secret"
  export AGMSG_RECEIPT_OPENSSL="$wrapper"
  assert_zero_stdout_failure base64-partial storage_list_unread_bounded receipts bob \
    --limit-items 1 --max-body-bytes 4096 --issue-receipt
  refute grep -Fq -- "$secret" "$BATS_TEST_TMPDIR/base64-partial.stderr"
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

@test "same-timestamp legacy and event rows bind source-kind and ordinal total order into the frame digest" {
  local db at=2026-01-01T00:00:00Z output token actual expected_file
  db="$(agmsg_db_path receipts)"
  sqlite3 "$db" "
    INSERT INTO messages(id,team,from_agent,to_agent,body,created_at)
      VALUES(101,'receipts','legacy-a','bob','legacy-body-a','$at');
    INSERT INTO messages(id,team,from_agent,to_agent,body,created_at)
      VALUES(102,'receipts','legacy-b','bob','legacy-body-b','$at');
    INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
      VALUES('message_sent','event-a','receipts','event-a-sender','bob','event-body-a','$at');
    INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
      VALUES('message_sent','event-b','receipts','event-b-sender','bob','event-body-b','$at');" >/dev/null
  output="$(storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt)"
  [ "$(printf '%s\n' "$output" | jq -r 'select(.type=="message_sent") | .id' | paste -sd, -)" = 101,102,event-a,event-b ]
  token="$(receipt_token "$output")"
  decode_receipt "$token"
  actual="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^frame_sha256=//p')"
  expected_file="$BATS_TEST_TMPDIR/expected-source-order.frame"
  {
    printf 'agmsg-frame-v1\n'
    printf 'index=0\nteam_len=8\nteam_hex=7265636569707473\nfrom_len=8\nfrom_hex=6c65676163792d61\nto_len=3\nto_hex=626f62\nat_len=20\nat_hex=323032362d30312d30315430303a30303a30305a\nsource=legacy\nsource_ord=101\n'
    printf 'index=1\nteam_len=8\nteam_hex=7265636569707473\nfrom_len=8\nfrom_hex=6c65676163792d62\nto_len=3\nto_hex=626f62\nat_len=20\nat_hex=323032362d30312d30315430303a30303a30305a\nsource=legacy\nsource_ord=102\n'
    printf 'index=2\nteam_len=8\nteam_hex=7265636569707473\nfrom_len=14\nfrom_hex=6576656e742d612d73656e646572\nto_len=3\nto_hex=626f62\nat_len=20\nat_hex=323032362d30312d30315430303a30303a30305a\nsource=event\nsource_ord=1\n'
    printf 'index=3\nteam_len=8\nteam_hex=7265636569707473\nfrom_len=14\nfrom_hex=6576656e742d622d73656e646572\nto_len=3\nto_hex=626f62\nat_len=20\nat_hex=323032362d30312d30315430303a30303a30305a\nsource=event\nsource_ord=2\n'
  } >"$expected_file"
  [ "$actual" = "$(shasum -a 256 "$expected_file" | awk '{print $1}')" ]
}

@test "public records and private receipt material come from one SQLite snapshot" {
  sql_event snapshot-a alice bob before-a 2026-01-01T00:00:00Z
  sql_event snapshot-b alice bob before-b 2026-01-01T00:00:01Z
  export SNAPSHOT_DB="$(agmsg_db_path receipts)"
  export SNAPSHOT_MARKER="$BATS_TEST_TMPDIR/snapshot-query-complete"
  agmsg_sqlite() {
    local joined="$*" rc
    command sqlite3 "$@"
    rc=$?
    if [ "$rc" -eq 0 ] && [[ "$joined" == *'__agmsg_receipt_meta|'* ]] &&
       [ ! -e "$SNAPSHOT_MARKER" ]; then
      : >"$SNAPSHOT_MARKER"
      command sqlite3 "$SNAPSHOT_DB" "
        INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
        VALUES('message_sent','snapshot-concurrent','receipts','alice','bob',
               'after-query','2026-01-01T00:00:02Z');" >/dev/null
    fi
    return "$rc"
  }

  local output token frontier
  output="$(storage_list_unread_bounded receipts bob --limit-items 10 --max-body-bytes 4096 --issue-receipt)"
  [ -e "$SNAPSHOT_MARKER" ]
  [ "$(printf '%s\n' "$output" | jq -r 'select(.type=="message_sent") | .id' | paste -sd, -)" = snapshot-a,snapshot-b ]
  [ "$(receipt_record "$output" | jq -r '.selected_count')" = 2 ]
  token="$(receipt_token "$output")"
  decode_receipt "$token"
  frontier="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^issuance_frontier=//p')"
  [ "$frontier" -lt "$(sqlite3 "$SNAPSHOT_DB" "SELECT seq FROM sqlite_sequence WHERE name='events';")" ]
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
