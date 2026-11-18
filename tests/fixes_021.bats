#!/usr/bin/env bats
# 0.2.1 fixes: ignore-file parsing, backup edge cases, JSON/Markdown escaping,
# CLI validation and SSH-006 without root.

load helpers

NOW=1795000000   # 2026-11-18 11:06:40 UTC

setup() {
  load_nosycat
  fake_etc
  export NOSY_FX_TODAY=2026-12-01
}

ign() { printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/ignore"; nosy load_ignore_file "$BATS_TEST_TMPDIR/ignore"; }

bkp_setup() {
  export NOSY_FS="$BATS_TEST_TMPDIR/fs" NOSY_FX_NOW="$NOW" NOSY_FX_BKP_TOOLS="" TZ=UTC
  mkdir -p "$NOSY_FS/root" "$NOSY_FS/home" "$NOSY_FS/var/spool/cron/crontabs" "$NOSY_ETC/cron.d" "$NOSY_ETC/systemd/system"
  CUR_MOD=backup
}

restic_repo() { # restic_repo DIR -> a minimal local restic repo with one fresh snapshot
  mkdir -p "$1/snapshots"; : >"$1/config"; : >"$1/snapshots/s1"; touch -d "@$((NOW - 3600))" "$1/snapshots/s1"
}

# ---------------------------------------------------------------- ignore file

@test "ignore: a # inside the reason is kept, and so is the until date" {
  ign "BKP-001: see ticket #123 until 2026-11-01"
  [ "${IGNORE_WHY[0]}" = "see ticket #123" ]
  [ "${IGNORE_UNTIL[0]}" = 2026-11-01 ]
  nosy warn BKP-001 "no backup tool found" "d" "f"
  assert_status BKP-001 WARN
  [[ "$(result_field BKP-001 DETAIL)" == *"ignore expired 2026-11-01"* ]]
}

@test "ignore: # still starts a comment at the start of a line and right after the id" {
  ign "# accepted" "   # indented comment" "SEC-00*   # globs work"
  [ "${#IGNORE_PAT[@]}" -eq 1 ]
  [ "${IGNORE_PAT[0]}" = "SEC-00*" ]
  [ -z "${IGNORE_WHY[0]}" ]
}

@test "ignore: until is case-insensitive" {
  local w
  for w in Until UNTIL uNtIl; do
    IGNORE_PAT=() IGNORE_WHY=() IGNORE_UNTIL=()
    ign "NET-001: x $w 2026-11-01"
    [ "${IGNORE_UNTIL[0]}" = 2026-11-01 ] || { echo "$w not recognised"; return 1; }
    [ "${IGNORE_WHY[0]}" = x ]
  done
}

@test "ignore: until without a date warns and skips the entry" {
  local line
  for line in "NET-001: open until" "NET-001 until" "NET-001: x UNTIL"; do
    IGNORE_PAT=() IGNORE_WHY=() IGNORE_UNTIL=()
    printf '%s\n' "$line" >"$BATS_TEST_TMPDIR/ignore"
    run load_ignore_file "$BATS_TEST_TMPDIR/ignore"
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs a date"* ]] || { echo "no warning for: $line"; return 1; }
    nosy load_ignore_file "$BATS_TEST_TMPDIR/ignore" 2>/dev/null
    [ "${#IGNORE_PAT[@]}" -eq 0 ] || { echo "accepted: $line"; return 1; }
  done
}

# ---------------------------------------------------------------- backup

@test "BKP-004: a repo path that is a symlink to another filesystem is followed (stat -L)" {
  bkp_setup
  export NOSY_FX_BKP_TOOLS=restic
  restic_repo "$NOSY_FS/mnt/vol/restic"
  ln -s "$NOSY_FS/mnt/vol/restic" "$NOSY_FS/backup"
  printf '0 3 * * * root restic -r /backup backup /etc\n' >"$NOSY_ETC/cron.d/restic"
  # fake device numbers: everything under $NOSY_FS/mnt is another filesystem
  stat() {
    local a follow=0 p
    for a in "$@"; do [ "$a" = -L ] && follow=1; done
    p="${*: -1}"; [ "$follow" -eq 1 ] && p="$(readlink -f -- "$p")"
    case "$p" in "$NOSY_FS"/mnt/*) echo 99 ;; *) echo 1 ;; esac
  }
  nosy mod_backup
  assert_status BKP-004 OK
  [[ "$(result_field BKP-004 TITLE)" == *"separate filesystem"* ]]
}

@test "BKP-004: when stat cannot tell, it is never reported as a separate filesystem" {
  bkp_setup
  export NOSY_FX_BKP_TOOLS=restic
  restic_repo "$NOSY_FS/srv/restic"
  printf '0 3 * * * root restic -r /srv/restic backup /etc\n' >"$NOSY_ETC/cron.d/restic"
  stat() { if [[ " $* " == *" -c %d "* ]]; then return 1; fi; command stat "$@"; }
  nosy mod_backup
  assert_status BKP-004 SKIP
  [[ "$(result_field BKP-004 DETAIL)" == *"could not determine"* ]]
}

@test "BKP-002: a backup tool named only in a trailing cron comment is not a schedule" {
  bkp_setup
  export NOSY_FX_BKP_TOOLS=restic
  printf '0 3 * * * root /usr/local/bin/sync.sh  # TODO: switch to restic\n' >"$NOSY_ETC/cron.d/sync"
  nosy mod_backup
  assert_status BKP-002 WARN
}

@test "BKP-002: a real backup line with a trailing comment still counts" {
  bkp_setup
  export NOSY_FX_BKP_TOOLS=restic
  printf '0 3 * * * root restic backup /etc  # nightly\n' >"$NOSY_ETC/cron.d/restic"
  nosy mod_backup
  assert_status BKP-002 OK
}

@test "BKP-003: timeshift snapshot names are local time" {
  bkp_setup
  export NOSY_FX_BKP_TOOLS=timeshift TZ='<-03>3'
  # 06:06:40 at UTC-3 is 09:06:40 UTC, two hours before NOW (read as UTC it would be five)
  mkdir -p "$NOSY_FS/timeshift/snapshots/2026-11-18_06-06-40"
  nosy mod_backup
  [[ "$(result_field BKP-003 TITLE)" == *"2 hour(s) ago"* ]]
}

@test "BKP-003: the limit is compared in seconds, not whole days" {
  bkp_setup
  export NOSY_FX_BKP_TOOLS=restic
  local d="$NOSY_FS/root/.cache/restic/4f1c0e2a/snapshots"
  mkdir -p "$d"; : >"$d/a"; touch -d "@$((NOW - 7 * 86400 - 5 * 3600))" "$d/a"
  nosy mod_backup
  assert_status BKP-003 WARN
  [[ "$(result_field BKP-003 TITLE)" == *"over 7 day(s) ago"* ]]
  R_STATUS=() R_ID=() R_TITLE=() R_DETAIL=() R_FIX=() R_MOD=() R_ORIG=() R_NOTE=() R_UNTIL=() R_EXPIRED=()
  touch -d "@$((NOW - 6 * 86400 - 23 * 3600))" "$d/a"
  nosy mod_backup
  assert_status BKP-003 OK
}

@test "BKP-003: borgmatic alone gives a reason for the SKIP" {
  bkp_setup
  export NOSY_FX_BKP_TOOLS=borgmatic
  nosy mod_backup
  assert_status BKP-003 SKIP
  local d; d="$(result_field BKP-003 DETAIL)"
  [[ "$d" == *"borgmatic: "* ]]
  [[ "$d" != *": " ]]
}

# ---------------------------------------------------------------- json / markdown

@test "json: invalid UTF-8 in a file name is replaced, valid UTF-8 is kept" {
  use_stubs
  export NOSY_FX_SUID="$FIX/suid/bad-utf8.suid" NOSY_PROC_MOUNTS="$FIX/mounts/debian-shm.mounts"
  printf '/usr/bin/sudo\n' >"$BATS_TEST_TMPDIR/owned"; export DPKG_STUB_OWNED="$BATS_TEST_TMPDIR/owned"
  PKG_MGR=apt-get CUR_MOD=security
  nosy mod_security
  ok ENV-001 "café ✓"
  HOST_NAME=h OS_NAME=x VIRT=kvm PROVIDER=none INIT_SYS=systemd OS_ID=x
  render_json >"$BATS_TEST_TMPDIR/r.json"
  if LC_ALL=C grep -q $'\xff' "$BATS_TEST_TMPDIR/r.json"; then echo "raw 0xff byte in json"; return 1; fi
  jq -e '.checks[] | select(.id == "SEC-004") | .title | contains("/tmp/nosy?bad")' "$BATS_TEST_TMPDIR/r.json"
  jq -e '.checks[] | select(.id == "ENV-001") | .title == "café ✓"' "$BATS_TEST_TMPDIR/r.json"
}

@test "_utf8_clean: truncated, overlong and surrogate sequences become ?" {
  [ "$(_utf8_clean $'a\xc3')" = "a?" ]
  [ "$(_utf8_clean $'\xc0\xaf')" = "??" ]
  [ "$(_utf8_clean $'\xed\xa0\x80')" = "???" ]
  [ "$(_utf8_clean $'\xf0\x9f\x98\x80')" = $'\xf0\x9f\x98\x80' ]
}

@test "md: emphasis, code, link and HTML characters are escaped; fixes stay code spans" {
  CUR_MOD=network
  warn NET-001 'a *b* _c_ [d](e) <f> `g`' 'x|y \z' 'echo 1 | sudo tee /x'
  HOST_NAME=h OS_NAME=x VIRT=kvm PROVIDER=none INIT_SYS=systemd OS_ID=x
  NOSY_LOCALE=C.UTF-8 run render_md
  [[ "$output" == *'a \*b\* \_c\_ \[d\](e) \<f\> \`g\`'* ]]
  [[ "$output" == *'x\|y \\z'* ]]
  [[ "$output" == *'`echo 1 \| sudo tee /x`'* ]]
}

@test "md: plain ASCII under --ascii or a non-UTF-8 locale" {
  CUR_MOD=environment; ok ENV-001 "x"
  HOST_NAME=h OS_NAME=x VIRT=kvm PROVIDER=none INIT_SYS=systemd OS_ID=x
  NOSY_LOCALE=C run render_md
  if printf '%s' "$output" | LC_ALL=C grep -q '[^ -~]'; then echo "non-ASCII: $output"; return 1; fi
  NOSY_LOCALE=C.UTF-8 ASCII_MODE=on run render_md
  if printf '%s' "$output" | LC_ALL=C grep -q '[^ -~]'; then echo "non-ASCII: $output"; return 1; fi
  NOSY_LOCALE=C.UTF-8 run render_md
  [[ "$output" == *"·"* ]]
}

# ---------------------------------------------------------------- CLI

@test "CLI: empty --only= / --skip= and friends are usage errors" {
  local o
  for o in --only= --skip= --format= --output= --state-dir= --ignore=; do
    run bash "$NOSY_SRC/nosycat.sh" "$o"
    [ "$status" -eq 3 ] || { echo "$o -> $status"; return 1; }
  done
}

@test "CLI: --timeout must be 1 or more" {
  local v
  for v in 0 00 -1 abc ""; do
    run bash "$NOSY_SRC/nosycat.sh" --timeout "$v"
    [ "$status" -eq 3 ] || { echo "--timeout '$v' -> $status"; return 1; }
  done
  run bash "$NOSY_SRC/nosycat.sh" --timeout=0
  [ "$status" -eq 3 ]
  run bash "$NOSY_SRC/nosycat.sh" --timeout 5 --only environment --format json
  [ "$status" -le 2 ]
}

@test "CLI: every module --list prints is accepted by --only" {
  local m
  run bash "$NOSY_SRC/nosycat.sh" --list
  [[ "$output" != *snapshot* ]]
  for m in $output; do
    run bash "$NOSY_SRC/nosycat.sh" --only "$m" --format json
    [ "$status" -le 2 ] || { echo "--only $m -> $status"; return 1; }
  done
}

# ---------------------------------------------------------------- SSH-006

ssh006() { # ssh006 IS_ROOT -> run mod_access against the fake /etc
  IS_ROOT="$1" CUR_MOD=access
  nosy mod_access
}

@test "SSH-006: without readable sudoers and no admin group member it is a SKIP, not a WARN" {
  printf 'root:x:0:\nsudo:x:27:\nwheel:x:10:\n' >"$NOSY_ETC/group"
  printf 'root ALL=(ALL:ALL) ALL\n' >"$NOSY_ETC/sudoers"; chmod 000 "$NOSY_ETC/sudoers"
  if [ -r "$NOSY_ETC/sudoers" ]; then chmod 644 "$NOSY_ETC/sudoers"; return 0; fi   # root reads it anyway
  ssh006 0
  assert_status SSH-006 SKIP
  [[ "$(result_field SSH-006 DETAIL)" == *"needs root"* ]]
  chmod 644 "$NOSY_ETC/sudoers"
}

@test "SSH-006: %group lines in \$ETC/sudoers.d count the group's members" {
  printf 'root:x:0:\nsudo:x:27:\nops:x:1001:alice,bob\n' >"$NOSY_ETC/group"
  printf 'root ALL=(ALL:ALL) ALL\n#includedir /etc/sudoers.d\n' >"$NOSY_ETC/sudoers"
  mkdir -p "$NOSY_ETC/sudoers.d"
  printf 'Defaults env_reset\nUser_Alias ADMINS = carol\nADMINS ALL=(ALL) ALL\n%%ops ALL=(ALL) NOPASSWD:ALL\ndave ALL=(ALL) /usr/bin/systemctl\n' >"$NOSY_ETC/sudoers.d/90-ops"
  ssh006 1
  assert_status SSH-006 OK
  local t; t="$(result_field SSH-006 TITLE)"
  [[ "$t" == *alice* && "$t" == *bob* ]]
  [[ "$t" != *dave* && "$t" != *ADMINS* && " ${t#*: } " != *" root "* ]]
}

@test "SSH-006: a sudoers user line counts; only root is a WARN" {
  printf 'root:x:0:\nsudo:x:27:root\n' >"$NOSY_ETC/group"
  printf 'root ALL=(ALL:ALL) ALL\n' >"$NOSY_ETC/sudoers"
  ssh006 1
  assert_status SSH-006 WARN
  mkdir -p "$NOSY_ETC/sudoers.d"; printf 'deploy ALL=(ALL) NOPASSWD: ALL\n' >"$NOSY_ETC/sudoers.d/deploy"
  R_STATUS=() R_ID=() R_TITLE=() R_DETAIL=() R_FIX=() R_MOD=() R_ORIG=() R_NOTE=() R_UNTIL=() R_EXPIRED=()
  ssh006 1
  assert_status SSH-006 OK
  [[ "$(result_field SSH-006 TITLE)" == *deploy* ]]
}
