#!/usr/bin/env bats
# backup module: tools, schedule, age of the last backup, where it is stored.
# Everything lives under NOSY_FS (a fake root) and NOSY_ETC; NOSY_FX_NOW pins the clock
# and NOSY_FX_BKP_TOOLS replaces the PATH lookup of backup tools.

load helpers

NOW=1795000000   # fixed "now" (epoch seconds)

setup() {
  load_nosycat
  fake_etc
  export NOSY_FS="$BATS_TEST_TMPDIR/fs" NOSY_FX_NOW="$NOW" NOSY_FX_BKP_TOOLS=""
  mkdir -p "$NOSY_FS/root" "$NOSY_FS/home" "$NOSY_FS/var/spool/cron/crontabs" "$NOSY_ETC/cron.d" "$NOSY_ETC/systemd/system"
  CUR_MOD=backup
}

# age FILE DAYS -> set FILE's mtime to DAYS days before NOW
age() { touch -d "@$((NOW - $2 * 86400))" "$1"; }

restic_cache() { # restic_cache HOME DAYS
  local d="$NOSY_FS$1/.cache/restic/4f1c0e2a/snapshots"
  mkdir -p "$d"; : >"$d/a1b2c3"; age "$d/a1b2c3" "$2"
}

@test "no backup tooling: BKP-001 WARN that mentions provider snapshots, the rest SKIP" {
  nosy mod_backup
  assert_status BKP-001 WARN
  [[ "$(result_field BKP-001 DETAIL)" == *"provider snapshots"* ]]
  assert_status BKP-002 SKIP
  assert_status BKP-003 SKIP
  assert_status BKP-004 SKIP
}

@test "restic in cron with a fresh cache: tool OK, schedule OK, age OK" {
  export NOSY_FX_BKP_TOOLS="restic"
  cp "$FIX/backup/restic.cron" "$NOSY_ETC/cron.d/restic"
  restic_cache /root 2
  nosy mod_backup
  assert_status BKP-001 OK
  [[ "$(result_field BKP-001 TITLE)" == *"restic"* ]]
  assert_status BKP-002 OK
  [[ "$(result_field BKP-002 DETAIL)" == *"cron.d/restic"* ]]
  assert_status BKP-003 OK
  [[ "$(result_field BKP-003 TITLE)" == *"2 day(s) ago"* ]]
}

@test "the restic password in a cron line is never printed" {
  export NOSY_FX_BKP_TOOLS="restic"
  cp "$FIX/backup/restic.cron" "$NOSY_ETC/cron.d/restic"
  restic_cache /root 2
  nosy mod_backup
  local all; all="$(printf '%s\n' "${R_TITLE[@]}" "${R_DETAIL[@]}" "${R_FIX[@]}")"
  [[ "$all" != *"hunter2"* ]]
  [[ "$all" != *"RESTIC_PASSWORD"* ]]
}

@test "last backup older than the limit is a WARN; --backup-max-age moves the limit" {
  export NOSY_FX_BKP_TOOLS="restic"
  cp "$FIX/backup/restic.cron" "$NOSY_ETC/cron.d/restic"
  restic_cache /root 10
  nosy mod_backup
  assert_status BKP-003 WARN
  [[ "$(result_field BKP-003 TITLE)" == *"10 day(s) ago"* ]]
  R_STATUS=() R_ID=() R_TITLE=() R_DETAIL=() R_FIX=() R_MOD=() R_ORIG=() R_NOTE=() R_UNTIL=() R_EXPIRED=()
  BACKUP_MAX_AGE=14
  nosy mod_backup
  assert_status BKP-003 OK
}

@test "local restic repo from the cron line: age from the repo's snapshots dir" {
  export NOSY_FX_BKP_TOOLS="restic"
  cp "$FIX/backup/restic.cron" "$NOSY_ETC/cron.d/restic"
  mkdir -p "$NOSY_FS/srv/restic-repo/snapshots"
  : >"$NOSY_FS/srv/restic-repo/config"; : >"$NOSY_FS/srv/restic-repo/snapshots/old"; : >"$NOSY_FS/srv/restic-repo/snapshots/new"
  age "$NOSY_FS/srv/restic-repo/snapshots/old" 9; age "$NOSY_FS/srv/restic-repo/snapshots/new" 1
  nosy mod_backup
  assert_status BKP-003 OK
  [[ "$(result_field BKP-003 TITLE)" == *"1 day(s) ago"* ]]
  [[ "$(result_field BKP-003 DETAIL)" == *"/srv/restic-repo"* ]]
  # a local repo on the root filesystem does not survive losing the disk
  assert_status BKP-004 WARN
}

@test "a commented-out cron line is not a schedule" {
  export NOSY_FX_BKP_TOOLS="restic"
  cp "$FIX/backup/commented.cron" "$NOSY_ETC/cron.d/restic"
  restic_cache /root 1
  nosy mod_backup
  assert_status BKP-002 WARN
}

@test "user crontab in the cron spool counts as a schedule" {
  export NOSY_FX_BKP_TOOLS="borg"
  printf '0 2 * * * borg create /mnt/b::{now} /etc\n' >"$NOSY_FS/var/spool/cron/crontabs/root"
  nosy mod_backup
  assert_status BKP-002 OK
}

@test "borgmatic via an enabled systemd timer, age from borg's security dir" {
  export NOSY_FX_BKP_TOOLS="borg borgmatic"
  cp "$FIX/backup/borgmatic.timer" "$NOSY_ETC/systemd/system/borgmatic.timer"
  mkdir -p "$NOSY_ETC/systemd/system/timers.target.wants"
  ln -s ../borgmatic.timer "$NOSY_ETC/systemd/system/timers.target.wants/borgmatic.timer"
  local sec="$NOSY_FS/root/.config/borg/security/9f8e7d"
  mkdir -p "$sec"; printf 'ssh://u123@u123.your-storagebox.de:23/./borg\n' >"$sec/location"; printf '2026-11-16T03:00:01\n' >"$sec/manifest-timestamp"
  age "$sec/manifest-timestamp" 3
  nosy mod_backup
  assert_status BKP-001 OK
  assert_status BKP-002 OK
  [[ "$(result_field BKP-002 DETAIL)" == *"borgmatic.timer"* ]]
  assert_status BKP-003 OK
  [[ "$(result_field BKP-003 TITLE)" == *"3 day(s) ago"* ]]
  # remote repository: nothing to say about the local disk
  assert_status BKP-004 OK
}

@test "a timer file that is not enabled is not a schedule" {
  export NOSY_FX_BKP_TOOLS="borgmatic"
  cp "$FIX/backup/borgmatic.timer" "$NOSY_ETC/systemd/system/borgmatic.timer"
  nosy mod_backup
  assert_status BKP-002 WARN
}

@test "rsnapshot: snapshot_root from rsnapshot.conf, newest *.0 dir, same disk as / is a WARN" {
  export NOSY_FX_BKP_TOOLS="rsnapshot"
  cp "$FIX/backup/rsnapshot.conf" "$NOSY_ETC/rsnapshot.conf"
  printf '0 3 * * * root /usr/bin/rsnapshot daily\n' >"$NOSY_ETC/cron.d/rsnapshot"
  mkdir -p "$NOSY_FS/.snapshots/daily.0" "$NOSY_FS/.snapshots/daily.1" "$NOSY_FS/.snapshots/weekly.0"
  age "$NOSY_FS/.snapshots/daily.0" 1; age "$NOSY_FS/.snapshots/daily.1" 2; age "$NOSY_FS/.snapshots/weekly.0" 6
  nosy mod_backup
  assert_status BKP-002 OK
  assert_status BKP-003 OK
  [[ "$(result_field BKP-003 TITLE)" == *"1 day(s) ago"* ]]
  [[ "$(result_field BKP-003 DETAIL)" == *"rsnapshot"* ]]
  assert_status BKP-004 WARN
  [[ "$(result_field BKP-004 DETAIL)" == *"/.snapshots"* ]]
}

@test "timeshift: schedule from timeshift.json, age from the snapshot name" {
  export NOSY_FX_BKP_TOOLS="timeshift"
  mkdir -p "$NOSY_ETC/timeshift"; cp "$FIX/backup/timeshift.json" "$NOSY_ETC/timeshift/timeshift.json"
  # NOW is 2026-11-18 (UTC); a snapshot named 2026-11-13_03-00-01 is 5 days old
  mkdir -p "$NOSY_FS/timeshift/snapshots/2026-11-13_03-00-01" "$NOSY_FS/timeshift/snapshots/2026-11-01_03-00-01"
  nosy mod_backup
  assert_status BKP-002 OK
  [[ "$(result_field BKP-002 DETAIL)" == *"timeshift"* ]]
  assert_status BKP-003 OK
  [[ "$(result_field BKP-003 TITLE)" == *"5 day(s) ago"* ]]
}

@test "duplicity: age from its local cache" {
  export NOSY_FX_BKP_TOOLS="duplicity"
  printf '0 4 * * * root duplicity /etc sftp://u@backup.example.com//b\n' >"$NOSY_ETC/cron.d/dup"
  mkdir -p "$NOSY_FS/root/.cache/duplicity/abc123"
  : >"$NOSY_FS/root/.cache/duplicity/abc123/duplicity-full.20261110T040001Z.manifest"
  age "$NOSY_FS/root/.cache/duplicity/abc123/duplicity-full.20261110T040001Z.manifest" 8
  nosy mod_backup
  assert_status BKP-003 WARN
  [[ "$(result_field BKP-003 TITLE)" == *"8 day(s) ago"* ]]
}

@test "kopia or duplicati only: age is a SKIP that explains why (no password, no database read)" {
  export NOSY_FX_BKP_TOOLS="kopia"
  nosy mod_backup
  assert_status BKP-001 OK
  assert_status BKP-003 SKIP
  [[ "$(result_field BKP-003 DETAIL)" == *"password"* ]]
  [[ "$(result_field BKP-003 FIX)" == "" ]]
}

@test "tool installed but nothing readable as non-root: SKIP that needs root" {
  export NOSY_FX_BKP_TOOLS="restic"
  IS_ROOT=0
  nosy mod_backup
  assert_status BKP-002 SKIP
  [[ "$(result_field BKP-002 DETAIL)" == *"needs root"* ]]
  assert_status BKP-003 SKIP
  [[ "$(result_field BKP-003 DETAIL)" == *"needs root"* ]]
}

@test "tool installed, root, no schedule anywhere: BKP-002 WARN" {
  export NOSY_FX_BKP_TOOLS="restic"
  nosy mod_backup
  assert_status BKP-002 WARN
  [[ "$(result_field BKP-002 FIX)" == *"timer"* ]]
}

@test "the newest backup wins when several tools are present" {
  export NOSY_FX_BKP_TOOLS="restic borg"
  restic_cache /root 12
  local sec="$NOSY_FS/home/deploy/.config/borg/security/1a"
  mkdir -p "$sec"; printf '/mnt/backup/borg\n' >"$sec/location"; : >"$sec/manifest-timestamp"; age "$sec/manifest-timestamp" 2
  nosy mod_backup
  assert_status BKP-003 OK
  [[ "$(result_field BKP-003 TITLE)" == *"2 day(s) ago"* ]]
  [[ "$(result_field BKP-003 DETAIL)" == *"borg"* ]]
}

@test "CLI: --backup-max-age validates its value and --only backup runs the module" {
  run bash "$NOSY_SRC/nosycat.sh" --backup-max-age abc
  [ "$status" -eq 3 ]
  run bash "$NOSY_SRC/nosycat.sh" --backup-max-age 0
  [ "$status" -eq 3 ]
  run bash "$NOSY_SRC/nosycat.sh" --list
  [[ "$output" == *"backup"* ]]
  run bash "$NOSY_SRC/nosycat.sh" --only backup --backup-max-age 3 --format json
  [ "$status" -le 2 ]
  printf '%s' "$output" | jq -e '[.checks[].id] | index("BKP-001") != null'
}
