#!/usr/bin/env bats
# Bug 1: the nftables check must only look at chains hooked on input.

load helpers

setup() { load_nosycat; }

fw() { export NOSY_FX_NFT="$FIX/nft/$1"; nosy detect_firewall; }

@test "docker on iptables-nft with INPUT policy accept is NOT a firewall" {
  fw docker-no-filter.nft
  [ "$FW_ACTIVE" = "none" ]
}

@test "input chain with policy drop is a firewall" {
  fw input-policy-drop.nft
  [ "$FW_ACTIVE" = "nftables" ]
}

@test "input chain with policy accept and a final drop rule is a firewall" {
  fw input-drop-rule.nft
  [ "$FW_ACTIVE" = "nftables" ]
}

@test "input chain that only drops invalid conntrack state is not a firewall" {
  fw input-only-invalid-drop.nft
  [ "$FW_ACTIVE" = "none" ]
}

@test "input chain that jumps to a chain with reject is a firewall" {
  fw input-jump.nft
  [ "$FW_ACTIVE" = "nftables" ]
}

@test "firewalld-style nft ruleset (reject at the end of filter_INPUT) is a firewall" {
  fw firewalld.nft
  [ "$FW_ACTIVE" = "nftables" ]
}

@test "iptables INPUT policy DROP is a firewall" {
  export NOSY_FX_IPTABLES_INPUT="$FIX/iptables/input-drop.rules"
  nosy detect_firewall
  [ "$FW_ACTIVE" = "iptables" ]
}

@test "iptables INPUT accept with only an INVALID drop is not a firewall" {
  export NOSY_FX_IPTABLES_INPUT="$FIX/iptables/input-accept-invalid.rules"
  nosy detect_firewall
  [ "$FW_ACTIVE" = "none" ]
}

@test "ufw status fixture wins first" {
  printf 'Status: active\n' >"$BATS_TEST_TMPDIR/ufw"
  export NOSY_FX_UFW_STATUS="$BATS_TEST_TMPDIR/ufw" NOSY_FX_NFT="$FIX/nft/input-policy-drop.nft"
  nosy detect_firewall
  [ "$FW_ACTIVE" = "ufw" ]
}

@test "non-root cannot read rules: firewall is unknown" {
  IS_ROOT=0
  fw input-policy-drop.nft
  [ "$FW_ACTIVE" = "unknown" ]
}

@test "NET-002 FAILs on a docker host whose only drops are in DOCKER-ISOLATION" {
  fake_etc
  export NOSY_FX_SS="$FIX/ss/docker-host.ss" NOSY_FX_SSHD_T="$FIX/sshd/pa-no.sshd-T"
  fw docker-no-filter.nft
  nosy mod_network
  assert_status NET-002 FAIL
  assert_status NET-001 WARN
}

@test "DKR-005 FAILs when a real nftables firewall is bypassed by published ports" {
  use_stubs
  printf '/web|false|unless-stopped|json-file|10m||0.0.0.0:3000>3000/tcp,\n' >"$BATS_TEST_TMPDIR/inspect"
  export DOCKER_STUB_INSPECT="$BATS_TEST_TMPDIR/inspect"
  fw input-policy-drop.nft
  nosy mod_docker
  assert_status DKR-005 FAIL
}

@test "DKR-005 stays WARN (NET-002 carries the FAIL) when there is no firewall at all" {
  use_stubs
  printf '/web|false|unless-stopped|json-file|10m||0.0.0.0:3000>3000/tcp,\n' >"$BATS_TEST_TMPDIR/inspect"
  export DOCKER_STUB_INSPECT="$BATS_TEST_TMPDIR/inspect"
  fw docker-no-filter.nft
  nosy mod_docker
  assert_status DKR-005 WARN
}
