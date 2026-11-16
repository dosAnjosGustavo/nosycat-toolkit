#!/usr/bin/env bash
# modules/docker.sh - common Docker foot-guns on a fresh VPS. Skipped if Docker is absent.
# shellcheck shell=bash

mod_docker() {
  if ! have docker; then
    skip DKR-001 "docker" "docker not installed"
    return 0
  fi
  if ! q docker info >/dev/null; then
    if [ "$IS_ROOT" -eq 1 ]; then
      warn DKR-001 "docker installed but daemon not reachable" "containers will not start on boot" "sudo systemctl enable --now docker"
    else
      skip DKR-001 "docker daemon" "not reachable as $(id -un); re-run with sudo"
    fi
    return 0
  fi
  ok DKR-001 "docker daemon reachable ($(q docker version --format '{{.Server.Version}}'))" ""

  # DKR-002 docker group = root
  local members
  members="$(getent group docker 2>/dev/null | cut -d: -f4)"
  if [ -n "$members" ]; then
    warn DKR-002 "users in the docker group: ${members//,/, }" "docker group membership is root-equivalent (docker run -v /:/host)" "keep it to admins only; remove with: sudo gpasswd -d USER docker"
  else
    ok DKR-002 "docker group is empty" ""
  fi

  local ids
  ids="$(q docker ps -q)"
  if [ -z "$ids" ]; then
    ok DKR-003 "no running containers" ""
    _docker_logcfg ""
    return 0
  fi

  # shellcheck disable=SC2016  # Go template, not shell
  local fmt='{{.Name}}|{{.HostConfig.Privileged}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.LogConfig.Type}}|{{index .HostConfig.LogConfig.Config "max-size"}}|{{range .Mounts}}{{.Source}},{{end}}|{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}}:{{.HostPort}}>{{$p}},{{end}}{{end}}'
  local name priv rp lt ms mounts ports p
  local privs=() socks=() pubs=() norestart=() nolog=()
  local -a parr
  # shellcheck disable=SC2086
  while IFS='|' read -r name priv rp lt ms mounts ports; do
    name="${name#/}"
    [ "$priv" = "true" ] && privs+=("$name")
    case ",$mounts" in *docker.sock,*) socks+=("$name") ;; esac
    case "$rp" in ''|no) norestart+=("$name") ;; esac
    if [ "$lt" = "json-file" ] && { [ -z "$ms" ] || [ "$ms" = "<no value>" ]; }; then nolog+=("$name"); fi
    IFS=',' read -r -a parr <<<"$ports"
    for p in "${parr[@]}"; do
      [ -z "$p" ] && continue
      case "${p%:*}" in 0.0.0.0|::|'') pubs+=("$name ${p##*:}") ;; esac
    done
  done < <(q docker inspect --format "$fmt" $ids)

  if [ "${#privs[@]}" -gt 0 ]; then
    fail DKR-003 "privileged containers: $(trunc_list 5 "${privs[@]}")" "--privileged disables isolation; a container escape is trivial" "drop 'privileged: true' and grant only the needed cap_add / devices"
  else
    ok DKR-003 "no privileged containers" ""
  fi

  if [ "${#socks[@]}" -gt 0 ]; then
    warn DKR-004 "docker.sock mounted in: $(trunc_list 5 "${socks[@]}")" "access to the Docker socket is root on the host; a bug in that container owns the server" "mount it read-only via a socket proxy (e.g. tecnativa/docker-socket-proxy) or remove it"
  else
    ok DKR-004 "docker.sock not mounted in containers" ""
  fi

  if [ "${#pubs[@]}" -gt 0 ]; then
    mapfile -t pubs < <(printf '%s\n' "${pubs[@]}" | sort -u)
    if [ "$FW_ACTIVE" = "ufw" ] || [ "$FW_ACTIVE" = "firewalld" ]; then
      fail DKR-005 "ports published on all interfaces: $(trunc_list 5 "${pubs[@]}")" "Docker writes its own iptables rules, so these ports are public even if $FW_ACTIVE denies them" "publish as '127.0.0.1:8080:80' behind a reverse proxy, or filter in the DOCKER-USER chain"
    else
      warn DKR-005 "ports published on all interfaces: $(trunc_list 5 "${pubs[@]}")" "reachable from the internet; host firewall rules do not apply to Docker-published ports" "publish as '127.0.0.1:8080:80' behind a reverse proxy"
    fi
  else
    ok DKR-005 "no container ports published on 0.0.0.0/::" ""
  fi

  if [ "${#norestart[@]}" -gt 0 ]; then
    warn DKR-006 "containers without restart policy: $(trunc_list 5 "${norestart[@]}")" "they stay down after a reboot or crash" "add 'restart: unless-stopped' (compose) or: docker update --restart unless-stopped NAME"
  else
    ok DKR-006 "all running containers have a restart policy" ""
  fi

  _docker_logcfg "$(join ', ' "${nolog[@]}")"
}

_docker_logcfg() {
  local nolist="$1" daemon=0
  if [ -r /etc/docker/daemon.json ] && grep -q '"max-size"' /etc/docker/daemon.json; then daemon=1; fi
  if [ -n "$nolist" ]; then
    warn DKR-007 "json-file logs without size limit: $nolist" "container logs grow until the disk is full" "set '{\"log-driver\":\"json-file\",\"log-opts\":{\"max-size\":\"10m\",\"max-file\":\"3\"}}' in /etc/docker/daemon.json, restart docker and recreate containers"
  elif [ "$daemon" -eq 1 ]; then
    ok DKR-007 "default log rotation set in daemon.json" ""
  else
    warn DKR-007 "no default log size limit in /etc/docker/daemon.json" "new containers will log without limit (json-file default)" "add log-opts max-size/max-file to /etc/docker/daemon.json and restart docker"
  fi
}
