#!/usr/bin/env bats
# Bug 3 (CLD-004 effective value), ssh_ports and the reload command.

load helpers

setup() {
  load_nosycat
  fake_etc
  printf 'Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication yes\n' >"$NOSY_ETC/ssh/sshd_config"
}

@test "CLD-004: a drop-in 'yes' overridden by an earlier 'no' is OK (parsed config)" {
  printf 'PasswordAuthentication no\n' >"$NOSY_ETC/ssh/sshd_config.d/00-hardening.conf"
  printf 'PasswordAuthentication yes\n' >"$NOSY_ETC/ssh/sshd_config.d/50-cloud-init.conf"
  IS_ROOT=0
  nosy mod_cloud_init
  assert_status CLD-004 OK
  [[ "$(result_field CLD-004 DETAIL)" == *"50-cloud-init.conf"* ]]
}

@test "CLD-004: a drop-in 'yes' overridden per sshd -T is OK" {
  printf 'PasswordAuthentication yes\n' >"$NOSY_ETC/ssh/sshd_config.d/50-cloud-init.conf"
  export NOSY_FX_SSHD_T="$FIX/sshd/pa-no.sshd-T"
  nosy mod_cloud_init
  assert_status CLD-004 OK
}

@test "CLD-004: an effective 'yes' from the drop-in WARNs" {
  printf 'PasswordAuthentication yes\n' >"$NOSY_ETC/ssh/sshd_config.d/50-cloud-init.conf"
  IS_ROOT=0
  nosy mod_cloud_init
  assert_status CLD-004 WARN
}

@test "SSH-002 follows the first value read through Include" {
  printf 'PasswordAuthentication no\n' >"$NOSY_ETC/ssh/sshd_config.d/00-hardening.conf"
  IS_ROOT=0
  nosy mod_access
  assert_status SSH-002 OK
}

@test "ssh_ports returns every port from sshd -T (port and listenaddress)" {
  export NOSY_FX_SSHD_T="$FIX/sshd/two-ports.sshd-T"
  run ssh_ports
  [ "$output" = "$(printf '22\n2222')" ]
}

@test "ssh_ports collects every Port line from the parsed config" {
  printf 'Port 22\nPort 2222\nListenAddress 192.0.2.10:2200\nListenAddress [2001:db8::1]:2201\nListenAddress 2001:db8::2\n' >"$NOSY_ETC/ssh/sshd_config"
  IS_ROOT=0
  run ssh_ports
  [ "$output" = "$(printf '22\n2200\n2201\n2222')" ]
}

@test "ssh_ports defaults to 22" {
  : >"$NOSY_ETC/ssh/sshd_config"
  IS_ROOT=0
  run ssh_ports
  [ "$output" = "22" ]
}

@test "NET-001: sshd on a second port is not reported as exposed" {
  export NOSY_FX_SSHD_T="$FIX/sshd/two-ports.sshd-T" NOSY_FX_SS="$FIX/ss/ssh-two-ports.ss"
  nosy mod_network
  assert_status NET-001 OK
}

@test "reload command: ssh.service on Debian/Ubuntu" {
  printf 'ssh.service enabled enabled\nsshd.service alias -\n' >"$BATS_TEST_TMPDIR/units"
  export NOSY_FX_SSH_UNITS="$BATS_TEST_TMPDIR/units"
  [ "$(ssh_reload_cmd)" = "sudo systemctl reload ssh" ]
}

@test "reload command: sshd.service on RHEL" {
  printf 'sshd.service enabled disabled\n' >"$BATS_TEST_TMPDIR/units"
  export NOSY_FX_SSH_UNITS="$BATS_TEST_TMPDIR/units"
  OS_FAMILY=rhel
  [ "$(ssh_reload_cmd)" = "sudo systemctl reload sshd" ]
}

@test "reload command: fall back on the distro family when units are unknown" {
  OS_FAMILY=rhel INIT_SYS=unknown
  [ "$(ssh_reload_cmd)" = "sudo systemctl reload sshd" ]
  OS_FAMILY=debian
  [ "$(ssh_reload_cmd)" = "sudo systemctl reload ssh" ]
}

@test "reload command: OpenRC" {
  OS_FAMILY=alpine INIT_SYS=openrc
  [ "$(ssh_reload_cmd)" = "sudo rc-service sshd reload" ]
}

@test "SSH-002 fix uses the detected reload command" {
  printf 'sshd.service enabled disabled\n' >"$BATS_TEST_TMPDIR/units"
  export NOSY_FX_SSH_UNITS="$BATS_TEST_TMPDIR/units" NOSY_FX_SSHD_T="$FIX/sshd/pa-yes.sshd-T"
  nosy mod_access
  assert_status SSH-002 FAIL
  [[ "$(result_field SSH-002 FIX)" == *"systemctl reload sshd"* ]]
}
