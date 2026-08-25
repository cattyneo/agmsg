#!/usr/bin/env bash

# Deterministic Task 5 mutation helpers.  Every mutation is applied to a
# throw-away archive copy; the implementation checkout is never edited.

receipt_mutation_archive() {
  local source="$1" destination="$2"
  mkdir -p "$destination" || return 1
  git -C "$source" archive --format=tar HEAD | tar -x -C "$destination" || return 1
}

# Keep each nested regression bounded.  Perl is part of the macOS base system
# and the alarm is applied to the nested test process without logging output.
receipt_run_bounded() {
  local seconds="$1"
  shift
  /usr/bin/perl -e 'my $seconds=shift; alarm($seconds); exec @ARGV or exit 127' \
    "$seconds" "$@"
}

# A fixed SQLite clock makes the retention-boundary mutant deterministic.  The
# probe runs the normal init/issue/ack path in a scratch installation and
# checks that a nonce at exactly now-86400 is retained (strict '<' pruning).
receipt_prune_boundary_probe() (
  local root="$1" work="$2" fixed_now db token real_sqlite
  fixed_now="$(date +%s)" || exit 1
  mkdir -p "$work/skill" || exit 1
  cp -R "$root/scripts/." "$work/skill/scripts/" || exit 1
  chmod +x "$work/skill/scripts/"*.sh 2>/dev/null || true
  export TEST_SKILL_DIR="$work/skill" HOME="$work/home" SCRIPTS="$work/skill/scripts"
  export SKILL_DIR="$TEST_SKILL_DIR" AGMSG_STORAGE_DRIVER=sqlite AGMSG_STORAGE_PATH="$work/store"
  mkdir -p "$HOME"
  bash "$SCRIPTS/internal/init-db.sh" || exit 1
  # shellcheck disable=SC1091
  . "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load || exit 1
  storage_init receipts >/dev/null || exit 1
  storage_receipt_init receipts >/dev/null || exit 1
  real_sqlite="$(command -v sqlite3)" || exit 1
  agmsg_sqlite() {
    local input="$work/sql.input" rewritten="$work/sql.rewritten" rc
    case " $* " in
      *' -batch '*)
        /bin/cat >"$input" || return 1
        if grep -q 'DELETE FROM receipt_nonces' "$input"; then
          sed -e "s/expires_at < CAST(strftime('%s','now') AS INTEGER)-86400/expires_at < $fixed_now-86400/" \
            -e "s/expires_at <= CAST(strftime('%s','now') AS INTEGER)-86400/expires_at <= $fixed_now-86400/" \
            "$input" >"$rewritten" || return 1
          "$real_sqlite" "$@" <"$rewritten"
        else
          "$real_sqlite" "$@" <"$input"
        fi
        rc=$?
        /bin/rm -f -- "$input" "$rewritten"
        return "$rc"
        ;;
      *) "$real_sqlite" "$@" ;;
    esac
  }
  db="$(agmsg_db_path receipts)" || exit 1
  sqlite3 "$db" "INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    VALUES('message_sent','boundary','receipts','alice','bob','body','2026-01-01T00:00:00Z');" >/dev/null || exit 1
  token="$(storage_list_unread_bounded receipts bob --limit-items 1 --max-body-bytes 4096 --issue-receipt |
    jq -r 'select(.type == "bounded_unread_receipt") | .receipt')" || exit 1
  [ -n "$token" ] || exit 1
  sqlite3 "$db" "INSERT INTO receipt_nonces VALUES(
    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    (SELECT value FROM receipt_meta WHERE key='store_generation'),
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    $((fixed_now - 86400)),$((fixed_now - 86400)));" || exit 1
  storage_ack_receipt receipts bob --receipt "$token" >/dev/null 2>/dev/null || exit 1
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM receipt_nonces WHERE nonce='eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';")" = 1 ]
)

_receipt_mutation_rewrite() {
  local file="$1" needle="$2" replacement="$3" tmp line before after count=0
  tmp="${file}.mutation.$$"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"$needle"*)
        count=$((count + 1))
        before="${line%%"$needle"*}"
        after="${line#*"$needle"}"
        line="${before}${replacement}${after}"
        ;;
    esac
    printf '%s\n' "$line"
  done <"$file" >"$tmp" || return 1
  [ "$count" -eq 1 ] || {
    /bin/rm -f -- "$tmp"
    return 1
  }
  /bin/mv -- "$tmp" "$file" || return 1
  /bin/chmod 755 "$file" 2>/dev/null || true
}

_receipt_mutation_delete() {
  local file="$1" needle="$2" tmp line count=0
  tmp="${file}.mutation.$$"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"$needle"*) count=$((count + 1)); continue ;;
    esac
    printf '%s\n' "$line"
  done <"$file" >"$tmp" || return 1
  [ "$count" -eq 1 ] || {
    /bin/rm -f -- "$tmp"
    return 1
  }
  /bin/mv -- "$tmp" "$file" || return 1
  /bin/chmod 755 "$file" 2>/dev/null || true
}

_receipt_mutation_insert_after() {
  local file="$1" needle="$2" extra="$3" tmp line count=0
  tmp="${file}.mutation.$$"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    case "$line" in
      *"$needle"*) count=$((count + 1)); printf '%s\n' "$extra" ;;
    esac
  done <"$file" >"$tmp" || return 1
  [ "$count" -eq 1 ] || {
    /bin/rm -f -- "$tmp"
    return 1
  }
  /bin/mv -- "$tmp" "$file" || return 1
  /bin/chmod 755 "$file" 2>/dev/null || true
}

_receipt_mutation_rewrite_nth() {
  local file="$1" needle="$2" replacement="$3" wanted="$4" tmp line before after count=0 matches=0
  tmp="${file}.mutation.$$"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"$needle"*)
        matches=$((matches + 1))
        if [ "$matches" -eq "$wanted" ]; then
          count=$((count + 1))
          before="${line%%"$needle"*}"
          after="${line#*"$needle"}"
          line="${before}${replacement}${after}"
        fi
        ;;
    esac
    printf '%s\n' "$line"
  done <"$file" >"$tmp" || return 1
  [ "$count" -eq 1 ] || {
    /bin/rm -f -- "$tmp"
    return 1
  }
  /bin/mv -- "$tmp" "$file" || return 1
  /bin/chmod 755 "$file" 2>/dev/null || true
}

# Apply one named semantic mutant.  The exact source fragment count is checked
# by the primitive helpers so a moved/duplicated production fragment fails the
# gate instead of silently testing the wrong mutant.
receipt_apply_mutation() {
  local id="$1" root="$2" receipt sqlite
  receipt="$root/scripts/lib/receipt.sh"
  sqlite="$root/scripts/drivers/storage/sqlite.sh"
  case "$id" in
    nonce-outside-transaction)
      _receipt_mutation_rewrite "$sqlite" \
        "printf 'BEGIN IMMEDIATE;\\n'" \
        ':' || return 1
      ;;
    no-bail)
      _receipt_mutation_rewrite "$sqlite" \
        "printf '.bail on\\n.timeout 1000\\n'" \
        "printf '.timeout 1000\\n'" || return 1
      ;;
    ignore-commit-result)
      _receipt_mutation_rewrite "$sqlite" \
        '[ "$rc" -eq 0 ] && [ -z "$result" ] && return 0' \
        'return 0' || return 1
      ;;
    no-prefix-reconstruction)
      _receipt_mutation_rewrite "$receipt" \
        '[ "$actual_batch" = "$batch_sha" ] && [ "$actual_frame" = "$frame_sha" ] || {' \
        'true || {' || return 1
      ;;
    no-in-transaction-expiry)
      _receipt_mutation_rewrite "$sqlite" \
        "AND CAST(strftime('%%s','now') AS INTEGER)<%s" \
        'AND 1' || return 1
      ;;
    no-recipient-binding)
      _receipt_mutation_rewrite "$receipt" \
        '[ "$team_hex" = "$expected_team" ] && [ "$recipient_hex" = "$expected_recipient" ]' \
        '[ "$team_hex" = "$expected_team" ]' || return 1
      ;;
    no-store-binding)
      _receipt_mutation_rewrite "$receipt" \
        '[ "$generation" = "$actual_generation" ] && [ "$key_sha" = "$actual_key" ]' \
        '[ "$generation" = "$actual_generation" ]' || return 1
      ;;
    no-frame-binding)
      _receipt_mutation_rewrite "$receipt" \
        '[ "$actual_batch" = "$batch_sha" ] && [ "$actual_frame" = "$frame_sha" ]' \
        '[ "$actual_batch" = "$batch_sha" ]' || return 1
      ;;
    no-temp-body-comparison)
      _receipt_mutation_rewrite "$sqlite" \
        'OR lower(hex(CAST(o.body AS BLOB)))!=x.body_hex)' \
        'OR 0)' || return 1
      ;;
    no-begin-immediate)
      _receipt_mutation_rewrite "$sqlite" \
        "printf 'BEGIN IMMEDIATE;\\n'" \
        "printf 'BEGIN;\\n'" || return 1
      ;;
    no-nonce-uniqueness)
      _receipt_mutation_rewrite "$receipt" \
        'nonce TEXT PRIMARY KEY,' \
        'nonce TEXT,' || return 1
      ;;
    weak-legacy-identity)
      _receipt_mutation_rewrite "$sqlite" \
        'OR lower(hex(CAST(m.created_at AS BLOB)))!=x.at_hex))' \
        'OR 0))' || return 1
      ;;
    no-db-integrity)
      _receipt_mutation_rewrite "$receipt" \
        '_agmsg_receipt_validate_file "$db" || {' \
        'true || {' || return 1
      ;;
    no-receipt-dir-integrity)
      _receipt_mutation_rewrite "$receipt" \
        '[ -d "$path" ] && [ ! -L "$path" ] || return 1' \
        '[ -L "$path" ] && return 0; [ -d "$path" ] || return 1' || return 1
      ;;
    no-key-integrity)
      _receipt_mutation_rewrite "$receipt" \
        '_agmsg_receipt_keys_valid "$team"' \
        'true #' || return 1
      ;;
    no-init-lock-integrity)
      _receipt_mutation_rewrite "$receipt" \
        '_agmsg_receipt_lock_file_valid "$lock" '\''1:2'\'' || return 12' \
        'true' || return 1
      ;;
    no-dead-owner-check)
      _receipt_mutation_rewrite "$receipt" \
        '_agmsg_pid_alive_local "$1"' \
        'return 1' || return 1
      ;;
    no-two-link-init-race)
      _receipt_mutation_rewrite_nth "$receipt" \
        '_agmsg_receipt_lock_file_valid "$stage" '\''1:2'\'' || return 12' \
        '_agmsg_receipt_lock_file_valid "$stage" 1 || return 12' 1 || return 1
      ;;
    no-init-transition-retry)
      _receipt_mutation_rewrite_nth "$receipt" \
        '_agmsg_receipt_reclaim_advanced_state "$stage" "$lock" "$record" "$pid"' \
        'return 12 #' 1 || return 1
      ;;
    no-lock-record-transition-retry)
      _receipt_mutation_rewrite_nth "$receipt" \
        '_agmsg_receipt_reclaim_advanced_state "$stage" "$lock" "$record" "$pid"' \
        'return 12 #' 2 || return 1
      ;;
    no-direct-init-transition-retry)
      _receipt_mutation_rewrite_nth "$receipt" \
        '_agmsg_receipt_reclaim_advanced_state "$stage" "$lock" "$record" "$pid"' \
        'return 12 #' 3 || return 1
      ;;
    wrong-init-owner-pid)
      _receipt_mutation_rewrite "$receipt" \
        '/bin/sh -c '\''printf "%s\n" "$PPID"'\'' >"$_AGMSG_RECEIPT_INIT_PID_FILE" 2>/dev/null || return 13' \
        'printf "%s\n" "$(/bin/sh -c '\''printf %s "$PPID"'\'')" >"$_AGMSG_RECEIPT_INIT_PID_FILE" || return 13' || return 1
      ;;
    unbounded-prune)
      _receipt_mutation_rewrite "$sqlite" \
        "expires_at < CAST(strftime('%%s','now') AS INTEGER)-86400" \
        "expires_at < CAST(strftime('%%s','now') AS INTEGER)" || return 1
      ;;
    no-claim-interlock)
      _receipt_mutation_rewrite_nth "$sqlite" \
        '_agmsg_receipt_capability_claim_check "$team" || return $?' \
        'true #' 2 || return 1
    ;;
    no-precommit-claim-interlock)
      _receipt_mutation_rewrite "$sqlite" \
        'if _agmsg_receipt_capability_claim_check "$team"; then' \
        'if true; then' || return 1
    ;;
    outer-shell-gate-owner)
      _receipt_mutation_rewrite "$sqlite" \
        '_AGMSG_RECEIPT_GATE_PARENT_PID="$parent"' \
        '_AGMSG_RECEIPT_GATE_PARENT_PID="$$"' || return 1
    ;;
    silent-postauth-scope-helper)
      _receipt_mutation_insert_after "$receipt" \
        'expected_team="$(_agmsg_receipt_scope_hex "$team" "$tmp/team-actual.hex")" || {' \
        '    exit 13' || return 1
    ;;
    silent-postcommit-cleanup)
      _receipt_mutation_rewrite_nth "$receipt" \
        '[ "$cleanup_status" -eq 0 ] || {' \
        '[ "$cleanup_status" -eq 0 ] || { exit 13;' 2 || return 1
    ;;
    jsonl-accepts-receipt)
      _receipt_mutation_rewrite "$root/scripts/lib/storage.sh" \
        "printf 'storage: unknown bounded read option\\n' >&2" \
        'return 0' || return 1
    ;;
    receipt-before-records)
      _receipt_mutation_rewrite_nth "$receipt" \
        'records="$(/bin/cat "$public")"' \
        'records="$receipt"' 2 || return 1
      ;;
    prune-boundary-inclusive)
      _receipt_mutation_rewrite "$sqlite" \
        "expires_at < CAST(strftime('%%s','now') AS INTEGER)-86400" \
        "expires_at <= CAST(strftime('%%s','now') AS INTEGER)-86400" || return 1
      ;;
    *)
      printf 'unknown receipt mutation: %s\n' "$id" >&2
      return 2
      ;;
  esac
}
