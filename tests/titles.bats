#!/usr/bin/env bats
# Review 2: titles and details never carry stray leading/trailing whitespace.

load helpers

setup() { load_nosycat; }

@test "record trims titles and details" {
  warn X-001 "failed units: casper-md5check.service " "  some detail  "
  [ "$(result_field X-001 TITLE)" = "failed units: casper-md5check.service" ]
  [ "$(result_field X-001 DETAIL)" = "some detail" ]
}

@test "SVC-001 title has no trailing space with one failed unit" {
  use_stubs
  export SYSTEMCTL_STUB_FAILED="casper-md5check.service loaded failed failed casper-md5checksum"
  systemd_up() { return 0; }
  nosy mod_services
  [ "$(result_field SVC-001 TITLE)" = "failed units: casper-md5check.service" ]
}

@test "SVC-001 lists several failed units separated by single spaces" {
  use_stubs
  export SYSTEMCTL_STUB_FAILED=$'a.service loaded failed failed A\nb.service loaded failed failed B'
  systemd_up() { return 0; }
  nosy mod_services
  [ "$(result_field SVC-001 TITLE)" = "failed units: a.service b.service" ]
}
