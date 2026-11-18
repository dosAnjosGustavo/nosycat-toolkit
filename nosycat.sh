#!/usr/bin/env bash
# nosycat-toolkit - read-only post-deploy check-up for Linux VPS.
# https://github.com/trizdev/nosycat-toolkit  (MIT)
#
# Never modifies the system. The only write is --snapshot (own state dir)
# and --output (report files in the directory you choose).

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "nosycat: bash 4 or newer is required" >&2; exit 3
fi
set -o pipefail
# Remember the caller's locale (for UTF-8 symbols), then parse everything bytewise.
NOSY_LOCALE="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
export LC_ALL=C
PATH="$PATH:/usr/sbin:/sbin"

NOSY_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=lib/common.sh
. "$NOSY_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
. "$NOSY_ROOT/lib/detect.sh"
# shellcheck source=lib/output.sh
. "$NOSY_ROOT/lib/output.sh"
# shellcheck source=modules/environment.sh
. "$NOSY_ROOT/modules/environment.sh"
# shellcheck source=modules/cloud_init.sh
. "$NOSY_ROOT/modules/cloud_init.sh"
# shellcheck source=modules/system.sh
. "$NOSY_ROOT/modules/system.sh"
# shellcheck source=modules/access.sh
. "$NOSY_ROOT/modules/access.sh"
# shellcheck source=modules/network.sh
. "$NOSY_ROOT/modules/network.sh"
# shellcheck source=modules/updates.sh
. "$NOSY_ROOT/modules/updates.sh"
# shellcheck source=modules/docker.sh
. "$NOSY_ROOT/modules/docker.sh"
# shellcheck source=modules/services.sh
. "$NOSY_ROOT/modules/services.sh"
# shellcheck source=modules/web_tls.sh
. "$NOSY_ROOT/modules/web_tls.sh"
# shellcheck source=modules/security.sh
. "$NOSY_ROOT/modules/security.sh"
# shellcheck source=modules/databases.sh
. "$NOSY_ROOT/modules/databases.sh"
# shellcheck source=modules/backup.sh
. "$NOSY_ROOT/modules/backup.sh"
# shellcheck source=modules/snapshot.sh
. "$NOSY_ROOT/modules/snapshot.sh"

ALL_MODULES=(environment cloud_init system access network updates docker services web_tls security databases backup)

usage() {
  cat <<USAGE
$NOSY_NAME $NOSY_VERSION - read-only post-deploy check-up for Linux VPS

usage: sudo ./nosycat.sh [options]

  --only m1,m2        run only these modules
  --skip m1,m2        skip these modules
  --format FMT        text (default) | md | json
  --output DIR        also write the report to DIR/nosycat-<host>-<time>.<ext>
  -q, --problems-only only WARN/FAIL checks (with why and fix) plus the summary;
                      md lists only those rows, json keeps only those in checks[]
                      (summary counts stay complete either way)
  --color WHEN        auto (default) | always | never; auto colors only a
                      terminal and honours NO_COLOR and TERM=dumb
  --no-color          same as --color never
  --ascii             plain ASCII symbols, box and bar (automatic when the
                      locale is not UTF-8)
  --snapshot          save a baseline of this server and exit
  --diff              compare the server against the saved baseline
  --state-dir DIR     baseline location (default: /var/lib/nosycat as root,
                      ~/.local/state/nosycat otherwise)
  --ignore FILE       accepted findings to report as IGNORED (repeatable);
                      STATE_DIR/.nosycat.ignore is always read if present.
                      lines: ID, ID: reason, optional "until YYYY-MM-DD"
  --backup-max-age N  warn when the last backup is older than N days (default 7)
  --timeout SECS      per-command timeout, 1 or more (default: $NOSY_TIMEOUT)
  --list              list the modules --only/--skip accept and exit
  -h, --help          show this help
  -V, --version       show version

modules: ${ALL_MODULES[*]}

exit codes: 0 all OK · 1 WARN present · 2 FAIL present · 3 usage/runtime error
            (IGNORED and SKIP results do not affect the exit code)
USAGE
}

die_usage() { echo "nosycat: $*" >&2; echo "try: ./nosycat.sh --help" >&2; exit 3; }

# set_backup_max_age DAYS -> validates and sets BACKUP_MAX_AGE (whole days, 1 or more).
set_backup_max_age() {
  if ! [[ "$1" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$1))" -lt 1 ]; then die_usage "--backup-max-age needs a number of days (1 or more)"; fi
  BACKUP_MAX_AGE="$((10#$1))"
}

# set_timeout SECS -> validates and sets NOSY_TIMEOUT (1 or more; timeout 0 would mean no limit).
set_timeout() {
  if ! [[ "$1" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$1))" -lt 1 ]; then die_usage "--timeout needs a number of seconds (1 or more)"; fi
  NOSY_TIMEOUT="$((10#$1))"
}

ONLY="" SKIP_LIST="" OUTDIR="" MODE="check" STATE_DIR="" IGNORE_FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --only) [ -n "${2:-}" ] || die_usage "--only needs a value"; ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; [ -n "$ONLY" ] || die_usage "--only needs a value"; shift ;;
    --skip) [ -n "${2:-}" ] || die_usage "--skip needs a value"; SKIP_LIST="$2"; shift 2 ;;
    --skip=*) SKIP_LIST="${1#*=}"; [ -n "$SKIP_LIST" ] || die_usage "--skip needs a value"; shift ;;
    --format) [ -n "${2:-}" ] || die_usage "--format needs a value"; FORMAT="$2"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; [ -n "$FORMAT" ] || die_usage "--format needs a value"; shift ;;
    --output) [ -n "${2:-}" ] || die_usage "--output needs a directory"; OUTDIR="$2"; shift 2 ;;
    --output=*) OUTDIR="${1#*=}"; [ -n "$OUTDIR" ] || die_usage "--output needs a directory"; shift ;;
    --state-dir) [ -n "${2:-}" ] || die_usage "--state-dir needs a directory"; STATE_DIR="$2"; shift 2 ;;
    --state-dir=*) STATE_DIR="${1#*=}"; [ -n "$STATE_DIR" ] || die_usage "--state-dir needs a directory"; shift ;;
    --ignore) [ -n "${2:-}" ] || die_usage "--ignore needs a file"; IGNORE_FILES+=("$2"); shift 2 ;;
    --ignore=*) [ -n "${1#*=}" ] || die_usage "--ignore needs a file"; IGNORE_FILES+=("${1#*=}"); shift ;;
    -q|--problems-only) PROBLEMS_ONLY=1; shift ;;
    --backup-max-age) set_backup_max_age "${2:-}"; shift 2 ;;
    --backup-max-age=*) set_backup_max_age "${1#*=}"; shift ;;
    --timeout) set_timeout "${2:-}"; shift 2 ;;
    --timeout=*) set_timeout "${1#*=}"; shift ;;
    --color) case "${2:-}" in auto|always|never) COLOR_MODE="$2" ;; *) die_usage "--color needs auto|always|never" ;; esac; shift 2 ;;
    --color=*) COLOR_MODE="${1#*=}"; case "$COLOR_MODE" in auto|always|never) ;; *) die_usage "--color needs auto|always|never" ;; esac; shift ;;
    --no-color) COLOR_MODE=never; shift ;;
    --ascii) ASCII_MODE=on; shift ;;
    --snapshot) [ "$MODE" = "diff" ] && die_usage "--snapshot and --diff are exclusive"; MODE="snapshot"; shift ;;
    --diff) [ "$MODE" = "snapshot" ] && die_usage "--snapshot and --diff are exclusive"; MODE="diff"; shift ;;
    --list) printf '%s\n' "${ALL_MODULES[@]}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) echo "$NOSY_NAME $NOSY_VERSION"; exit 0 ;;
    *) die_usage "unknown option: $1" ;;
  esac
done

case "$FORMAT" in text|md|json) ;; *) die_usage "invalid --format '$FORMAT' (text|md|json)" ;; esac
[ "$FORMAT" = "text" ] || LIVE_TEXT=0
if [ -z "$STATE_DIR" ]; then
  if [ "$IS_ROOT" -eq 1 ]; then STATE_DIR="/var/lib/nosycat"; else STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/nosycat"; fi
fi

if [ -f "$STATE_DIR/.nosycat.ignore" ]; then
  load_ignore_file "$STATE_DIR/.nosycat.ignore" || die_usage "cannot read $STATE_DIR/.nosycat.ignore"
fi
for f in "${IGNORE_FILES[@]}"; do
  load_ignore_file "$f" || die_usage "cannot read ignore file: $f"
done

_valid_mod() { local m; for m in "${ALL_MODULES[@]}"; do [ "$m" = "$1" ] && return 0; done; return 1; }

RUN=()
if [ -n "$ONLY" ]; then
  IFS=',' read -r -a req <<<"$ONLY"
  for m in "${req[@]}"; do _valid_mod "$m" || die_usage "unknown module: $m"; done
  for m in "${ALL_MODULES[@]}"; do case ",$ONLY," in *",$m,"*) RUN+=("$m") ;; esac; done
else
  RUN=("${ALL_MODULES[@]}")
fi
if [ -n "$SKIP_LIST" ]; then
  IFS=',' read -r -a req <<<"$SKIP_LIST"
  for m in "${req[@]}"; do _valid_mod "$m" || die_usage "unknown module: $m"; done
  keep=()
  for m in "${RUN[@]}"; do case ",$SKIP_LIST," in *",$m,"*) ;; *) keep+=("$m") ;; esac; done
  RUN=("${keep[@]}")
fi
[ "${#RUN[@]}" -gt 0 ] || die_usage "no modules left to run"

if [ -n "$OUTDIR" ] && ! mkdir -p "$OUTDIR" 2>/dev/null; then die_usage "cannot create output dir: $OUTDIR"; fi

# Remove temp dirs on any exit, including Ctrl-C and kill.
trap nosy_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

setup_colors
setup_glyphs
detect_all

if [ "$MODE" = "snapshot" ]; then
  snapshot_save; exit $?
fi

if [ "$MODE" = "diff" ]; then
  if [ ! -f "$STATE_DIR/baseline/meta" ]; then
    echo "nosycat: no baseline in $STATE_DIR/baseline; run with --snapshot first" >&2; exit 3
  fi
  RUN=(snapshot)
fi

if [ "$FORMAT" = "text" ]; then
  print_banner
  print_run_note
fi

for m in "${RUN[@]}"; do
  CUR_MOD="$m"
  module_header "$m"
  "mod_$m"
done

[ "$FORMAT" = "text" ] && print_summary
case "$FORMAT" in md) render_md ;; json) render_json ;; esac

if [ -n "$OUTDIR" ]; then
  ext="txt"; [ "$FORMAT" = "md" ] && ext="md"; [ "$FORMAT" = "json" ] && ext="json"
  outfile="$OUTDIR/nosycat-${HOST_NAME%%.*}-$(date +%Y%m%d-%H%M%S).$ext"
  case "$FORMAT" in
    text) ( colors_off; render_text_full ) >"$outfile" ;;
    md) render_md >"$outfile" ;;
    json) render_json >"$outfile" ;;
  esac
  echo "nosycat: report written to $outfile" >&2
fi

exit "$(final_exit_code)"
