#!/usr/bin/env bash
# lib/common.sh - shared state, result recording and small helpers.
# Sourced by nosycat.sh; never executed directly.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are consumed by other sourced files

NOSY_NAME="nosycat-toolkit"
NOSY_VERSION="0.1.0"

# Result store (parallel arrays, one entry per check).
R_STATUS=()
R_ID=()
R_MOD=()
R_TITLE=()
R_DETAIL=()
R_FIX=()

CUR_MOD=""
FORMAT="text"
USE_COLOR=1
LIVE_TEXT=1
NOSY_TIMEOUT="${NOSY_TIMEOUT:-10}"

if [ "$(id -u)" -eq 0 ]; then IS_ROOT=1; else IS_ROOT=0; fi

C_OK="" C_WARN="" C_FAIL="" C_SKIP="" C_DIM="" C_BOLD="" C_PINK="" C_RST=""

setup_colors() {
  if [ "$USE_COLOR" -eq 1 ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'
    C_SKIP=$'\033[90m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_PINK=$'\033[35m'; C_RST=$'\033[0m'
  fi
}

# have CMD -> true when CMD is on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# Detect a usable timeout(1) once (GNU coreutils and busybox both accept -k).
_TIMEOUT_MODE="none"
if have timeout; then
  if timeout -k 1 2 true >/dev/null 2>&1; then _TIMEOUT_MODE="k"; else _TIMEOUT_MODE="plain"; fi
fi

# t SECONDS CMD [ARGS...] -> run CMD with a hard time limit and no stdin.
# Returns 124 on timeout (GNU semantics).
t() {
  local secs="$1"; shift
  case "$_TIMEOUT_MODE" in
    k)     timeout -k 2 "$secs" "$@" </dev/null ;;
    plain) timeout "$secs" "$@" </dev/null ;;
    *)     "$@" </dev/null ;;
  esac
}

# q CMD... -> run with the default timeout, discard stderr.
q() { t "$NOSY_TIMEOUT" "$@" 2>/dev/null; }

# record STATUS ID TITLE [DETAIL] [FIX]
record() {
  local st="$1" id="$2" title="$3" detail="${4:-}" fix="${5:-}"
  R_STATUS+=("$st"); R_ID+=("$id"); R_MOD+=("$CUR_MOD")
  R_TITLE+=("$title"); R_DETAIL+=("$detail"); R_FIX+=("$fix")
  if [ "$FORMAT" = "text" ] && [ "$LIVE_TEXT" -eq 1 ]; then
    print_check_line "$st" "$id" "$title" "$detail" "$fix"
  fi
}
ok()   { record OK   "$@"; }
warn() { record WARN "$@"; }
fail() { record FAIL "$@"; }
skip() { record SKIP "$1" "$2" "${3:-}" ""; }

print_check_line() {
  local st="$1" id="$2" title="$3" detail="$4" fix="$5" col
  case "$st" in
    OK) col="$C_OK" ;; WARN) col="$C_WARN" ;; FAIL) col="$C_FAIL" ;; *) col="$C_SKIP" ;;
  esac
  printf '  %s%-6s%s %-8s %s\n' "$col" "[$st]" "$C_RST" "$id" "$title"
  if [ -n "$detail" ]; then printf '  %s                why: %s%s\n' "$C_DIM" "$detail" "$C_RST"; fi
  if [ -n "$fix" ] && [ "$st" != "OK" ]; then printf '  %s                fix: %s%s\n' "$C_DIM" "$fix" "$C_RST"; fi
}

module_header() {
  if [ "$FORMAT" = "text" ] && [ "$LIVE_TEXT" -eq 1 ]; then
    printf '\n%s❀ %s%s\n' "$C_PINK$C_BOLD" "$1" "$C_RST"
  fi
}

# need_root ID TITLE -> records a SKIP and returns 1 when not root.
need_root() {
  if [ "$IS_ROOT" -eq 1 ]; then return 0; fi
  skip "$1" "$2" "needs root to read this; re-run with sudo"
  return 1
}

# join SEP ITEMS... -> items joined by SEP.
join() { local sep="$1" out="" x; shift; for x in "$@"; do out="${out:+$out$sep}$x"; done; printf '%s' "$out"; }

# trunc_list MAX ITEMS... -> "a, b, c (+N more)"
trunc_list() {
  local max="$1"; shift
  local n=$# shown=()
  while [ $# -gt 0 ] && [ "${#shown[@]}" -lt "$max" ]; do shown+=("$1"); shift; done
  join ", " "${shown[@]}"
  if [ "$n" -gt "$max" ]; then printf ' (+%d more)' "$((n - max))"; fi
}

# login_users -> name:uid:home:shell for root and regular accounts with a login shell.
login_users() {
  getent passwd 2>/dev/null | awk -F: '($3==0 || ($3>=1000 && $3!=65534)) && $7 !~ /(nologin|false|sync|shutdown|halt)$/ && $7 != "" {print $1":"$3":"$6":"$7}'
}

# systemd_up -> true when PID 1 is systemd and systemctl is usable.
systemd_up() { [ -d /run/systemd/system ] && have systemctl; }

# unit_active NAME -> true when a systemd unit is active.
unit_active() { systemd_up && q systemctl is-active --quiet "$1"; }
unit_enabled() { systemd_up && q systemctl is-enabled --quiet "$1"; }

# Listener cache: lines "proto host port process"
_LISTENERS_DONE=0
LISTENERS=()
collect_listeners() {
  [ "$_LISTENERS_DONE" -eq 1 ] && return 0
  _LISTENERS_DONE=1
  local line proto local_addr proc host port
  local -a f
  if have ss; then
    while IFS= read -r line; do
      read -r -a f <<<"$line"
      proto="${f[0]}"; local_addr="${f[4]}"; proc=""
      case "$line" in *'users:(("'*) proc="${line#*users:((\"}"; proc="${proc%%\"*}" ;; esac
      port="${local_addr##*:}"; host="${local_addr%:*}"
      host="${host#[}"; host="${host%]}"; host="${host%%%*}"
      LISTENERS+=("$proto $host $port ${proc:--}")
    done < <(q ss -H -tuln -p || q ss -H -tuln)
  elif have netstat; then
    while IFS= read -r line; do
      read -r -a f <<<"$line"
      proto="${f[0]%6}"; local_addr="${f[3]}"; proc="-"
      case "$line" in */*) proc="${line##*/}"; proc="${proc%% *}" ;; esac
      port="${local_addr##*:}"; host="${local_addr%:*}"
      LISTENERS+=("$proto $host $port $proc")
    done < <(q netstat -tulnp 2>/dev/null | awk '$1 ~ /^(tcp|udp)/ && ($1 ~ /^udp/ || $6 == "LISTEN")' || true)
  else
    return 1
  fi
  return 0
}

# addr_scope HOST -> loopback | any | private | public
addr_scope() {
  case "$1" in
    127.*|::1|::ffff:127.*|localhost) echo loopback ;;
    0.0.0.0|::|'*'|'') echo any ;;
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|169.254.*|fd*|fc*|fe80*) echo private ;;
    *) echo public ;;
  esac
}
