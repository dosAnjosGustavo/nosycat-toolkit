#!/usr/bin/env bash
# modules/network.sh - what is reachable, is a firewall in front of it, DNS, sysctl.
# shellcheck shell=bash

_sysctl() { local f="/proc/sys/${1//.//}"; [ -r "$f" ] && cat "$f"; }

mod_network() {
  local l proto host port proc scope exposed=() sshp
  sshp=" $(ssh_ports 2>/dev/null | tr '\n' ' ') "

  # NET-001 listeners on all interfaces / public addresses
  if ! collect_listeners; then
    skip NET-001 "listening sockets" "neither ss nor netstat available"
  else
    for l in "${LISTENERS[@]}"; do
      read -r proto host port proc <<<"$l"
      scope="$(addr_scope "$host")"
      [ "$scope" = "any" ] || [ "$scope" = "public" ] || continue
      case "$sshp" in *" $port "*) [ "$proto" = "tcp" ] && continue ;; esac
      # DHCP clients legitimately listen on 0.0.0.0:68 / [::]:546
      if [ "$proto" = "udp" ] && { [ "$port" = "68" ] || [ "$port" = "546" ]; }; then continue; fi
      exposed+=("$port/$proto($proc)")
    done
    # de-duplicate (v4 + v6 sockets)
    if [ "${#exposed[@]}" -gt 0 ]; then
      mapfile -t exposed < <(printf '%s\n' "${exposed[@]}" | sort -u | sort -t/ -k1,1n)
    fi
    local pn=""; [ "$IS_ROOT" -eq 1 ] || pn=" (process names need root)"
    if [ "${#exposed[@]}" -gt 0 ]; then
      warn NET-001 "${#exposed[@]} service(s) listening on all interfaces: $(trunc_list 8 "${exposed[@]}")" "anything bound to 0.0.0.0/:: is reachable from the internet unless a firewall blocks it$pn" "bind internal services to 127.0.0.1, or restrict them in the firewall; inspect with: sudo ss -tulnp"
    else
      ok NET-001 "only SSH (or nothing) listens on public interfaces" ""
    fi
  fi

  # NET-002 host firewall
  case "$FW_ACTIVE" in
    ufw|firewalld|nftables|iptables) ok NET-002 "host firewall active: $FW_ACTIVE" "" ;;
    unknown) skip NET-002 "host firewall" "needs root to read firewall rules" ;;
    *)
      if [ "$VIRT_KIND" = "container" ]; then
        skip NET-002 "host firewall" "inside a container; the host controls filtering"
      elif [ "${#exposed[@]}" -gt 0 ]; then
        fail NET-002 "no active host firewall" "${#exposed[@]} service(s) are exposed with no host filtering; provider firewalls are not visible from here" "sudo ufw allow OpenSSH && sudo ufw enable   # or firewalld / nftables"
      else
        warn NET-002 "no active host firewall" "nothing extra is exposed today, but the next service you install will be" "sudo ufw allow OpenSSH && sudo ufw enable   # or firewalld / nftables"
      fi ;;
  esac

  # NET-003 IPv6 reachable without IPv6 rules
  local v6=0
  if [ -r /proc/net/if_inet6 ] && awk '$4=="00" && $6!="lo"' /proc/net/if_inet6 | grep -q .; then v6=1; fi
  if [ "$v6" -eq 0 ]; then
    ok NET-003 "no global IPv6 address" ""
  elif [ "$IS_ROOT" -ne 1 ]; then
    skip NET-003 "IPv6 filtering" "global IPv6 present; needs root to inspect rules"
  else
    case "$FW_ACTIVE" in
      ufw)
        if grep -qE '^IPV6=yes' /etc/default/ufw 2>/dev/null; then ok NET-003 "IPv6 filtered by ufw" ""
        else fail NET-003 "ufw has IPV6=no but the server has a global IPv6" "every service is reachable over IPv6 bypassing your ufw rules" "sudo sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw && sudo ufw reload"; fi ;;
      firewalld) ok NET-003 "IPv6 filtered by firewalld" "" ;;
      nftables)
        if q nft list ruleset | grep -qE '^table (inet|ip6) '; then ok NET-003 "IPv6 covered by nftables (inet/ip6 table)" ""
        else warn NET-003 "nftables has no inet/ip6 table" "IPv6 traffic may be unfiltered" "use 'table inet filter' instead of 'table ip filter'"; fi ;;
      *)
        if have ip6tables && q ip6tables -S INPUT | grep -qE '^-P INPUT (DROP|REJECT)|-j (DROP|REJECT)'; then ok NET-003 "IPv6 filtered by ip6tables" ""
        else warn NET-003 "global IPv6 address without IPv6 firewall rules" "services listening on :: are reachable over IPv6" "enable a firewall that covers IPv6 (ufw IPV6=yes, firewalld, nft inet table)"; fi ;;
    esac
  fi

  # NET-004 DNS resolution
  if ! grep -qE '^[[:space:]]*nameserver' /etc/resolv.conf 2>/dev/null && ! unit_active systemd-resolved; then
    fail NET-004 "no nameserver configured" "package updates, ACME renewals and outbound APIs will fail" "check /etc/resolv.conf or systemd-resolved / netplan DNS settings"
  elif t 6 getent ahosts example.com >/dev/null 2>&1 || t 6 getent hosts example.com >/dev/null 2>&1; then
    ok NET-004 "DNS resolution works" ""
  else
    fail NET-004 "DNS resolution failed (example.com)" "package updates, ACME renewals and outbound APIs will fail" "resolvectl status   # or cat /etc/resolv.conf"
  fi

  # NET-005..007 kernel network parameters
  local fwd sc ra rd
  fwd="$(_sysctl net.ipv4.ip_forward)"
  if [ "$fwd" = "1" ]; then
    if have docker || have podman || have kubelet || have k3s || [ -d /etc/wireguard ] || have tailscaled; then
      ok NET-005 "net.ipv4.ip_forward=1" "expected with containers/VPN on this host"
    else
      warn NET-005 "net.ipv4.ip_forward=1" "the server routes packets between interfaces; unneeded on a plain VPS" "echo 'net.ipv4.ip_forward=0' | sudo tee /etc/sysctl.d/99-forward.conf && sudo sysctl --system"
    fi
  elif [ -n "$fwd" ]; then ok NET-005 "net.ipv4.ip_forward=0" ""
  else skip NET-005 "ip_forward" "not readable"; fi

  sc="$(_sysctl net.ipv4.tcp_syncookies)"
  if [ -z "$sc" ]; then skip NET-006 "tcp_syncookies" "not readable"
  elif [ "$sc" = "0" ]; then warn NET-006 "net.ipv4.tcp_syncookies=0" "SYN floods can exhaust the connection backlog" "echo 'net.ipv4.tcp_syncookies=1' | sudo tee /etc/sysctl.d/99-syncookies.conf && sudo sysctl --system"
  else ok NET-006 "net.ipv4.tcp_syncookies=$sc" ""; fi

  ra="$(_sysctl net.ipv4.conf.all.accept_redirects)"; rd="$(_sysctl net.ipv4.conf.default.accept_redirects)"
  if [ -z "$ra" ]; then skip NET-007 "accept_redirects" "not readable"
  elif [ "$ra" = "1" ] || [ "$rd" = "1" ]; then warn NET-007 "ICMP redirects accepted (all=$ra default=$rd)" "a host on the same network can silently re-route your traffic" "printf 'net.ipv4.conf.all.accept_redirects=0\nnet.ipv4.conf.default.accept_redirects=0\n' | sudo tee /etc/sysctl.d/99-redirects.conf && sudo sysctl --system"
  else ok NET-007 "ICMP redirects ignored" ""; fi
}
