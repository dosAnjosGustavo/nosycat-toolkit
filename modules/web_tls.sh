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

  # WEB-004 certificate expiry (only certificates the enabled config uses)
  _web_cert_check

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

# _web_enabled_conf -> the web server configuration that is actually loaded:
# `nginx -T` when it can run, otherwise nginx.conf, conf.d and sites-enabled
# (never sites-available); the enabled apache files likewise.
_web_enabled_conf() {
  local out="" f
  if fx_set NGINX_T || { have nginx && [ "$IS_ROOT" -eq 1 ]; }; then
    out="$(if fx_set NGINX_T; then fx NGINX_T; else t 15 nginx -T 2>/dev/null; fi)"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    for f in "$ETC"/nginx/nginx.conf "$ETC"/nginx/conf.d/*.conf "$ETC"/nginx/sites-enabled/*; do
      [ -f "$f" ] && [ -r "$f" ] && cat -- "$f"
    done
  fi
  for f in "$ETC"/apache2/apache2.conf "$ETC"/apache2/ports.conf "$ETC"/apache2/sites-enabled/* \
           "$ETC"/apache2/conf-enabled/*.conf "$ETC"/apache2/mods-enabled/*.conf \
           "$ETC"/httpd/conf/httpd.conf "$ETC"/httpd/conf.d/*.conf; do
    [ -f "$f" ] && [ -r "$f" ] && cat -- "$f"
  done
  return 0
}

# _cert_state FILE -> expired | soon | good | unread
_cert_state() {
  if [ ! -r "$1" ]; then echo unread
  elif ! q openssl x509 -in "$1" -noout -checkend 0 >/dev/null; then echo expired
  elif ! q openssl x509 -in "$1" -noout -checkend $((CERT_WARN_DAYS * 86400)) >/dev/null; then echo soon
  else echo good; fi
}

_web_cert_check() {
  local used=() orphan=() f c d
  while read -r f; do
    [ -n "$f" ] || continue
    case "$f" in /etc/*) f="$ETC/${f#/etc/}" ;; esac
    used+=("$f")
  done < <(_web_enabled_conf | grep -hoiE '^[[:space:]]*(ssl_certificate|SSLCertificateFile)[[:space:]]+[^;[:space:]]+' | awk '{print $2}' | tr -d '"'"'" | grep -v '\$' | sort -u)
  # Let's Encrypt lineages no enabled vhost points at (left over from old sites).
  for d in "$ETC"/letsencrypt/live/*/; do
    [ -e "$d/cert.pem" ] || continue
    case " ${used[*]} " in *" ${d%/}/"*) continue ;; esac
    orphan+=("${d%/}/cert.pem")
  done
  if [ "${#used[@]}" -eq 0 ] && [ "${#orphan[@]}" -eq 0 ]; then
    skip WEB-004 "certificate expiry" "no certificates found in enabled nginx/apache config or /etc/letsencrypt"
    return
  fi
  if ! have openssl; then skip WEB-004 "certificate expiry" "openssl not installed"; return; fi
  local expired=() soon=() stale=() good=0 unread=0 end st
  for c in "${used[@]}"; do
    st="$(_cert_state "$c")"
    end="$(q openssl x509 -in "$c" -noout -enddate | cut -d= -f2)"
    case "$st" in
      expired) expired+=("$c ($end)") ;; soon) soon+=("$c ($end)") ;;
      good) good=$((good + 1)) ;; *) unread=$((unread + 1)) ;;
    esac
  done
  for c in "${orphan[@]}"; do
    st="$(_cert_state "$c")"
    case "$st" in
      expired|soon) stale+=("$(basename "$(dirname "$c")") ($st, $(q openssl x509 -in "$c" -noout -enddate | cut -d= -f2))") ;;
      good) good=$((good + 1)) ;; *) unread=$((unread + 1)) ;;
    esac
  done
  local note=""
  [ "${#stale[@]}" -gt 0 ] && note="Let's Encrypt cert(s) not used by any enabled vhost: $(trunc_list 3 "${stale[@]}")"
  if [ "${#expired[@]}" -gt 0 ]; then
    fail WEB-004 "expired certificate(s) in enabled config: $(trunc_list 3 "${expired[@]}")" "browsers and API clients refuse the connection${note:+; also: $note}" "sudo certbot renew   # then reload the web server"
  elif [ "${#soon[@]}" -gt 0 ]; then
    warn WEB-004 "certificate(s) expire within $CERT_WARN_DAYS days: $(trunc_list 3 "${soon[@]}")" "auto-renewal normally renews at 30 days left; this one is not renewing${note:+; also: $note}" "sudo certbot renew --dry-run"
  elif [ "${#stale[@]}" -gt 0 ]; then
    warn WEB-004 "$note" "no enabled site serves them, but certbot keeps trying to renew them (renewal errors, rate limits)" "sudo certbot delete --cert-name NAME   # if the site is gone"
  elif [ "$good" -gt 0 ]; then
    ok WEB-004 "$good certificate(s) valid for more than $CERT_WARN_DAYS days" ""
  else
    skip WEB-004 "certificate expiry" "$unread certificate(s) not readable; needs root"
  fi
}
