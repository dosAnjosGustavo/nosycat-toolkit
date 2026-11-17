#!/usr/bin/env bats
# ENV-006: running without root is a note about the run, not a server problem.

load helpers

setup() { load_nosycat; }

@test "ENV-006 is INFO (not WARN) when not root, OK when root" {
  IS_ROOT=0; nosy mod_environment
  assert_status ENV-006 INFO
  [[ "$(result_field ENV-006 TITLE)" == "running as "*" (not root)" ]]
  R_STATUS=() R_ID=() R_MOD=() R_TITLE=() R_DETAIL=() R_FIX=() R_ORIG=() R_NOTE=()
  IS_ROOT=1; nosy mod_environment
  assert_status ENV-006 OK
}

@test "INFO does not change the exit code, fix first or the box counts" {
  FORMAT=text COLOR_MODE=never NOSY_LOCALE=C.UTF-8 ASCII_MODE=auto IS_ROOT=0
  setup_colors; setup_glyphs
  CUR_MOD=environment
  ok ENV-001 "distribution: Ubuntu 24.04"
  record INFO ENV-006 "running as deploy (not root)" "reduced visibility"
  [ "$(final_exit_code)" -eq 0 ]
  run print_summary
  [[ "$output" != *"fix first"* ]]
  [[ "$output" == *"=^.^="* ]]
  [[ "$output" == *"1 checks"* ]] || [[ "$output" == *"1 check"* ]]
  [[ "$output" == *"environment "*"✓ ok"* ]]
}

@test "INFO is printed as [INFO] in the check stream and counted in json/md" {
  run print_check_line INFO ENV-006 "running as deploy (not root)" "reduced visibility" "sudo ./nosycat.sh"
  [[ "$output" == *"[INFO] ENV-006"* ]]
  [[ "$output" != *"fix:"* ]]
  CUR_MOD=environment; ok ENV-001 "x"; record INFO ENV-006 "running as deploy (not root)" "reduced visibility"
  HOST_NAME=h OS_NAME=x VIRT=kvm PROVIDER=none INIT_SYS=systemd OS_ID=x
  run render_json
  printf '%s' "$output" | jq -e '.summary.info == 1 and .summary.warn == 0'
  run render_md
  [[ "$output" == *"· 1 INFO"* ]]
}

@test "a real non-root run: ENV-006 is INFO and does not set exit code 1 by itself" {
  [ "$(id -u)" -ne 0 ] || skip "needs a non-root runner"
  run bash "$NOSY_SRC/nosycat.sh" --only environment --format json
  printf '%s' "$output" | jq -e '.checks[] | select(.id == "ENV-006") | .status == "INFO"'
  # the exit code follows WARN/FAIL only (other ENV checks may WARN on the CI host)
  local want
  want="$(printf '%s' "$output" | jq -r 'if .summary.fail > 0 then 2 elif .summary.warn > 0 then 1 else 0 end')"
  [ "$status" -eq "$want" ]
  printf '%s' "$output" | jq -e '.summary.info == 1'
}
