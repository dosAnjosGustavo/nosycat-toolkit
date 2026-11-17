#!/usr/bin/env bash
# lib/common.sh - shared state, result recording and small helpers.
# Sourced by nosycat.sh; never executed directly.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are consumed by other sourced files

NOSY_NAME="nosycat-toolkit"
NOSY_VERSION="0.1.1"

# Result store (parallel arrays, one entry per check).
R_STATUS=()
R_ID=()
R_MOD=()
R_TITLE=()
R_DETAIL=()
R_FIX=()
R_ORIG=()   # original status of IGNORED checks (empty otherwise)
R_NOTE=()   # ignore reason of IGNORED checks

# Accepted findings (.nosycat.ignore): glob patterns on check ids + reasons.
IGNORE_PAT=()
IGNORE_WHY=()

CUR_MOD=""
FORMAT="text"
COLOR_MODE="auto"   # auto | always | never (--color / --no-color)
ASCII_MODE="auto"   # auto | on (--ascii)
LIVE_TEXT=1
NOSY_TIMEOUT="${NOSY_TIMEOUT:-10}"
# Locale of the caller; nosycat.sh captures it before forcing LC_ALL=C.
NOSY_LOCALE="${NOSY_LOCALE-}"

if [ "$(id -u)" -eq 0 ]; then IS_ROOT=1; else IS_ROOT=0; fi

C_OK="" C_WARN="" C_FAIL="" C_SKIP="" C_IGN="" C_DIM="" C_BOLD="" C_PINK="" C_LILAC="" C_SKY="" C_RST=""

# colors_off -> blank every color variable (used for files and pipes).
colors_off() {
  C_OK="" C_WARN="" C_FAIL="" C_SKIP="" C_IGN="" C_DIM="" C_BOLD="" C_PINK="" C_LILAC="" C_SKY="" C_RST=""
}

# want_color -> true when ANSI colors should be used on stdout.
# never/--no-color: off. always: on (even when piped or NO_COLOR is set).
# auto: on only for a terminal, without NO_COLOR, and with TERM other than dumb.
want_color() {
  case "$COLOR_MODE" in
    never) return 1 ;;
    always) return 0 ;;
  esac
  { [ -t 1 ] || [ "${NOSY_FX_TTY:-}" = 1 ]; } && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]
}

# color_depth -> truecolor | 256 | 8
color_depth() {
  case "${COLORTERM:-}" in truecolor|24bit) echo truecolor; return ;; esac
  case "${TERM:-}" in *256color*|*-direct|xterm-kitty|alacritty|wezterm|foot*) echo 256; return ;; esac
  echo 8
}

# Pastel palette (mid-tones, so it reads on dark and light backgrounds):
#   FAIL rose #ec5f99 · WARN peach #ef9a48 · OK mint #3dbd88 · SKIP lavender #9a8fd0
#   IGNORED grey #9a9aa6 · divider pink #ff79c6 · box/headers lilac #b084f5 · fix sky #4aaee3
setup_colors() {
  colors_off
  want_color || return 0
  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
  case "$(color_depth)" in
    truecolor)
      C_FAIL=$'\033[38;2;236;95;153m'; C_WARN=$'\033[38;2;239;154;72m'; C_OK=$'\033[38;2;61;189;136m'
      C_SKIP=$'\033[38;2;154;143;208m'; C_IGN=$'\033[38;2;154;154;166m'; C_PINK=$'\033[38;2;255;121;198m'
      C_LILAC=$'\033[38;2;176;132;245m'; C_SKY=$'\033[38;2;74;174;227m' ;;
    256)
      C_FAIL=$'\033[38;5;204m'; C_WARN=$'\033[38;5;215m'; C_OK=$'\033[38;5;78m'
      C_SKIP=$'\033[38;5;140m'; C_IGN=$'\033[38;5;247m'; C_PINK=$'\033[38;5;212m'
      C_LILAC=$'\033[38;5;141m'; C_SKY=$'\033[38;5;74m' ;;
    *)
      C_FAIL=$'\033[31m'; C_WARN=$'\033[33m'; C_OK=$'\033[32m'; C_SKIP=$'\033[90m'
      C_IGN=$'\033[90m'; C_PINK=$'\033[35m'; C_LILAC=$'\033[35m'; C_SKY=$'\033[36m' ;;
  esac
}

# use_utf8 -> true when box drawing and symbols are safe to print.
use_utf8() {
  [ "$ASCII_MODE" = "on" ] && return 1
  case "$NOSY_LOCALE" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return 0 ;; esac
  return 1
}

# Glyphs: UTF-8 when the locale allows it, plain ASCII otherwise (or with --ascii).
setup_glyphs() {
  if use_utf8; then
    G_FAIL="✗" G_WARN="!" G_OK="✓" G_SKIP="·" G_IGN="~"
    G_TL="╭" G_TR="╮" G_BL="╰" G_BR="╯" G_H="─" G_V="│"
    G_BAR="█" G_BAR_FAIL="█" G_BAR_WARN="▓" G_BAR_OK="▒" G_BAR_SKIP="░" G_BAR_IGN="░"
    G_FLOWER="❀" G_DIV=".·:*¨¨* ❀ *¨¨*:·." G_MORE="…" G_DOT="·"
  else
    G_FAIL="x" G_WARN="!" G_OK="+" G_SKIP="." G_IGN="~"
    G_TL="+" G_TR="+" G_BL="+" G_BR="+" G_H="-" G_V="|"
    G_BAR="#" G_BAR_FAIL="X" G_BAR_WARN="!" G_BAR_OK="=" G_BAR_SKIP="." G_BAR_IGN="~"
    G_FLOWER="@" G_DIV=".:*''* @ *''*:." G_MORE="..." G_DOT="-"
  fi
}
setup_glyphs

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

# Fixture hooks for the test suite (tests/*.bats). Production runs never set them.
#   NOSY_ETC=DIR          read config files from DIR instead of /etc
#   NOSY_FX_<NAME>=FILE   use FILE as the output of a command instead of running it:
#     NFT (nft list ruleset), IPTABLES_INPUT / IP6TABLES_INPUT (iptables -S INPUT),
#     UFW_STATUS, FIREWALLD_STATE, SS (ss -H -tuln -p), SSHD_T (sshd -T),
#     SSH_UNITS (systemctl list-unit-files ssh.service sshd.service), NGINX_T (nginx -T),
#     SUID (list of SUID files)
#   NOSY_FSTAB, NOSY_PROC_MOUNTS  alternative fstab and /proc/mounts
#   NOSY_FX_TTY=1         treat stdout as a terminal (color auto-detection tests)
ETC="${NOSY_ETC:-/etc}"

# fx NAME CMD... -> print the NOSY_FX_NAME fixture if set, otherwise run CMD under q.
fx() {
  local v="NOSY_FX_$1"; shift
  if [ -n "${!v:-}" ]; then cat -- "${!v}" 2>/dev/null; return; fi
  q "$@"
}
# fx_set NAME -> true when a fixture replaces this command.
fx_set() { local v="NOSY_FX_$1"; [ -n "${!v:-}" ]; }
# fx_have NAME CMD -> true when the fixture is set or CMD is installed.
fx_have() { fx_set "$1" || have "$2"; }

# Temporary paths removed on exit, Ctrl-C or TERM (see the traps in nosycat.sh).
NOSY_CLEANUP=()
nosy_cleanup() {
  local p
  for p in "${NOSY_CLEANUP[@]}"; do [ -n "$p" ] && rm -rf -- "$p"; done
  NOSY_CLEANUP=()
}

# nosy_mktemp_dir -> prints a fresh private temp dir and registers it for cleanup.
# Fails (never falls back to a predictable /tmp path, which is unsafe as root).
# Call it without $(...) so the registration survives: nosy_mktemp_dir VAR
nosy_mktemp_dir() {
  local d
  d="$(mktemp -d 2>/dev/null)" && [ -n "$d" ] && [ -d "$d" ] || return 1
  NOSY_CLEANUP+=("$d")
  printf -v "$1" '%s' "$d"
}

# load_ignore_file FILE -> adds its entries to IGNORE_PAT/IGNORE_WHY.
# Format, one per line:  ID  |  ID: reason  |  NET-*  (globs)  |  # comment
# Returns 1 when FILE cannot be read; malformed lines are reported and skipped.
load_ignore_file() {
  local file="$1" line pat why n=0
  [ -r "$file" ] && [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%%[[:space:]]#*}"
    case "$line" in \#*) continue ;; esac
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    pat="${line%%[:[:space:]]*}"
    why="${line:${#pat}}"; why="${why#"${why%%[![:space:]]*}"}"; why="${why#:}"; why="${why#"${why%%[![:space:]]*}"}"
    pat="$(printf '%s' "$pat" | tr '[:lower:]' '[:upper:]')"
    if ! [[ "$pat" =~ ^[A-Z]{2,4}-[0-9*?]{1,3}$ ]]; then
      echo "nosycat: $file line $n: '$line' is not a check id (e.g. NET-001 or NET-*), skipped" >&2
      continue
    fi
    IGNORE_PAT+=("$pat"); IGNORE_WHY+=("$why")
  done <"$file"
  return 0
}

# ignore_match ID -> prints the reason and returns 0 when ID is ignored.
ignore_match() {
  local i
  for i in "${!IGNORE_PAT[@]}"; do
    # shellcheck disable=SC2053  # the pattern is a deliberate glob
    if [[ "$1" == ${IGNORE_PAT[$i]} ]]; then printf '%s' "${IGNORE_WHY[$i]}"; return 0; fi
  done
  return 1
}

# record STATUS ID TITLE [DETAIL] [FIX]
# WARN/FAIL results whose id is in the ignore list are stored as IGNORED.
# _trim TEXT -> TEXT without leading/trailing whitespace (lists built with
# `tr '\n' ' '` end in a space).
_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

record() {
  local st="$1" id="$2" title="$3" detail="${4:-}" fix="${5:-}" orig="" note=""
  title="$(_trim "$title")"; detail="$(_trim "$detail")"; fix="$(_trim "$fix")"
  if { [ "$st" = "WARN" ] || [ "$st" = "FAIL" ]; } && [ "${#IGNORE_PAT[@]}" -gt 0 ] && note="$(ignore_match "$id")"; then
    orig="$st"; st="IGNORED"
    detail="ignored, was $orig${note:+: $note}${detail:+ · $detail}"
  else
    note=""
  fi
  R_STATUS+=("$st"); R_ID+=("$id"); R_MOD+=("$CUR_MOD")
  R_TITLE+=("$title"); R_DETAIL+=("$detail"); R_FIX+=("$fix")
  R_ORIG+=("$orig"); R_NOTE+=("$note")
  if [ "$FORMAT" = "text" ] && [ "$LIVE_TEXT" -eq 1 ]; then
    print_check_line "$st" "$id" "$title" "$detail" "$fix"
  fi
}
ok()   { record OK   "$@"; }
warn() { record WARN "$@"; }
fail() { record FAIL "$@"; }
skip() { record SKIP "$1" "$2" "${3:-}" ""; }

print_check_line() {
  local st="$1" id="$2" title="$3" detail="$4" fix="$5" col label="$1"
  if ! use_utf8; then title="$(_asciify "$title")"; detail="$(_asciify "$detail")"; fi
  case "$st" in
    OK) col="$C_OK" ;; WARN) col="$C_WARN" ;; FAIL) col="$C_FAIL" ;; IGNORED) col="$C_IGN"; label="IGN" ;; *) col="$C_SKIP" ;;
  esac
  printf '  %s%-6s%s %s%-8s%s %s\n' "$col$C_BOLD" "[$label]" "$C_RST" "$C_LILAC" "$id" "$C_RST" "$title"
  if [ -n "$detail" ]; then printf '                  %swhy:%s %s%s%s\n' "$C_SKIP" "$C_RST" "$C_DIM" "$detail" "$C_RST"; fi
  if [ -n "$fix" ] && [ "$st" != "OK" ] && [ "$st" != "IGNORED" ]; then printf '                  %sfix:%s %s%s%s\n' "$col" "$C_RST" "$C_SKY" "$fix" "$C_RST"; fi
}

module_header() {
  if [ "$FORMAT" = "text" ] && [ "$LIVE_TEXT" -eq 1 ]; then
    printf '\n%s%s%s %s%s%s\n' "$C_PINK" "$G_FLOWER" "$C_RST" "$C_LILAC$C_BOLD" "$1" "$C_RST"
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
  if fx_have SS ss; then
    while IFS= read -r line; do
      read -r -a f <<<"$line"
      proto="${f[0]}"; local_addr="${f[4]}"; proc=""
      case "$line" in *'users:(("'*) proc="${line#*users:((\"}"; proc="${proc%%\"*}" ;; esac
      port="${local_addr##*:}"; host="${local_addr%:*}"
      host="${host#[}"; host="${host%]}"; host="${host%%%*}"
      LISTENERS+=("$proto $host $port ${proc:--}")
    done < <(if fx_set SS; then fx SS; else q ss -H -tuln -p || q ss -H -tuln; fi)
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
# fe80::/10 (link-local) is fe8x..febx; fc00::/7 (ULA) is fcxx/fdxx.
addr_scope() {
  local a
  a="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$a" in
    127.*|::1|::ffff:127.*|localhost) echo loopback ;;
    0.0.0.0|::|'*'|'') echo any ;;
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|169.254.*) echo private ;;
    ::ffff:10.*|::ffff:192.168.*|::ffff:172.1[6-9].*|::ffff:172.2[0-9].*|::ffff:172.3[01].*) echo private ;;
    f[cd][0-9a-f][0-9a-f]:*|fe[89ab][0-9a-f]:*) echo private ;;
    *) echo public ;;
  esac
}
