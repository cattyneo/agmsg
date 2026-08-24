#!/usr/bin/env bats

# Driver-agnostic tests for the phase-1 bounded read-only storage facade.
# The public CLI, ID transport grammar, receipts/ack, JSONL recovery, and claim
# precedence are deliberately not exercised here; those are later contracts.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init agsuite >/dev/null
}

teardown() { teardown_test_env; }

store_dir() { dirname "$(agmsg_db_path agsuite)"; }

remove_store() {
  local dir; dir="$(store_dir)"
  case "${AGMSG_STORAGE_DRIVER:-sqlite}" in
    jsonl)
      rm -f "$dir/events.jsonl" "$dir/events.jsonl.lock" \
        "$dir/.read-cursor-v1" "$dir/.read-cursor-v1.lock" \
        "$dir/read-cursors.tsv" "$dir"/read-cursors.tsv.tmp.*
      ;;
    *)
      rm -f "$dir/messages.db" "$dir/messages.db-wal" "$dir/messages.db-shm"
      ;;
  esac
}

store_fingerprint() {
  # SQLite's WAL shared-memory index is refreshed by a read transaction; it is
  # an ephemeral lock/index artifact, not durable message/read state.
  find "$(store_dir)" -type f ! -name 'messages.db-shm' -exec shasum {} \; 2>/dev/null | LC_ALL=C sort
}

json_count() {
  printf '%s\n' "$1" | jq -s '[.[] | select(.type == "message_sent")] | length'
}

json_result() {
  printf '%s\n' "$1" | tail -1 | jq -e 'select(.type == "bounded_unread_result")'
}

reset_bounded_store() {
  remove_store
  storage_init agsuite >/dev/null
}

repeat_char() {
  local count="$1" char="$2"
  [ "$count" -gt 0 ] || return 0
  printf '%*s' "$count" '' | tr ' ' "$char"
}

append_fixture_message() {
  local id="$1" body="$2" at="$3"
  case "${AGMSG_STORAGE_DRIVER:-sqlite}" in
    jsonl)
      jq -cn --arg id "$id" --arg body "$body" --arg at "$at" \
        '{type:"message_sent",id:$id,team:"agsuite",from:"alice",to:"bob",body:$body,at:$at}' \
        >> "$(store_dir)/events.jsonl"
      ;;
    *)
      local db id_sql body_sql at_sql
      db="$(agmsg_db_path agsuite)"
      id_sql="$(agmsg_sqlesc "$id")"
      body_sql="$(agmsg_sqlesc "$body")"
      at_sql="$(agmsg_sqlesc "$at")"
      agmsg_sqlite "$db" "INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
        VALUES('message_sent','$id_sql','agsuite','alice','bob','$body_sql','$at_sql');" >/dev/null
      ;;
  esac
}

opaque_id_for_record_bytes() {
  local target="$1" empty_record base_bytes id_bytes
  empty_record="$(jq -cn '{type:"message_sent",id:"",team:"agsuite",from:"alice",to:"bob",body:"x",at:"2026-01-01T00:00:00Z"}')"
  base_bytes="$(printf '%s' "$empty_record" | wc -c | tr -d ' ')"
  id_bytes=$((target - base_bytes))
  [ "$id_bytes" -ge 1 ] || return 1
  repeat_char "$id_bytes" i
}

assert_bounded_stderr() {
  local file="$1" bytes
  [ -s "$file" ]
  bytes="$(wc -c < "$file" | tr -d ' ')"
  [ "$bytes" -le 256 ]
}

@test "bounded summary observes a missing store without creating it" {
  remove_store
  local before after
  before="$(store_fingerprint)"
  run storage_unread_summary agsuite bob
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.type')" = unread_summary ]
  [ "$(printf '%s' "$output" | jq -r '.unread_count')" = 0 ]
  [ "$(printf '%s' "$output" | jq -r '.newest_id')" = null ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "bounded summary returns count/newest id without a body field" {
  local first second
  first=$(storage_send agsuite alice bob first-summary)
  second=$(storage_send agsuite alice bob second-summary)
  storage_send agsuite alice carol other-summary >/dev/null
  local before after
  before="$(store_fingerprint)"
  run storage_unread_summary agsuite bob
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.type')" = unread_summary ]
  [ "$(printf '%s' "$output" | jq -r '.unread_count')" = 2 ]
  [ "$(printf '%s' "$output" | jq -r '.newest_id')" = "$second" ]
  [ "$(printf '%s' "$output" | jq -e 'has("body") | not')" = true ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
  [ -n "$first" ]
}

@test "bounded list and exact show observe a missing store without creating it" {
  remove_store
  local before after out="$TEST_SKILL_DIR/missing-show.stdout"
  before="$(store_fingerprint)"
  run storage_list_unread_bounded agsuite bob --limit-items 10 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.type')" = bounded_unread_result ]
  [ "$(printf '%s' "$output" | jq -r '.remaining_count')" = 0 ]
  if storage_get_message_bounded agsuite bob missing --max-body-bytes 4096 >"$out" 2>/dev/null; then
    false
  fi
  [ ! -s "$out" ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "bounded summary and list return explicit empty records for an initialized empty store" {
  run storage_unread_summary agsuite bob
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.unread_count')" = 0 ]
  [ "$(printf '%s' "$output" | jq -r '.newest_id')" = null ]
  run storage_list_unread_bounded agsuite bob --limit-items 10 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.type')" = bounded_unread_result ]
  [ "$(printf '%s' "$output" | jq -r '.selected_count')" = 0 ]
  [ "$(printf '%s' "$output" | jq -r '.remaining_count')" = 0 ]
}

@test "bounded list honors item limits 0, 1, and 10 and emits counts/bytes" {
  local i
  for i in $(seq 1 10); do storage_send agsuite alice bob "m$i" >/dev/null; done

  run storage_list_unread_bounded agsuite bob --limit-items 0 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(json_count "$output")" = 0 ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.selected_count')" = 0 ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.remaining_count')" = 10 ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.remaining_body_bytes')" = 21 ]

  run storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(json_count "$output")" = 1 ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.selected_count')" = 1 ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.remaining_count')" = 9 ]

  run storage_list_unread_bounded agsuite bob --limit-items 10 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(json_count "$output")" = 10 ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.selected_count')" = 10 ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.remaining_count')" = 0 ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.selected_body_bytes')" = 21 ]
}

@test "bounded list uses raw UTF-8 body bytes and never truncates" {
  storage_send agsuite alice bob あ >/dev/null
  local body; body="$(printf 'line1\nline2\t\001')"
  local id; id=$(storage_send agsuite alice bob "$body")

  run storage_list_unread_bounded agsuite bob --limit-items 10 --max-body-bytes 3
  [ "$status" -eq 0 ]
  [ "$(json_count "$output")" = 1 ]
  [ "$(printf '%s' "$output" | head -1 | jq -r '.body')" = あ ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.remaining_count')" = 1 ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.remaining_body_bytes')" = 13 ]

  run storage_get_message_bounded agsuite bob "$id" --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.type')" = message_sent ]
  [ "$(printf '%s' "$output" | jq -r '.id')" = "$id" ]
  [ "$(printf '%s' "$output" | jq -r '.body')" = "$body" ]
}

@test "bounded list accepts an empty body at a zero-byte bound" {
  storage_send agsuite alice bob '' >/dev/null
  run storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 0
  [ "$status" -eq 0 ]
  [ "$(json_count "$output")" = 1 ]
  [ "$(printf '%s' "$output" | head -1 | jq -r '.body')" = '' ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.selected_body_bytes')" = 0 ]
}

@test "bounded list reaches the one-byte and 4096-byte body boundaries" {
  local one; one=$(storage_send agsuite alice bob x)
  run storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.selected_body_bytes')" = 1 ]
  storage_mark_read_batch agsuite bob "$one" >/dev/null

  local body; body="$(printf '%4096s' x | tr ' ' x)"
  storage_send agsuite alice bob "$body" >/dev/null
  run storage_list_unread_bounded agsuite bob --limit-items 10 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.selected_body_bytes')" = 4096 ]
  [ "$(printf '%s' "$output" | tail -1 | jq -r '.remaining_body_bytes')" = 0 ]
}

@test "bounded list reports a first-row body overflow without leaking its body" {
  local body; body="$(printf '%4097s' x | tr ' ' x)"
  storage_send agsuite alice bob "$body" >/dev/null
  run storage_list_unread_bounded agsuite bob --limit-items 10 --max-body-bytes 4096
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | jq -r '.type')" = bounded_unread_error ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = body_too_large ]
  [ "$(printf '%s' "$output" | jq -r '.body_bytes')" = 4097 ]
  [ "$(printf '%s' "$output" | jq -e 'has("body") | not')" = true ]
  [[ "$output" != *"xxxxxxxxxxxxxxxxxxxxxxxx"* ]]
}

@test "bounded list rejects unsafe bounds with zero stdout" {
  storage_send agsuite alice bob bound-check >/dev/null
  local out="$TEST_SKILL_DIR/bounds.stdout"
  if storage_list_unread_bounded agsuite bob --limit-items 11 --max-body-bytes 4096 >"$out" 2>/dev/null; then
    false
  fi
  [ ! -s "$out" ]
  if storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes -1 >"$out" 2>/dev/null; then
    false
  fi
  [ ! -s "$out" ]
}

@test "exact show can inspect a later unread row without changing the store" {
  local first later
  first=$(storage_send agsuite alice bob first-row)
  later=$(storage_send agsuite alice bob later-row)
  local before after
  before="$(store_fingerprint)"
  run storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 9
  [ "$status" -eq 0 ]
  [ "$(json_count "$output")" = 1 ]
  [ "$(printf '%s' "$output" | head -1 | jq -r '.id')" = "$first" ]
  run storage_get_message_bounded agsuite bob "$later" --max-body-bytes 9
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.id')" = "$later" ]
  [ "$(printf '%s' "$output" | jq -r '.body')" = later-row ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "exact show is recipient-scoped and overflow is metadata-only" {
  local id; id=$(storage_send agsuite alice bob scoped-row)
  local out="$TEST_SKILL_DIR/show.stdout"
  if storage_get_message_bounded agsuite carol "$id" --max-body-bytes 4096 >"$out" 2>/dev/null; then
    false
  fi
  [ ! -s "$out" ]
  if storage_get_message_bounded agsuite bob "$id" --limit-items 1 >"$out" 2>/dev/null; then
    false
  fi
  [ ! -s "$out" ]

  local body; body="$(printf '%4097s' x | tr ' ' x)"
  local large; large=$(storage_send agsuite alice bob "$body")
  run storage_get_message_bounded agsuite bob "$large" --max-body-bytes 4096
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | jq -r '.type')" = bounded_message_error ]
  [ "$(printf '%s' "$output" | jq -e 'has("body") | not')" = true ]
  [[ "$output" != *"xxxxxxxxxxxxxxxxxxxxxxxx"* ]]
}

@test "bounded read failures do not print partial output" {
  remove_store
  printf 'not a store\n' > "$(store_dir)/messages.db"
  if [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = jsonl ]; then
    printf 'not a store\n' > "$(store_dir)/events.jsonl"
  fi
  local out="$TEST_SKILL_DIR/failure.stdout"
  if storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 4096 >"$out" 2>/dev/null; then
    false
  fi
  [ ! -s "$out" ]
  if storage_get_message_bounded agsuite bob unknown --max-body-bytes 4096 >"$out" 2>/dev/null; then
    false
  fi
  [ ! -s "$out" ]
}

@test "sqlite bounded reads preserve an opaque event id and a legacy decimal id" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = sqlite ] || skip "sqlite-specific IDs"
  local db; db="$(agmsg_db_path agsuite)"
  agmsg_sqlite "$db" "INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    VALUES('message_sent','opaque/id.v1','agsuite','alice','bob','opaque-body','2026-01-01T00:00:00Z');
    INSERT INTO messages(team,from_agent,to_agent,body,created_at)
    VALUES('agsuite','alice','bob','legacy-body','2026-01-01T00:00:01Z');" >/dev/null
  run storage_get_message_bounded agsuite bob opaque/id.v1 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.id')" = opaque/id.v1 ]
  run storage_list_unread_bounded agsuite bob --limit-items 10 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq -- 'legacy-body'
  printf '%s\n' "$output" | grep -Fq -- '"id":"opaque/id.v1"'
}

@test "sqlite malformed candidate metadata fails before stdout" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = sqlite ] || skip "sqlite-specific envelope"
  local db; db="$(agmsg_db_path agsuite)"
  agmsg_sqlite "$db" "INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    VALUES('message_sent','bad-meta','agsuite',NULL,'bob','body','2026-01-01T00:00:00Z');" >/dev/null
  local out="$TEST_SKILL_DIR/malformed.stdout"
  if storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 4096 >"$out" 2>/dev/null; then
    false
  fi
  [ ! -s "$out" ]
}

@test "jsonl malformed candidate metadata fails before stdout" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = jsonl ] || skip "jsonl-specific envelope"
  local log; log="$(store_dir)/events.jsonl"
  printf '%s\n' '{"type":"message_sent","id":"bad","team":"agsuite","from":"alice","to":"bob","body":null,"at":"2026-01-01T00:00:00Z"}' >> "$log"
  local out="$TEST_SKILL_DIR/malformed.stdout"
  if storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 4096 >"$out" 2>/dev/null; then
    false
  fi
  [ ! -s "$out" ]
}

@test "jsonl bounded reads project an imported logical message without mutation" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = jsonl ] || skip "jsonl-specific nested event"
  local log; log="$(store_dir)/events.jsonl"
  printf '%s\n' '{"type":"sync_pull_commit","messages":[{"status":"imported","local_event":{"type":"message_sent","id":"opaque/nested","team":"agsuite","from":"alice","to":"bob","body":"nested-body","at":"2026-01-01T00:00:00Z"}}]}' >> "$log"
  local before after
  before="$(store_fingerprint)"
  run storage_unread_summary agsuite bob
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.unread_count')" = 1 ]
  [ "$(printf '%s' "$output" | jq -r '.newest_id')" = opaque/nested ]
  run storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | head -1 | jq -r '.id')" = opaque/nested ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "jsonl bounded reads virtually adopt a pre-marker log by message ordinal without mutation" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = jsonl ] || skip "jsonl-specific adoption"
  remove_store
  local log; log="$(store_dir)/events.jsonl"
  append_fixture_message adopted-1 first '2026-01-01T00:00:00Z'
  printf '%s\n' '{"type":"team_joined","id":"side-event","team":"agsuite","agent":"alice","at":"2026-01-01T00:00:01Z"}' >> "$log"
  append_fixture_message adopted-2 second '2026-01-01T00:00:02Z'

  local before after
  before="$(store_fingerprint)"
  run storage_unread_summary agsuite bob
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.unread_count')" = 0 ]
  [ "$(printf '%s' "$output" | jq -r '.newest_id')" = null ]
  run storage_list_unread_bounded agsuite bob --limit-items 10 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  [ "$(json_count "$output")" = 0 ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
  [ ! -e "$(store_dir)/.read-cursor-v1" ]
  [ ! -e "$(store_dir)/read-cursors.tsv" ]
}

@test "bounded list and summary use the same timestamp and stable-tie order in both drivers" {
  append_fixture_message order-late late '2026-01-01T00:00:03Z'
  append_fixture_message order-early early '2026-01-01T00:00:00Z'
  append_fixture_message order-tie-a tie-a '2026-01-01T00:00:01Z'
  append_fixture_message order-tie-b tie-b '2026-01-01T00:00:01Z'

  local before after ids
  before="$(store_fingerprint)"
  run storage_list_unread_bounded agsuite bob --limit-items 10 --max-body-bytes 4096
  [ "$status" -eq 0 ]
  ids="$(printf '%s\n' "$output" | jq -r 'select(.type=="message_sent") | .id' | paste -sd, -)"
  [ "$ids" = order-early,order-tie-a,order-tie-b,order-late ]
  run storage_unread_summary agsuite bob
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.newest_id')" = order-late ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "duplicate opaque IDs fail before stdout and do not mutate the store" {
  append_fixture_message duplicate-id first '2026-01-01T00:00:00Z'
  append_fixture_message duplicate-id second '2026-01-01T00:00:01Z'
  local before after out="$TEST_SKILL_DIR/duplicate.stdout" err="$TEST_SKILL_DIR/duplicate.stderr"
  before="$(store_fingerprint)"
  if storage_list_unread_bounded agsuite bob --limit-items 10 --max-body-bytes 4096 >"$out" 2>"$err"; then
    false
  fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "one JSON message record accepts 8192 bytes and rejects 8193 bytes including an opaque ID" {
  export AGMSG_BOUNDED_MAX_RECORD_BYTES=8192
  local id out="$TEST_SKILL_DIR/record.stdout" err="$TEST_SKILL_DIR/record.stderr"
  local before after first_bytes

  id="$(opaque_id_for_record_bytes 8192)"
  append_fixture_message "$id" x '2026-01-01T00:00:00Z'
  before="$(store_fingerprint)"
  storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 1 >"$out" 2>"$err"
  [ ! -s "$err" ]
  first_bytes="$(sed -n '1p' "$out" | wc -c | tr -d ' ')"
  [ "$first_bytes" -eq 8193 ]
  [ "$(sed -n '1p' "$out" | jq -r '.id')" = "$id" ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]

  reset_bounded_store
  id="$(opaque_id_for_record_bytes 8193)"
  append_fixture_message "$id" x '2026-01-01T00:00:00Z'
  before="$(store_fingerprint)"
  if storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 1 >"$out" 2>"$err"; then
    false
  fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "bounded record policy accepts 65536 and rejects 65537 with zero stdout" {
  local before after out="$TEST_SKILL_DIR/policy.stdout" err="$TEST_SKILL_DIR/policy.stderr"
  before="$(store_fingerprint)"
  export AGMSG_BOUNDED_MAX_RECORD_BYTES=65536
  run storage_unread_summary agsuite bob
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.type')" = unread_summary ]

  export AGMSG_BOUNDED_MAX_RECORD_BYTES=65537
  if storage_unread_summary agsuite bob >"$out" 2>"$err"; then
    false
  fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "record policy covers missing and initialized summary result and error records" {
  export AGMSG_BOUNDED_MAX_RECORD_BYTES=1
  local before after out="$TEST_SKILL_DIR/small-cap.stdout" err="$TEST_SKILL_DIR/small-cap.stderr"

  remove_store
  before="$(store_fingerprint)"
  if storage_unread_summary agsuite bob >"$out" 2>"$err"; then false; fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
  : > "$err"
  if storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 1 >"$out" 2>"$err"; then false; fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]

  reset_bounded_store
  before="$(store_fingerprint)"
  : > "$err"
  if storage_unread_summary agsuite bob >"$out" 2>"$err"; then false; fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
  : > "$err"
  if storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 1 >"$out" 2>"$err"; then false; fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]

  append_fixture_message small-cap-error xx '2026-01-01T00:00:00Z'
  before="$(store_fingerprint)"
  : > "$err"
  if storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 1 >"$out" 2>"$err"; then false; fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
  : > "$err"
  if storage_get_message_bounded agsuite bob small-cap-error --max-body-bytes 1 >"$out" 2>"$err"; then false; fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "exact show measures the public record at 8192 and rejects 8193" {
  export AGMSG_BOUNDED_MAX_RECORD_BYTES=8192
  local id before after out="$TEST_SKILL_DIR/show-record.stdout" err="$TEST_SKILL_DIR/show-record.stderr" bytes

  id="$(opaque_id_for_record_bytes 8192)"
  append_fixture_message "$id" x '2026-01-01T00:00:00Z'
  before="$(store_fingerprint)"
  storage_get_message_bounded agsuite bob "$id" --max-body-bytes 1 >"$out" 2>"$err"
  [ ! -s "$err" ]
  bytes="$(sed -n '1p' "$out" | wc -c | tr -d ' ')"
  [ "$bytes" -eq 8193 ]
  [ "$(sed -n '1p' "$out" | jq -r '.id')" = "$id" ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]

  reset_bounded_store
  id="$(opaque_id_for_record_bytes 8193)"
  append_fixture_message "$id" x '2026-01-01T00:00:00Z'
  before="$(store_fingerprint)"
  if storage_get_message_bounded agsuite bob "$id" --max-body-bytes 1 >"$out" 2>"$err"; then false; fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "bounded public output failures return non-zero without durable mutation" {
  local id before after out="$TEST_SKILL_DIR/output.stdout" err="$TEST_SKILL_DIR/output.stderr"
  id="$(storage_send agsuite alice bob output-failure)"
  before="$(store_fingerprint)"

  # Fail only the final public emitter. Internal printf calls still work, so
  # this distinguishes a consumer write failure from a query/render failure.
  printf() {
    if [ "$1" = '%s\n' ]; then
      case "${FUNCNAME[1]:-}" in
        _agmsg_bounded_emit_records|_sqlite_bounded_public_result|_jsonl_bounded_emit|storage_get_message_bounded)
          return 1
          ;;
      esac
    fi
    command printf "$@"
  }

  if storage_unread_summary agsuite bob >"$out" 2>"$err"; then false; fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
  : > "$err"
  if storage_list_unread_bounded agsuite bob --limit-items 1 --max-body-bytes 4096 >"$out" 2>"$err"; then false; fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
  : > "$err"
  if storage_get_message_bounded agsuite bob "$id" --max-body-bytes 4096 >"$out" 2>"$err"; then false; fi
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"

  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}

@test "sqlite bounded public result does not mask a final emitter failure" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = sqlite ] || skip "sqlite-specific emitter"
  local payload out="$TEST_SKILL_DIR/sqlite-emitter.stdout" err="$TEST_SKILL_DIR/sqlite-emitter.stderr" rc
  payload=$'{"type":"__agmsg_bounded_status","status":"ok"}\n{"type":"bounded_unread_result","selected_count":0}'
  printf() {
    if [ "$1" = '%s\n' ] && [[ "${2:-}" = '{"type":"bounded_unread_result"'* ]]; then
      return 1
    fi
    command printf "$@"
  }

  set +e
  _sqlite_bounded_public_result "$payload" ok >"$out" 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ]
  [ ! -s "$out" ]
  assert_bounded_stderr "$err"
}

@test "bounded summary projects metadata before aggregation" {
  local large before after
  large="$(repeat_char 20000 x)"
  append_fixture_message summary-large-body "$large" '2026-01-01T00:00:00Z'
  before="$(store_fingerprint)"

  if [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = jsonl ]; then
    local log; log="$(store_dir)/events.jsonl"
    jq() {
      local arg saw_slurp=0
      for arg in "$@"; do [ "$arg" = -s ] && saw_slurp=1; done
      if [ "$saw_slurp" -eq 1 ]; then
        for arg in "$@"; do [ "$arg" = "$log" ] && return 97; done
      fi
      command jq "$@"
    }
  else
    local summary_sql
    summary_sql="$(_sqlite_bounded_summary_sql agsuite bob 8192)"
    [[ "$summary_sql" != *"e.body AS body"* ]]
    [[ "$summary_sql" != *"m.body AS body"* ]]
  fi

  run storage_unread_summary agsuite bob
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.unread_count')" = 1 ]
  [ "$(printf '%s' "$output" | jq -e 'has("body") | not')" = true ]
  [ "$(printf '%s' "$output" | wc -c | tr -d ' ')" -le 256 ]
  after="$(store_fingerprint)"
  [ "$after" = "$before" ]
}
