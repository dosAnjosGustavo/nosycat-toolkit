#!/usr/bin/env bash
# modules/cloud_init.sh - leftovers from the provider image and first boot.
# shellcheck shell=bash

_default_hostname_re='^(localhost|localhost\.localdomain|ubuntu|debian|centos|rocky|almalinux|alma|fedora|alpine|archlinux|arch|vps|server|srv|host|instance|default|vmi[0-9]+|ip-[0-9-]+|ubuntu-[a-z0-9-]+|debian-[a-z0-9-]+|droplet[a-z0-9-]*|instance-[0-9a-z-]+|static\.[0-9.]+.*|[0-9a-f]{8,}|li[0-9]+-[0-9]+|vultr(\..*)?|[0-9]+-[0-9]+-[0-9]+-[0-9]+)$'

mod_cloud_init() {
  local h short st rc
  short="${HOST_NAME%%.*}"
  if printf '%s\n' "$HOST_NAME" | grep -qiE "$_default_hostname_re" || printf '%s\n' "$short" | grep -qiE "$_default_hostname_re"; then
    warn CLD-001 "hostname looks like a provider default: $HOST_NAME" "generic hostnames make logs, alerts and monitoring ambiguous across servers" "sudo hostnamectl set-hostname web-01.example.com"
  else
    ok CLD-001 "hostname is custom: $HOST_NAME" ""
  fi

  if ! have cloud-init; then
    skip CLD-002 "cloud-init status" "cloud-init not installed"
  else
    st="$(q cloud-init status 2>&1)"; rc=$?
    st="$(printf '%s' "$st" | awk -F': *' '/^status/{print $2; exit}')"
    case "$st" in
      done) ok CLD-002 "cloud-init finished: done" "" ;;
      running) warn CLD-002 "cloud-init still running" "first-boot configuration is not finished; users, keys or packages may still change" "cloud-init status --wait" ;;
      error) fail CLD-002 "cloud-init finished with errors" "some first-boot steps (users, keys, packages) may not have been applied" "sudo cloud-init status --long; sudo less /var/log/cloud-init.log" ;;
      degraded*) warn CLD-002 "cloud-init finished degraded" "recoverable errors during first boot" "sudo cloud-init status --long" ;;
      disabled) ok CLD-002 "cloud-init disabled" "" ;;
      *) if [ "$rc" -eq 124 ]; then warn CLD-002 "cloud-init status timed out" "" "cloud-init status --long"; else skip CLD-002 "cloud-init status" "status not reported (${st:-empty})"; fi ;;
    esac
  fi

  # Default image users still able to log in.
  local u found=()
  for u in ubuntu debian ec2-user centos rocky almalinux cloud-user fedora alpine arch opc admin linuxuser; do
    h="$(getent passwd "$u" 2>/dev/null)" || continue
    case "${h##*:}" in *nologin|*false) continue ;; esac
    found+=("$u")
  done
  if [ "${#found[@]}" -gt 0 ]; then
    warn CLD-003 "default image user(s) with a login shell: $(join ', ' "${found[@]}")" "well-known usernames are the first target of SSH brute force; keep only if you actually use them" "sudo usermod -L -s /usr/sbin/nologin ${found[0]}   # after creating your own sudo user"
  else
    ok CLD-003 "no default image users with a login shell" ""
  fi

  # cloud-init drop-ins that set password login. sshd keeps the first value it
  # reads, so a drop-in "yes" only matters when it is also the effective value.
  local f bad=()
  for f in "$ETC"/ssh/sshd_config.d/*.conf; do
    [ -r "$f" ] || continue
    if grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$f"; then bad+=("$f"); fi
  done
  if [ "${#bad[@]}" -gt 0 ]; then
    _sshd_load
    local eff="${SSHD_CFG[passwordauthentication]:-yes}"
    if [ "$eff" = "no" ]; then
      ok CLD-004 "sshd drop-in password auth is overridden" "$(join ', ' "${bad[@]}") says yes, but the effective value is no (from $SSHD_CFG_SRC)"
    else
      warn CLD-004 "sshd drop-in enables password auth: $(join ', ' "${bad[@]}")" "provider/cloud-init drop-ins (e.g. 50-cloud-init.conf) are read before sshd_config and override it, so editing sshd_config alone does nothing" "sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' ${bad[0]} && $(ssh_reload_cmd)"
    fi
  else
    ok CLD-004 "no sshd drop-in forcing password auth" ""
  fi

  # Root keys injected by the provider.
  if [ "$IS_ROOT" -eq 1 ]; then
    if [ -s /root/.ssh/authorized_keys ]; then
      local n
      n="$(grep -cvE '^[[:space:]]*(#|$)' /root/.ssh/authorized_keys)"
      if grep -q 'Please login as the user' /root/.ssh/authorized_keys; then
        ok CLD-005 "root keys are provider login blockers" "cloud image redirects root logins to the default user"
      else
        warn CLD-005 "root has $n authorized key(s)" "keys injected at deploy time often stay forever; make sure each one is yours and still needed" "sudo ssh-keygen -lf /root/.ssh/authorized_keys"
      fi
    else
      ok CLD-005 "root has no authorized_keys" ""
    fi
  else
    skip CLD-005 "root authorized_keys" "needs root; re-run with sudo"
  fi
}
