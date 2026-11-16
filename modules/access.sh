#!/usr/bin/env bash
# modules/access.sh - SSH daemon settings and user accounts.
# shellcheck shell=bash

SSHD_CFG_SRC=""
declare -gA SSHD_CFG=()
SSHD_PORTS=()

# _sshd_port_of VALUE -> port of a ListenAddress value ("[::]:22", "0.0.0.0:22"), if any.
_sshd_port_of() {
  case "$1" in
    \[*\]:*) printf '%s\n' "${1##*]:}" ;;
    *:*:*) ;;                      # bare IPv6 address, no port
    *:*) printf '%s\n' "${1##*:}" ;;
  esac
}

# Parse sshd_config + Include files (first value wins, stop at Match), as a
# fallback when `sshd -T` is not available (non-root). Port and ListenAddress
# are cumulative in sshd, so every one of them is kept in SSHD_PORTS.
_sshd_parse_file() {
  local file="$1" k v inc line
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    read -r k v <<<"$line"
    [ -z "$k" ] && continue
    k="$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')"
    if [ "$k" = "match" ]; then return 1; fi
    if [ "$k" = "include" ]; then
      # split without globbing first, so the pattern is expanded under $ETC
      local -a incs; local g
      read -r -a incs <<<"$v"
      for inc in "${incs[@]}"; do
        case "$inc" in /etc/*) inc="$ETC/${inc#/etc/}" ;; /*) ;; *) inc="$ETC/ssh/$inc" ;; esac
        for g in $inc; do _sshd_parse_file "$g" || return 1; done
      done
      continue
    fi
    case "$k" in
      port) SSHD_PORTS+=("$v") ;;
      listenaddress) mapfile -t -O "${#SSHD_PORTS[@]}" SSHD_PORTS < <(_sshd_port_of "$v") ;;
    esac
    if [ -z "${SSHD_CFG[$k]+x}" ]; then SSHD_CFG[$k]="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"; fi
  done <"$file"
  return 0
}

# _sshd_load -> fills SSHD_CFG (effective values) and SSHD_PORTS once per run.
# Prefers `sshd -T` (root), falls back to parsing the config files.
_sshd_load() {
  [ -n "$SSHD_CFG_SRC" ] && return 0
  local sshd="" k v
  if have sshd; then sshd="$(command -v sshd)"; elif [ -x /usr/sbin/sshd ]; then sshd=/usr/sbin/sshd; fi
  if fx_set SSHD_T || { [ -n "$sshd" ] && [ "$IS_ROOT" -eq 1 ]; }; then
    while read -r k v; do
      [ -n "$k" ] || continue
      case "$k" in
        port) SSHD_PORTS+=("$v") ;;
        listenaddress) mapfile -t -O "${#SSHD_PORTS[@]}" SSHD_PORTS < <(_sshd_port_of "$v") ;;
      esac
      [ -z "${SSHD_CFG[$k]+x}" ] && SSHD_CFG[$k]="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    done < <(fx SSHD_T "$sshd" -T)
    if [ "${#SSHD_CFG[@]}" -gt 0 ]; then SSHD_CFG_SRC="sshd -T"; return 0; fi
    SSHD_PORTS=()
  fi
  _sshd_parse_file "$ETC/ssh/sshd_config"
  SSHD_CFG_SRC="parsed sshd_config"
  # OpenSSH compiled-in defaults for anything not set.
  : "${SSHD_CFG[passwordauthentication]:=yes}"
  : "${SSHD_CFG[permitrootlogin]:=prohibit-password}"
  : "${SSHD_CFG[port]:=22}"
  : "${SSHD_CFG[kbdinteractiveauthentication]:=${SSHD_CFG[challengeresponseauthentication]:-yes}}"
  : "${SSHD_CFG[usepam]:=no}"
  : "${SSHD_CFG[permitemptypasswords]:=no}"
  return 0
}

# ssh_ports -> every port sshd listens on (Port + ListenAddress), one per line, sorted.
ssh_ports() {
  _sshd_load
  if [ "${#SSHD_PORTS[@]}" -eq 0 ]; then echo 22; return; fi
  printf '%s\n' "${SSHD_PORTS[@]}" | grep -E '^[0-9]+$' | sort -nu
}

# ssh_reload_cmd -> the command that reloads sshd on this system
# (ssh.service on Debian/Ubuntu, sshd.service elsewhere, rc-service on OpenRC).
ssh_reload_cmd() {
  local units=""
  if fx_set SSH_UNITS || systemd_up; then
    units="$(fx SSH_UNITS systemctl list-unit-files --no-legend ssh.service sshd.service | awk '{print $1" "$2}')"
  fi
  case "$units" in
    *"ssh.service "*) echo "sudo systemctl reload ssh"; return ;;
    *"sshd.service "*) echo "sudo systemctl reload sshd"; return ;;
  esac
  if [ "$INIT_SYS" = "openrc" ]; then echo "sudo rc-service sshd reload"; return; fi
  case "$OS_FAMILY" in
    debian) echo "sudo systemctl reload ssh" ;;
    *) echo "sudo systemctl reload sshd" ;;
  esac
}

_perm_bad() {
  # _perm_bad PATH -> true if group- or world-writable
  local m
  m="$(stat -c '%a' "$1" 2>/dev/null)" || return 1
  [ "${#m}" -gt 3 ] && m="${m: -3}"
  case "${m:1:1}${m:2:1}" in *[2367]*) return 0 ;; esac
  return 1
}

mod_access() {
  if [ ! -e "$ETC/ssh/sshd_config" ] && ! fx_set SSHD_T && ! have sshd && [ ! -x /usr/sbin/sshd ]; then
    skip SSH-001 "ssh daemon" "OpenSSH server not installed"
  else
    _sshd_load
    local src="(from $SSHD_CFG_SRC)" pa kbd prl ports reload
    reload="$(ssh_reload_cmd)"
    [ "$SSHD_CFG_SRC" = "parsed sshd_config" ] && src="(parsed config, run as root for 'sshd -T')"
    ok SSH-001 "ssh daemon config read" "$src"

    pa="${SSHD_CFG[passwordauthentication]}"
    kbd="${SSHD_CFG[kbdinteractiveauthentication]:-no}"
    if [ "$pa" = "yes" ]; then
      fail SSH-002 "SSH password authentication is enabled" "internet-facing SSH with passwords is brute-forced within minutes of deploy" "set 'PasswordAuthentication no' (check /etc/ssh/sshd_config.d/ too), confirm key login in a 2nd session, then: $reload"
    elif [ "$kbd" = "yes" ] && [ "${SSHD_CFG[usepam]}" = "yes" ]; then
      warn SSH-002 "keyboard-interactive auth enabled with PAM" "PAM can still prompt for a password even with PasswordAuthentication no" "set 'KbdInteractiveAuthentication no', then: $reload"
    else
      ok SSH-002 "SSH password authentication disabled" "$src"
    fi

    prl="${SSHD_CFG[permitrootlogin]}"
    case "$prl" in
      yes) fail SSH-003 "PermitRootLogin yes" "root can log in with a password; one guessed password = full compromise" "set 'PermitRootLogin no' (after creating a sudo user), then: $reload" ;;
      prohibit-password|without-password) warn SSH-003 "PermitRootLogin $prl" "root can log in with a key; a personal sudo user gives an audit trail and one more barrier" "set 'PermitRootLogin no' once your sudo user works" ;;
      *) ok SSH-003 "PermitRootLogin $prl" "" ;;
    esac

    if [ "${SSHD_CFG[permitemptypasswords]}" = "yes" ]; then
      fail SSH-004 "PermitEmptyPasswords yes" "accounts without a password can log in" "set 'PermitEmptyPasswords no', then: $reload"
    else
      ok SSH-004 "empty passwords not permitted" ""
    fi

    ports="$(ssh_ports | paste -sd, -)"
    if [ "$ports" = "22" ]; then
      ok SSH-005 "SSH port 22" "default port is fine with key-only auth; moving it only reduces log noise"
    else
      ok SSH-005 "SSH port(s) ${ports//,/, }" "remember to allow them in the provider firewall and to pass -p PORT"
    fi
  fi

  # SSH-006 a non-root sudo/wheel user exists
  local g members admins=()
  for g in sudo wheel admin; do
    members="$(getent group "$g" 2>/dev/null | cut -d: -f4)"
    [ -n "$members" ] && admins+=("${members//,/ }")
  done
  if [ "$IS_ROOT" -eq 1 ] && [ -d /etc/sudoers.d ]; then
    members="$(grep -hE '^[a-z_][a-z0-9_-]*[[:space:]]+ALL' /etc/sudoers /etc/sudoers.d/* 2>/dev/null | awk '$1!="root"{print $1}' | sort -u | tr '\n' ' ')"
    [ -n "$members" ] && admins+=("$members")
  fi
  # shellcheck disable=SC2206
  local list=(${admins[*]})
  if [ "${#list[@]}" -gt 0 ]; then
    ok SSH-006 "non-root admin user(s): $(printf '%s\n' "${list[@]}" | sort -u | paste -sd' ')" ""
  else
    local nr=""; [ "$IS_ROOT" -eq 1 ] || nr=" (sudoers files not readable without root, so this may be incomplete)"
    warn SSH-006 "no non-root sudo/wheel user" "working as root means no audit trail and no safety net; you also cannot disable root login$nr" "sudo adduser deploy && sudo usermod -aG sudo deploy   # wheel on RHEL/Arch/Alpine"
  fi

  # SSH-007 authorized_keys permissions (StrictModes silently rejects keys)
  local entry name uid home bad=() checked=0
  while IFS=: read -r name uid home _; do
    [ -d "$home/.ssh" ] || continue
    checked=$((checked + 1))
    for entry in "$home" "$home/.ssh" "$home/.ssh/authorized_keys"; do
      [ -e "$entry" ] || continue
      if _perm_bad "$entry"; then bad+=("$entry ($(stat -c '%a' "$entry"))"); fi
      local own
      own="$(stat -c '%u' "$entry" 2>/dev/null)"
      if [ -n "$own" ] && [ "$own" != "$uid" ] && [ "$own" != "0" ]; then bad+=("$entry (owner uid $own)"); fi
    done
  done < <(login_users)
  if [ "${#bad[@]}" -gt 0 ]; then
    fail SSH-007 "unsafe \$HOME/.ssh permissions: $(trunc_list 4 "${bad[@]}")" "with StrictModes (default) sshd ignores the keys and you get locked out; otherwise others can add keys" "chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && chmod go-w ~"
  elif [ "$checked" -eq 0 ]; then
    skip SSH-007 "authorized_keys permissions" "no readable ~/.ssh directories"
  else
    ok SSH-007 "\$HOME/.ssh permissions safe ($checked account(s))" ""
  fi

  # SSH-008 accounts that never logged in / SSH-009 empty passwords
  local never=() ll=""
  if have lastlog2; then ll="lastlog2"; elif have lastlog; then ll="lastlog"; fi
  if [ -n "$ll" ]; then
    while IFS=: read -r name uid _ _; do
      [ "$uid" -eq 0 ] && continue
      if q "$ll" -u "$name" | tail -n +2 | grep -q 'Never logged in'; then never+=("$name"); fi
    done < <(login_users)
    if [ "${#never[@]}" -gt 0 ]; then
      warn SSH-008 "login accounts never used: $(trunc_list 5 "${never[@]}")" "unused accounts with a shell are forgotten attack surface" "sudo usermod -L -s /usr/sbin/nologin USER   # or userdel -r USER"
    else
      ok SSH-008 "all login accounts have been used" ""
    fi
  else
    skip SSH-008 "unused accounts" "lastlog/lastlog2 not available"
  fi

  if [ "$IS_ROOT" -eq 1 ] && [ -r /etc/shadow ]; then
    local empty
    empty="$(awk -F: '$2==""{print $1}' /etc/shadow | tr '\n' ' ')"
    if [ -n "$empty" ]; then
      fail SSH-009 "accounts with an empty password: $empty" "anyone can log in on the console or su to them" "sudo passwd -l USER"
    else
      ok SSH-009 "no accounts with an empty password" ""
    fi
  else
    skip SSH-009 "empty passwords" "needs root to read /etc/shadow"
  fi
}
