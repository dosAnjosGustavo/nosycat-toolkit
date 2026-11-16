#!/usr/bin/env bash
# modules/web_tls.sh - web server config validity and certificate expiry.
# shellcheck shell=bash

CERT_WARN_DAYS="${CERT_WARN_DAYS:-21}"

mod_web_tls() {
  local out

  # WEB-001 nginx -t
  if have nginx; then
    if [ "$IS_ROOT" -ne 1 ]; then
      skip WEB-001 "nginx config test" "needs root (nginx -t reads keys and the pid file)"
    elif out="$(t 15 nginx -t 2>&1)"; then
      ok WEB-001 "nginx -t: configuration valid" ""
    else
      fail WEB-001 "nginx -t failed" "$(printf '%s' "$out" | grep -m1 -E 'emerg|error' || echo 'see nginx -t output'); the next reload/restart will take the site down" "sudo nginx -t"
    fi
    if [ -e /etc/nginx/sites-enabled/default ]; then
      warn WEB-002 "nginx default site still enabled" "unknown Host headers and direct-IP scans get the default page (or your first vhost)" "sudo rm /etc/nginx/sites-enabled/default && sudo nginx -t && sudo systemctl reload nginx"
    else
      ok WEB-002 "nginx default site not enabled" ""
    fi
  else
    skip WEB-001 "nginx config test" "nginx not installed"
    skip WEB-002 "nginx default site" "nginx not installed"
  fi

  # WEB-003 apache configtest
  local actl=""
  for actl in apache2ctl apachectl httpd; do have "$actl" && break; actl=""; done
  if [ -n "$actl" ]; then
    if [ "$IS_ROOT" -ne 1 ]; then
      skip WEB-003 "apache config test" "needs root"
    elif out="$(t 15 "$actl" -t 2>&1)"; then
      ok WEB-003 "apache configtest: Syntax OK" ""
    else
      fail WEB-003 "apache configtest failed" "$(printf '%s' "$out" | head -n1); the next reload will fail" "sudo $actl -t"
    fi
  else
    skip WEB-003 "apache config test" "apache not installed"
  fi

  # WEB-004 certificate expiry
  local certs=() c f d
  for c in "$ETC"/letsencrypt/live/*/cert.pem; do [ -e "$c" ] && certs+=("$c"); done
  if [ -d "$ETC/nginx" ]; then
    while read -r f; do [ -n "$f" ] && certs+=("$f"); done < <(grep -rhoE '^[[:space:]]*ssl_certificate[[:space:]]+[^;]+' "$ETC/nginx" 2>/dev/null | awk '{print $2}' | tr -d '"'"'" | grep -v '\$')
  fi
  for d in "$ETC/apache2" "$ETC/httpd"; do
    [ -d "$d" ] || continue
    while read -r f; do [ -n "$f" ] && certs+=("$f"); done < <(grep -rhoiE '^[[:space:]]*SSLCertificateFile[[:space:]]+[^[:space:]]+' "$d" 2>/dev/null | awk '{print $2}' | tr -d '"')
  done
  if [ "${#certs[@]}" -eq 0 ]; then
    skip WEB-004 "certificate expiry" "no certificates found in /etc/letsencrypt, nginx or apache config"
  elif ! have openssl; then
    skip WEB-004 "certificate expiry" "openssl not installed"
  else
    local expired=() soon=() good=0 unread=0 end
    mapfile -t certs < <(printf '%s\n' "${certs[@]}" | sort -u)
    for c in "${certs[@]}"; do
      if [ ! -r "$c" ]; then unread=$((unread + 1)); continue; fi
      end="$(q openssl x509 -in "$c" -noout -enddate | cut -d= -f2)"
      if ! q openssl x509 -in "$c" -noout -checkend 0 >/dev/null; then expired+=("$c ($end)")
      elif ! q openssl x509 -in "$c" -noout -checkend $((CERT_WARN_DAYS * 86400)) >/dev/null; then soon+=("$c ($end)")
      else good=$((good + 1)); fi
    done
    if [ "${#expired[@]}" -gt 0 ]; then
      fail WEB-004 "expired certificate(s): $(trunc_list 3 "${expired[@]}")" "browsers and API clients refuse the connection" "sudo certbot renew   # then reload the web server"
    elif [ "${#soon[@]}" -gt 0 ]; then
      warn WEB-004 "certificate(s) expire within $CERT_WARN_DAYS days: $(trunc_list 3 "${soon[@]}")" "auto-renewal normally renews at 30 days left; this one is not renewing" "sudo certbot renew --dry-run"
    elif [ "$good" -gt 0 ]; then
      ok WEB-004 "$good certificate(s) valid for more than $CERT_WARN_DAYS days" ""
    else
      skip WEB-004 "certificate expiry" "$unread certificate(s) not readable; needs root"
    fi
  fi

  # WEB-005 certbot renewal scheduled
  if have certbot || [ -d /etc/letsencrypt/renewal ]; then
    if unit_enabled certbot.timer || unit_enabled snap.certbot.renew.timer || [ -e /etc/cron.d/certbot ] || grep -qs certbot /etc/crontab /var/spool/cron/crontabs/root /var/spool/cron/root; then
      ok WEB-005 "certbot renewal scheduled" ""
    else
      warn WEB-005 "certbot installed but no renewal timer/cron found" "certificates silently expire after 90 days" "sudo systemctl enable --now certbot.timer   # or add 'certbot renew -q' to cron"
    fi
  else
    skip WEB-005 "certbot renewal" "certbot not installed"
  fi
}
