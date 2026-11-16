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
# shellcheck source=modules/snapshot.sh
. "$NOSY_ROOT/modules/snapshot.sh"

ALL_MODULES=(environment cloud_init system access network updates docker services web_tls security databases)

usage() {
  cat <<USAGE
$NOSY_NAME $NOSY_VERSION - read-only post-deploy check-up for Linux VPS

usage: sudo ./nosycat.sh [options]

  --only m1,m2        run only these modules
  --skip m1,m2        skip these modules
  --format FMT        text (default) | md | json
  --output DIR        also write the report to DIR/nosycat-<host>-<time>.<ext>
  --no-color          disable ANSI colors (NO_COLOR is honoured too)
  --snapshot          save a baseline of this server and exit
  --diff              compare the server against the saved baseline
  --state-dir DIR     baseline location (default: /var/lib/nosycat as root,
                      ~/.local/state/nosycat otherwise)
  --timeout SECS      per-command timeout (default: $NOSY_TIMEOUT)
  --list              list modules and exit
  -h, --help          show this help
  -V, --version       show version

modules: ${ALL_MODULES[*]}

exit codes: 0 all OK · 1 WARN present · 2 FAIL present · 3 usage/runtime error
USAGE
}

die_usage() { echo "nosycat: $*" >&2; echo "try: ./nosycat.sh --help" >&2; exit 3; }

ONLY="" SKIP_LIST="" OUTDIR="" MODE="check" STATE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) [ -n "${2:-}" ] || die_usage "--only needs a value"; ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    --skip) [ -n "${2:-}" ] || die_usage "--skip needs a value"; SKIP_LIST="$2"; shift 2 ;;
    --skip=*) SKIP_LIST="${1#*=}"; shift ;;
    --format) [ -n "${2:-}" ] || die_usage "--format needs a value"; FORMAT="$2"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    --output) [ -n "${2:-}" ] || die_usage "--output needs a directory"; OUTDIR="$2"; shift 2 ;;
    --output=*) OUTDIR="${1#*=}"; shift ;;
    --state-dir) [ -n "${2:-}" ] || die_usage "--state-dir needs a directory"; STATE_DIR="$2"; shift 2 ;;
    --state-dir=*) STATE_DIR="${1#*=}"; shift ;;
    --timeout) [[ "${2:-}" =~ ^[0-9]+$ ]] || die_usage "--timeout needs seconds"; NOSY_TIMEOUT="$2"; shift 2 ;;
    --no-color) USE_COLOR=0; shift ;;
    --snapshot) [ "$MODE" = "diff" ] && die_usage "--snapshot and --diff are exclusive"; MODE="snapshot"; shift ;;
    --diff) [ "$MODE" = "snapshot" ] && die_usage "--snapshot and --diff are exclusive"; MODE="diff"; shift ;;
    --list) printf '%s\n' "${ALL_MODULES[@]}" snapshot; exit 0 ;;
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

setup_colors
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

[ "$FORMAT" = "text" ] && print_banner
if [ "$IS_ROOT" -ne 1 ] && [ "$FORMAT" = "text" ]; then
  printf '  %snote: not running as root, so some checks are SKIPped. use sudo for the full picture.%s\n' "$C_WARN" "$C_RST"
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
    text) ( C_OK="" C_WARN="" C_FAIL="" C_SKIP="" C_DIM="" C_BOLD="" C_PINK="" C_RST=""; render_text_full ) >"$outfile" ;;
    md) render_md >"$outfile" ;;
    json) render_json >"$outfile" ;;
  esac
  echo "nosycat: report written to $outfile" >&2
fi

if [ "$(count_status FAIL)" -gt 0 ]; then exit 2
elif [ "$(count_status WARN)" -gt 0 ]; then exit 1
else exit 0; fi
