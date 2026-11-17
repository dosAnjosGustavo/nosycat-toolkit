#!/usr/bin/env bats
# Runner: options, temp dir handling, banner.

load helpers

@test "--version and --help" {
  run bash "$NOSY_SRC/nosycat.sh" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "nosycat-toolkit "* ]]
  run bash "$NOSY_SRC/nosycat.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--ignore FILE"* ]]
}

@test "unknown option exits 3" {
  run bash "$NOSY_SRC/nosycat.sh" --bogus
  [ "$status" -eq 3 ]
}

@test "--ignore with a missing file exits 3" {
  run bash "$NOSY_SRC/nosycat.sh" --ignore "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 3 ]
}

@test "--ignore turns a WARN into IGNORED in a real run" {
  local ign="$BATS_TEST_TMPDIR/ignore"
  printf 'ENV-*\nCLD-*\n' >"$ign"
  run bash "$NOSY_SRC/nosycat.sh" --only environment,cloud_init --format json --ignore "$ign"
  echo "$output" | jq -e '[.checks[] | select(.status == "WARN" or .status == "FAIL")] | length == 0'
  [ "$status" -eq 0 ]
}

@test "the state-dir .nosycat.ignore is read automatically" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf 'ENV-*\nCLD-*\n' >"$BATS_TEST_TMPDIR/state/.nosycat.ignore"
  run bash "$NOSY_SRC/nosycat.sh" --only environment,cloud_init --format json --state-dir "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ]
}

@test "--diff fails cleanly instead of using a predictable /tmp path when mktemp fails" {
  use_stubs
  local st="$BATS_TEST_TMPDIR/state"
  bash "$NOSY_SRC/nosycat.sh" --snapshot --state-dir "$st" >/dev/null 2>&1
  MKTEMP_STUB_FAIL=1 run bash "$NOSY_SRC/nosycat.sh" --diff --state-dir "$st" --no-color
  [ "$status" -eq 3 ]
  [[ "$output" == *"temporary directory"* ]]
}

@test "--diff removes its temp dir on exit" {
  use_stubs
  local st="$BATS_TEST_TMPDIR/state" td="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$td"
  bash "$NOSY_SRC/nosycat.sh" --snapshot --state-dir "$st" >/dev/null 2>&1
  MKTEMP_STUB_DIR="$td" run bash "$NOSY_SRC/nosycat.sh" --diff --state-dir "$st" --no-color
  [ "$status" -le 2 ]
  [ -z "$(ls -A "$td")" ]
}

@test "temp dir is removed when the run is interrupted (TERM)" {
  use_stubs
  local st="$BATS_TEST_TMPDIR/state" td="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$td"
  bash "$NOSY_SRC/nosycat.sh" --snapshot --state-dir "$st" >/dev/null 2>&1
  # the comm stub sleeps, so the run is caught after mod_snapshot made its temp dir
  MKTEMP_STUB_DIR="$td" COMM_STUB_SLEEP=2 bash "$NOSY_SRC/nosycat.sh" --diff --state-dir "$st" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 50); do [ -n "$(ls -A "$td")" ] && break; sleep 0.1; done
  [ -n "$(ls -A "$td")" ]
  kill -TERM "$pid"
  wait "$pid" || true
  [ -z "$(ls -A "$td")" ]
}

@test "script banner is the README art (cat with \$ sniff)" {
  load_nosycat
  NOSY_LOCALE=C.UTF-8; setup_glyphs
  local readme banner
  readme="$(awk '/^<pre>$/{f=1;next} /^<\/pre>$/{f=0} f' "$NOSY_SRC/README.md" | sed 's/[[:space:]]*$//')"
  banner="$(C_PINK='' C_RST='' C_DIM='' print_banner | sed '/^  v[0-9]/d; s/[[:space:]]*$//')"
  [ "$banner" = "$readme" ]
  [[ "$banner" == *'$ sniff'* ]]
}
