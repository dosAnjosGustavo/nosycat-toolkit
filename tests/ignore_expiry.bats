#!/usr/bin/env bats
# .nosycat.ignore entries with an expiry date: "ID[: reason] until YYYY-MM-DD".

load helpers

setup() {
  load_nosycat
  export NOSY_FX_TODAY=2026-12-01
}

ign() { printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/ignore"; nosy load_ignore_file "$BATS_TEST_TMPDIR/ignore"; }

@test "nosy_today honours NOSY_FX_TODAY, else today's date" {
  [ "$(nosy_today)" = 2026-12-01 ]
  unset NOSY_FX_TODAY
  [ "$(nosy_today)" = "$(date +%Y-%m-%d)" ]
}

@test "ID: reason until DATE is ignored before and on the date, with reason and expiry kept apart" {
  ign "SEC-005: installer needs exec until 2027-01-31"
  nosy warn SEC-005 "/tmp is not noexec" "d" "f"
  assert_status SEC-005 IGNORED
  [[ "$(result_field SEC-005 DETAIL)" == *"installer needs exec"* ]]
  [[ "$(result_field SEC-005 DETAIL)" == *"until 2027-01-31"* ]]
  run render_json
  printf '%s' "$output" | jq -e '.checks[0].ignore_reason == "installer needs exec" and .checks[0].ignore_until == "2027-01-31"'
  R_STATUS=() R_ID=() R_MOD=() R_TITLE=() R_DETAIL=() R_FIX=() R_ORIG=() R_NOTE=() R_UNTIL=() R_EXPIRED=()
  export NOSY_FX_TODAY=2027-01-31
  nosy warn SEC-005 "/tmp is not noexec" "d" "f"
  assert_status SEC-005 IGNORED
}

@test "after the date the ignore stops applying: normal status, a note, and it counts for the exit code" {
  export NOSY_FX_TODAY=2027-02-01
  ign "SEC-005: installer needs exec until 2027-01-31"
  nosy warn SEC-005 "/tmp is not noexec" "exploits run payloads there" "mount tmpfs noexec"
  assert_status SEC-005 WARN
  [[ "$(result_field SEC-005 DETAIL)" == *"ignore expired 2027-01-31"*"installer needs exec"* ]]
  [[ "$(result_field SEC-005 DETAIL)" == *"exploits run payloads there"* ]]
  [ "$(final_exit_code)" -eq 1 ]
  run render_json
  printf '%s' "$output" | jq -e '.checks[0].status == "WARN" and .checks[0].ignore_expired == "2027-01-31" and .checks[0].ignore_reason == "installer needs exec" and .summary.ignore_expired == 1'
}

@test "ID until DATE without a reason" {
  ign "NET-001 until 2027-03-01"
  nosy warn NET-001 "1 service(s) listening" "" ""
  assert_status NET-001 IGNORED
  run render_json
  printf '%s' "$output" | jq -e '.checks[0].ignore_reason == "" and .checks[0].ignore_until == "2027-03-01"'
}

@test "permanent ignores still work and report ignore_until null" {
  ign "NET-001: behind the provider firewall"
  nosy warn NET-001 "x" "" ""
  assert_status NET-001 IGNORED
  run render_json
  printf '%s' "$output" | jq -e '.checks[0].ignore_until == null and .checks[0].ignore_reason == "behind the provider firewall"'
}

@test "globs work with an expiry" {
  ign "SNP-* until 2027-01-01"
  nosy warn SNP-003 "users changed" "" ""
  assert_status SNP-003 IGNORED
}

@test "invalid dates give a warning and the entry is skipped (the finding shows), no crash" {
  local bad
  for bad in 2027-02-30 2027-13-01 2026-00-10 31/01/2027 2027-1-5 2027-01-31x; do
    IGNORE_PAT=() IGNORE_WHY=() IGNORE_UNTIL=()
    printf 'SEC-005: reason until %s\n' "$bad" >"$BATS_TEST_TMPDIR/ignore"
    run load_ignore_file "$BATS_TEST_TMPDIR/ignore"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not a valid date"* ]] || { echo "no warning for $bad: $output"; return 1; }
    nosy load_ignore_file "$BATS_TEST_TMPDIR/ignore" 2>/dev/null
    [ "${#IGNORE_PAT[@]}" -eq 0 ] || { echo "$bad was accepted"; return 1; }
  done
}

@test "leap days are valid dates" {
  ign "SEC-005 until 2028-02-29"
  [ "${IGNORE_UNTIL[0]}" = 2028-02-29 ]
  IGNORE_PAT=() IGNORE_WHY=() IGNORE_UNTIL=()
  run load_ignore_file <(printf 'SEC-005 until 2027-02-29\n')
  [[ "$output" == *"not a valid date"* ]]
}

@test "a reason that merely contains the word until stays a permanent reason" {
  ign "NET-001: open until we move to the vpn"
  [ "${IGNORE_WHY[0]}" = "open until we move to the vpn" ]
  [ -z "${IGNORE_UNTIL[0]}" ]
}

@test "summary: gentle hint for ignores without expiry, and a line for expired ones" {
  FORMAT=text COLOR_MODE=never NOSY_LOCALE=C.UTF-8; setup_colors; setup_glyphs
  ign "NET-001: behind the provider firewall" "SEC-005: installer until 2026-11-01" "SSH-008 until 2027-06-01"
  CUR_MOD=network; nosy warn NET-001 "x" "" ""
  CUR_MOD=security; nosy warn SEC-005 "y" "" ""
  CUR_MOD=access; nosy warn SSH-008 "z" "" ""
  run print_summary
  [[ "$output" == *"1 ignore without an expiry"* ]]
  [[ "$output" == *"until YYYY-MM-DD"* ]]
  [[ "$output" == *"1 ignore expired"*"SEC-005"* ]]
}

@test "no hint when every applied ignore has an expiry" {
  FORMAT=text COLOR_MODE=never NOSY_LOCALE=C.UTF-8; setup_colors; setup_glyphs
  ign "NET-001 until 2027-01-01"
  CUR_MOD=network; nosy warn NET-001 "x" "" ""
  run print_summary
  [[ "$output" != *"without an expiry"* ]]
  [[ "$output" != *"expired"* ]]
}

@test "real run: expired ignore turns IGNORED back into WARN/FAIL" {
  printf 'ENV-* until 2026-01-01\nCLD-* until 2026-01-01\n' >"$BATS_TEST_TMPDIR/ignore"
  NOSY_FX_TODAY=2025-12-31 run bash "$NOSY_SRC/nosycat.sh" --only environment,cloud_init --format json --ignore "$BATS_TEST_TMPDIR/ignore"
  [ "$status" -eq 0 ]
  local n_ign; n_ign="$(printf '%s' "$output" | jq '.summary.ignored')"
  NOSY_FX_TODAY=2026-01-02 run bash "$NOSY_SRC/nosycat.sh" --only environment,cloud_init --format json --ignore "$BATS_TEST_TMPDIR/ignore"
  printf '%s' "$output" | jq -e --argjson n "$n_ign" '.summary.ignored == 0 and .summary.ignore_expired == $n'
  if [ "$n_ign" -gt 0 ]; then [ "$status" -ge 1 ]; fi
}
