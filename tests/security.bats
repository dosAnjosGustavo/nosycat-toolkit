#!/usr/bin/env bats
# SEC-004 confirms SUID ownership with the package manager.

load helpers

setup() {
  load_nosycat
  use_stubs
  printf '/usr/bin/sudo\n/opt/tools/sudo\n/usr/bin/mount\n' >"$BATS_TEST_TMPDIR/suid"
  export NOSY_FX_SUID="$BATS_TEST_TMPDIR/suid"
  printf '/usr/bin/sudo\n/bin/mount\n' >"$BATS_TEST_TMPDIR/owned"
  export DPKG_STUB_OWNED="$BATS_TEST_TMPDIR/owned"
  export NOSY_PROC_MOUNTS="$FIX/mounts/debian-shm.mounts"
}

@test "a SUID 'sudo' outside any package is flagged even though the name is known" {
  PKG_MGR=apt-get
  nosy mod_security
  assert_status SEC-004 WARN
  local t; t="$(result_field SEC-004 TITLE)"
  [[ "$t" == *"/opt/tools/sudo"* ]]
  [[ "$t" != *"/usr/bin/sudo"* ]]
}

@test "usrmerge: /usr/bin/mount owned as /bin/mount counts as packaged" {
  PKG_MGR=apt-get
  nosy mod_security
  [[ "$(result_field SEC-004 TITLE)" != *"/usr/bin/mount"* ]]
}

@test "everything packaged: SEC-004 OK" {
  printf '/usr/bin/sudo\n' >"$NOSY_FX_SUID"
  PKG_MGR=apt-get
  nosy mod_security
  assert_status SEC-004 OK
}

@test "SUID in /tmp is a FAIL" {
  printf '/tmp/.x/sh\n' >"$NOSY_FX_SUID"
  PKG_MGR=apt-get
  nosy mod_security
  assert_status SEC-004 FAIL
}

@test "no ownership tool: falls back to the name list and says so" {
  PKG_MGR=none
  nosy mod_security
  assert_status SEC-004 OK
  [[ "$(result_field SEC-004 DETAIL)" == *"name"* ]]
}
