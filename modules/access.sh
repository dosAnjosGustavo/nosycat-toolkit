#!/usr/bin/env bash
# modules/access.sh - SSH daemon settings and user accounts.
# shellcheck shell=bash

SSHD_CFG_SRC=""
declare -A SSHD_CFG=()

# Parse sshd_config + Include files (first value wins, stop at Match), as a
# fallback when `sshd -T` is not available (non-root).
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
      for inc in $v; do
        case "$inc" in /*) ;; *) inc="/etc/ssh/$inc" ;; esac
        local g
        for g in $inc; do _sshd_parse_file "$g" || return 1; done
      done
      continue
    fi
    if [ -z "${SSHD_CFG[$k]+x}" ]; then SSHD_CFG[$k]="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"; fi
  done <"$file"
  return 0
}

_sshd_load() {
  local sshd k v
  sshd="$(command -v sshd 2>/dev/null || { [ -x /usr/sbin/sshd ] && echo /usr/sbin/sshd; })"
  if [ -n "$sshd" ] && [ "$IS_ROOT" -eq 1 ]; then
    while read -r k v; do
      [ -n "$k" ] && [ -z "${SSHD_CFG[$k]+x}" ] && SSHD_CFG[$k]="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    done < <(q "$sshd" -T)
    if [ "${#SSHD_CFG[@]}" -gt 0 ]; then SSHD_CFG_SRC="sshd -T"; return 0; fi
  fi
  _sshd_parse_file /etc/ssh/sshd_config
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

ssh_ports() {
  if [ "${#SSHD_CFG[@]}" -eq 0 ]; then _sshd_load; fi
  printf '%s\n' "${SSHD_CFG[port]:-22}"
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
  if [ ! -e /etc/ssh/sshd_config ] && ! have sshd && [ ! -x /usr/sbin/sshd ]; then
    skip SSH-001 "ssh daemon" "OpenSSH server not installed"
  else
    _sshd_load
    local src="(from $SSHD_CFG_SRC)" pa kbd prl port
    [ "$SSHD_CFG_SRC" = "parsed sshd_config" ] && src="(parsed config, run as root for 'sshd -T')"
    ok SSH-001 "ssh daemon config read" "$src"

    pa="${SSHD_CFG[passwordauthentication]}"
    kbd="${SSHD_CFG[kbdinteractiveauthentication]:-no}"
    if [ "$pa" = "yes" ]; then
      fail SSH-002 "SSH password authentication is enabled" "internet-facing SSH with passwords is brute-forced within minutes of deploy" "set 'PasswordAuthentication no' (check /etc/ssh/sshd_config.d/ too), confirm key login in a 2nd session, then: sudo systemctl reload ssh"
    elif [ "$kbd" = "yes" ] && [ "${SSHD_CFG[usepam]}" = "yes" ]; then
      warn SSH-002 "keyboard-interactive auth enabled with PAM" "PAM can still prompt for a password even with PasswordAuthentication no" "set 'KbdInteractiveAuthentication no' and reload sshd"
    else
      ok SSH-002 "SSH password authentication disabled" "$src"
    fi

    prl="${SSHD_CFG[permitrootlogin]}"
    case "$prl" in
      yes) fail SSH-003 "PermitRootLogin yes" "root can log in with a password; one guessed password = full compromise" "set 'PermitRootLogin no' (after creating a sudo user) and reload sshd" ;;
      prohibit-password|without-password) warn SSH-003 "PermitRootLogin $prl" "root can log in with a key; a personal sudo user gives an audit trail and one more barrier" "set 'PermitRootLogin no' once your sudo user works" ;;
      *) ok SSH-003 "PermitRootLogin $prl" "" ;;
    esac

    if [ "${SSHD_CFG[permitemptypasswords]}" = "yes" ]; then
      fail SSH-004 "PermitEmptyPasswords yes" "accounts without a password can log in" "set 'PermitEmptyPasswords no' and reload sshd"
    else
      ok SSH-004 "empty passwords not permitted" ""
    fi

    port="${SSHD_CFG[port]}"
    if [ "$port" = "22" ]; then
      ok SSH-005 "SSH port 22" "default port is fine with key-only auth; moving it only reduces log noise"
    else
      ok SSH-005 "SSH port $port" "remember to allow it in the provider firewall and to pass -p $port"
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
