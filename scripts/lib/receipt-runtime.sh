#!/usr/bin/env bash
# Deterministic runtime selection for the optional SQLite receipt capability.
# Legacy storage paths never source a runtime executable through PATH: receipt
# operations either use one of the closed platform candidates below or a fully
# probed absolute override.
# shellcheck disable=SC2030,SC2031 # scoped probe helpers share subshell globals

[ -n "${_AGMSG_RECEIPT_RUNTIME_SH:-}" ] && return 0
_AGMSG_RECEIPT_RUNTIME_SH=1

AGMSG_RECEIPT_OPENSSL_RESOLVED=
AGMSG_RECEIPT_XXD_RESOLVED=
_AGMSG_RECEIPT_RUNTIME_TMP=
_AGMSG_RECEIPT_RUNTIME_CHILD_PID=
_AGMSG_RECEIPT_RUNTIME_SELECTED=
_AGMSG_RECEIPT_OPENSSL_VERSION=
_AGMSG_RECEIPT_XXD_VERSION=
_AGMSG_RECEIPT_FIXTURE_SHA256=
_AGMSG_RECEIPT_PUBLIC_KEY_SHA256=
_AGMSG_RECEIPT_RUNTIME_MISSING=10
_AGMSG_RECEIPT_RUNTIME_ERROR=13

agmsg_receipt_runtime_candidates() {
  case "$1:$2" in
    Darwin:openssl)
      printf '%s\n' \
        /opt/homebrew/opt/openssl@3/bin/openssl \
        /usr/local/opt/openssl@3/bin/openssl
      ;;
    Darwin:xxd) printf '%s\n' /usr/bin/xxd ;;
    Linux:openssl) printf '%s\n' /usr/bin/openssl ;;
    Linux:xxd) printf '%s\n' /usr/bin/xxd ;;
    *) return 1 ;;
  esac
}

_agmsg_receipt_runtime_run() {
  "$@" 3>&- 4>&- &
  _AGMSG_RECEIPT_RUNTIME_CHILD_PID=$!
  wait "$_AGMSG_RECEIPT_RUNTIME_CHILD_PID"
  local status=$?
  _AGMSG_RECEIPT_RUNTIME_CHILD_PID=
  return "$status"
}

_agmsg_receipt_runtime_cleanup() {
  local status=0
  if [ -n "${_AGMSG_RECEIPT_RUNTIME_CHILD_PID:-}" ]; then
    kill -TERM "$_AGMSG_RECEIPT_RUNTIME_CHILD_PID" 2>/dev/null || true
    wait "$_AGMSG_RECEIPT_RUNTIME_CHILD_PID" 2>/dev/null || true
    _AGMSG_RECEIPT_RUNTIME_CHILD_PID=
  fi
  if [ -n "${_AGMSG_RECEIPT_RUNTIME_TMP:-}" ] &&
     [ -d "$_AGMSG_RECEIPT_RUNTIME_TMP" ]; then
    /bin/rm -rf -- "$_AGMSG_RECEIPT_RUNTIME_TMP" 2>/dev/null || status=1
  fi
  _AGMSG_RECEIPT_RUNTIME_TMP=
  return "$status"
}

_agmsg_receipt_runtime_signal_hup() { exit 129; }
_agmsg_receipt_runtime_signal_int() { exit 130; }
_agmsg_receipt_runtime_signal_term() { exit 143; }

_agmsg_receipt_runtime_run_scoped() (
  local body="$1" status cleanup_status=0
  shift

  _AGMSG_RECEIPT_RUNTIME_TMP="$(/usr/bin/mktemp -d \
    "${TMPDIR:-/tmp}/agmsg-receipt-runtime.XXXXXX" 2>/dev/null)" || {
    printf '%s\n' 'agmsg receipt: cannot create private temporary directory' >&2
    exit "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  /bin/chmod 700 "$_AGMSG_RECEIPT_RUNTIME_TMP" 2>/dev/null || {
    _agmsg_receipt_runtime_cleanup >/dev/null 2>&1 || true
    printf '%s\n' 'agmsg receipt: cannot protect temporary directory' >&2
    exit "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  trap '_agmsg_receipt_runtime_cleanup >/dev/null 2>&1 || true' EXIT
  trap _agmsg_receipt_runtime_signal_hup HUP
  trap _agmsg_receipt_runtime_signal_int INT
  trap _agmsg_receipt_runtime_signal_term TERM

  "$body" "$@"
  status=$?
  trap - EXIT HUP INT TERM
  _agmsg_receipt_runtime_cleanup || cleanup_status=$?
  if [ "$cleanup_status" -ne 0 ]; then
    printf '%s\n' 'agmsg receipt: cannot clean private temporary directory' >&2
    exit "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  fi
  exit "$status"
)

_agmsg_receipt_runtime_is_sha256() {
  local digest="$1"
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in *[!0-9a-f]*) return 1 ;; esac
}

_agmsg_receipt_runtime_openssl_probe() {
  local openssl="$1" version digest
  local private_key="$_AGMSG_RECEIPT_RUNTIME_TMP/private.pem"
  local public_key="$_AGMSG_RECEIPT_RUNTIME_TMP/public.pem"
  local message="$_AGMSG_RECEIPT_RUNTIME_TMP/message.bin"
  local signature="$_AGMSG_RECEIPT_RUNTIME_TMP/signature.bin"
  local sha_fixture="$_AGMSG_RECEIPT_RUNTIME_TMP/sha-fixture.bin"
  local output="$_AGMSG_RECEIPT_RUNTIME_TMP/command.out"

  if ! _agmsg_receipt_runtime_run "$openssl" version >"$output" 2>/dev/null; then
    printf '%s\n' 'agmsg receipt: cannot execute OpenSSL version probe' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
  fi
  IFS= read -r version <"$output" || {
    printf '%s\n' 'agmsg receipt: invalid OpenSSL version output' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  [ -n "$version" ] || {
    printf '%s\n' 'agmsg receipt: invalid OpenSSL version output' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  case "$version" in
    OpenSSL\ 3.*[[:cntrl:]]*)
      printf '%s\n' 'agmsg receipt: invalid OpenSSL version output' >&2
      return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
      ;;
    OpenSSL\ 3.*) ;;
    *)
      printf '%s\n' 'agmsg receipt: OpenSSL major version must be 3' >&2
      return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
      ;;
  esac

  umask 077
  printf 'agmsg-receipt-runtime/v1\n' >"$message" 2>/dev/null || {
    printf '%s\n' 'agmsg receipt: cannot create message probe file' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  : >"$private_key" 2>/dev/null || {
    printf '%s\n' 'agmsg receipt: cannot create private key probe file' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  /bin/chmod 600 "$private_key" 2>/dev/null || {
    printf '%s\n' 'agmsg receipt: cannot protect private key probe file' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  if ! _agmsg_receipt_runtime_run "$openssl" genpkey -algorithm ED25519 \
      -out "$private_key" >"$output" 2>&1 ||
     ! /bin/chmod 600 "$private_key" 2>/dev/null ||
     ! _agmsg_receipt_runtime_run "$openssl" pkey -in "$private_key" -pubout \
      -out "$public_key" >"$output" 2>&1 ||
     ! _agmsg_receipt_runtime_run "$openssl" pkeyutl -sign -rawin \
      -inkey "$private_key" -in "$message" -out "$signature" >"$output" 2>&1 ||
     ! _agmsg_receipt_runtime_run "$openssl" pkeyutl -verify -rawin -pubin \
      -inkey "$public_key" -in "$message" -sigfile "$signature" >"$output" 2>&1; then
    printf '%s\n' 'agmsg receipt: OpenSSL Ed25519 capability failed' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
  fi

  printf 'agmsg-receipt-sha256\n' >"$sha_fixture" 2>/dev/null || {
    printf '%s\n' 'agmsg receipt: cannot create SHA-256 probe file' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  if ! _agmsg_receipt_runtime_run "$openssl" dgst -sha256 -r "$sha_fixture" \
      >"$output" 2>/dev/null; then
    printf '%s\n' 'agmsg receipt: OpenSSL SHA-256 capability failed' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
  fi
  IFS=' ' read -r digest _ <"$output" || {
    printf '%s\n' 'agmsg receipt: invalid OpenSSL SHA-256 output' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  _agmsg_receipt_runtime_is_sha256 "$digest" || {
    printf '%s\n' 'agmsg receipt: invalid OpenSSL SHA-256 output' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  if [ "$digest" != d27f861cb9d0b38cfa55f9dc21ee51924312da12c5b1e2541b91ca24d2a41190 ]; then
    printf '%s\n' 'agmsg receipt: OpenSSL SHA-256 capability failed' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
  fi

  if ! _agmsg_receipt_runtime_run "$openssl" dgst -sha256 -r "$public_key" \
      >"$output" 2>/dev/null; then
    printf '%s\n' 'agmsg receipt: OpenSSL public-key hash failed' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
  fi
  IFS=' ' read -r _AGMSG_RECEIPT_PUBLIC_KEY_SHA256 _ <"$output" || {
    printf '%s\n' 'agmsg receipt: invalid OpenSSL public-key hash output' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  if ! _agmsg_receipt_runtime_is_sha256 "$_AGMSG_RECEIPT_PUBLIC_KEY_SHA256"; then
    printf '%s\n' 'agmsg receipt: invalid OpenSSL public-key hash output' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  fi
  _AGMSG_RECEIPT_OPENSSL_VERSION="$version"
}

_agmsg_receipt_runtime_xxd_probe() {
  local xxd="$1" openssl="$2" i=0 digest bytes compare_status
  local canonical="$_AGMSG_RECEIPT_RUNTIME_TMP/canonical.hex"
  local original="$_AGMSG_RECEIPT_RUNTIME_TMP/original.bin"
  local encoded="$_AGMSG_RECEIPT_RUNTIME_TMP/encoded.hex"
  local restored="$_AGMSG_RECEIPT_RUNTIME_TMP/restored.bin"
  local output="$_AGMSG_RECEIPT_RUNTIME_TMP/command.out"

  : >"$canonical" 2>/dev/null || {
    printf '%s\n' 'agmsg receipt: cannot create xxd probe file' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  while [ "$i" -le 255 ]; do
    printf '%02x' "$i" >>"$canonical" 2>/dev/null || {
      printf '%s\n' 'agmsg receipt: cannot write xxd probe file' >&2
      return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
    }
    i=$((i + 1))
  done
  printf '0a0a\n' >>"$canonical" 2>/dev/null || {
    printf '%s\n' 'agmsg receipt: cannot write xxd probe file' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }

  if ! _agmsg_receipt_runtime_run "$xxd" -r -p "$canonical" "$original" \
      >"$output" 2>&1 ||
     ! _agmsg_receipt_runtime_run "$xxd" -p -c 256 "$original" "$encoded" \
      >"$output" 2>&1 ||
     ! _agmsg_receipt_runtime_run "$xxd" -r -p "$encoded" "$restored" \
      >"$output" 2>&1; then
    printf '%s\n' 'agmsg receipt: xxd binary round-trip failed' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
  fi
  bytes="$(/usr/bin/wc -c <"$original" 2>/dev/null | /usr/bin/tr -d ' ')" || {
    printf '%s\n' 'agmsg receipt: cannot inspect xxd probe output' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  [ "$bytes" = 258 ] || {
    printf '%s\n' 'agmsg receipt: xxd binary round-trip failed' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
  }
  /usr/bin/cmp -s "$original" "$restored"
  compare_status=$?
  case "$compare_status" in
    0) ;;
    1)
      printf '%s\n' 'agmsg receipt: xxd binary round-trip failed' >&2
      return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
      ;;
    *)
      printf '%s\n' 'agmsg receipt: cannot inspect xxd probe output' >&2
      return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
      ;;
  esac

  if ! _agmsg_receipt_runtime_run "$openssl" dgst -sha256 -r "$original" \
      >"$output" 2>/dev/null; then
    printf '%s\n' 'agmsg receipt: fixture SHA-256 failed' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
  fi
  IFS=' ' read -r digest _ <"$output" || {
    printf '%s\n' 'agmsg receipt: invalid fixture SHA-256 output' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  if ! _agmsg_receipt_runtime_is_sha256 "$digest"; then
    printf '%s\n' 'agmsg receipt: invalid fixture SHA-256 output' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  fi
  _AGMSG_RECEIPT_FIXTURE_SHA256="$digest"

  if _agmsg_receipt_runtime_run "$xxd" -v >"$output" 2>&1; then
    IFS= read -r _AGMSG_RECEIPT_XXD_VERSION <"$output" || {
      printf '%s\n' 'agmsg receipt: invalid xxd version output' >&2
      return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
    }
    [ -n "$_AGMSG_RECEIPT_XXD_VERSION" ] || {
      printf '%s\n' 'agmsg receipt: invalid xxd version output' >&2
      return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
    }
    case "$_AGMSG_RECEIPT_XXD_VERSION" in
      *[[:cntrl:]]*)
        printf '%s\n' 'agmsg receipt: invalid xxd version output' >&2
        return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
        ;;
    esac
  else
    _AGMSG_RECEIPT_XXD_VERSION=unknown
  fi
}

_agmsg_receipt_runtime_select() {
  local os="$1" tool="$2" override="$3" candidate candidates probe_status
  _AGMSG_RECEIPT_RUNTIME_SELECTED=

  if [ -n "$override" ]; then
    case "$override" in
      /*) ;;
      *)
        printf 'agmsg receipt: AGMSG_RECEIPT_%s must be an absolute executable path\n' \
          "$(printf '%s' "$tool" | /usr/bin/tr '[:lower:]' '[:upper:]')" >&2
        return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
        ;;
    esac
    case "$override" in
      *[[:cntrl:]]*)
        printf 'agmsg receipt: invalid AGMSG_RECEIPT_%s override\n' \
          "$(printf '%s' "$tool" | /usr/bin/tr '[:lower:]' '[:upper:]')" >&2
        return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
        ;;
    esac
    if [ ! -x "$override" ]; then
      printf 'agmsg receipt: AGMSG_RECEIPT_%s must be an absolute executable path\n' \
        "$(printf '%s' "$tool" | /usr/bin/tr '[:lower:]' '[:upper:]')" >&2
      return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
    fi
    if [ "$tool" = openssl ]; then
      _agmsg_receipt_runtime_openssl_probe "$override" 2>/dev/null
      probe_status=$?
    else
      _agmsg_receipt_runtime_xxd_probe "$override" \
        "$AGMSG_RECEIPT_OPENSSL_RESOLVED" 2>/dev/null
      probe_status=$?
    fi
    case "$probe_status" in
      0) ;;
      10)
        printf 'agmsg receipt: configured %s is unavailable or incapable\n' "$tool" >&2
        return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
        ;;
      *)
        printf 'agmsg receipt: configured %s probe failed internally\n' "$tool" >&2
        return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
        ;;
    esac
    _AGMSG_RECEIPT_RUNTIME_SELECTED="$override"
    return 0
  fi

  candidates="$(agmsg_receipt_runtime_candidates "$os" "$tool" 2>/dev/null)" ||
    candidates=
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    if [ "$tool" = openssl ]; then
      _agmsg_receipt_runtime_openssl_probe "$candidate" >/dev/null 2>&1
      probe_status=$?
    else
      _agmsg_receipt_runtime_xxd_probe "$candidate" \
        "$AGMSG_RECEIPT_OPENSSL_RESOLVED" >/dev/null 2>&1
      probe_status=$?
    fi
    if [ "$probe_status" -eq 0 ]; then
      _AGMSG_RECEIPT_RUNTIME_SELECTED="$candidate"
      return 0
    fi
    if [ "$probe_status" -ne "$_AGMSG_RECEIPT_RUNTIME_MISSING" ]; then
      printf 'agmsg receipt: %s candidate probe failed internally\n' "$tool" >&2
      return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
    fi
  done <<EOF
$candidates
EOF

  printf 'agmsg receipt: no capable %s candidate for %s\n' "$tool" "$os" >&2
  return "$_AGMSG_RECEIPT_RUNTIME_MISSING"
}

_agmsg_receipt_runtime_resolve_body() {
  local os="$1" status
  AGMSG_RECEIPT_OPENSSL_RESOLVED=
  AGMSG_RECEIPT_XXD_RESOLVED=

  _agmsg_receipt_runtime_select "$os" openssl \
    "${AGMSG_RECEIPT_OPENSSL:-}" || {
    status=$?
    return "$status"
  }
  AGMSG_RECEIPT_OPENSSL_RESOLVED="$_AGMSG_RECEIPT_RUNTIME_SELECTED"
  _agmsg_receipt_runtime_select "$os" xxd \
    "${AGMSG_RECEIPT_XXD:-}" || {
    status=$?
    AGMSG_RECEIPT_OPENSSL_RESOLVED=
    return "$status"
  }
  AGMSG_RECEIPT_XXD_RESOLVED="$_AGMSG_RECEIPT_RUNTIME_SELECTED"

  printf '%s\n' \
    "$AGMSG_RECEIPT_OPENSSL_RESOLVED" \
    "$AGMSG_RECEIPT_XXD_RESOLVED" \
    "$_AGMSG_RECEIPT_OPENSSL_VERSION" \
    "$_AGMSG_RECEIPT_XXD_VERSION" \
    "$_AGMSG_RECEIPT_FIXTURE_SHA256" \
    "$_AGMSG_RECEIPT_PUBLIC_KEY_SHA256"
}

agmsg_receipt_resolve_runtime() {
  local os="${1:-$(/usr/bin/uname -s)}" result status extra
  local openssl_path xxd_path openssl_version xxd_version fixture_sha public_sha

  AGMSG_RECEIPT_OPENSSL_RESOLVED=
  AGMSG_RECEIPT_XXD_RESOLVED=
  if result="$(_agmsg_receipt_runtime_run_scoped \
      _agmsg_receipt_runtime_resolve_body "$os")"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] || return "$status"
  {
    IFS= read -r openssl_path || return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
    IFS= read -r xxd_path || return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
    IFS= read -r openssl_version || return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
    IFS= read -r xxd_version || return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
    IFS= read -r fixture_sha || return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
    IFS= read -r public_sha || return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
    IFS= read -r extra || true
  } <<EOF
$result
EOF
  [ -z "$extra" ] || {
    printf '%s\n' 'agmsg receipt: invalid runtime probe result' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  case "$openssl_path:$xxd_path" in
    /*:/*) ;;
    *)
      printf '%s\n' 'agmsg receipt: invalid runtime probe result' >&2
      return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
      ;;
  esac
  _agmsg_receipt_runtime_is_sha256 "$fixture_sha" || {
    printf '%s\n' 'agmsg receipt: invalid runtime probe result' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }
  _agmsg_receipt_runtime_is_sha256 "$public_sha" || {
    printf '%s\n' 'agmsg receipt: invalid runtime probe result' >&2
    return "$_AGMSG_RECEIPT_RUNTIME_ERROR"
  }

  AGMSG_RECEIPT_OPENSSL_RESOLVED="$openssl_path"
  AGMSG_RECEIPT_XXD_RESOLVED="$xxd_path"
  _AGMSG_RECEIPT_OPENSSL_VERSION="$openssl_version"
  _AGMSG_RECEIPT_XXD_VERSION="$xxd_version"
  _AGMSG_RECEIPT_FIXTURE_SHA256="$fixture_sha"
  _AGMSG_RECEIPT_PUBLIC_KEY_SHA256="$public_sha"
}
