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

assert_internal_receipt_failure() {
  local name="$1"
  shift
  assert_zero_stdout_failure "$name" "$@"
  [ "$(cat "$BATS_TEST_TMPDIR/$name.stderr")" = \
    'agmsg receipt: cannot construct receipt' ]
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

@test "a scope encoder that prints valid hex then fails cannot issue a receipt" {
  local opaque='opaque/scope-id:private-91bc4e72' body='scope-body-private-91bc4e72'
  local before wrapper="$BATS_TEST_TMPDIR/xxd-scope-partial" secret='xxd-secret-stderr-91bc4e72'
  sql_event "$opaque" alice bob "$body" 2026-01-01T00:00:00Z
  before="$(durable_state)"
  cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 3 ] && [ "${1:-}" = -p ] && [ "${2:-}" = -c ] &&
   [ "${3:-}" = 1000000 ]; then
  printf '%s' 61
  printf '%s\n' "$SCOPE_FAILURE_SECRET" >&2
  exit 71
fi
exec "$REAL_RECEIPT_XXD" "$@"
SH
  chmod 755 "$wrapper"
  export REAL_RECEIPT_XXD="$(command -v xxd)"
  export SCOPE_FAILURE_SECRET="$secret"
  export AGMSG_RECEIPT_XXD="$wrapper"
  assert_internal_receipt_failure xxd-partial storage_list_unread_bounded receipts bob \
    --limit-items 1 --max-body-bytes 4096 --issue-receipt
  refute grep -Fq -- "$secret" "$BATS_TEST_TMPDIR/xxd-partial.stderr"
  refute grep -Fq -- "$opaque" "$BATS_TEST_TMPDIR/xxd-partial.stderr"
  refute grep -Fq -- "$body" "$BATS_TEST_TMPDIR/xxd-partial.stderr"
  [ "$(durable_state)" = "$before" ]
}

@test "nonce and hash failures emit one bounded non-sensitive internal diagnostic" {
  local before wrapper="$BATS_TEST_TMPDIR/openssl-internal-failure"
  local secret='openssl-internal-secret-91bc4e72'
  sql_event internal-failure alice bob internal-body 2026-01-01T00:00:00Z
  before="$(durable_state)"
  cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
case "${INTERNAL_FAILURE_MODE:-}: $* " in
  'rand: rand -hex 16 ')
    printf '%s' 00112233445566778899aabbccddeeff
    printf '%s\n' "$INTERNAL_FAILURE_SECRET" >&2
    exit 71
    ;;
  hash:*' dgst -sha256 -r '*'agmsg-receipt-issue.'*)
    printf '%s  ignored\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    printf '%s\n' "$INTERNAL_FAILURE_SECRET" >&2
    exit 71
    ;;
esac
exec "$REAL_RECEIPT_OPENSSL" "$@"
SH
  chmod 755 "$wrapper"
  export REAL_RECEIPT_OPENSSL="$(command -v openssl)"
  export INTERNAL_FAILURE_SECRET="$secret"
  export AGMSG_RECEIPT_OPENSSL="$wrapper"

  export INTERNAL_FAILURE_MODE=rand
  assert_internal_receipt_failure rand-failure storage_list_unread_bounded receipts bob \
    --limit-items 1 --max-body-bytes 4096 --issue-receipt
  refute grep -Fq -- "$secret" "$BATS_TEST_TMPDIR/rand-failure.stderr"
  [ "$(durable_state)" = "$before" ]

  export INTERNAL_FAILURE_MODE=hash
  assert_internal_receipt_failure hash-failure storage_list_unread_bounded receipts bob \
    --limit-items 1 --max-body-bytes 4096 --issue-receipt
  refute grep -Fq -- "$secret" "$BATS_TEST_TMPDIR/hash-failure.stderr"
  [ "$(durable_state)" = "$before" ]
}

@test "canonical payload and token syntax failures use the internal diagnostic" {
  local snapshot wrapper="$BATS_TEST_TMPDIR/openssl-invalid-base64"
  agmsg_receipt_resolve_runtime
  snapshot='{"type":"bounded_unread_result","selected_count":1,"selected_body_bytes":1,"remaining_count":0,"remaining_body_bytes":0,"limit_items":1,"max_body_bytes":4096}
__agmsg_receipt_meta|not-a-generation|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|1|1
__agmsg_receipt_row|0|7265636569707473|616c696365|626f62|323032362d30312d30315430303a30303a30305a|event|1|6964|78'
  printf '%s\n' "$snapshot" | assert_internal_receipt_failure payload-syntax \
    _agmsg_receipt_issue_stream receipts bob

  sql_event token-syntax alice bob body 2026-01-01T00:00:00Z
  cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = base64 ]; then
  printf '%s' '***'
  exit 0
fi
exec "$REAL_RECEIPT_OPENSSL" "$@"
SH
  chmod 755 "$wrapper"
  export REAL_RECEIPT_OPENSSL="$(command -v openssl)"
  export AGMSG_RECEIPT_OPENSSL="$wrapper"
  assert_internal_receipt_failure token-syntax storage_list_unread_bounded receipts bob \
    --limit-items 1 --max-body-bytes 4096 --issue-receipt
  refute grep -Fq -- '***' "$BATS_TEST_TMPDIR/token-syntax.stderr"
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

ack_abi_required() {
  declare -F storage_ack_receipt >/dev/null || {
    printf 'missing optional receipt acknowledgement function: storage_ack_receipt\n' >&2
    return 1
  }
}

issue_list_token() {
  local output
  output="$(storage_list_unread_bounded receipts "$1" --limit-items "${2:-10}" \
    --max-body-bytes 4096 --issue-receipt)" || return $?
  receipt_token "$output"
}

base64url_encode_file() {
  openssl base64 -A -in "$1" | tr '+/' '-_' | tr -d '='
}

resign_receipt_field() {
  local token="$1" field="$2" value="$3" payload_part signature_part
  payload_part="${token%%.*}"; signature_part="${token#*.}"
  base64url_decode_to "$payload_part" "$BATS_TEST_TMPDIR/resign.in"
  awk -F= -v field="$field" -v value="$value" \
    '$1 == field {$0=field "=" value} {print}' "$BATS_TEST_TMPDIR/resign.in" \
    >"$BATS_TEST_TMPDIR/resign.payload"
  openssl pkeyutl -sign -rawin -inkey "$(receipt_private_key)" \
    -in "$BATS_TEST_TMPDIR/resign.payload" -out "$BATS_TEST_TMPDIR/resign.sig"
  printf '%s.%s\n' \
    "$(base64url_encode_file "$BATS_TEST_TMPDIR/resign.payload")" \
    "$(base64url_encode_file "$BATS_TEST_TMPDIR/resign.sig")"
}

resign_receipt_times() {
  local token="$1" issued="$2" expires="$3" payload_part
  payload_part="${token%%.*}"
  base64url_decode_to "$payload_part" "$BATS_TEST_TMPDIR/resign.in"
  awk -F= -v issued="$issued" -v expires="$expires" '
    $1 == "issued_at" {$0="issued_at=" issued}
    $1 == "expires_at" {$0="expires_at=" expires}
    {print}
  ' "$BATS_TEST_TMPDIR/resign.in" >"$BATS_TEST_TMPDIR/resign.payload"
  openssl pkeyutl -sign -rawin -inkey "$(receipt_private_key)" \
    -in "$BATS_TEST_TMPDIR/resign.payload" -out "$BATS_TEST_TMPDIR/resign.sig"
  printf '%s.%s\n' \
    "$(base64url_encode_file "$BATS_TEST_TMPDIR/resign.payload")" \
    "$(base64url_encode_file "$BATS_TEST_TMPDIR/resign.sig")"
}

forge_receipt_signature() {
  local token="$1" payload_part signature_part first replacement
  payload_part="${token%%.*}"; signature_part="${token#*.}"
  base64url_decode_to "$signature_part" "$BATS_TEST_TMPDIR/forge.sig"
  first="$(xxd -p -l 1 "$BATS_TEST_TMPDIR/forge.sig")"
  [ "$first" = 00 ] && replacement=01 || replacement=00
  printf '%s' "$replacement" | xxd -r -p >"$BATS_TEST_TMPDIR/forge.new"
  tail -c +2 "$BATS_TEST_TMPDIR/forge.sig" >>"$BATS_TEST_TMPDIR/forge.new"
  printf '%s.%s\n' "$payload_part" "$(base64url_encode_file "$BATS_TEST_TMPDIR/forge.new")"
}

ack_failure_text() {
  local name="$1" recipient="$2" token="$3"
  ack_abi_required
  assert_zero_stdout_failure "$name" storage_ack_receipt receipts "$recipient" --receipt "$token"
  cat "$BATS_TEST_TMPDIR/$name.stderr"
}

@test "Task 4 commits one exact prefix and an exact retained retry is already_committed" {
  ack_abi_required
  sql_event ack-a alice bob first 2026-01-01T00:00:00Z
  sql_event ack-b carol bob second 2026-01-01T00:00:01Z
  local token frontier nonce payload_sha generation team_sha recipient_sha batch_sha frame_sha expires
  token="$(issue_list_token bob)"
  decode_receipt "$token"
  frontier="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^issuance_frontier=//p')"
  nonce="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^nonce=//p')"
  generation="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^store_generation=//p')"
  batch_sha="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^batch_sha256=//p')"
  frame_sha="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^frame_sha256=//p')"
  expires="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^expires_at=//p')"
  payload_sha="$(shasum -a 256 "$BATS_TEST_TMPDIR/payload.bin" | awk '{print $1}')"
  team_sha="$(printf receipts | shasum -a 256 | awk '{print $1}')"
  recipient_sha="$(printf bob | shasum -a 256 | awk '{print $1}')"
  run storage_ack_receipt receipts bob --receipt "$token"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(sqlite3 "$(agmsg_db_path receipts)" "SELECT COUNT(*) FROM receipt_nonces;")" = 1 ]
  [ "$(sqlite3 "$(agmsg_db_path receipts)" "SELECT payload_sha256||':'||store_generation||':'||team_sha256||':'||recipient_sha256||':'||batch_sha256||':'||frame_sha256||':'||expires_at FROM receipt_nonces WHERE nonce='$nonce';")" = \
    "$payload_sha:$generation:$team_sha:$recipient_sha:$batch_sha:$frame_sha:$expires" ]
  [ "$(sqlite3 "$(agmsg_db_path receipts)" "SELECT COUNT(*) FROM events WHERE type='message_read' AND team='receipts' AND agent='bob';")" = 2 ]
  [ "$(sqlite3 "$(agmsg_db_path receipts)" "SELECT group_concat(id,',') FROM (SELECT id FROM events WHERE type='message_read' ORDER BY seq);")" = \
    "receipt-v1:$nonce:0,receipt-v1:$nonce:1" ]
  [ "$(sqlite3 "$(agmsg_db_path receipts)" "SELECT local_position FROM read_cursors WHERE team='receipts' AND agent='bob';")" = "$frontier" ]
  local retry_text
  retry_text="$(ack_failure_text retained-retry bob "$token")"
  [ "$retry_text" = 'agmsg receipt: already_committed' ] || {
    printf 'unexpected retry diagnostic: %s\n' "$retry_text" >&2
    return 1
  }
}

@test "Task 4 rejects malformed forged wrong-scope and sender-as-recipient tokens without mutation" {
  ack_abi_required
  sql_event scoped alice bob body 2026-01-01T00:00:00Z
  local token before forged wrong_scope
  token="$(issue_list_token bob)"; before="$(durable_state)"
  [ "$(ack_failure_text malformed bob not-a-token)" = 'agmsg receipt: invalid receipt' ]
  forged="$(forge_receipt_signature "$token")"
  [ "$(ack_failure_text forged bob "$forged")" = 'agmsg receipt: invalid receipt signature' ]
  wrong_scope="$(resign_receipt_field "$token" recipient_hex "$(hex_of carol)")"
  [ "$(ack_failure_text wrong-scope bob "$wrong_scope")" = 'agmsg receipt: receipt scope mismatch' ]
  [ "$(ack_failure_text sender-recipient alice "$token")" = 'agmsg receipt: receipt scope mismatch' ]
  [ "$(durable_state)" = "$before" ]
}

@test "Task 4 authenticates canonical lifetime key generation and store scope before writes" {
  ack_abi_required
  sql_event auth alice bob body 2026-01-01T00:00:00Z
  local token now before changed
  token="$(issue_list_token bob)"; now="$(date +%s)"; before="$(durable_state)"
  changed="$(resign_receipt_times "$token" "$((now - 901))" "$((now - 1))")"
  [ "$(ack_failure_text expired bob "$changed")" = 'agmsg receipt: receipt expired' ]
  changed="$(resign_receipt_times "$token" "$((now + 100))" "$((now + 1000))")"
  [ "$(ack_failure_text future bob "$changed")" = 'agmsg receipt: receipt is not yet valid' ]
  changed="$(resign_receipt_times "$token" "$now" "$((now + 901))")"
  [ "$(ack_failure_text lifetime bob "$changed")" = 'agmsg receipt: invalid receipt' ]
  changed="$(resign_receipt_field "$token" store_generation 11111111111111111111111111111111)"
  [ "$(ack_failure_text generation bob "$changed")" = 'agmsg receipt: receipt store identity mismatch' ]
  changed="$(resign_receipt_field "$token" key_sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
  [ "$(ack_failure_text key bob "$changed")" = 'agmsg receipt: receipt store identity mismatch' ]
  [ "$(durable_state)" = "$before" ]
}

@test "Task 4 refuses late earlier rows prefix gaps and displayed row drift but permits later append" {
  ack_abi_required
  sql_event drift-a alice bob first 2026-01-01T00:00:01Z
  local token before
  token="$(issue_list_token bob 1)"; before="$(durable_state)"
  sql_event later alice bob later 2026-01-01T00:00:02Z
  run storage_ack_receipt receipts bob --receipt "$token"
  [ "$status" -eq 0 ]

  # A fresh recipient proves that a newly inserted earlier row changes the
  # signed prefix instead of being hidden by a later unrelated append.
  sql_event drift-b alice dave first 2026-01-01T00:00:01Z
  token="$(issue_list_token dave 1)"
  sql_event drift-earlier eve dave earlier 2026-01-01T00:00:00Z
  [ "$(ack_failure_text earlier dave "$token")" = 'agmsg receipt: unread prefix changed' ]
  sqlite3 "$(agmsg_db_path receipts)" "DELETE FROM events WHERE id='drift-earlier'; UPDATE events SET body='changed',from_agent='mallory',at='2026-01-01T00:00:09Z' WHERE id='drift-b';"
  [ "$(ack_failure_text drift dave "$token")" = 'agmsg receipt: unread prefix changed' ]
}

@test "Task 4 mirrors exact direct legacy and event-linked rows without decimal id collision" {
  ack_abi_required
  local db token direct_id linked_id
  db="$(agmsg_db_path receipts)"
  sqlite3 "$db" "
    INSERT INTO messages(team,from_agent,to_agent,body,created_at) VALUES('receipts','legacy','bob','direct','2026-01-01T00:00:00Z');
    INSERT INTO messages(team,from_agent,to_agent,body,created_at) VALUES('receipts','event','bob','linked','2026-01-01T00:00:01Z');
    INSERT INTO events(type,id,team,from_agent,to_agent,body,at,legacy_id)
      VALUES('message_sent','event-linked','receipts','event','bob','linked','2026-01-01T00:00:01Z',last_insert_rowid());"
  direct_id="$(sqlite3 "$db" "SELECT id FROM messages WHERE body='direct';")"
  linked_id="$(sqlite3 "$db" "SELECT id FROM messages WHERE body='linked';")"
  token="$(issue_list_token bob)"
  run storage_ack_receipt receipts bob --receipt "$token"
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM messages WHERE id IN ($direct_id,$linked_id) AND read_at IS NOT NULL;")" = 2 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE type='message_read' AND msg_id IN ('$direct_id','event-linked');")" = 2 ]
  sqlite3 "$db" "INSERT INTO events(type,id,team,from_agent,to_agent,body,at) VALUES('message_sent','$direct_id','receipts','x','carol','collision','2026-01-01T00:00:00Z');"
  token="$(issue_list_token carol)"
  [ -n "$token" ]
}

@test "Task 4 claim markers and a busy writer fail closed without partial state" {
  ack_abi_required
  sql_event guarded alice bob body 2026-01-01T00:00:00Z
  local token before locker_rc fifo locker_pid describe_def
  token="$(issue_list_token bob)"; before="$(durable_state)"
  agmsg_claim_next() { :; }
  [ "$(ack_failure_text claim-function bob "$token")" = 'agmsg receipt: message claim capability conflicts with receipt state' ]
  unset -f agmsg_claim_next
  describe_def="$(declare -f storage_describe)"
  storage_describe() { printf 'name=sqlite\nbackend=test\ncapabilities=stage1-sync,message-claim-unknown\n'; }
  [ "$(ack_failure_text claim-token bob "$token")" = 'agmsg receipt: message claim capability conflicts with receipt state' ]
  eval "$describe_def"
  sqlite3 "$(agmsg_db_path receipts)" 'CREATE TABLE claims(id INTEGER);'
  [ "$(ack_failure_text claims bob "$token")" = 'agmsg receipt: message claim capability conflicts with receipt state' ]
  sqlite3 "$(agmsg_db_path receipts)" 'DROP TABLE claims;'
  sqlite3 "$(agmsg_db_path receipts)" 'PRAGMA journal_mode=DELETE;' >/dev/null
  fifo="$BATS_TEST_TMPDIR/sqlite-lock.fifo"; mkfifo "$fifo"
  sqlite3 "$(agmsg_db_path receipts)" <"$fifo" >/dev/null 2>&1 & locker_pid=$!
  exec 9>"$fifo"
  printf 'BEGIN IMMEDIATE;\n' >&9
  sleep 0.2
  assert_zero_stdout_failure busy storage_ack_receipt receipts bob --receipt "$token"
  printf 'ROLLBACK;\n' >&9; exec 9>&-
  wait "$locker_pid" || locker_rc=$?
  [ "${locker_rc:-0}" -eq 0 ]
  [ "$(durable_state)" = "$before" ]
}

@test "Task 4 same-token concurrency commits once in WAL and DELETE modes" {
  ack_abi_required
  local mode db token out1 out2 err1 err2 rc1 rc2 frontier
  for mode in WAL DELETE; do
    db="$(agmsg_db_path receipts)"
    sqlite3 "$db" "PRAGMA journal_mode=$mode; DELETE FROM events WHERE type='message_read'; DELETE FROM read_cursors; DELETE FROM receipt_nonces;" >/dev/null
    sqlite3 "$db" "DELETE FROM events WHERE type='message_sent'; DELETE FROM messages;
      INSERT INTO messages(team,from_agent,to_agent,body,created_at) VALUES('receipts','legacy','bob','direct','2026-01-01T00:00:00Z');
      INSERT INTO messages(team,from_agent,to_agent,body,created_at) VALUES('receipts','linked','bob','linked','2026-01-01T00:00:01Z');
      INSERT INTO events(type,id,team,from_agent,to_agent,body,at,legacy_id)
        VALUES('message_sent','concurrent-$mode','receipts','linked','bob','linked','2026-01-01T00:00:01Z',last_insert_rowid());" >/dev/null
    token="$(issue_list_token bob)"
    decode_receipt "$token"
    frontier="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^issuance_frontier=//p')"
    out1="$BATS_TEST_TMPDIR/$mode.1.out"; out2="$BATS_TEST_TMPDIR/$mode.2.out"
    err1="$BATS_TEST_TMPDIR/$mode.1.err"; err2="$BATS_TEST_TMPDIR/$mode.2.err"
    export RECEIPT_TOKEN_FILE="$BATS_TEST_TMPDIR/$mode.token"
    printf '%s\n' "$token" >"$RECEIPT_TOKEN_FILE"; chmod 600 "$RECEIPT_TOKEN_FILE"
    /bin/bash -c 'source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load; token="$(cat "$RECEIPT_TOKEN_FILE")"; storage_ack_receipt receipts bob --receipt "$token"' >"$out1" 2>"$err1" & local p1=$!
    /bin/bash -c 'source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load; token="$(cat "$RECEIPT_TOKEN_FILE")"; storage_ack_receipt receipts bob --receipt "$token"' >"$out2" 2>"$err2" & local p2=$!
    wait "$p1" || rc1=$?; wait "$p2" || rc2=$?
    [ ! -s "$out1" ] && [ ! -s "$out2" ]
    [ "$(( ${rc1:-0} == 0 ? 1 : 0 ))" -ne "$(( ${rc2:-0} == 0 ? 1 : 0 ))" ]
    local replay_count
    replay_count="$(grep -h -c '^agmsg receipt: already_committed$' "$err1" "$err2" | awk '{s+=$1} END{print s+0}')"
    [ "$replay_count" = 1 ] || {
      printf 'unexpected concurrency diagnostics (%s rc1=%s rc2=%s): one=%s two=%s\n' \
        "$mode" "${rc1:-0}" "${rc2:-0}" "$(cat "$err1")" "$(cat "$err2")" >&2
      return 1
    }
    [ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM receipt_nonces;')" = 1 ]
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 2 ]
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM messages WHERE read_at IS NOT NULL;")" = 2 ]
    [ "$(sqlite3 "$db" "SELECT local_position FROM read_cursors WHERE team='receipts' AND agent='bob';")" = "$frontier" ]
    unset rc1 rc2
  done
}

@test "Task 4 canonical mutation cross-store use and external argv stay fail-closed and private" {
  ack_abi_required
  local opaque='ack/private:id-91bc4e72' body='ack-private-body-91bc4e72'
  local token changed original_path other_path argv wrapper real_sqlite
  sql_event "$opaque" alice bob "$body" 2026-01-01T00:00:00Z
  token="$(issue_list_token bob)"
  changed="$(resign_receipt_field "$token" issuance_frontier 00)"
  [ "$(ack_failure_text noncanonical bob "$changed")" = 'agmsg receipt: invalid receipt' ]

  original_path="$AGMSG_STORAGE_PATH"; other_path="$BATS_TEST_TMPDIR/other-store"
  AGMSG_STORAGE_PATH="$other_path"; export AGMSG_STORAGE_PATH
  storage_init receipts >/dev/null; storage_receipt_init receipts >/dev/null
  assert_zero_stdout_failure cross-store storage_ack_receipt receipts bob --receipt "$token"
  [ "$(sqlite3 "$(agmsg_db_path receipts)" 'SELECT COUNT(*) FROM receipt_nonces;')" = 0 ]
  AGMSG_STORAGE_PATH="$original_path"; export AGMSG_STORAGE_PATH

  wrapper="$BATS_TEST_TMPDIR/sqlite-argv"; argv="$BATS_TEST_TMPDIR/ack.argv"
  real_sqlite="$(command -v sqlite3)"
  cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ACK_ARGV_LOG"
exec "$REAL_ACK_SQLITE" "$@"
SH
  chmod 755 "$wrapper"; export REAL_ACK_SQLITE="$real_sqlite" ACK_ARGV_LOG="$argv"
  PATH="$(dirname "$wrapper"):$PATH"; mv "$wrapper" "$(dirname "$wrapper")/sqlite3"
  run storage_ack_receipt receipts bob --receipt "$token"
  [ "$status" -eq 0 ]
  refute grep -Fq -- "$token" "$argv"
  refute grep -Fq -- "$opaque" "$argv"
  refute grep -Fq -- "$body" "$argv"
}

@test "Task 4 independently binds every displayed field source identity and cursor frontier" {
  ack_abi_required
  local field recipient token db original frontier
  db="$(agmsg_db_path receipts)"
  for field in body from_agent to_agent team at source; do
    recipient="drift-$field"
    sql_event "id-$field" alice "$recipient" original 2026-01-01T00:00:00Z
    token="$(issue_list_token "$recipient")"
    case "$field" in
      body) sqlite3 "$db" "UPDATE events SET body='changed' WHERE id='id-$field';" ;;
      from_agent) sqlite3 "$db" "UPDATE events SET from_agent='mallory' WHERE id='id-$field';" ;;
      to_agent) sqlite3 "$db" "UPDATE events SET to_agent='nobody' WHERE id='id-$field';" ;;
      team) sqlite3 "$db" "UPDATE events SET team='other' WHERE id='id-$field';" ;;
      at) sqlite3 "$db" "UPDATE events SET at='2026-01-01T00:00:01Z' WHERE id='id-$field';" ;;
      source)
        sqlite3 "$db" "DELETE FROM events WHERE id='id-$field';
          INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
          VALUES('message_sent','id-$field','receipts','alice','$recipient','original','2026-01-01T00:00:00Z');"
        ;;
    esac
    assert_zero_stdout_failure "drift-$field" storage_ack_receipt receipts "$recipient" --receipt "$token"
  done

  sql_event cursor-a alice cursor-user first 2026-01-01T00:00:00Z
  token="$(issue_list_token cursor-user)"; decode_receipt "$token"
  frontier="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^issuance_frontier=//p')"
  sql_event unrelated alice someone-else later 2026-01-01T00:00:01Z
  run storage_ack_receipt receipts cursor-user --receipt "$token"
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT local_position FROM read_cursors WHERE team='receipts' AND agent='cursor-user';")" = "$frontier" ]
}

@test "Task 4 all write-stage faults including failed prune roll back nonce read legacy and cursor" {
  ack_abi_required
  local db token before stage trigger_sql now old
  db="$(agmsg_db_path receipts)"
  for stage in nonce read legacy cursor; do
    sqlite3 "$db" "DELETE FROM events; DELETE FROM messages; DELETE FROM read_cursors; DELETE FROM receipt_nonces;
      INSERT INTO messages(team,from_agent,to_agent,body,created_at) VALUES('receipts','legacy','bob','body','2026-01-01T00:00:00Z');"
    token="$(issue_list_token bob)"; before="$(durable_state)"
    case "$stage" in
      nonce) trigger_sql="CREATE TRIGGER fault BEFORE INSERT ON receipt_nonces BEGIN SELECT RAISE(ABORT,'fault'); END;" ;;
      read) trigger_sql="CREATE TRIGGER fault BEFORE INSERT ON events WHEN NEW.type='message_read' BEGIN SELECT RAISE(ABORT,'fault'); END;" ;;
      legacy) trigger_sql="CREATE TRIGGER fault BEFORE UPDATE ON messages BEGIN SELECT RAISE(ABORT,'fault'); END;" ;;
      cursor) trigger_sql="CREATE TRIGGER fault BEFORE INSERT ON read_cursors BEGIN SELECT RAISE(ABORT,'fault'); END;" ;;
    esac
    sqlite3 "$db" "$trigger_sql"
    assert_zero_stdout_failure "fault-$stage" storage_ack_receipt receipts bob --receipt "$token"
    sqlite3 "$db" 'DROP TRIGGER fault;'
    [ "$(durable_state)" = "$before" ]
  done

  now="$(date +%s)"; old=$((now - 90000))
  sqlite3 "$db" "INSERT INTO receipt_nonces VALUES('eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',$old,$old);
    CREATE TRIGGER fault BEFORE INSERT ON events WHEN NEW.type='message_read' BEGIN SELECT RAISE(ABORT,'fault'); END;"
  assert_zero_stdout_failure failed-prune storage_ack_receipt receipts bob --receipt "$token"
  sqlite3 "$db" 'DROP TRIGGER fault;'
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM receipt_nonces WHERE nonce='eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';")" = 1 ]
}

@test "Task 4 ack uses the complete closed claim-marker grammar" {
  ack_abi_required
  sql_event claims-matrix alice bob body 2026-01-01T00:00:00Z
  local token before claims_file describe_def fn
  token="$(issue_list_token bob)"; before="$(durable_state)"
  claims_file="$TEST_SKILL_DIR/scripts/lib/claims.sh"; : >"$claims_file"
  assert_zero_stdout_failure claim-file storage_ack_receipt receipts bob --receipt "$token"
  rm -f "$claims_file"
  for fn in agmsg_claim_next agmsg_ack_claim agmsg_release_claim; do
    eval "$fn() { :; }"
    assert_zero_stdout_failure "claim-$fn" storage_ack_receipt receipts bob --receipt "$token"
    unset -f "$fn"
  done
  describe_def="$(declare -f storage_describe)"
  storage_describe() { printf 'name=sqlite\nbackend=test\ncapabilities=stage1-sync,stage1-sync\n'; }
  assert_zero_stdout_failure claim-duplicate storage_ack_receipt receipts bob --receipt "$token"
  storage_describe() { printf 'name=sqlite\nbackend=test\ncapabilities=stage1-sync,,stage2-read-state\n'; }
  assert_zero_stdout_failure claim-malformed storage_ack_receipt receipts bob --receipt "$token"
  storage_describe() { printf 'name=sqlite\nbackend=test\ncapabilities=stage1-sync,unrelated-lease-v1\n'; }
  run storage_ack_receipt receipts bob --receipt "$token"
  [ "$status" -eq 0 ]
  eval "$describe_def"
  [ "$(sqlite3 "$(agmsg_db_path receipts)" 'SELECT COUNT(*) FROM receipt_nonces;')" = 1 ]
}

@test "Task 4 retained expiry retries reconcile and eligible old nonces prune only on success" {
  ack_abi_required
  sql_event retention alice bob body 2026-01-01T00:00:00Z
  local token now old boundary i ancient boundary_token
  token="$(issue_list_token bob)"
  run storage_ack_receipt receipts bob --receipt "$token"
  [ "$status" -eq 0 ]
  [ "$(ack_failure_text retained-expired bob "$token")" = 'agmsg receipt: already_committed' ]
  now="$(date +%s)"; old=$((now - 86401)); boundary=$((now - 86340))
  for i in $(seq 1 50); do
    sqlite3 "$(agmsg_db_path receipts)" "INSERT INTO receipt_nonces VALUES(
      '$(printf '%032x' "$i")','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',$old,$old);"
  done
  sqlite3 "$(agmsg_db_path receipts)" "INSERT INTO receipt_nonces VALUES(
    'ffffffffffffffffffffffffffffffff','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',$boundary,$boundary);"
  sql_event retention-next alice carol next 2026-01-01T00:00:01Z
  token="$(issue_list_token carol)"
  run storage_ack_receipt receipts carol --receipt "$token"
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$(agmsg_db_path receipts)" "SELECT COUNT(*) FROM receipt_nonces WHERE expires_at=$old;")" = 0 ]
  [ "$(sqlite3 "$(agmsg_db_path receipts)" "SELECT COUNT(*) FROM receipt_nonces WHERE nonce='ffffffffffffffffffffffffffffffff';")" = 1 ]
  [ "$(sqlite3 "$(agmsg_db_path receipts)" 'SELECT COUNT(*) FROM receipt_nonces;')" -le 4 ]

  sql_event stale alice dave stale 2026-01-01T00:00:02Z
  token="$(issue_list_token dave)"
  ancient="$(resign_receipt_times "$token" "$((now - 87301))" "$((now - 86401))")"
  [ "$(ack_failure_text stale-pruned dave "$ancient")" = 'agmsg receipt: stale_or_replayed' ]
  boundary_token="$(resign_receipt_times "$token" "$((now - 87240))" "$((now - 86340))")"
  [ "$(ack_failure_text retention-boundary dave "$boundary_token")" = 'agmsg receipt: receipt expired' ]
}

@test "Task 4 statement failure and outer-verification drift roll back every mutation" {
  ack_abi_required
  sql_event faulted alice bob original 2026-01-01T00:00:00Z
  local db token before real_sqlite mutate_once=1
  db="$(agmsg_db_path receipts)"; token="$(issue_list_token bob)"; before="$(durable_state)"
  sqlite3 "$db" "CREATE TRIGGER refuse_ack BEFORE INSERT ON events
    WHEN NEW.type='message_read' BEGIN SELECT RAISE(ABORT,'forced ack fault'); END;"
  assert_zero_stdout_failure statement-fault storage_ack_receipt receipts bob --receipt "$token"
  sqlite3 "$db" 'DROP TRIGGER refuse_ack;'
  [ "$(durable_state)" = "$before" ]

  real_sqlite="$(command -v sqlite3)"
  agmsg_sqlite() {
    local input rc
    case " $* " in
    *' -batch '*)
      input="$BATS_TEST_TMPDIR/barrier.sql"; cat >"$input"
      if [ "$mutate_once" -eq 1 ] && grep -q 'CREATE TEMP TABLE _ack_expected' "$input"; then
        mutate_once=0
        "$real_sqlite" "$db" "UPDATE events SET body='changed-at-barrier' WHERE id='faulted';"
      fi
      "$real_sqlite" "$@" <"$input"; rc=$?; return "$rc"
      ;;
    esac
    "$real_sqlite" "$@"
  }
  assert_zero_stdout_failure barrier storage_ack_receipt receipts bob --receipt "$token"
  unset -f agmsg_sqlite
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM receipt_nonces;")" = 0 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM read_cursors;")" = 0 ]
}

@test "Task 4 ack begins one IMMEDIATE transaction before durable writes" {
  ack_abi_required
  sql_event immediate alice bob body 2026-01-01T00:00:00Z
  local token db real_sqlite
  token="$(issue_list_token bob)"; db="$(agmsg_db_path receipts)"
  real_sqlite="$(command -v sqlite3)"
  agmsg_sqlite() {
    local input rc
    case " $* " in
    *' -batch '*)
      input="$BATS_TEST_TMPDIR/immediate.sql"; cat >"$input"
      if grep -q 'CREATE TEMP TABLE _ack_expected' "$input"; then
        [ "$(grep -c '^BEGIN IMMEDIATE;$' "$input")" -eq 1 ] || return 97
      fi
      "$real_sqlite" "$@" <"$input"; rc=$?; return "$rc"
      ;;
    esac
    "$real_sqlite" "$@"
  }
  run storage_ack_receipt receipts bob --receipt "$token"
  unset -f agmsg_sqlite
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM receipt_nonces;')" = 1 ]
}

@test "Task 4 an injected COMMIT-boundary failure cannot report or retain success" {
  ack_abi_required
  sql_event commit-fault alice bob body 2026-01-01T00:00:00Z
  local token before db real_sqlite
  token="$(issue_list_token bob)"; before="$(durable_state)"; db="$(agmsg_db_path receipts)"
  real_sqlite="$(command -v sqlite3)"
  agmsg_sqlite() {
    local input rewritten rc
    case " $* " in
    *' -batch '*)
      input="$BATS_TEST_TMPDIR/commit.input"; rewritten="$BATS_TEST_TMPDIR/commit.rewritten"
      cat >"$input"
      if grep -q 'CREATE TEMP TABLE _ack_expected' "$input"; then
        sed 's/^COMMIT;$/ROLLBACK;\nSELECT no_such_commit_boundary_function();/' "$input" >"$rewritten"
        "$real_sqlite" "$@" <"$rewritten"; rc=$?; return "$rc"
      fi
      "$real_sqlite" "$@" <"$input"; rc=$?; return "$rc"
      ;;
    esac
    "$real_sqlite" "$@"
  }
  assert_zero_stdout_failure commit-fault storage_ack_receipt receipts bob --receipt "$token"
  unset -f agmsg_sqlite
  [ "$(durable_state)" = "$before" ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
}

@test "Task 4 private precommit verdict publication failure is one bounded refusal" {
  ack_abi_required
  sql_event verdict-publication-fault alice bob verdict-private-body-91bc4e72 \
    2026-01-01T00:00:00Z
  sqlite3 "$(agmsg_db_path receipts)" "
    INSERT INTO messages(team,from_agent,to_agent,body,created_at)
      VALUES('receipts','alice','bob','verdict-private-body-91bc4e72',
        '2026-01-01T00:00:00Z');
    UPDATE events SET legacy_id=last_insert_rowid()
      WHERE id='verdict-publication-fault';"
  local db token before stderr path
  db="$(agmsg_db_path receipts)"; token="$(issue_list_token bob)"
  before="$(sqlite3 "$db" "
    SELECT 'nonce=' || COUNT(*) FROM receipt_nonces;
    SELECT 'read=' || COUNT(*) FROM events WHERE type='message_read';
    SELECT 'read_at=' || COALESCE(group_concat(id || ':' || COALESCE(read_at,''), ','), '')
      FROM messages;
    SELECT 'cursor=' || COUNT(*) || ':' || COALESCE(
      group_concat(team || ':' || agent || ':' || local_position, ','), '')
      FROM read_cursors;")"

  # The transaction owner must treat a private temp-create/atomic-rename
  # failure as an operational refusal.  This shell seam is the same kind of
  # reachable fault injection used for agmsg_sqlite/OpenSSL in the surrounding
  # receipt tests; it never exposes the private row or token.
  _sqlite_receipt_publish_verdict() { return 71; }
  path="$BATS_TEST_TMPDIR/verdict-publication-fault"
  if storage_ack_receipt receipts bob --receipt "$token" >"$path.stdout" 2>"$path.stderr"; then
    return 1
  fi
  [ ! -s "$path.stdout" ]
  [ "$(wc -l <"$path.stderr" | tr -d ' ')" = 1 ]
  [ "$(wc -c <"$path.stderr" | tr -d ' ')" -le 4096 ]
  stderr="$(cat "$path.stderr")"
  [ "$stderr" = 'agmsg receipt: acknowledgement failed' ]
  refute grep -Fq -- "$token" "$path.stderr"
  refute grep -Fq -- verdict-private-body-91bc4e72 "$path.stderr"
  refute grep -Fq -- "$BATS_TEST_TMPDIR" "$path.stderr"
  [ "$(sqlite3 "$db" "
    SELECT 'nonce=' || COUNT(*) FROM receipt_nonces;
    SELECT 'read=' || COUNT(*) FROM events WHERE type='message_read';
    SELECT 'read_at=' || COALESCE(group_concat(id || ':' || COALESCE(read_at,''), ','), '')
      FROM messages;
    SELECT 'cursor=' || COUNT(*) || ':' || COALESCE(
      group_concat(team || ':' || agent || ':' || local_position, ','), '')
      FROM read_cursors;")" = "$before" ]
}

@test "Task 4 parent death after the waiting marker bounds the child and permits retry" {
  ack_abi_required
  local db token before rows snapshot selected payload_sha generation key_sha team_hex
  local recipient_hex batch_sha frame_sha frontier issued expires nonce team_sha recipient_sha
  local runner wrapper_dir work ack_pid ack_rc wrapper_pid i real_sqlite
  db="$(agmsg_db_path receipts)"
  sql_event parent-death-private-id-91bc4e72 alice bob parent-death-private-body-91bc4e72 \
    2026-01-01T00:00:00Z
  sqlite3 "$db" "
    INSERT INTO messages(team,from_agent,to_agent,body,created_at)
      VALUES('receipts','alice','bob','parent-death-private-body-91bc4e72',
        '2026-01-01T00:00:00Z');
    UPDATE events SET legacy_id=last_insert_rowid()
      WHERE id='parent-death-private-id-91bc4e72';"
  token="$(issue_list_token bob)"; decode_receipt "$token"
  selected="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^selected_count=//p')"
  generation="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^store_generation=//p')"
  key_sha="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^key_sha256=//p')"
  team_hex="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^team_hex=//p')"
  recipient_hex="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^recipient_hex=//p')"
  batch_sha="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^batch_sha256=//p')"
  frame_sha="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^frame_sha256=//p')"
  frontier="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^issuance_frontier=//p')"
  issued="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^issued_at=//p')"
  expires="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^expires_at=//p')"
  nonce="$(printf '%s\n' "$RECEIPT_PAYLOAD" | sed -n 's/^nonce=//p')"
  payload_sha="$(shasum -a 256 "$BATS_TEST_TMPDIR/payload.bin" | awk '{print $1}')"
  printf '%s\n' "$team_hex" >"$BATS_TEST_TMPDIR/team.hex"
  xxd -r -p "$BATS_TEST_TMPDIR/team.hex" >"$BATS_TEST_TMPDIR/team.bin"
  team_sha="$(shasum -a 256 "$BATS_TEST_TMPDIR/team.bin" | awk '{print $1}')"
  printf '%s\n' "$recipient_hex" >"$BATS_TEST_TMPDIR/recipient.hex"
  xxd -r -p "$BATS_TEST_TMPDIR/recipient.hex" >"$BATS_TEST_TMPDIR/recipient.bin"
  recipient_sha="$(shasum -a 256 "$BATS_TEST_TMPDIR/recipient.bin" | awk '{print $1}')"
  snapshot="$(_sqlite_data_stdin receipts \
    "$(_sqlite_receipt_ack_snapshot_sql receipts bob "$selected")")"
  rows="$BATS_TEST_TMPDIR/parent-death.rows"
  printf '%s\n' "$snapshot" | sed -n 's/^__agmsg_receipt_row|//p' >"$rows"
  [ "$(wc -l <"$rows" | tr -d ' ')" = "$selected" ]

  before="$(sqlite3 "$db" "
    SELECT 'nonce=' || COUNT(*) FROM receipt_nonces;
    SELECT 'read=' || COUNT(*) FROM events WHERE type='message_read';
    SELECT 'read_at=' || COALESCE(group_concat(id || ':' || COALESCE(read_at,''), ','), '')
      FROM messages;
    SELECT 'cursor=' || COUNT(*) || ':' || COALESCE(
      group_concat(team || ':' || agent || ':' || local_position, ','), '')
      FROM read_cursors;")"

  work="$BATS_TEST_TMPDIR/parent-death-work"; mkdir "$work"
  wrapper_dir="$work/sqlite-wrapper"; mkdir "$wrapper_dir"
  real_sqlite="$(command -v sqlite3)"
  cat >"$wrapper_dir/sqlite3" <<'SH'
#!/usr/bin/env bash
set -u
input="${ACK_PARENT_DEATH_WORK}/sqlite.input.$$"
watcher=
child_pid=
cleanup() {
  if [ -n "$child_pid" ]; then
    kill "$child_pid" 2>/dev/null || true
  fi
}
trap cleanup TERM INT
case " $* " in
  *' -batch '*)
    /bin/cat >"$input"
    if grep -q 'CREATE TEMP TABLE _ack_expected' "$input" &&
       [ -n "${AGMSG_RECEIPT_GATE_WAITING:-}" ]; then
      (
        while [ ! -f "$AGMSG_RECEIPT_GATE_WAITING" ]; do sleep 0.01; done
        : >"$ACK_PARENT_DEATH_WORK/waiting-observed"
      ) &
      watcher=$!
    fi
    printf '%s' "$$" >"$ACK_PARENT_DEATH_WORK/wrapper.pid"
    if "$REAL_ACK_SQLITE" "$@" <"$input" & then
      child_pid=$!
      if wait "$child_pid"; then rc=0; else rc=$?; fi
    else
      rc=$?
    fi
    [ -z "$watcher" ] || wait "$watcher" 2>/dev/null || true
    printf '%s' "$rc" >"$ACK_PARENT_DEATH_WORK/sqlite-done"
    tmp_dir="${AGMSG_RECEIPT_GATE_WAITING%/*}"
    case "$tmp_dir" in
      /*) /bin/rm -rf -- "$tmp_dir" ;;
    esac
    /bin/rm -f -- "$input"
    trap - TERM INT
    exit "$rc"
    ;;
  *) exec "$REAL_ACK_SQLITE" "$@" ;;
esac
SH
  chmod 755 "$wrapper_dir/sqlite3"

  runner="$work/run-transaction.sh"
  cat >"$runner" <<'SH'
#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
source "$SCRIPTS/lib/storage.sh"
agmsg_storage_load
_agmsg_receipt_capability_claim_check() {
  : >"$ACK_PARENT_DEATH_CLAIM_ENTERED"
  while [ ! -f "$ACK_PARENT_DEATH_ALLOW" ]; do sleep 0.01; done
  return 0
}
_sqlite_receipt_ack_transaction \
  "$ACK_TEAM" "$ACK_RECIPIENT" "$ACK_ROWS" "$ACK_NONCE" "$ACK_PAYLOAD_SHA" \
  "$ACK_GENERATION" "$ACK_KEY_SHA" "$ACK_TEAM_SHA" "$ACK_RECIPIENT_SHA" \
  "$ACK_BATCH_SHA" "$ACK_FRAME_SHA" "$ACK_FRONTIER" "$ACK_ISSUED" "$ACK_EXPIRES"
SH
  chmod 755 "$runner"
  export ACK_PARENT_DEATH_WORK="$work" REAL_ACK_SQLITE="$real_sqlite"
  export ACK_PARENT_DEATH_CLAIM_ENTERED="$work/claim-entered"
  export ACK_PARENT_DEATH_ALLOW="$work/claim-allow"
  export ACK_TEAM=receipts ACK_RECIPIENT=bob ACK_ROWS="$rows" ACK_NONCE="$nonce"
  export ACK_PAYLOAD_SHA="$payload_sha" ACK_GENERATION="$generation" ACK_KEY_SHA="$key_sha"
  export ACK_TEAM_SHA="$team_sha" ACK_RECIPIENT_SHA="$recipient_sha"
  export ACK_BATCH_SHA="$batch_sha" ACK_FRAME_SHA="$frame_sha" ACK_FRONTIER="$frontier"
  export ACK_ISSUED="$issued" ACK_EXPIRES="$expires"
  PATH="$wrapper_dir:$PATH"; export PATH

  run_parent_transaction() {
    exec "$runner" >"$work/runner.stdout" 2>"$work/runner.stderr"
  }
  run_parent_transaction &
  ack_pid=$!
  [ -n "$ack_pid" ]
  for i in $(seq 1 50); do
    [ -f "$work/waiting-observed" ] && break
    sleep 0.1
  done
  [ -f "$work/waiting-observed" ]
  kill -KILL "$ack_pid" 2>/dev/null || true
  if wait "$ack_pid"; then ack_rc=0; else ack_rc=$?; fi
  [ "$ack_rc" -ne 0 ]

  # The old 10-second gate timeout is deliberately outside this bound.  If a
  # mutant or regression leaves the wrapper alive, terminate that exact PID
  # recorded by the wrapper before failing the test; never guess by command or
  # process name.
  for i in $(seq 1 50); do
    [ -f "$work/sqlite-done" ] && break
    sleep 0.1
  done
  if [ ! -f "$work/sqlite-done" ]; then
    wrapper_pid="$(cat "$work/wrapper.pid" 2>/dev/null || true)"
    case "$wrapper_pid" in
      ''|*[!0-9]*) ;;
      *) kill -TERM "$wrapper_pid" 2>/dev/null || true ;;
    esac
    return 1
  fi
  [ "$(cat "$work/sqlite-done")" -ne 0 ]
  [ "$(sqlite3 "$db" "
    SELECT 'nonce=' || COUNT(*) FROM receipt_nonces;
    SELECT 'read=' || COUNT(*) FROM events WHERE type='message_read';
    SELECT 'read_at=' || COALESCE(group_concat(id || ':' || COALESCE(read_at,''), ','), '')
      FROM messages;
    SELECT 'cursor=' || COUNT(*) || ':' || COALESCE(
      group_concat(team || ':' || agent || ':' || local_position, ','), '')
      FROM read_cursors;")" = "$before" ]

  PATH="${PATH#"$wrapper_dir:"}"; export PATH
  run storage_ack_receipt receipts bob --receipt "$token"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM receipt_nonces;")" = 1 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 1 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM messages WHERE read_at IS NOT NULL;")" = 1 ]
}

@test "Task 4 process death after commit is reconciled by the exact retry" {
  ack_abi_required
  sql_event killed alice bob body 2026-01-01T00:00:00Z
  local token wrapper_dir real_sqlite
  token="$(issue_list_token bob)"; wrapper_dir="$BATS_TEST_TMPDIR/sqlite-kill-wrapper"
  real_sqlite="$(command -v sqlite3)"; mkdir "$wrapper_dir"
  cat >"$wrapper_dir/sqlite3" <<'SH'
#!/usr/bin/env bash
set -eu
input=
case " $* " in
  *' -batch '*)
    input="$(mktemp "${TMPDIR:-/tmp}/agmsg-kill-sql.XXXXXX")"
    chmod 600 "$input"; cat >"$input"
    "$REAL_ACK_SQLITE" "$@" <"$input"
    rc=$?
    if [ "$rc" -eq 0 ] && grep -q 'CREATE TEMP TABLE _ack_expected' "$input"; then
      rm -f "$input"
      kill -KILL "$PPID"
      exit 137
    fi
    rm -f "$input"; exit "$rc"
    ;;
esac
exec "$REAL_ACK_SQLITE" "$@"
SH
  chmod 755 "$wrapper_dir/sqlite3"
  export REAL_ACK_SQLITE="$real_sqlite"
  PATH="$wrapper_dir:$PATH"; export PATH
  run --separate-stderr storage_ack_receipt receipts bob --receipt "$token"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  PATH="${PATH#"$wrapper_dir:"}"; export PATH
  unset AGMSG_RECEIPT_OPENSSL_RESOLVED AGMSG_RECEIPT_XXD_RESOLVED _AGMSG_ESCAPE_PROBED _AGMSG_ESCAPE_FLAG
  [ "$(ack_failure_text killed-retry bob "$token")" = 'agmsg receipt: already_committed' ]
  [ "$(sqlite3 "$(agmsg_db_path receipts)" 'SELECT COUNT(*) FROM receipt_nonces;')" = 1 ]
  [ "$(sqlite3 "$(agmsg_db_path receipts)" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 1 ]
}

@test "Task 4 storage capability is advertised only with the complete ack ABI" {
  ack_abi_required
  [ "$(storage_describe | awk -F= '$1=="capabilities"{print $2}')" = \
    stage1-sync,stage1-resync,stage2-read-state,sqlite-receipt-ack-v1 ]
}

@test "Task 4 validates absent symlink hardlink and unsafe-mode stores before any SQLite open" {
  ack_abi_required
  local original_path="$AGMSG_STORAGE_PATH" original_db count_file real_sqlite alt
  original_db="$(agmsg_db_path receipts)"; real_sqlite="$(command -v sqlite3)"
  count_file="$BATS_TEST_TMPDIR/sqlite-open-count"; : >"$count_file"
  agmsg_sqlite() {
    printf 'open\n' >>"$count_file"
    "$real_sqlite" "$@"
  }

  AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/absent-store"; export AGMSG_STORAGE_PATH
  assert_zero_stdout_failure absent-store storage_ack_receipt receipts bob --receipt not-a-token
  [ ! -e "$(agmsg_db_path receipts)" ]
  [ ! -s "$count_file" ]
  assert_zero_stdout_failure absent-valid-shape storage_ack_receipt receipts bob --receipt a.a
  [ ! -e "$(agmsg_db_path receipts)" ]
  [ ! -s "$count_file" ]

  for alt in symlink hardlink; do
    AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/$alt-store"; export AGMSG_STORAGE_PATH
    mkdir -p "$AGMSG_STORAGE_PATH"
    if [ "$alt" = symlink ]; then
      ln -s "$original_db" "$(agmsg_db_path receipts)"
    else
      ln "$original_db" "$(agmsg_db_path receipts)"
    fi
    : >"$count_file"
    assert_zero_stdout_failure "$alt-store" storage_ack_receipt receipts bob --receipt a.a
    [ ! -s "$count_file" ]
  done

  AGMSG_STORAGE_PATH="$original_path"; export AGMSG_STORAGE_PATH
  chmod 666 "$original_db"; : >"$count_file"
  assert_zero_stdout_failure unsafe-mode storage_ack_receipt receipts bob --receipt a.a
  chmod 600 "$original_db"
  [ ! -s "$count_file" ]
  unset -f agmsg_sqlite
}

@test "Task 4 transaction guards the full event-linked legacy identity" {
  ack_abi_required
  local db case_name recipient token before linked_id
  db="$(agmsg_db_path receipts)"
  for case_name in team from to body at dangling; do
    recipient="legacy-$case_name"
    sqlite3 "$db" "
      INSERT INTO messages(team,from_agent,to_agent,body,created_at)
        VALUES('receipts','alice','$recipient','body','2026-01-01T00:00:00Z');
      INSERT INTO events(type,id,team,from_agent,to_agent,body,at,legacy_id)
        VALUES('message_sent','event-$case_name','receipts','alice','$recipient','body','2026-01-01T00:00:00Z',last_insert_rowid());"
    linked_id="$(sqlite3 "$db" "SELECT legacy_id FROM events WHERE id='event-$case_name';")"
    token="$(issue_list_token "$recipient")"; before="$(durable_state)"
    case "$case_name" in
      team) sqlite3 "$db" "UPDATE messages SET team='other' WHERE id=$linked_id;" ;;
      from) sqlite3 "$db" "UPDATE messages SET from_agent='mallory' WHERE id=$linked_id;" ;;
      to) sqlite3 "$db" "UPDATE messages SET to_agent='nobody' WHERE id=$linked_id;" ;;
      body) sqlite3 "$db" "UPDATE messages SET body='changed' WHERE id=$linked_id;" ;;
      at) sqlite3 "$db" "UPDATE messages SET created_at='2026-01-01T00:00:01Z' WHERE id=$linked_id;" ;;
      dangling) sqlite3 "$db" "DELETE FROM messages WHERE id=$linked_id;" ;;
    esac
    assert_zero_stdout_failure "linked-$case_name" storage_ack_receipt receipts "$recipient" --receipt "$token"
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM receipt_nonces;")" = 0 ]
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
  done
}

@test "Task 4 rechecks the repo claim marker after BEGIN immediately before COMMIT" {
  ack_abi_required
  sql_event claim-race alice bob body 2026-01-01T00:00:00Z
  local token db claims_file real_sqlite before barrier lock_probe
  token="$(issue_list_token bob)"; db="$(agmsg_db_path receipts)"; before="$(durable_state)"
  claims_file="$TEST_SKILL_DIR/scripts/lib/claims.sh"; real_sqlite="$(command -v sqlite3)"
  barrier="$BATS_TEST_TMPDIR/claim-race.precommit"; lock_probe="$BATS_TEST_TMPDIR/claim-race.locked"
  export CLAIM_RACE_CLAIMS_FILE="$claims_file" CLAIM_RACE_DB="$db"
  export CLAIM_RACE_REAL_SQLITE="$real_sqlite" CLAIM_RACE_BARRIER="$barrier"
  export CLAIM_RACE_LOCK_PROBE="$lock_probe"
  agmsg_sqlite() {
    local input rc
    case " $* " in
    *' -batch '*)
      input="$BATS_TEST_TMPDIR/claim-race.sql"; cat >"$input"
      if grep -q 'CREATE TEMP TABLE _ack_expected' "$input" &&
         [ -n "${AGMSG_RECEIPT_GATE_SCRIPT:-}" ]; then
        printf '%s\n' '#!/bin/bash' \
          'set -u' \
          'if "$CLAIM_RACE_REAL_SQLITE" -cmd ".timeout 1" "$CLAIM_RACE_DB" "BEGIN IMMEDIATE; ROLLBACK;" >/dev/null 2>&1; then' \
          '  printf unlocked >"$CLAIM_RACE_LOCK_PROBE"' \
          'else' \
          '  printf locked >"$CLAIM_RACE_LOCK_PROBE"' \
          'fi' \
          ': >"$CLAIM_RACE_CLAIMS_FILE"' \
          ': >"$CLAIM_RACE_BARRIER"' \
          ': >"$AGMSG_RECEIPT_GATE_WAITING"' \
          'attempt=0' \
          'while [ ! -f "$AGMSG_RECEIPT_GATE_VERDICT" ]; do' \
          '  attempt=$((attempt + 1)); [ "$attempt" -le 1000 ] || exit 1' \
          '  sleep 0.01' \
          'done' >"$AGMSG_RECEIPT_GATE_SCRIPT"
        chmod 700 "$AGMSG_RECEIPT_GATE_SCRIPT"
      fi
      "$real_sqlite" "$@" <"$input"; rc=$?; return "$rc"
      ;;
    esac
    "$real_sqlite" "$@"
  }
  assert_zero_stdout_failure claim-race storage_ack_receipt receipts bob --receipt "$token"
  unset -f agmsg_sqlite; rm -f "$claims_file"
  [ -f "$barrier" ]
  [ "$(cat "$lock_probe")" = locked ]
  [ "$(cat "$BATS_TEST_TMPDIR/claim-race.stderr")" = \
    'agmsg receipt: message claim capability conflicts with receipt state' ]
  [ "$(durable_state)" = "$before" ]
}

@test "Task 4 exact retry reconciles a post-auth snapshot backend failure" {
  ack_abi_required
  sql_event retry-backend alice bob body 2026-01-01T00:00:00Z
  local token real_sqlite
  token="$(issue_list_token bob)"
  run storage_ack_receipt receipts bob --receipt "$token"
  [ "$status" -eq 0 ]
  real_sqlite="$(command -v sqlite3)"
  agmsg_sqlite() {
    local input rc
    case " $* " in
    *' -batch '*)
      input="$BATS_TEST_TMPDIR/retry-backend.sql"; cat >"$input"
      if grep -q "SELECT '__agmsg_receipt_row|'" "$input"; then return 71; fi
      "$real_sqlite" "$@" <"$input"; rc=$?; return "$rc"
      ;;
    esac
    "$real_sqlite" "$@"
  }
  [ "$(ack_failure_text retry-backend bob "$token")" = 'agmsg receipt: already_committed' ]
  unset -f agmsg_sqlite
}

@test "Task 4 post-auth canonicalization faults emit one bounded sanitized diagnostic" {
  ack_abi_required
  sql_event helper-fault alice bob private-body 2026-01-01T00:00:00Z
  local token wrapper real_openssl
  token="$(issue_list_token bob)"; wrapper="$BATS_TEST_TMPDIR/openssl-ack-fault"
  real_openssl="$(command -v openssl)"
  cat >"$wrapper" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' dgst -sha256 -r '*'/agmsg-receipt-ack.'*'/batch'*) exit 71 ;;
esac
exec "$REAL_ACK_OPENSSL" "$@"
SH
  chmod 755 "$wrapper"; export REAL_ACK_OPENSSL="$real_openssl" AGMSG_RECEIPT_OPENSSL="$wrapper"
  assert_zero_stdout_failure helper-fault storage_ack_receipt receipts bob --receipt "$token"
  [ "$(wc -l <"$BATS_TEST_TMPDIR/helper-fault.stderr" | tr -d ' ')" = 1 ]
  refute grep -Fq -- "$token" "$BATS_TEST_TMPDIR/helper-fault.stderr"
  refute grep -Fq -- private-body "$BATS_TEST_TMPDIR/helper-fault.stderr"
}

@test "Task 4 transaction-time expiry is classified after reconciliation" {
  ack_abi_required
  sql_event expiry-barrier alice bob body 2026-01-01T00:00:00Z
  local token now real_sqlite
  token="$(issue_list_token bob)"; now="$(date +%s)"
  token="$(resign_receipt_times "$token" "$((now - 892))" "$((now + 8))")"
  real_sqlite="$(command -v sqlite3)"
  agmsg_sqlite() {
    local input rc
    case " $* " in
    *' -batch '*)
      input="$BATS_TEST_TMPDIR/expiry-barrier.sql"; cat >"$input"
      if grep -q 'CREATE TEMP TABLE _ack_expected' "$input"; then sleep 9; fi
      "$real_sqlite" "$@" <"$input"; rc=$?; return "$rc"
      ;;
    esac
    "$real_sqlite" "$@"
  }
  [ "$(ack_failure_text expiry-barrier bob "$token")" = 'agmsg receipt: receipt expired' ]
  unset -f agmsg_sqlite
}
