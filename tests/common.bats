#!/usr/bin/env bats
# addr_scope and the listener parser.

load helpers

setup() { load_nosycat; }

@test "addr_scope: the whole fe80::/10 link-local range is private" {
  for a in fe80::1 fe9a::1 fea0::1 febf::1 FEBF::1; do
    [ "$(addr_scope "$a")" = "private" ] || { echo "$a -> $(addr_scope "$a")"; return 1; }
  done
}

@test "addr_scope: fec0::/10 and global IPv6 are public" {
  [ "$(addr_scope fec0::1)" = "public" ]
  [ "$(addr_scope 2001:db8::1)" = "public" ]
}

@test "addr_scope: ULA, RFC1918, CGNAT, loopback and wildcard" {
  [ "$(addr_scope fd12:3456::1)" = "private" ]
  [ "$(addr_scope fc00::1)" = "private" ]
  [ "$(addr_scope 10.1.2.3)" = "private" ]
  [ "$(addr_scope 172.20.0.1)" = "private" ]
  [ "$(addr_scope 172.32.0.1)" = "public" ]
  [ "$(addr_scope 100.64.0.1)" = "private" ]
  [ "$(addr_scope 127.0.0.53)" = "loopback" ]
  [ "$(addr_scope ::1)" = "loopback" ]
  [ "$(addr_scope 0.0.0.0)" = "any" ]
  [ "$(addr_scope '*')" = "any" ]
  [ "$(addr_scope 192.0.2.10)" = "public" ]
}

@test "collect_listeners parses ss output (v4, v6, process)" {
  export NOSY_FX_SS="$FIX/ss/web.ss"
  collect_listeners
  [ "${#LISTENERS[@]}" -eq 6 ]
  [ "${LISTENERS[0]}" = "tcp 0.0.0.0 80 nginx" ]
  [ "${LISTENERS[2]}" = "tcp :: 80 nginx" ]
}
