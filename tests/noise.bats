#!/usr/bin/env bats
# Less noise: web servers on 80/443, /dev/shm, and the ignore file.

load helpers

setup() {
  load_nosycat
  fake_etc
  : >"$NOSY_ETC/ssh/sshd_config"
}

@test "NET-001: nginx on 80/443 is expected, nginx on 8080 is not" {
  export NOSY_FX_SS="$FIX/ss/web.ss"
  nosy mod_network
  assert_status NET-001 WARN
  local t; t="$(result_field NET-001 TITLE)"
  [[ "$t" == *"8080/tcp(nginx)"* ]]
  [[ "$t" != *"80/tcp(nginx),"* ]]
  [[ "$t" != *"443/tcp"* ]]
  [[ "$t" == "1 service(s)"* ]]
}

@test "NET-001: only web server on 80/443 plus SSH is OK" {
  grep -v ':8080 ' "$FIX/ss/web.ss" >"$BATS_TEST_TMPDIR/web.ss"
  export NOSY_FX_SS="$BATS_TEST_TMPDIR/web.ss"
  nosy mod_network
  assert_status NET-001 OK
  [[ "$(result_field NET-001 DETAIL)" == *"80/443"* ]]
}

@test "NET-001: an unknown process on 80 is still reported" {
  printf 'tcp LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("python3",pid=9,fd=3))\n' >"$BATS_TEST_TMPDIR/py.ss"
  export NOSY_FX_SS="$BATS_TEST_TMPDIR/py.ss"
  nosy mod_network
  assert_status NET-001 WARN
}

@test "SEC-005: /dev/shm without noexec (Debian default) no longer WARNs" {
  export NOSY_PROC_MOUNTS="$FIX/mounts/debian-shm.mounts"
  nosy mod_security
  assert_status SEC-005 OK
  [[ "$(result_field SEC-005 DETAIL)" == *"/dev/shm"* ]]
}

@test "SEC-005: /tmp without its own noexec mount still WARNs" {
  export NOSY_PROC_MOUNTS="$FIX/mounts/no-tmp.mounts"
  nosy mod_security
  assert_status SEC-005 WARN
}

@test "ignore file: IDs and ID: reason lines turn WARN/FAIL into IGNORED" {
  printf '# accepted findings\nNET-001: nginx on 8080 is the admin panel\n\nSEC-00*   # globs work\n' >"$BATS_TEST_TMPDIR/ignore"
  nosy load_ignore_file "$BATS_TEST_TMPDIR/ignore"
  nosy warn NET-001 "1 service(s) listening" "why" "fix"
  nosy fail SEC-004 "odd suid" "why" "fix"
  nosy ok SEC-001 "fail2ban active" ""
  nosy warn SSH-008 "unused" "why" "fix"
  assert_status NET-001 IGNORED
  assert_status SEC-004 IGNORED
  assert_status SEC-001 OK
  assert_status SSH-008 WARN
  [[ "$(result_field NET-001 DETAIL)" == *"was WARN"*"admin panel"* ]]
}

@test "ignored checks do not count for the exit code" {
  printf 'NET-001\n' >"$BATS_TEST_TMPDIR/ignore"
  nosy load_ignore_file "$BATS_TEST_TMPDIR/ignore"
  nosy warn NET-001 "x" "" ""
  nosy ok SSH-002 "y" ""
  [ "$(final_exit_code)" -eq 0 ]
  nosy warn SSH-008 "z" "" ""
  [ "$(final_exit_code)" -eq 1 ]
}

@test "JSON output keeps the original status of ignored checks" {
  printf 'NET-001: accepted\n' >"$BATS_TEST_TMPDIR/ignore"
  nosy load_ignore_file "$BATS_TEST_TMPDIR/ignore"
  nosy warn NET-001 "x" "d" "f"
  run render_json
  echo "$output" | jq -e '.checks[0].status == "IGNORED" and .checks[0].original_status == "WARN" and .checks[0].ignore_reason == "accepted" and .summary.ignored == 1'
}

@test "malformed ignore lines are reported and skipped" {
  printf 'not an id\nNET-001\n' >"$BATS_TEST_TMPDIR/ignore"
  run load_ignore_file "$BATS_TEST_TMPDIR/ignore"
  [ "$status" -eq 0 ]
  [[ "$output" == *"line 1"* ]]
}
