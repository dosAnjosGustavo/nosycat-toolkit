# tests/helpers.bash - shared setup for the bats suite.
# Sources the libraries and modules (not nosycat.sh, which would run a scan)
# so each test can call one detector or module against fixture files.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC1091  # globals are read by the sourced code; paths resolve at runtime

NOSY_SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
FIX="$BATS_TEST_DIRNAME/fixtures"

load_nosycat() {
  export LC_ALL=C
  # Deterministic defaults: no real firewall frontends, no real systemd unit list.
  export NOSY_FX_UFW_STATUS=/dev/null NOSY_FX_FIREWALLD_STATE=/dev/null
  export NOSY_FX_NFT=/dev/null NOSY_FX_IPTABLES_INPUT=/dev/null NOSY_FX_IP6TABLES_INPUT=/dev/null
  export NOSY_FX_SSH_UNITS=/dev/null
  # shellcheck source=../lib/common.sh
  . "$NOSY_SRC/lib/common.sh"
  # shellcheck source=../lib/detect.sh
  . "$NOSY_SRC/lib/detect.sh"
  # shellcheck source=../lib/output.sh
  . "$NOSY_SRC/lib/output.sh"
  local m
  for m in "$NOSY_SRC"/modules/*.sh; do
    # shellcheck disable=SC1090
    . "$m"
  done
  FORMAT=json LIVE_TEXT=0 CUR_MOD=test
  IS_ROOT=1 VIRT_KIND=vm OS_FAMILY=debian PKG_MGR=none FW_ACTIVE=none
}

# use_stubs -> put tests/stubs first on PATH (fake docker, redis-cli, dpkg...).
use_stubs() { export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"; }

# fake_etc -> empty /etc-like tree in the test tmpdir, exported as NOSY_ETC.
fake_etc() {
  export NOSY_ETC="$BATS_TEST_TMPDIR/etc"
  ETC="$NOSY_ETC"
  mkdir -p "$NOSY_ETC/ssh/sshd_config.d"
}

# result_field ID FIELD -> STATUS | TITLE | DETAIL | FIX of the last record with ID.
result_field() {
  local id="$1" field="$2" i found=""
  for i in "${!R_ID[@]}"; do [ "${R_ID[$i]}" = "$id" ] && found="$i"; done
  [ -n "$found" ] || { echo "NO_RESULT"; return 1; }
  case "$field" in
    STATUS) echo "${R_STATUS[$found]}" ;;
    TITLE) echo "${R_TITLE[$found]}" ;;
    DETAIL) echo "${R_DETAIL[$found]}" ;;
    FIX) echo "${R_FIX[$found]}" ;;
  esac
}
status_of() { result_field "$1" STATUS; }

# assert_status ID EXPECTED -> fails with the full record when it differs.
assert_status() {
  local got
  got="$(status_of "$1")"
  if [ "$got" != "$2" ]; then
    echo "expected $1=$2, got $got"
    echo "title:  $(result_field "$1" TITLE)"
    echo "detail: $(result_field "$1" DETAIL)"
    return 1
  fi
}

# nosy CMD... -> run nosycat code without bats' errexit: the script itself runs
# without `set -e` and relies on non-zero returns in conditions.
nosy() { set +e; "$@"; set -e; }
