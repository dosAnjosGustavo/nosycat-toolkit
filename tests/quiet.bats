#!/usr/bin/env bats
# -q / --problems-only: only WARN/FAIL checks (with why + fix) plus the summary.

load helpers

setup() {
  load_nosycat
  FORMAT=text LIVE_TEXT=1 COLOR_MODE=never NOSY_LOCALE=C.UTF-8 ASCII_MODE=auto
  setup_colors; setup_glyphs
}

@test "problems-only stream: OK/SKIP/INFO/IGNORED lines are hidden, WARN/FAIL keep why and fix" {
  PROBLEMS_ONLY=1
  run bash -c '
    . "$1/lib/common.sh"; . "$1/lib/output.sh"
    FORMAT=text LIVE_TEXT=1 PROBLEMS_ONLY=1 COLOR_MODE=never NOSY_LOCALE=C.UTF-8; setup_colors; setup_glyphs
    printf "NET-009: accepted\n" >"$2/ign"; load_ignore_file "$2/ign"
    CUR_MOD=environment; module_header environment; ok ENV-001 "distro fine"; record INFO ENV-006 "running as x (not root)" "note"
    CUR_MOD=network; module_header network; ok NET-002 "firewall"; warn NET-001 "1 service(s) listening" "redis on 6379" "bind it to 127.0.0.1"; warn NET-009 "accepted thing" "d" "f"
    CUR_MOD=access; module_header access; skip SSH-009 "empty passwords" "needs root"; fail SSH-002 "password auth on" "brute force" "PasswordAuthentication no"
  ' _ "$NOSY_SRC" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"[OK]"* ]]
  [[ "$output" != *"[SKIP]"* ]]
  [[ "$output" != *"[INFO]"* ]]
  [[ "$output" != *"[IGN]"* ]]
  [[ "$output" == *"[WARN] NET-001"* ]]
  [[ "$output" == *"why: redis on 6379"* ]]
  [[ "$output" == *"fix: bind it to 127.0.0.1"* ]]
  [[ "$output" == *"[FAIL] SSH-002"* ]]
  # module headers only for modules with something to show
  [[ "$output" != *"❀ environment"* ]]
  [[ "$output" == *"❀ network"* ]]
  [[ "$output" == *"❀ access"* ]]
}

@test "problems-only keeps every result in the store (summary counts stay complete)" {
  PROBLEMS_ONLY=1 LIVE_TEXT=0
  CUR_MOD=network; ok NET-002 "fw"; warn NET-001 "x" "d" "f"; skip NET-003 "y" "z"
  [ "$(count_status OK)" -eq 1 ]
  [ "$(count_status SKIP)" -eq 1 ]
  run print_summary
  [[ "$output" == *"3 checks"* ]]
  [[ "$output" == *"1 OK"* ]]
}

@test "problems-only run note about root is one short line" {
  IS_ROOT=0 PROBLEMS_ONLY=1
  run print_run_note
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"not root"* ]]
  [ "$(printf '%s' "$output" | LC_ALL=C tr -d '\200-\277' | wc -c)" -le 80 ]
  IS_ROOT=0 PROBLEMS_ONLY=0
  run print_run_note
  [[ "$output" == *"not root"* ]]
  IS_ROOT=1
  run print_run_note
  [ -z "$output" ]
}

@test "CLI: -q and --problems-only hide OK lines and the big banner, keep the summary and the exit code" {
  run bash "$NOSY_SRC/nosycat.sh" --only environment,system,services --no-color
  local full_rc="$status"
  run bash "$NOSY_SRC/nosycat.sh" --only environment,system,services --no-color -q
  [ "$status" -eq "$full_rc" ]
  [[ "$output" != *"[OK]"* ]]
  [[ "$output" != *"[SKIP]"* ]]
  [[ "$output" != *"( o.o )"* ]]
  [[ "$output" == *"nosycat-toolkit v"* ]]
  [[ "$output" == *"summary"* ]]
  run bash "$NOSY_SRC/nosycat.sh" --only environment,system,services --no-color --problems-only
  [ "$status" -eq "$full_rc" ]
  [[ "$output" != *"[OK]"* ]]
}

@test "CLI: -q with --format md lists only WARN/FAIL rows but the full summary line" {
  run bash "$NOSY_SRC/nosycat.sh" --only environment,system --format json
  local ok; ok="$(printf '%s' "$output" | jq -r .summary.ok)"
  run bash "$NOSY_SRC/nosycat.sh" --only environment,system --format md -q
  [[ "$output" != *"| OK |"* ]]
  [[ "$output" != *"| SKIP |"* ]]
  [[ "$output" == *"**summary:** $ok OK"* ]]
  [[ "$output" == *"problems only"* ]]
}

@test "CLI: -q with --format json filters checks[] to WARN/FAIL, keeps summary counts, flags problems_only" {
  run bash "$NOSY_SRC/nosycat.sh" --only environment,system,services --format json
  local full="$output"
  run bash "$NOSY_SRC/nosycat.sh" --only environment,system,services --format json -q
  printf '%s' "$output" | jq -e '.problems_only == true'
  printf '%s' "$output" | jq -e '[.checks[] | select(.status != "WARN" and .status != "FAIL")] | length == 0'
  [ "$(printf '%s' "$output" | jq -c .summary)" = "$(printf '%s' "$full" | jq -c .summary)" ]
  printf '%s' "$full" | jq -e '.problems_only == false'
}
