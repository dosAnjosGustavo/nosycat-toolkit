#!/usr/bin/env bash
# lib/output.sh - summary, text/markdown/json renderers.
# shellcheck shell=bash

count_status() {
  local s n=0
  for s in "${R_STATUS[@]}"; do [ "$s" = "$1" ] && n=$((n + 1)); done
  echo "$n"
}

json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

md_esc() { local s="${1//|/\\|}"; printf '%s' "${s//$'\n'/ }"; }

print_banner() {
  printf '%s' "$C_PINK"
  cat <<'BANNER'
       .---.
     _/_____\_     ________   .·:*¨¨* ❀ *¨¨*:·.
      ( o.o )     |$ ps aux|  nosycat-toolkit
       > ^ <      |$ _     |  post-deploy check-up for linux vps
      /     \_____|________|  .·:*¨¨* ❀ *¨¨*:·.
     (__| |__)   /________/   ~ trizdev · sniffing for clues ~
BANNER
  printf '%s\n  v%s · host %s · %s · read-only%s\n' "$C_RST$C_DIM" "$NOSY_VERSION" "$HOST_NAME" "$(date '+%Y-%m-%d %H:%M %Z')" "$C_RST"
}

print_summary() {
  local o w f s
  o="$(count_status OK)"; w="$(count_status WARN)"; f="$(count_status FAIL)"; s="$(count_status SKIP)"
  printf '\n%s.·:*¨¨* ❀ *¨¨*:·.%s\n' "$C_PINK" "$C_RST"
  printf '  summary: %s%d OK%s · %s%d WARN%s · %s%d FAIL%s · %s%d SKIP%s\n' \
    "$C_OK" "$o" "$C_RST" "$C_WARN" "$w" "$C_RST" "$C_FAIL" "$f" "$C_RST" "$C_SKIP" "$s" "$C_RST"
  if [ "$f" -gt 0 ]; then printf '  fix the FAIL items first; they are the ones that usually bite right after deploy.\n'
  elif [ "$w" -gt 0 ]; then printf '  no hard failures. review the WARN items when you can.\n'
  else printf '  all clear. =^.^=\n'; fi
}

# render_text_full -> plain report (used for --output with text format)
render_text_full() {
  local i last=""
  printf '%s %s report for %s (%s)\n' "$NOSY_NAME" "$NOSY_VERSION" "$HOST_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'os=%s virt=%s provider=%s pkg=%s firewall=%s root=%s\n' "$OS_NAME" "$VIRT" "$PROVIDER" "$PKG_MGR" "$FW_ACTIVE" "$IS_ROOT"
  for i in "${!R_ID[@]}"; do
    if [ "${R_MOD[$i]}" != "$last" ]; then printf '\n❀ %s\n' "${R_MOD[$i]}"; last="${R_MOD[$i]}"; fi
    print_check_line "${R_STATUS[$i]}" "${R_ID[$i]}" "${R_TITLE[$i]}" "${R_DETAIL[$i]}" "${R_FIX[$i]}"
  done
  print_summary
}

render_md() {
  local i last=""
  printf '# %s report: %s\n\n' "$NOSY_NAME" "$(md_esc "$HOST_NAME")"
  printf '_generated %s by %s %s (read-only)_\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NOSY_NAME" "$NOSY_VERSION"
  printf '| os | virtualization | provider | package manager | firewall | root |\n|---|---|---|---|---|---|\n'
  printf '| %s | %s | %s | %s | %s | %s |\n\n' "$(md_esc "$OS_NAME")" "$VIRT" "$PROVIDER" "$PKG_MGR" "$FW_ACTIVE" "$([ "$IS_ROOT" -eq 1 ] && echo yes || echo no)"
  printf '**summary:** %s OK · %s WARN · %s FAIL · %s SKIP\n' "$(count_status OK)" "$(count_status WARN)" "$(count_status FAIL)" "$(count_status SKIP)"
  for i in "${!R_ID[@]}"; do
    if [ "${R_MOD[$i]}" != "$last" ]; then
      printf '\n## %s\n\n| status | id | check | why | fix |\n|---|---|---|---|---|\n' "${R_MOD[$i]}"
      last="${R_MOD[$i]}"
    fi
    local fx="${R_FIX[$i]}"; [ "${R_STATUS[$i]}" = "OK" ] && fx=""
    printf '| %s | %s | %s | %s | %s |\n' "${R_STATUS[$i]}" "${R_ID[$i]}" "$(md_esc "${R_TITLE[$i]}")" "$(md_esc "${R_DETAIL[$i]}")" "${fx:+\`$(md_esc "$fx")\`}"
  done
}

render_json() {
  local i sep=""
  printf '{"tool":"%s","version":"%s","generated_at":"%s","host":"%s",' "$NOSY_NAME" "$NOSY_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_esc "$HOST_NAME")"
  printf '"environment":{"os":"%s","os_id":"%s","family":"%s","kernel":"%s","virt":"%s","virt_kind":"%s","provider":"%s","pkg_manager":"%s","init":"%s","firewall":"%s","root":%s},' \
    "$(json_esc "$OS_NAME")" "$(json_esc "$OS_ID")" "$OS_FAMILY" "$(uname -r)" "$(json_esc "$VIRT")" "$VIRT_KIND" "$(json_esc "$PROVIDER")" "$PKG_MGR" "$(json_esc "$INIT_SYS")" "$FW_ACTIVE" "$([ "$IS_ROOT" -eq 1 ] && echo true || echo false)"
  printf '"summary":{"ok":%d,"warn":%d,"fail":%d,"skip":%d},"checks":[' "$(count_status OK)" "$(count_status WARN)" "$(count_status FAIL)" "$(count_status SKIP)"
  for i in "${!R_ID[@]}"; do
    printf '%s{"id":"%s","module":"%s","status":"%s","title":"%s","detail":"%s","fix":"%s"}' "$sep" \
      "${R_ID[$i]}" "${R_MOD[$i]}" "${R_STATUS[$i]}" "$(json_esc "${R_TITLE[$i]}")" "$(json_esc "${R_DETAIL[$i]}")" "$(json_esc "${R_FIX[$i]}")"
    sep=","
  done
  printf ']}\n'
}
