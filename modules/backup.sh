#!/usr/bin/env bash
# modules/backup.sh - is there a backup, does it run by itself, how old is the last one?
# shellcheck shell=bash
#
# Read-only and secret-free: nosycat never runs a backup tool, never asks for or
# reads a password, env file, keyring or repository key. The age of the last
# backup comes only from metadata that is readable without a password:
#   restic   cache files (~/.cache/restic/*/snapshots), or a local repo's snapshots/ dir
#   borg     ~/.config/borg/security/*/manifest-timestamp (written on every borg run)
#   rsnapshot  mtime of <snapshot_root>/<interval>.0 from rsnapshot.conf
#   timeshift  snapshot directory names (YYYY-MM-DD_HH-MM-SS)
#   duplicity  ~/.cache/duplicity/*/ manifest and signature files
# kopia and duplicati keep that state behind the repository password or in their
# own database, so their age is a SKIP. Provider snapshots are invisible from inside.

_BKP_TOOLS=(restic borg borgmatic rsnapshot timeshift duplicity duplicati kopia)
_BKP_RE='(^|[^[:alnum:]_.-])(restic|resticprofile|autorestic|borg|borgmatic|rsnapshot|timeshift|duplicity|duplicati|duplicati-cli|kopia)([^[:alnum:]_]|$)'

# _bkp_has TOOL -> installed? (NOSY_FX_BKP_TOOLS replaces the lookup in tests)
_bkp_has() {
  if [ -n "${NOSY_FX_BKP_TOOLS+x}" ]; then
    case " $NOSY_FX_BKP_TOOLS " in *" $1 "*) return 0 ;; esac
    return 1
  fi
  case "$1" in
    duplicati) have duplicati || have duplicati-cli || have duplicati-server || [ -d /opt/duplicati ] || [ -d /usr/lib/duplicati ] ;;
    *) have "$1" ;;
  esac
}

# _bkp_homes -> home dirs to look for per-user caches (root first).
_bkp_homes() {
  local R="${NOSY_FS:-}" h
  if [ -n "$R" ]; then
    printf '%s\n' "$R/root"
    for h in "$R"/home/*; do [ -d "$h" ] && printf '%s\n' "$h"; done
    return 0
  fi
  { echo /root; login_users | cut -d: -f3; } | awk '!seen[$0]++' | while IFS= read -r h; do [ -d "$h" ] && printf '%s\n' "$h"; done
}

# _bkp_show PATH -> PATH as it is on the real server (fixture prefixes removed).
_bkp_show() {
  local p="$1"
  [ "$ETC" != "/etc" ] && [[ "$p" == "$ETC"* ]] && p="/etc${p#"$ETC"}"
  [ -n "${NOSY_FS:-}" ] && [[ "$p" == "$NOSY_FS"* ]] && p="${p#"$NOSY_FS"}"
  printf '%s' "$p"
}

# _bkp_mtime_max PATH... -> newest mtime (epoch) of the existing PATHs, empty if none.
_bkp_mtime_max() {
  local -a ex=()
  local p
  for p in "$@"; do [ -e "$p" ] && ex+=("$p"); done
  [ "${#ex[@]}" -gt 0 ] || return 1
  stat -c %Y -- "${ex[@]}" 2>/dev/null | sort -n | tail -n 1
}

# _bkp_same_fs PATH -> 0 when PATH (symlinks followed) is on the same filesystem
# as / (or NOSY_FS in tests), 1 when it is on another one, 2 when stat cannot tell.
_bkp_same_fs() {
  local a b
  a="$(stat -L -c %d -- "$1" 2>/dev/null)" && [ -n "$a" ] || return 2
  b="$(stat -L -c %d -- "${NOSY_FS:-}/" 2>/dev/null)" && [ -n "$b" ] || return 2
  [ "$a" = "$b" ] && return 0
  return 1
}

# _bkp_local_offset -> seconds east of UTC for the local time zone (from date +%z).
_bkp_local_offset() {
  local z sign hh mm
  z="$(date +%z 2>/dev/null)"
  [[ "$z" =~ ^([+-])([0-9]{2})([0-9]{2})$ ]] || { echo 0; return 0; }
  sign="${BASH_REMATCH[1]}"; hh=$((10#${BASH_REMATCH[2]})); mm=$((10#${BASH_REMATCH[3]}))
  echo "${sign}$((hh * 3600 + mm * 60))"
}

# _bkp_age_text SECONDS -> "N day(s)" or "N hour(s)" for titles.
_bkp_age_text() {
  if [ "$1" -lt 86400 ]; then printf '%d hour(s)' $(($1 / 3600)); else printf '%d day(s)' $(($1 / 86400)); fi
}

# Result of the scan (module globals, reset by _bkp_scan).
_BKP_SCHED=()    # where a schedule was found (display strings)
_BKP_FILES=()    # files with a backup command line (cron, unit files), for repo paths
_BKP_AGE=()      # "epoch|label" candidates for the last backup
_BKP_LOCAL=()    # local backup targets (real paths under NOSY_FS)
_BKP_REMOTE=0    # a remote repository was seen

_bkp_scan_schedules() {
  local R="${NOSY_FS:-}" f d u name svc
  local -a cron=("$ETC/crontab" "$ETC/anacrontab" "$ETC"/cron.d/* "$ETC"/cron.hourly/* "$ETC"/cron.daily/* "$ETC"/cron.weekly/* "$ETC"/cron.monthly/* "$ETC"/crontabs/* "$R"/var/spool/cron/crontabs/* "$R"/var/spool/cron/*)
  local -a readable=()
  for f in "${cron[@]}"; do [ -f "$f" ] && [ -r "$f" ] && readable+=("$f"); done
  if [ "${#readable[@]}" -gt 0 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      _BKP_SCHED+=("cron $(_bkp_show "$f")"); _BKP_FILES+=("$f")
    done < <(awk -v re="$_BKP_RE" '{ l = $0; sub(/[[:space:]]#.*$/, "", l) } l !~ /^[[:space:]]*#/ && l ~ re { print FILENAME }' "${readable[@]}" 2>/dev/null | awk '!seen[$0]++')
  fi

  # enabled systemd timers (a *.wants/ link) whose name or service mentions a backup tool
  for u in "$ETC"/systemd/system/*.wants/*.timer; do
    [ -e "$u" ] || [ -L "$u" ] || continue
    name="${u##*/}"; svc="${name%.timer}.service"
    if printf '%s' "$name" | grep -qE "$_BKP_RE"; then
      _BKP_SCHED+=("systemd $name")
    fi
    for d in "$ETC/systemd/system" "$R/usr/lib/systemd/system" "$R/lib/systemd/system"; do
      f="$d/$svc"
      [ -f "$f" ] || continue; [ -r "$f" ] || continue
      if awk -v re="$_BKP_RE" '/^[[:space:]]*(ExecStart|ExecStartPre|Environment)=/ && $0 ~ re {found=1} END {exit !found}' "$f"; then
        case " ${_BKP_SCHED[*]} " in *" $name"*) ;; *) _BKP_SCHED+=("systemd $name") ;; esac
        _BKP_FILES+=("$f")
      fi
      break
    done
  done
  # services with their own scheduler
  for u in "$ETC"/systemd/system/*.wants/duplicati*.service "$ETC"/systemd/system/*.wants/kopia*.service; do
    [ -e "$u" ] || [ -L "$u" ] || continue
    _BKP_SCHED+=("systemd ${u##*/} (built-in scheduler)")
  done
  # timeshift's own schedule
  f="$ETC/timeshift/timeshift.json"
  if [ -r "$f" ] && grep -qE '"schedule_(monthly|weekly|daily|hourly|boot)"[[:space:]]*:[[:space:]]*"true"' "$f" 2>/dev/null; then
    _BKP_SCHED+=("timeshift $(_bkp_show "$f")")
  fi
  return 0
}

# _bkp_age_add EPOCH LABEL
_bkp_age_add() { [ -n "$1" ] && _BKP_AGE+=("$1|$2"); return 0; }

_bkp_scan_ages() {
  local R="${NOSY_FS:-}" h d f e repo loc conf root
  local -a homes=()
  mapfile -t homes < <(_bkp_homes)

  # restic: cache metadata per user, and local repos named on a scheduled command line
  if _bkp_has restic; then
    for h in "${homes[@]}"; do
      for d in "$h"/.cache/restic/*/snapshots; do
        [ -d "$d" ] || continue; [ -r "$d" ] || continue
        e="$(_bkp_mtime_max "$d"/*)" && _bkp_age_add "$e" "restic cache $(_bkp_show "${d%/snapshots}")"
      done
    done
    if [ "${#_BKP_FILES[@]}" -gt 0 ]; then
      # only the repository argument is extracted; the line itself is never kept or printed
      while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        case "$repo" in
          /*)
            if [ -f "$R$repo/config" ] && [ -d "$R$repo/snapshots" ]; then
              _BKP_LOCAL+=("$R$repo")
              e="$(_bkp_mtime_max "$R$repo"/snapshots/*)" && _bkp_age_add "$e" "restic repo $repo"
            fi ;;
          *:*) _BKP_REMOTE=1 ;;
        esac
      done < <(grep -hv '^[[:space:]]*#' "${_BKP_FILES[@]}" 2>/dev/null | sed 's/[[:space:]]#.*$//' \
        | grep -oE -- '(-r|--repo)[= ]+[^ "'"'"';]+|RESTIC_REPOSITORY=["'"'"']?[^ "'"'"';]+' \
        | sed -E 's/^(-r|--repo)[= ]+//; s/^RESTIC_REPOSITORY=["'"'"']?//' | awk '!seen[$0]++')
    fi
  fi

  # borg: the security dir records the repo location and touches manifest-timestamp on each run
  if _bkp_has borg || _bkp_has borgmatic; then
    for h in "${homes[@]}"; do
      for d in "$h"/.config/borg/security/*; do
        [ -f "$d/manifest-timestamp" ] || continue
        loc="$(head -c 512 "$d/location" 2>/dev/null | head -n 1)"
        case "$loc" in
          /*) [ -d "$R$loc" ] && _BKP_LOCAL+=("$R$loc"); _bkp_age_add "$(_bkp_mtime_max "$d/manifest-timestamp")" "borg repo $loc" ;;
          '') _bkp_age_add "$(_bkp_mtime_max "$d/manifest-timestamp")" "borg (repo location unknown)" ;;
          *) _BKP_REMOTE=1; _bkp_age_add "$(_bkp_mtime_max "$d/manifest-timestamp")" "borg remote repo" ;;
        esac
      done
    done
  fi

  # rsnapshot: newest <interval>.0 under snapshot_root
  conf="$ETC/rsnapshot.conf"
  if _bkp_has rsnapshot && [ -r "$conf" ]; then
    root="$(awk -F'\t' '$1 == "snapshot_root" {print $2; exit}' "$conf")"
    root="${root%/}"
    if [ -n "$root" ] && [ -d "$R$root" ]; then
      _BKP_LOCAL+=("$R$root")
      e="$(_bkp_mtime_max "$R$root"/*.0)" && _bkp_age_add "$e" "rsnapshot $root"
    fi
  fi

  # timeshift: snapshot dirs are named after their time
  if _bkp_has timeshift; then
    local best=0 n off
    off="$(_bkp_local_offset)"
    for d in "$R/timeshift/snapshots" "$R/timeshift-btrfs/snapshots" "$R"/run/timeshift/backup/timeshift*/snapshots "$R"/run/timeshift/*/backup/timeshift*/snapshots; do
      [ -d "$d" ] || continue
      _BKP_LOCAL+=("$d")
      for f in "$d"/*; do
        n="${f##*/}"
        [[ "$n" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]] || continue
        # the name is local time: convert it to UTC epoch seconds
        e=$(( $(ymd_epoch "${BASH_REMATCH[@]:1:6}") - off ))
        [ "$e" -gt "$best" ] && best="$e"
      done
    done
    [ "$best" -gt 0 ] && _bkp_age_add "$best" "timeshift snapshot"
  fi

  # duplicity: local cache of manifests and signatures
  if _bkp_has duplicity; then
    for h in "${homes[@]}"; do
      for d in "$h"/.cache/duplicity/*; do
        [ -d "$d" ] || continue
        e="$(_bkp_mtime_max "$d"/duplicity-*)" && _bkp_age_add "$e" "duplicity cache $(_bkp_show "$d")"
      done
    done
  fi
  return 0
}

mod_backup() {
  local t found=() n
  _BKP_SCHED=() _BKP_FILES=() _BKP_AGE=() _BKP_LOCAL=() _BKP_REMOTE=0
  local provider_note="provider snapshots (Hetzner, DigitalOcean, Contabo...) cannot be seen from inside the VM"

  for t in "${_BKP_TOOLS[@]}"; do _bkp_has "$t" && found+=("$t"); done
  if [ "${#found[@]}" -eq 0 ]; then
    warn BKP-001 "no backup tool found" "looked for $(join ", " "${_BKP_TOOLS[@]}"). $provider_note; if you rely on them, accept this in .nosycat.ignore with an until date" "sudo apt install restic   # then a systemd timer to a repository off this server"
    skip BKP-002 "backup schedule" "no backup tool found (BKP-001)"
    skip BKP-003 "age of the last backup" "no backup tool found (BKP-001)"
    skip BKP-004 "backups stored off the root disk" "no backup tool found (BKP-001)"
    return 0
  fi
  ok BKP-001 "backup tools: $(join ', ' "${found[@]}")" "$provider_note; only tools on this server are checked"

  _bkp_scan_schedules
  _bkp_scan_ages

  # BKP-002 schedule
  if [ "${#_BKP_SCHED[@]}" -gt 0 ]; then
    ok BKP-002 "backup job scheduled" "$(trunc_list 4 "${_BKP_SCHED[@]}")"
  elif [ "$IS_ROOT" -ne 1 ]; then
    skip BKP-002 "backup schedule" "no schedule visible; needs root to read the cron spool, root's crontab and unit files"
  else
    warn BKP-002 "backup tool installed but no schedule found" "looked in /etc/crontab, /etc/cron.*, the cron spool, enabled systemd timers and timeshift.json; a backup that runs by hand stops running" "write a systemd service + timer (systemctl enable --now NAME.timer) or a /etc/cron.d entry, then run it once"
  fi

  # BKP-003 age
  if [ "${#_BKP_AGE[@]}" -gt 0 ]; then
    local best=0 label="" c e now age when
    for c in "${_BKP_AGE[@]}"; do e="${c%%|*}"; [ "$e" -gt "$best" ] && { best="$e"; label="${c#*|}"; }; done
    # compare in seconds: 7 days and 5 hours is older than a 7-day limit
    now="$(nosy_now)"; age=$((now - best)); [ "$age" -lt 0 ] && age=0
    when="$(_bkp_age_text "$age")"
    if [ "$age" -gt $((BACKUP_MAX_AGE * 86400)) ]; then
      [ $((age / 86400)) -le "$BACKUP_MAX_AGE" ] && when="over $BACKUP_MAX_AGE day(s)"
      warn BKP-003 "last backup $when ago" "newest: $label; older than $BACKUP_MAX_AGE days (--backup-max-age). the job may be failing quietly" "check the job's log (journalctl -u NAME, cron mail) and run it once by hand"
    else
      ok BKP-003 "last backup $when ago" "newest: $label; limit $BACKUP_MAX_AGE days. an age is not a restore test, try one now and then"
    fi
  elif [ "$IS_ROOT" -ne 1 ]; then
    skip BKP-003 "age of the last backup" "needs root to read root's backup caches and repositories"
  else
    local why=()
    for t in "${found[@]}"; do
      case "$t" in
        kopia|duplicati) why+=("$t keeps it behind the repository password or in its database") ;;
        borgmatic) case " ${found[*]} " in *" borg "*) ;; *) why+=("borgmatic: no borg security dir (~/.config/borg/security) readable") ;; esac ;;
        *) why+=("$t: no readable cache or local repository") ;;
      esac
    done
    [ "${#why[@]}" -gt 0 ] || why=("no readable backup metadata")
    skip BKP-003 "age of the last backup" "cannot tell from metadata readable without a password: $(join '; ' "${why[@]}")"
  fi

  # BKP-004 where backups are stored
  if [ "${#_BKP_LOCAL[@]}" -gt 0 ] || [ "$_BKP_REMOTE" -eq 1 ]; then
    local p rc onroot=() elsewhere=() unknown=() unk_note=""
    for p in "${_BKP_LOCAL[@]}"; do
      _bkp_same_fs "$p"; rc=$?
      case "$rc" in
        0) onroot+=("$(_bkp_show "$p")") ;;
        1) elsewhere+=("$(_bkp_show "$p")") ;;
        *) unknown+=("$(_bkp_show "$p")") ;;
      esac
    done
    [ "${#unknown[@]}" -gt 0 ] && unk_note="; could not determine the filesystem of $(trunc_list 3 "${unknown[@]}")"
    if [ "$_BKP_REMOTE" -eq 1 ]; then
      ok BKP-004 "a remote repository is in use" "copies live off this server"
    elif [ "${#elsewhere[@]}" -gt 0 ]; then
      ok BKP-004 "backups on a separate filesystem" "$(trunc_list 3 "${elsewhere[@]}"); a second volume survives a broken root disk, not a deleted server${onroot[0]:+; also on the root filesystem: $(trunc_list 3 "${onroot[@]}")}$unk_note"
    elif [ "${#onroot[@]}" -gt 0 ]; then
      warn BKP-004 "backups stored on the root filesystem" "$(trunc_list 3 "${onroot[@]}"): lost together with the disk or the server$unk_note" "send a copy off the server (restic/borg to a storage box or S3, rsync to another host)"
    else
      skip BKP-004 "backups stored off the root disk" "could not determine the filesystem of $(trunc_list 3 "${unknown[@]}") (stat failed)"
    fi
  else
    skip BKP-004 "backups stored off the root disk" "backup destination not visible (remote, or set in a config nosycat does not read)"
  fi
}
