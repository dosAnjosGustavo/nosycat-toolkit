#!/usr/bin/env bats
# scripts/bundle.sh: the single-file release asset behaves like the source tree.

load helpers

setup() {
  load_nosycat
  BUNDLE_DIR="$BATS_TEST_TMPDIR/alone"
  mkdir -p "$BUNDLE_DIR"
  run "$NOSY_SRC/scripts/bundle.sh" "$BUNDLE_DIR/nosycat.sh"
  [ "$status" -eq 0 ]
  BUNDLE="$BUNDLE_DIR/nosycat.sh"
  fake_etc
  export NOSY_FX_SS="$FIX/ss/docker-host.ss" NOSY_FX_SSHD_T="$FIX/sshd/pa-yes.sshd-T"
  export NOSY_FX_NFT="$FIX/nft/fail2ban-only.nft"
}

@test "bundle is one executable file with no source lines left, and is reproducible" {
  [ -x "$BUNDLE" ]
  [ "$(ls "$BUNDLE_DIR")" = "nosycat.sh" ]
  ! grep -q 'NOSY_ROOT' "$BUNDLE"
  [ "$(grep -c '^#!' "$BUNDLE")" -eq 1 ]
  "$NOSY_SRC/scripts/bundle.sh" "$BATS_TEST_TMPDIR/again.sh" >/dev/null
  [ "$(cksum <"$BUNDLE")" = "$(cksum <"$BATS_TEST_TMPDIR/again.sh")" ]
}

@test "bundle runs on its own (no lib/ or modules/ next to it)" {
  cd "$BUNDLE_DIR"
  run ./nosycat.sh --version
  [ "$status" -eq 0 ]
  [ "$output" = "$(bash "$NOSY_SRC/nosycat.sh" --version)" ]
  [ "$(./nosycat.sh --list)" = "$(bash "$NOSY_SRC/nosycat.sh" --list)" ]
  [ "$(./nosycat.sh --help)" = "$(bash "$NOSY_SRC/nosycat.sh" --help)" ]
  run ./nosycat.sh --bogus
  [ "$status" -eq 3 ]
}

@test "bundle and tree give the same JSON on fixtures (timestamps aside) and the same exit code" {
  local a b ra=0 rb=0
  a="$(bash "$NOSY_SRC/nosycat.sh" --only cloud_init,access,network,databases --format json)" || ra=$?
  b="$("$BUNDLE" --only cloud_init,access,network,databases --format json)" || rb=$?
  [ "$ra" -eq "$rb" ]
  [ "$(printf '%s' "$a" | jq -S 'del(.generated_at)')" = "$(printf '%s' "$b" | jq -S 'del(.generated_at)')" ]
  printf '%s' "$b" | jq -e '.checks | length > 10'
}

@test "bundle and tree give the same text report on fixtures (banner date aside)" {
  local a b
  a="$(bash "$NOSY_SRC/nosycat.sh" --only cloud_init,access,network --color never | grep -v ' read-only$')" || true
  b="$("$BUNDLE" --only cloud_init,access,network --color never | grep -v ' read-only$')" || true
  [ -n "$a" ]
  [ "$a" = "$b" ]
}

@test "full run: bundle and tree report the same check ids" {
  local a b
  a="$(bash "$NOSY_SRC/nosycat.sh" --format json | jq -c '[.checks[].id]')" || true
  b="$("$BUNDLE" --format json | jq -c '[.checks[].id]')" || true
  [ "$a" != "" ] && [ "$a" = "$b" ]
}
