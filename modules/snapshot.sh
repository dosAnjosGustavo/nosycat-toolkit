#!/usr/bin/env bash
# modules/snapshot.sh - save a baseline right after deploy and diff against it later.
# shellcheck shell=bash

# snapshot_collect DIR -> writes one sorted text file per category into DIR.
snapshot_collect() {
  local dir="$1" l proto host port proc f
  mkdir -p "$dir" || return 1

  collect_listeners >/dev/null 2>&1
  for l in "${LISTENERS[@]}"; do
    read -r proto host port proc <<<"$l"
    printf '%s %s:%s %s\n' "$proto" "$host" "$port" "$proc"
  done | sort -u >"$dir/listeners"

  if systemd_up; then
    q systemctl list-unit-files --type=service,timer,socket --state=enabled --no-legend | awk '{print $1}' | sort -u >"$dir/services"
  elif have rc-update; then
    q rc-update show | awk '{print $1" "$3}' | sort -u >"$dir/services"
  else
    : >"$dir/services"
  fi

  getent passwd | awk -F: '{print $1":"$3":"$7}' | sort >"$dir/users"
  getent group | awk -F: '$1 ~ /^(sudo|wheel|admin|docker|root)$/ {print $1":"$4}' | sort >"$dir/admin_groups"

  {
    for f in /etc/crontab /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/* \
             /var/spool/cron/* /var/spool/cron/crontabs/* /etc/periodic/*/*; do
      [ -f "$f" ] && [ -r "$f" ] && printf '%s %s\n' "$(sha256sum "$f" | cut -c1-16)" "$f"
    done
    if systemd_up; then q systemctl list-timers --all --no-legend | awk '{for(i=1;i<=NF;i++) if($i ~ /\.timer$/) print "timer "$i}'; fi
  } | sort -u >"$dir/cron"

  {
    local name home k
    while IFS=: read -r name _ home _; do
      for k in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
        [ -r "$k" ] || continue
        while IFS= read -r l; do
          case "$l" in ''|\#*) continue ;; esac
          printf '%s %s %s\n' "$name" "$(printf '%s' "$l" | sha256sum | cut -c1-16)" "${l##* }"
        done <"$k"
      done
    done < <(login_users)
  } | sort -u >"$dir/authorized_keys"

  local pc=""
  case "$PKG_MGR" in
    apt-get) pc="$(dpkg-query -W -f='.\n' 2>/dev/null | wc -l)" ;;
    dnf|yum|zypper) pc="$(q rpm -qa | wc -l)" ;;
    apk) pc="$(q apk info | wc -l)" ;;
    pacman) pc="$(q pacman -Q | wc -l)" ;;
  esac
  printf 'packages %s\n' "${pc:-unknown}" >"$dir/packages"

  if have docker && q docker info >/dev/null; then
    q docker ps -a --format '{{.Names}} {{.Image}}' | sort >"$dir/containers"
  else
    : >"$dir/containers"
  fi

  {
    printf 'tool=%s\nversion=%s\nhost=%s\ncreated=%s\nuser=%s\n' "$NOSY_NAME" "$NOSY_VERSION" "$HOST_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(id -un)"
  } >"$dir/meta"
}

snapshot_save() {
  local base="$STATE_DIR/baseline" tmp
  tmp="$STATE_DIR/.baseline.tmp.$$"
  umask 077
  if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    echo "nosycat: cannot create state dir $STATE_DIR (use --state-dir)" >&2; return 3
  fi
  snapshot_collect "$tmp" || { echo "nosycat: snapshot failed" >&2; rm -rf "$tmp"; return 3; }
  rm -rf "$base" && mv "$tmp" "$base"
  echo "nosycat: baseline saved to $base ($(wc -l <"$base/listeners") listeners, $(wc -l <"$base/services") units, $(wc -l <"$base/users") users)"
  [ "$IS_ROOT" -eq 1 ] || echo "nosycat: note: not root, so other users' keys, crontabs and process names were not captured" >&2
  return 0
}

# _snap_cmp CATEGORY ID TITLE
_snap_cmp() {
  local cat="$1" id="$2" title="$3" old="$STATE_DIR/baseline/$1" new="$SNAP_NOW/$1" add rem a r
  if [ ! -f "$old" ]; then skip "$id" "$title" "not in baseline"; return; fi
  add="$(comm -13 "$old" "$new")"; rem="$(comm -23 "$old" "$new")"
  if [ -z "$add" ] && [ -z "$rem" ]; then ok "$id" "$title: unchanged" ""; return; fi
  a="$(printf '%s' "$add" | grep -c .)"; r="$(printf '%s' "$rem" | grep -c .)"
  local det=""
  [ -n "$add" ] && det="added: $(printf '%s\n' "$add" | head -n 5 | tr '\n' ';' | sed 's/;$//')"
  [ -n "$rem" ] && det="${det:+$det | }removed: $(printf '%s\n' "$rem" | head -n 5 | tr '\n' ';' | sed 's/;$//')"
  warn "$id" "$title: +$a / -$r since baseline" "$det" "review the change; if expected, refresh the baseline: sudo ./nosycat.sh --snapshot"
  : "$cat"
}

mod_snapshot() {
  local base="$STATE_DIR/baseline"
  SNAP_NOW="$(mktemp -d 2>/dev/null || echo "/tmp/nosycat.$$")"
  snapshot_collect "$SNAP_NOW"
  local created
  created="$(awk -F= '$1=="created"{print $2}' "$base/meta" 2>/dev/null)"
  ok SNP-000 "baseline from ${created:-unknown}" "$base"
  _snap_cmp listeners SNP-001 "listening sockets"
  _snap_cmp services SNP-002 "enabled services/timers"
  _snap_cmp users SNP-003 "user accounts"
  _snap_cmp admin_groups SNP-004 "admin/docker group members"
  _snap_cmp cron SNP-005 "cron jobs and timers"
  _snap_cmp authorized_keys SNP-006 "SSH authorized keys"
  _snap_cmp packages SNP-007 "installed package count"
  _snap_cmp containers SNP-008 "containers"
  rm -rf "$SNAP_NOW"
}
