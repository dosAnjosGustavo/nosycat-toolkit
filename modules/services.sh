#!/usr/bin/env bash
# modules/services.sh - failed units, services that should run, logs that survive and rotate.
# shellcheck shell=bash

mod_services() {
  if ! systemd_up; then
    if have rc-status; then
      local crashed
      crashed="$(q rc-status --crashed | paste -sd ' ' -)"
      if [ -n "${crashed// /}" ]; then warn SVC-001 "crashed OpenRC services: $crashed" "they are not running and will not be retried" "rc-service NAME restart; check /var/log/messages"
      else ok SVC-001 "no crashed OpenRC services" ""; fi
    else
      skip SVC-001 "failed units" "systemd is not running as PID 1"
    fi
    skip SVC-002 "enabled but inactive services" "systemd only"
    skip SVC-003 "journal persistence" "systemd only"
    skip SVC-004 "journal size limit" "systemd only"
  else
    local failed
    failed="$(q systemctl list-units --state=failed --no-legend --plain | awk '{print $1}' | paste -sd ' ' -)"
    if [ -n "${failed// /}" ]; then
      warn SVC-001 "failed units: $failed" "a failed unit at deploy time usually means a broken config or missing dependency" "systemctl status UNIT; journalctl -u UNIT -b"
    else
      ok SVC-001 "no failed systemd units" ""
    fi

    # SVC-002 enabled services that are not running (excluding oneshot/timer/socket-activated)
    local units id type state trig cond k v dead=()
    mapfile -t units < <(q systemctl list-unit-files --type=service --state=enabled --no-legend | awk '$1 !~ /@/ {print $1}')
    if [ "${#units[@]}" -gt 0 ]; then
      id="" type="" state="" trig="" cond=""
      while IFS='=' read -r k v; do
        case "$k" in
          Id) id="$v" ;; Type) type="$v" ;; ActiveState) state="$v" ;; TriggeredBy) trig="$v" ;; ConditionResult) cond="$v" ;;
          '')
            if [ -n "$id" ] && [ "$type" != "oneshot" ] && [ -z "$trig" ] && [ "$cond" != "no" ] && { [ "$state" = "inactive" ] || [ "$state" = "failed" ]; }; then dead+=("$id"); fi
            id="" type="" state="" trig="" cond="" ;;
        esac
      done < <(q systemctl show -p Id,Type,ActiveState,TriggeredBy,ConditionResult "${units[@]}"; echo)
    fi
    if [ "${#dead[@]}" -gt 0 ]; then
      warn SVC-002 "enabled but not running: $(trunc_list 6 "${dead[@]}")" "they are supposed to start on boot but are down now" "systemctl status UNIT   # or disable it if unneeded"
    else
      ok SVC-002 "all enabled services are running" ""
    fi

    # SVC-003 persistent journal
    local storage
    storage="$(cat /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null | awk -F= '/^[[:space:]]*Storage=/{s=$2} END{print s}')"
    if [ "$storage" = "volatile" ] || [ "$storage" = "none" ]; then
      warn SVC-003 "journal Storage=$storage" "logs are lost on reboot, so you cannot see why the server crashed" "set Storage=persistent in /etc/systemd/journald.conf and restart systemd-journald"
    elif [ "$storage" = "persistent" ] || [ -d /var/log/journal ]; then
      ok SVC-003 "journal is persistent" ""
    else
      warn SVC-003 "journal is volatile (/var/log/journal missing)" "logs are lost on reboot, so you cannot see why the server crashed" "sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal && sudo systemctl restart systemd-journald"
    fi

    # SVC-004 journal size cap
    local maxuse usage
    maxuse="$(cat /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null | awk -F= '/^[[:space:]]*SystemMaxUse=/{s=$2} END{print s}')"
    usage="$(q journalctl --disk-usage | grep -oE '[0-9.]+[KMGT]?B?' | head -n1)"
    if [ -n "$maxuse" ]; then
      ok SVC-004 "journal capped at SystemMaxUse=$maxuse${usage:+ (using $usage)}" ""
    elif printf '%s' "$usage" | grep -qE '^[0-9.]+G'; then
      warn SVC-004 "journal uses $usage with no explicit cap" "default cap is 10% of the filesystem (max 4G), a lot on a small VPS disk" "echo -e '[Journal]\nSystemMaxUse=500M' | sudo tee /etc/systemd/journald.conf.d/size.conf && sudo systemctl restart systemd-journald"
    else
      ok SVC-004 "journal size: ${usage:-unknown} (default cap: 10% of fs, max 4G)" ""
    fi
  fi

  # SVC-005 logrotate
  if have logrotate || [ -x /usr/sbin/logrotate ]; then
    if unit_enabled logrotate.timer || [ -e /etc/cron.daily/logrotate ] || [ -e /etc/periodic/daily/logrotate ]; then
      ok SVC-005 "logrotate installed and scheduled" ""
    else
      warn SVC-005 "logrotate installed but not scheduled" "logs in /var/log grow without limit" "sudo systemctl enable --now logrotate.timer"
    fi
  else
    warn SVC-005 "logrotate not installed" "application logs in /var/log grow until the disk is full" "install the 'logrotate' package"
  fi
}
