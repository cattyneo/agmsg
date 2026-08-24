#!/usr/bin/env bash

# Deterministic Task 5 mutation helpers.  Every mutation is applied to a
# throw-away archive copy; the implementation checkout is never edited.

receipt_mutation_archive() {
  local source="$1" destination="$2"
  mkdir -p "$destination" || return 1
  git -C "$source" archive --format=tar HEAD | tar -x -C "$destination" || return 1
}

_receipt_mutation_rewrite() {
  local file="$1" needle="$2" replacement="$3" tmp line count=0
  tmp="${file}.mutation.$$"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"$needle"*)
        count=$((count + 1))
        line="${line/"$needle"/"$replacement"}"
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
  local file="$1" needle="$2" replacement="$3" wanted="$4" tmp line count=0 matches=0
  tmp="${file}.mutation.$$"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"$needle"*)
        matches=$((matches + 1))
        if [ "$matches" -eq "$wanted" ]; then
          count=$((count + 1))
          line="${line/"$needle"/"$replacement"}"
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
      _receipt_mutation_insert_after "$sqlite" \
        "printf 'CREATE TEMP TABLE _ack_guard(value INTEGER CHECK(value=1));\\n'" \
        "printf 'COMMIT;\\n'" || return 1
      ;;
    no-bail)
      _receipt_mutation_rewrite "$sqlite" \
        "printf '.bail on\\n.timeout 1000\\n'" \
        "printf '.timeout 1000\\n'" || return 1
      ;;
    ignore-commit-result)
      _receipt_mutation_rewrite "$sqlite" \
        '[ "$rc" -eq 0 ] && return 0' \
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
        '[ -d "$path" ] || return 1' || return 1
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
        'kill -0 "$pid" 2>/dev/null && return 0' \
        'return 1' || return 1
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
    jsonl-accepts-receipt)
      _receipt_mutation_rewrite "$root/scripts/lib/storage.sh" \
        "printf 'storage: unknown bounded read option\\n' >&2" \
        'continue #' || return 1
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
