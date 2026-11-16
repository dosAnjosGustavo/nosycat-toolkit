#!/usr/bin/env bats
# Bug 2: DB-002 must test the detected host:port and only trust NOAUTH.

load helpers

setup() {
  load_nosycat
  use_stubs
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  unset REDISCLI_AUTH
}

@test "connection refused is not 'requires authentication'" {
  export NOSY_FX_SS="$FIX/ss/redis-local.ss"
  export REDIS_STUB_REPLY="Could not connect to Redis at 127.0.0.1:6379: Connection refused" REDIS_STUB_RC=1
  nosy mod_databases
  assert_status DB-002 SKIP
  [[ "$(result_field DB-002 DETAIL)" == *"could not connect to 127.0.0.1:6379"* ]]
}

@test "empty reply (timeout) is not OK either" {
  export NOSY_FX_SS="$FIX/ss/redis-local.ss" REDIS_STUB_REPLY="" REDIS_STUB_RC=124
  nosy mod_databases
  assert_status DB-002 SKIP
}

@test "NOAUTH reply means Redis requires authentication" {
  export NOSY_FX_SS="$FIX/ss/redis-local.ss" REDIS_STUB_REPLY="NOAUTH Authentication required."
  nosy mod_databases
  assert_status DB-002 OK
}

@test "PONG on a public listener is a FAIL" {
  export NOSY_FX_SS="$FIX/ss/redis-public.ss" REDIS_STUB_REPLY="PONG"
  nosy mod_databases
  assert_status DB-002 FAIL
  assert_status DB-001 FAIL
}

@test "PONG on loopback only is a WARN" {
  export NOSY_FX_SS="$FIX/ss/redis-local.ss" REDIS_STUB_REPLY="PONG"
  nosy mod_databases
  assert_status DB-002 WARN
}

@test "Redis on a private IP and a non-default port is probed on that host:port" {
  export NOSY_FX_SS="$FIX/ss/redis-private-port.ss" REDIS_STUB_REPLY="NOAUTH Authentication required."
  nosy mod_databases
  assert_status DB-002 OK
  grep -q -- '-h 10.0.0.5 -p 6380' "$STUB_LOG"
}

@test "protected-mode DENIED reply is a WARN (no password set)" {
  export NOSY_FX_SS="$FIX/ss/redis-private-port.ss"
  export REDIS_STUB_REPLY="DENIED Redis is running in protected mode because protected mode is enabled"
  nosy mod_databases
  assert_status DB-002 WARN
}

@test "REDISCLI_AUTH from the caller's environment is not used" {
  export NOSY_FX_SS="$FIX/ss/redis-local.ss" REDIS_STUB_REPLY="NOAUTH Authentication required." REDISCLI_AUTH=secret
  nosy mod_databases
  assert_status DB-002 OK
}

@test "redis not listening: DB-002 is skipped" {
  printf '' >"$BATS_TEST_TMPDIR/empty.ss"
  export NOSY_FX_SS="$BATS_TEST_TMPDIR/empty.ss"
  nosy mod_databases
  assert_status DB-002 SKIP
  [ ! -s "$STUB_LOG" ]
}
