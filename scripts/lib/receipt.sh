#!/usr/bin/env bash
# Private state and runtime helpers for the optional SQLite receipt capability.
# This file is sourced only by the SQLite storage driver. It does not advertise
# the complete capability; issuance and acknowledgement are added in later
# implementation tasks.

[ -n "${_AGMSG_RECEIPT_SH:-}" ] && return 0
_AGMSG_RECEIPT_SH=1

_AGMSG_RECEIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AGMSG_RECEIPT_SKILL_DIR="$(cd "$_AGMSG_RECEIPT_LIB_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$_AGMSG_RECEIPT_LIB_DIR/receipt-runtime.sh"

_agmsg_receipt_error() { printf 'agmsg receipt: %s\n' "$1" >&2; }

# Receipt read probes need both `.bail on` and an explicit backend outcome.
# Their stderr is captured only for classification and is never re-emitted:
# sqlite3 diagnostics can contain database paths. 13 is reserved for a
# transient busy/locked backend; every other failed read is invalid state.
_agmsg_receipt_sqlite_read() {
  local db="$1" sql="$2" result status
  if result="$(
      printf '.bail on\n%s\n' "$sql" |
        LC_ALL=C agmsg_sqlite -batch "$db" 2>&1
    )"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    case "$result" in
      *'database is locked'*|*'database table is locked'*|*'database schema is locked'*)
        return 13
        ;;
      *) return 12 ;;
    esac
  fi
  result="$(printf '%s' "$result" | /usr/bin/tr -d '\r')" || return 13
  printf '%s' "$result"
}

_agmsg_receipt_control_result() {
  local status="$1"
  case "$status" in
    0) printf '%s\n' ok ;;
    10) printf '%s\n' missing_deps ;;
    12) printf '%s\n' corrupt_state ;;
    *) status=13; printf '%s\n' runtime_error ;;
  esac
  return "$status"
}

_agmsg_receipt_platform() {
  case "$(/usr/bin/uname -s 2>/dev/null)" in
    Darwin|Linux) return 0 ;;
    *)
      _agmsg_receipt_error 'receipt state is unsupported on this platform'
      return 13
      ;;
  esac
}

_agmsg_receipt_db() { agmsg_db_path "$1"; }
_agmsg_receipt_store_dir() { dirname "$(_agmsg_receipt_db "$1")"; }
_agmsg_receipt_dir() { printf '%s/receipt-v1\n' "$(_agmsg_receipt_store_dir "$1")"; }
_agmsg_receipt_private_key() { printf '%s/private.pem\n' "$(_agmsg_receipt_dir "$1")"; }
_agmsg_receipt_public_key() { printf '%s/public.pem\n' "$(_agmsg_receipt_dir "$1")"; }
_agmsg_receipt_lock() { printf '%s/init.lock\n' "$(_agmsg_receipt_dir "$1")"; }

_agmsg_receipt_stat() {
  case "$(/usr/bin/uname -s 2>/dev/null)" in
    Darwin) stat -f '%u:%Lp:%l:%d:%i' "$1" 2>/dev/null ;;
    Linux) stat -c '%u:%a:%h:%d:%i' "$1" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

_agmsg_receipt_mode_safe() {
  local mode="$1"
  case "$mode" in
    [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
    *) return 1 ;;
  esac
  [ $((8#$mode & 8#22)) -eq 0 ]
}

_agmsg_receipt_validate_dir() {
  local path="$1" exact_mode="${2:-}" fields owner mode _links _dev _inode
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  fields="$(_agmsg_receipt_stat "$path")" || return 1
  IFS=: read -r owner mode _links _dev _inode <<EOF
$fields
EOF
  [ "$owner" = "$(id -u)" ] || return 1
  if [ -n "$exact_mode" ]; then
    [ "$mode" = "$exact_mode" ] || return 1
  else
    _agmsg_receipt_mode_safe "$mode" || return 1
  fi
}

_agmsg_receipt_validate_file() {
  local path="$1" exact_mode="${2:-}" fields owner mode links _dev _inode
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  fields="$(_agmsg_receipt_stat "$path")" || return 1
  IFS=: read -r owner mode links _dev _inode <<EOF
$fields
EOF
  [ "$owner" = "$(id -u)" ] && [ "$links" = 1 ] || return 1
  if [ -n "$exact_mode" ]; then
    [ "$mode" = "$exact_mode" ] || return 1
  else
    _agmsg_receipt_mode_safe "$mode" || return 1
  fi
}

_agmsg_receipt_validate_store() {
  local team="$1" db parent
  db="$(_agmsg_receipt_db "$team")" || {
    _agmsg_receipt_error 'cannot resolve SQLite store'
    return 12
  }
  parent="$(dirname "$db")"
  _agmsg_receipt_validate_dir "$parent" || {
    _agmsg_receipt_error 'storage directory integrity check failed'
    return 12
  }
  _agmsg_receipt_validate_file "$db" || {
    _agmsg_receipt_error 'SQLite database integrity check failed'
    return 12
  }
}

_agmsg_receipt_capability_claim_check() {
  local team="$1" db description count capabilities old_ifs token seen='' rc

  if [ -e "$_AGMSG_RECEIPT_SKILL_DIR/scripts/lib/claims.sh" ] ||
     [ -L "$_AGMSG_RECEIPT_SKILL_DIR/scripts/lib/claims.sh" ]; then
    _agmsg_receipt_error 'message claim capability conflicts with receipt state'
    return 13
  fi
  for token in agmsg_claim_next agmsg_ack_claim agmsg_release_claim; do
    if declare -F "$token" >/dev/null 2>&1; then
      _agmsg_receipt_error 'message claim capability conflicts with receipt state'
      return 13
    fi
  done

  description="$(storage_describe 2>/dev/null)" || {
    _agmsg_receipt_error 'storage capability metadata is invalid'
    return 12
  }
  count="$(printf '%s\n' "$description" | awk -F= '$1 == "capabilities" { count++ } END { print count+0 }')"
  [ "$count" = 1 ] || {
    _agmsg_receipt_error 'storage capability metadata is invalid'
    return 12
  }
  capabilities="$(printf '%s\n' "$description" | awk -F= '$1 == "capabilities" { print substr($0, length($1)+2) }')"
  case "$capabilities" in ''|,*|*,|*,,*)
    _agmsg_receipt_error 'storage capability metadata is invalid'
    return 12
    ;;
  esac
  old_ifs="$IFS"
  IFS=,
  for token in $capabilities; do
    IFS="$old_ifs"
    if ! [[ "$token" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      _agmsg_receipt_error 'storage capability metadata is invalid'
      return 12
    fi
    case ",$seen," in *,"$token",*)
      _agmsg_receipt_error 'storage capability metadata is invalid'
      return 12
      ;;
    esac
    seen="${seen:+$seen,}$token"
    case "$token" in message-claim-*)
      _agmsg_receipt_error 'message claim capability conflicts with receipt state'
      return 13
      ;;
    esac
    IFS=,
  done
  IFS="$old_ifs"

  db="$(_agmsg_receipt_db "$team")" || return 12
  count="$(_agmsg_receipt_sqlite_read "$db" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='claims';")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 13 ]; then
      _agmsg_receipt_error 'SQLite backend is busy'
      return 13
    fi
    _agmsg_receipt_error 'cannot inspect SQLite capability metadata'
    return 12
  fi
  case "$count" in
    0) return 0 ;;
    1)
      _agmsg_receipt_error 'message claim capability conflicts with receipt state'
      return 13
      ;;
    *)
      _agmsg_receipt_error 'SQLite claim capability metadata is invalid'
      return 12
      ;;
  esac
}

_agmsg_receipt_state_kind() {
  local db="$1" result status
  result="$(_agmsg_receipt_sqlite_read "$db" "
    SELECT
      (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='receipt_meta') || ':' ||
      (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='receipt_nonces');
  ")"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  case "$result" in
    0:0) printf '%s\n' absent ;;
    1:1) printf '%s\n' ready ;;
    *) printf '%s\n' partial ;;
  esac
}

_agmsg_receipt_schema_valid() {
  local db="$1" result status
  result="$(_agmsg_receipt_sqlite_read "$db" "
    SELECT CASE WHEN
      (SELECT group_concat(name || ':' || type || ':' || \"notnull\" || ':' || pk, ',')
         FROM (SELECT name,type,\"notnull\",pk FROM pragma_table_info('receipt_meta') ORDER BY cid))
        = 'key:TEXT:0:1,value:TEXT:1:0'
      AND
      (SELECT group_concat(name || ':' || type || ':' || \"notnull\" || ':' || pk, ',')
         FROM (SELECT name,type,\"notnull\",pk FROM pragma_table_info('receipt_nonces') ORDER BY cid))
        = 'nonce:TEXT:0:1,payload_sha256:TEXT:1:0,store_generation:TEXT:1:0,team_sha256:TEXT:1:0,recipient_sha256:TEXT:1:0,batch_sha256:TEXT:1:0,frame_sha256:TEXT:1:0,expires_at:INTEGER:1:0,committed_at:INTEGER:1:0'
      AND (SELECT COUNT(*) FROM receipt_meta) = 3
      AND (SELECT COUNT(*) FROM receipt_meta WHERE key='schema_version' AND value='1') = 1
      AND (SELECT COUNT(*) FROM receipt_meta WHERE key='store_generation'
             AND length(value)=32 AND value NOT GLOB '*[^0-9a-f]*') = 1
      AND (SELECT COUNT(*) FROM receipt_meta WHERE key='public_key_sha256'
             AND length(value)=64 AND value NOT GLOB '*[^0-9a-f]*') = 1
      AND NOT EXISTS (
        SELECT 1 FROM receipt_nonces
         WHERE length(nonce)!=32 OR nonce GLOB '*[^0-9a-f]*'
            OR length(payload_sha256)!=64 OR payload_sha256 GLOB '*[^0-9a-f]*'
            OR length(store_generation)!=32 OR store_generation GLOB '*[^0-9a-f]*'
            OR length(team_sha256)!=64 OR team_sha256 GLOB '*[^0-9a-f]*'
            OR length(recipient_sha256)!=64 OR recipient_sha256 GLOB '*[^0-9a-f]*'
            OR length(batch_sha256)!=64 OR batch_sha256 GLOB '*[^0-9a-f]*'
            OR length(frame_sha256)!=64 OR frame_sha256 GLOB '*[^0-9a-f]*'
            OR typeof(expires_at)!='integer' OR typeof(committed_at)!='integer'
      )
    THEN 1 ELSE 0 END;
  ")"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  [ "$result" = 1 ] || return 12
}

_agmsg_receipt_public_fingerprint() {
  local public="$1" output digest
  output="$("$AGMSG_RECEIPT_OPENSSL_RESOLVED" dgst -sha256 -r "$public" \
    2>/dev/null)" || return 1
  IFS=' ' read -r digest _ <<EOF
$output
EOF
  _agmsg_receipt_runtime_is_sha256 "$digest" || return 1
  printf '%s\n' "$digest"
}

_agmsg_receipt_keys_valid() {
  local team="$1" private public db tmp derived actual expected status cleanup_status=0
  private="$(_agmsg_receipt_private_key "$team")"
  public="$(_agmsg_receipt_public_key "$team")"
  db="$(_agmsg_receipt_db "$team")"
  _agmsg_receipt_validate_file "$private" 600 || return 12
  _agmsg_receipt_validate_file "$public" 600 || return 12

  tmp="$(/usr/bin/mktemp -d \
    "${TMPDIR:-/tmp}/agmsg-receipt-keycheck.XXXXXX" 2>/dev/null)" ||
    return 13
  /bin/chmod 700 "$tmp" 2>/dev/null || {
    /bin/rm -rf -- "$tmp" 2>/dev/null || true
    return 13
  }
  derived="$tmp/public.pem"
  if ! "$AGMSG_RECEIPT_OPENSSL_RESOLVED" pkey -in "$private" -pubout \
      -out "$derived" >/dev/null 2>&1 ||
     ! /usr/bin/cmp -s "$derived" "$public"; then
    /bin/rm -rf -- "$tmp" 2>/dev/null || cleanup_status=1
    [ "$cleanup_status" -eq 0 ] || return 13
    return 12
  fi
  /bin/rm -rf -- "$tmp" 2>/dev/null || return 13

  actual="$(_agmsg_receipt_public_fingerprint "$public")" || return 12
  expected="$(_agmsg_receipt_sqlite_read "$db" \
    "SELECT value FROM receipt_meta WHERE key='public_key_sha256';")"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  [ "$actual" = "$expected" ] || return 12
}

_agmsg_receipt_validate_ready() {
  local team="$1" dir db kind status
  dir="$(_agmsg_receipt_dir "$team")"
  db="$(_agmsg_receipt_db "$team")"
  _agmsg_receipt_validate_store "$team" || return $?
  kind="$(_agmsg_receipt_state_kind "$db")"
  status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 13 ]; then
      _agmsg_receipt_error 'SQLite backend is busy'
    else
      _agmsg_receipt_error 'cannot inspect receipt schema'
    fi
    return "$status"
  fi
  if [ "$kind" = absent ]; then
    _agmsg_receipt_error 'receipt state is not initialized'
    [ ! -e "$dir" ] && [ ! -L "$dir" ] && return 13
    return 12
  fi
  [ "$kind" = ready ] || {
    _agmsg_receipt_error 'receipt schema is incomplete'
    return 12
  }
  _agmsg_receipt_validate_dir "$dir" 700 || {
    _agmsg_receipt_error 'receipt directory integrity check failed'
    return 12
  }
  _agmsg_receipt_schema_valid "$db"
  status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 13 ]; then
      _agmsg_receipt_error 'SQLite backend is busy'
    else
      _agmsg_receipt_error 'receipt schema or nonce state is invalid'
    fi
    return "$status"
  fi
  _agmsg_receipt_keys_valid "$team"
  status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 13 ]; then
      _agmsg_receipt_error 'cannot validate receipt key state'
    else
      _agmsg_receipt_error 'receipt key state is invalid'
    fi
    return "$status"
  fi
}

_AGMSG_RECEIPT_INIT_LOCK=
_AGMSG_RECEIPT_INIT_STAGE=
_AGMSG_RECEIPT_INIT_NONCE=
_AGMSG_RECEIPT_INIT_IDENTITY=
_AGMSG_RECEIPT_INIT_PID=
_AGMSG_RECEIPT_INIT_HELD=0
_AGMSG_RECEIPT_RECOVERED_EMPTY=0

_agmsg_receipt_lock_record() {
  local path="$1" line1 line2 line3 extra
  line1='' line2='' line3='' extra=''
  {
    IFS= read -r line1 || true
    IFS= read -r line2 || true
    IFS= read -r line3 || true
    IFS= read -r extra || true
  } <"$path" 2>/dev/null || return 1
  [ -z "$extra" ] || return 1
  case "$line1" in pid=[0-9]*) ;; *) return 1 ;; esac
  case "${line1#pid=}" in ''|*[!0-9]*) return 1 ;; esac
  case "$line2" in owner_nonce=[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) return 1 ;; esac
  case "$line3" in created_at=[0-9]*) ;; *) return 1 ;; esac
  case "${line3#created_at=}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s:%s:%s\n' "${line1#pid=}" "${line2#owner_nonce=}" "${line3#created_at=}"
}

_agmsg_receipt_same_inode() {
  local first second
  first="$(_agmsg_receipt_file_identity "$1")" || return 1
  second="$(_agmsg_receipt_file_identity "$2")" || return 1
  [ "$first" = "$second" ]
}

_agmsg_receipt_file_identity() {
  local stat owner mode links dev inode
  stat="$(_agmsg_receipt_stat "$1")" || return 1
  IFS=: read -r owner mode links dev inode <<EOF
$stat
EOF
  [ -n "$dev" ] && [ -n "$inode" ] || return 1
  printf '%s:%s\n' "$dev" "$inode"
}

# kill -0 can fail with EPERM for a live process under a sandbox. Reclamation
# requires positive absence from the process table as well; an unobservable PID
# is conservatively treated as live/unknown and never removed.
_agmsg_receipt_pid_is_live_or_unknown() {
  local pid="$1" error
  kill -0 "$pid" 2>/dev/null && return 0
  error="$(export LC_ALL=C; kill -0 "$pid" 2>&1)"
  case "$error" in
    *[Nn]'o such process'*) return 1 ;;
    *) return 0 ;;
  esac
}

_agmsg_receipt_lock_file_valid() {
  local path="$1" links_allowed="$2" stat owner mode links _dev _inode
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  stat="$(_agmsg_receipt_stat "$path")" || return 1
  IFS=: read -r owner mode links _dev _inode <<EOF
$stat
EOF
  [ "$owner" = "$(id -u)" ] && [ "$mode" = 600 ] || return 1
  case ":$links_allowed:" in *:"$links":*) return 0 ;; *) return 1 ;; esac
}

_agmsg_receipt_remove_own_lock() {
  local record stat
  [ "${_AGMSG_RECEIPT_INIT_HELD:-0}" -eq 1 ] || return 0
  [ -f "$_AGMSG_RECEIPT_INIT_LOCK" ] && [ ! -L "$_AGMSG_RECEIPT_INIT_LOCK" ] || return 0
  record="$(_agmsg_receipt_lock_record "$_AGMSG_RECEIPT_INIT_LOCK")" || return 0
  case "$record" in
    "$_AGMSG_RECEIPT_INIT_PID:$_AGMSG_RECEIPT_INIT_NONCE:"*) ;;
    *) return 0 ;;
  esac
  stat="$(_agmsg_receipt_file_identity "$_AGMSG_RECEIPT_INIT_LOCK")" || return 0
  [ "$stat" = "$_AGMSG_RECEIPT_INIT_IDENTITY" ] || return 0
  /bin/rm -f -- "$_AGMSG_RECEIPT_INIT_LOCK"
  _AGMSG_RECEIPT_INIT_HELD=0
}

_agmsg_receipt_init_cleanup() {
  _agmsg_receipt_remove_own_lock
  if [ -n "${_AGMSG_RECEIPT_INIT_STAGE:-}" ] &&
     [ -f "$_AGMSG_RECEIPT_INIT_STAGE" ] &&
     [ ! -L "$_AGMSG_RECEIPT_INIT_STAGE" ]; then
    local record
    record="$(_agmsg_receipt_lock_record "$_AGMSG_RECEIPT_INIT_STAGE")" || record=
    case "$record" in "$_AGMSG_RECEIPT_INIT_PID:$_AGMSG_RECEIPT_INIT_NONCE:"*)
      /bin/rm -f -- "$_AGMSG_RECEIPT_INIT_STAGE"
      ;;
    esac
  fi
}

_agmsg_receipt_lock_state() {
  local lock="$1" dir record pid nonce _created stat owner mode links dev inode stage stage_record
  _agmsg_receipt_lock_file_valid "$lock" '1:2' || return 12
  record="$(_agmsg_receipt_lock_record "$lock")" || return 12
  IFS=: read -r pid nonce _created <<EOF
$record
EOF
  stat="$(_agmsg_receipt_stat "$lock")" || return 12
  IFS=: read -r owner mode links dev inode <<EOF
$stat
EOF
  if _agmsg_receipt_pid_is_live_or_unknown "$pid"; then return 13; fi
  if [ "$links" = 2 ]; then
    dir="$(dirname "$lock")"
    stage="$dir/.init-stage.$nonce"
    _agmsg_receipt_lock_file_valid "$stage" 2 || return 12
    _agmsg_receipt_same_inode "$lock" "$stage" || return 12
    stage_record="$(_agmsg_receipt_lock_record "$stage")" || return 12
    [ "$stage_record" = "$record" ] || return 12
    /bin/rm -f -- "$stage" || return 13
  else
    stage="$(dirname "$lock")/.init-stage.$nonce"
    [ ! -e "$stage" ] && [ ! -L "$stage" ] || return 12
  fi
  /bin/rm -f -- "$lock" || return 13
  _AGMSG_RECEIPT_RECOVERED_EMPTY=1
  return 0
}

_agmsg_receipt_reclaim_stages() {
  local dir="$1" stage record pid nonce _created suffix stat owner mode links _dev _inode
  for stage in "$dir"/.init-stage.*; do
    [ -e "$stage" ] || [ -L "$stage" ] || continue
    _agmsg_receipt_lock_file_valid "$stage" 1 || return 12
    record="$(_agmsg_receipt_lock_record "$stage")" || return 12
    IFS=: read -r pid nonce _created <<EOF
$record
EOF
    suffix="${stage##*/.init-stage.}"
    [ "$suffix" = "$nonce" ] || return 12
    if _agmsg_receipt_pid_is_live_or_unknown "$pid"; then return 13; fi
    /bin/rm -f -- "$stage" || return 13
    _AGMSG_RECEIPT_RECOVERED_EMPTY=1
  done
}

_agmsg_receipt_acquire_init_lock() {
  local team="$1" dir lock attempt=0 created_at stat
  dir="$(_agmsg_receipt_dir "$team")"
  lock="$(_agmsg_receipt_lock "$team")"
  _AGMSG_RECEIPT_INIT_LOCK="$lock"

  while [ "$attempt" -lt 100 ]; do
    if [ -e "$lock" ] || [ -L "$lock" ]; then
      _agmsg_receipt_lock_state "$lock"
      case $? in
        0) continue ;;
        12) _agmsg_receipt_error 'receipt init lock state is corrupt'; return 12 ;;
        *) attempt=$((attempt + 1)); sleep 0.05; continue ;;
      esac
    fi
    _agmsg_receipt_reclaim_stages "$dir"
    case $? in
      0) ;;
      12) _agmsg_receipt_error 'receipt init staging state is corrupt'; return 12 ;;
      *) attempt=$((attempt + 1)); sleep 0.05; continue ;;
    esac

    _AGMSG_RECEIPT_INIT_NONCE="$("$AGMSG_RECEIPT_OPENSSL_RESOLVED" rand -hex 16 \
      2>/dev/null)" || {
      _agmsg_receipt_error 'cannot generate receipt init owner nonce'
      return 13
    }
    case "$_AGMSG_RECEIPT_INIT_NONCE" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *) _agmsg_receipt_error 'invalid receipt init owner nonce'; return 13 ;;
    esac
    _AGMSG_RECEIPT_INIT_STAGE="$dir/.init-stage.$_AGMSG_RECEIPT_INIT_NONCE"
    created_at="$(date +%s)"
    ( umask 077
      printf 'pid=%s\nowner_nonce=%s\ncreated_at=%s\n' \
        "$_AGMSG_RECEIPT_INIT_PID" "$_AGMSG_RECEIPT_INIT_NONCE" "$created_at" \
        >"$_AGMSG_RECEIPT_INIT_STAGE"
    ) || return 13
    /bin/chmod 600 "$_AGMSG_RECEIPT_INIT_STAGE" || return 13
    if ln "$_AGMSG_RECEIPT_INIT_STAGE" "$lock" 2>/dev/null; then
      stat="$(_agmsg_receipt_file_identity "$lock")" || return 13
      _AGMSG_RECEIPT_INIT_IDENTITY="$stat"
      _AGMSG_RECEIPT_INIT_HELD=1
      /bin/rm -f -- "$_AGMSG_RECEIPT_INIT_STAGE" || return 13
      _AGMSG_RECEIPT_INIT_STAGE=
      return 0
    fi
    /bin/rm -f -- "$_AGMSG_RECEIPT_INIT_STAGE"
    _AGMSG_RECEIPT_INIT_STAGE=
    attempt=$((attempt + 1))
    sleep 0.05
  done
  _agmsg_receipt_error 'timed out waiting for receipt init lock'
  return 13
}

_agmsg_receipt_create_state() {
  local team="$1" private public db generation fingerprint sql
  private="$(_agmsg_receipt_private_key "$team")"
  public="$(_agmsg_receipt_public_key "$team")"
  db="$(_agmsg_receipt_db "$team")"
  [ ! -e "$private" ] && [ ! -L "$private" ] &&
    [ ! -e "$public" ] && [ ! -L "$public" ] || {
    _agmsg_receipt_error 'pre-existing receipt key state is incomplete'
    return 12
  }

  umask 077
  "$AGMSG_RECEIPT_OPENSSL_RESOLVED" genpkey -algorithm ED25519 -out "$private" \
    >/dev/null 2>&1 || {
    _agmsg_receipt_error 'cannot generate receipt private key'
    return 13
  }
  /bin/chmod 600 "$private" || return 13
  "$AGMSG_RECEIPT_OPENSSL_RESOLVED" pkey -in "$private" -pubout -out "$public" \
    >/dev/null 2>&1 || {
    _agmsg_receipt_error 'cannot derive receipt public key'
    return 13
  }
  /bin/chmod 600 "$public" || return 13
  if ! _agmsg_receipt_validate_file "$private" 600 ||
     ! _agmsg_receipt_validate_file "$public" 600; then
    _agmsg_receipt_error 'new receipt key filesystem state is invalid'
    return 12
  fi
  fingerprint="$(_agmsg_receipt_public_fingerprint "$public")" || {
    _agmsg_receipt_error 'cannot fingerprint receipt public key'
    return 13
  }
  generation="$("$AGMSG_RECEIPT_OPENSSL_RESOLVED" rand -hex 16 2>/dev/null)" ||
    return 13
  case "$generation" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) _agmsg_receipt_error 'invalid store generation'; return 13 ;;
  esac

  sql=".bail on
BEGIN IMMEDIATE;
CREATE TABLE receipt_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE receipt_nonces (
  nonce TEXT PRIMARY KEY,
  payload_sha256 TEXT NOT NULL,
  store_generation TEXT NOT NULL,
  team_sha256 TEXT NOT NULL,
  recipient_sha256 TEXT NOT NULL,
  batch_sha256 TEXT NOT NULL,
  frame_sha256 TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  committed_at INTEGER NOT NULL
);
INSERT INTO receipt_meta(key,value) VALUES
  ('schema_version','1'),
  ('store_generation','$generation'),
  ('public_key_sha256','$fingerprint');
COMMIT;"
  printf '%s\n' "$sql" | agmsg_sqlite -batch "$db" >/dev/null 2>&1 || {
    _agmsg_receipt_error 'cannot commit receipt metadata'
    return 13
  }
}

storage_receipt_status() (
  local team="${1:-}" rc
  if [ "$#" -ne 1 ] ||
     ! agmsg_validate_team_name "$team" >/dev/null 2>&1; then
    _agmsg_receipt_error 'status requires one valid team selector'
    _agmsg_receipt_control_result 13
    exit $?
  fi
  _agmsg_receipt_platform || {
    rc=$?; _agmsg_receipt_control_result "$rc"; exit $?
  }
  _agmsg_receipt_validate_store "$team" || {
    rc=$?; _agmsg_receipt_control_result "$rc"; exit $?
  }
  agmsg_receipt_resolve_runtime || {
    rc=$?; _agmsg_receipt_control_result "$rc"; exit $?
  }
  _agmsg_receipt_capability_claim_check "$team" || {
    rc=$?; _agmsg_receipt_control_result "$rc"; exit $?
  }
  _agmsg_receipt_validate_ready "$team"
  rc=$?
  _agmsg_receipt_control_result "$rc"
)

storage_receipt_init() (
  local team="${1:-}" rc dir db kind created_dir=0
  if [ "$#" -ne 1 ] ||
     ! agmsg_validate_team_name "$team" >/dev/null 2>&1; then
    _agmsg_receipt_error 'init requires one valid team selector'
    _agmsg_receipt_control_result 13
    exit $?
  fi
  # Bash 3.2 keeps $$ fixed across subshells. Ask a short-lived child for its
  # PPID to record the actual process executing this scoped initializer.
  _AGMSG_RECEIPT_INIT_PID="$(/bin/sh -c 'printf %s "$PPID"')"
  case "$_AGMSG_RECEIPT_INIT_PID" in
    ''|*[!0-9]*)
      _agmsg_receipt_error 'cannot determine receipt initializer process'
      _agmsg_receipt_control_result 13
      exit $?
      ;;
  esac
  trap _agmsg_receipt_init_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  _agmsg_receipt_platform || {
    rc=$?; _agmsg_receipt_control_result "$rc"; exit $?
  }
  _agmsg_receipt_validate_store "$team" || {
    rc=$?; _agmsg_receipt_control_result "$rc"; exit $?
  }
  agmsg_receipt_resolve_runtime || {
    rc=$?; _agmsg_receipt_control_result "$rc"; exit $?
  }
  _agmsg_receipt_capability_claim_check "$team" || {
    rc=$?; _agmsg_receipt_control_result "$rc"; exit $?
  }

  dir="$(_agmsg_receipt_dir "$team")"
  db="$(_agmsg_receipt_db "$team")"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    if ( umask 077; mkdir "$dir" ); then
      created_dir=1
      /bin/chmod 700 "$dir" || {
        _agmsg_receipt_error 'cannot protect receipt directory'
        _agmsg_receipt_control_result 13
        exit $?
      }
    fi
  fi
  _agmsg_receipt_validate_dir "$dir" 700 || {
    _agmsg_receipt_error 'receipt directory integrity check failed'
    _agmsg_receipt_control_result 12
    exit $?
  }

  _agmsg_receipt_acquire_init_lock "$team" || {
    rc=$?; _agmsg_receipt_control_result "$rc"; exit $?
  }
  _agmsg_receipt_validate_store "$team" || {
    rc=$?; _agmsg_receipt_control_result "$rc"; exit $?
  }
  _agmsg_receipt_capability_claim_check "$team" || {
    rc=$?; _agmsg_receipt_control_result "$rc"; exit $?
  }

  kind="$(_agmsg_receipt_state_kind "$db")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 13 ]; then
      _agmsg_receipt_error 'SQLite backend is busy'
    else
      _agmsg_receipt_error 'cannot inspect receipt schema'
    fi
    _agmsg_receipt_control_result "$rc"
    exit $?
  fi
  case "$kind" in
    ready)
      _agmsg_receipt_validate_ready "$team"
      rc=$?
      _agmsg_receipt_control_result "$rc"
      exit $?
      ;;
    partial)
      _agmsg_receipt_error 'receipt schema is incomplete'
      _agmsg_receipt_control_result 12
      exit $?
      ;;
    absent)
      if [ "$created_dir" -ne 1 ] && [ "$_AGMSG_RECEIPT_RECOVERED_EMPTY" -ne 1 ]; then
        _agmsg_receipt_error 'pre-existing empty receipt state is degraded'
        _agmsg_receipt_control_result 12
        exit $?
      fi
      ;;
  esac
  _agmsg_receipt_create_state "$team" || {
    rc=$?; _agmsg_receipt_control_result "$rc"; exit $?
  }
  _agmsg_receipt_validate_ready "$team"
  rc=$?
  _agmsg_receipt_control_result "$rc"
)
