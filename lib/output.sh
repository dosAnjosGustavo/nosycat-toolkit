#!/usr/bin/env bash
# lib/output.sh - summary, text/markdown/json renderers.
# shellcheck shell=bash

count_status() {
  local s n=0
  for s in "${R_STATUS[@]}"; do [ "$s" = "$1" ] && n=$((n + 1)); done
  echo "$n"
}

# final_exit_code -> 2 on any FAIL, 1 on any WARN, else 0 (IGNORED/SKIP/INFO do not count).
final_exit_code() {
  if [ "$(count_status FAIL)" -gt 0 ]; then echo 2
  elif [ "$(count_status WARN)" -gt 0 ]; then echo 1
  else echo 0; fi
}

# _ign_summary -> " · N IGNORED" when something was ignored.
_ign_summary() {
  local n
  n="$(count_status IGNORED)"; [ "$n" -gt 0 ] && printf ' · %d IGNORED' "$n"
  n="$(count_status INFO)"; [ "$n" -gt 0 ] && printf ' · %d INFO' "$n"
  return 0
}

json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

md_esc() { local s="${1//|/\\|}"; printf '%s' "${s//$'\n'/ }"; }

print_banner() {
  local art
  art="$(cat <<'BANNER'
           .---.
         _/_____\_     ________
          ( o.o )     |$ sniff |
           > ^ <      |$ _     |
          /     \_____|________|
         (__| |__)   /________/

.·:*¨¨* ❀ nosycat-toolkit ❀ *¨¨*:·.
   post-deploy check-up for linux vps
         ~ sniffing for clues ~
BANNER
)"
  use_utf8 || art="$(_asciify "$art")"
  printf '%s%s%s\n' "$C_PINK" "$art" "$C_RST"
  printf '%s  v%s %s host %s %s %s %s read-only%s\n' "$C_DIM" "$NOSY_VERSION" "$G_DOT" "$HOST_NAME" "$G_DOT" "$(date '+%Y-%m-%d %H:%M %Z')" "$G_DOT" "$C_RST"
}

# _asciify TEXT -> TEXT with the cute non-ASCII symbols replaced (for --ascii / non-UTF-8 locales).
_asciify() {
  local s="$1"
  s="${s//❀/@}"; s="${s//·/.}"; s="${s//¨/\'}"; s="${s//…/...}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------- summary
# The text summary is a small card: counts + a proportional bar in a box,
# per-module status in two columns, the top FAIL/WARN items and a verdict.
# Everything is laid out by display width (not bytes) so the box stays
# aligned under LC_ALL=C, and fits 80 columns.
# Indentation follows the per-check stream: headings ("❀ module", the divider,
# "❀ by module", "❀ fix first") at column 0, everything else at column 2.

SUM_W=58          # inner width of the summary box; the box is SUM_W+4 columns (+2 indent)
FIX_FIRST_MAX=8   # how many FAIL/WARN items the "fix first" list shows

# _ulen TEXT -> display width of plain TEXT (UTF-8 aware, bytewise-safe).
_ulen() {
  local LC_ALL=C s="$1" i n=0 c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    [[ "$c" < $'\x80' || "$c" > $'\xbf' ]] && n=$((n + 1))
  done
  echo "$n"
}

# _utrunc TEXT MAX -> TEXT cut to MAX display columns (ending in G_MORE when cut).
_utrunc() {
  local LC_ALL=C s="$1" max="$2" i n=0 c out="" ml
  if [ "$(_ulen "$s")" -le "$max" ]; then printf '%s' "$s"; return; fi
  ml="$(_ulen "$G_MORE")"
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    if [[ "$c" < $'\x80' || "$c" > $'\xbf' ]]; then
      [ $((n + 1)) -gt $((max - ml)) ] && break
      n=$((n + 1))
    fi
    out+="$c"
  done
  printf '%s%s' "$out" "$G_MORE"
}

# _rainbow TEXT -> TEXT with each visible character in the next pastel color.
_rainbow() {
  local LC_ALL=C s="$1" i c ch="" k=0 out=""
  local -a pal=("$C_PINK" "$C_WARN" "$C_OK" "$C_SKY" "$C_LILAC")
  [ -n "$C_RST" ] || { printf '%s' "$s"; return; }
  for ((i = 0; i <= ${#s}; i++)); do
    c="${s:i:1}"
    if [ -n "$ch" ] && { [ -z "$c" ] || [[ "$c" < $'\x80' || "$c" > $'\xbf' ]]; }; then
      if [ "$ch" = " " ]; then out+=" "; else out+="${pal[k % 5]}$ch"; k=$((k + 1)); fi
      ch=""
    fi
    ch+="$c"
  done
  printf '%s%s' "$out" "$C_RST"
}

# _rep TEXT N -> TEXT repeated N times.
_rep() { local out="" i; for ((i = 0; i < $2; i++)); do out+="$1"; done; printf '%s' "$out"; }

# _st_color / _st_glyph STATUS
_st_color() { case "$1" in FAIL) printf '%s' "$C_FAIL" ;; WARN) printf '%s' "$C_WARN" ;; OK) printf '%s' "$C_OK" ;; IGNORED) printf '%s' "$C_IGN" ;; *) printf '%s' "$C_SKIP" ;; esac; }
_st_glyph() { case "$1" in FAIL) printf '%s' "$G_FAIL" ;; WARN) printf '%s' "$G_WARN" ;; OK) printf '%s' "$G_OK" ;; IGNORED) printf '%s' "$G_IGN" ;; *) printf '%s' "$G_SKIP" ;; esac; }

# Line builder: _ln_add keeps a colored and a plain copy so widths come from the plain one.
_LN="" _LN_PLAIN=""
_ln_reset() { _LN="" _LN_PLAIN=""; }
_ln_add() { _LN+="$2$1${2:+$C_RST}"; _LN_PLAIN+="$1"; }   # _ln_add TEXT [COLOR]
_ln_pad() { local w; w="$(_ulen "$_LN_PLAIN")"; [ "$w" -lt "$1" ] && _ln_add "$(_rep ' ' $(($1 - w)))"; return 0; }

# _box_row -> print _LN padded to SUM_W inside the box borders.
_box_row() { _ln_pad "$SUM_W"; printf '  %s%s%s %s %s%s%s\n' "$C_LILAC" "$G_V" "$C_RST" "$_LN" "$C_LILAC" "$G_V" "$C_RST"; }

# bar_widths WIDTH C1 C2 ... -> one width per count, summing to WIDTH; any non-zero
# count gets at least one cell, the rest is split by largest remainder.
bar_widths() {
  local width="$1"; shift
  local -a c=("$@") ws=() r=()
  local total=0 i sum=0 best
  for i in "${!c[@]}"; do total=$((total + c[i])); done
  if [ "$total" -eq 0 ]; then for i in "${!c[@]}"; do ws+=(0); done; echo "${ws[*]}"; return; fi
  for i in "${!c[@]}"; do
    ws[i]=$((c[i] * width / total)); r[i]=$((c[i] * width % total))
    [ "${c[i]}" -gt 0 ] && [ "${ws[i]}" -eq 0 ] && { ws[i]=1; r[i]=-1; }
    sum=$((sum + ws[i]))
  done
  while [ "$sum" -lt "$width" ]; do
    best=-1
    for i in "${!c[@]}"; do [ "${c[i]}" -gt 0 ] && { [ "$best" -lt 0 ] || [ "${r[i]}" -gt "${r[best]}" ]; } && best=$i; done
    ws[best]=$((ws[best] + 1)); r[best]=-1; sum=$((sum + 1))
  done
  while [ "$sum" -gt "$width" ]; do
    best=0
    for i in "${!c[@]}"; do [ "${ws[i]}" -gt "${ws[best]}" ] && best=$i; done
    ws[best]=$((ws[best] - 1)); sum=$((sum - 1))
  done
  echo "${ws[*]}"
}

_summary_box() {
  local f="$1" w="$2" o="$3" s="$4" ig="$5" total head tail fill
  total=$((f + w + o + s + ig))
  head="$G_H summary "; tail=" $total checks $G_H"
  fill=$((SUM_W + 2 - $(_ulen "$head") - $(_ulen "$tail")))
  printf '  %s%s%s%s%s%s%s%s%s%s\n' "$C_LILAC" "$G_TL$G_H " "$C_PINK$C_BOLD" "summary" "$C_RST$C_LILAC" " $(_rep "$G_H" "$fill")" "$C_RST$C_DIM" " $total checks" "$C_RST$C_LILAC" " $G_H$G_TR$C_RST"

  _ln_reset
  _ln_add "$G_FAIL $f FAIL" "$C_FAIL$C_BOLD"; _ln_add "   "
  _ln_add "$G_WARN $w WARN" "$C_WARN$C_BOLD"; _ln_add "   "
  _ln_add "$G_OK $o OK" "$C_OK$C_BOLD"; _ln_add "   "
  _ln_add "$G_SKIP $s SKIP" "$C_SKIP$C_BOLD"
  [ "$ig" -gt 0 ] && { _ln_add "   "; _ln_add "$G_IGN $ig IGN" "$C_IGN$C_BOLD"; }
  _box_row

  local -a bw
  read -r -a bw <<<"$(bar_widths "$SUM_W" "$f" "$w" "$o" "$s" "$ig")"
  local -a st=(FAIL WARN OK SKIP IGNORED) ch
  if [ -n "$C_RST" ]; then ch=("$G_BAR" "$G_BAR" "$G_BAR" "$G_BAR" "$G_BAR")
  else ch=("$G_BAR_FAIL" "$G_BAR_WARN" "$G_BAR_OK" "$G_BAR_SKIP" "$G_BAR_IGN"); fi
  local i
  _ln_reset
  for i in 0 1 2 3 4; do
    [ "${bw[i]}" -gt 0 ] && _ln_add "$(_rep "${ch[i]}" "${bw[i]}")" "$(_st_color "${st[i]}")"
  done
  _box_row

  printf '  %s%s%s%s%s\n' "$C_LILAC" "$G_BL" "$(_rep "$G_H" $((SUM_W + 2)))" "$G_BR" "$C_RST"
}

# _module_cell MODULE -> sets _LN to the colored status of MODULE (worst first).
_module_cell() {
  local m="$1" i nf=0 nw=0 no=0 ns=0 ni=0
  for i in "${!R_MOD[@]}"; do
    [ "${R_MOD[$i]}" = "$m" ] || continue
    [ "${R_STATUS[$i]}" = "INFO" ] && continue
    case "${R_STATUS[$i]}" in FAIL) nf=$((nf + 1)) ;; WARN) nw=$((nw + 1)) ;; OK) no=$((no + 1)) ;; IGNORED) ni=$((ni + 1)) ;; *) ns=$((ns + 1)) ;; esac
  done
  _ln_reset
  if [ "$nf" -gt 0 ]; then _ln_add "$G_FAIL $nf fail" "$C_FAIL$C_BOLD"; fi
  if [ "$nw" -gt 0 ]; then [ "$nf" -gt 0 ] && _ln_add " "; _ln_add "$G_WARN $nw warn" "$C_WARN"; fi
  if [ $((nf + nw)) -eq 0 ]; then
    if [ "$no" -gt 0 ]; then _ln_add "$G_OK ok" "$C_OK"
    elif [ "$ns" -gt 0 ]; then _ln_add "$G_SKIP skipped" "$C_SKIP"
    elif [ "$ni" -gt 0 ]; then _ln_add "$G_IGN ignored" "$C_IGN"
    else _ln_add "$G_OK ok" "$C_OK"; fi   # only INFO notes
  fi
}

# _heading TEXT -> a section heading styled like the per-module headers.
_heading() { printf '\n%s%s%s %s%s%s\n' "$C_PINK" "$G_FLOWER" "$C_RST" "$C_LILAC$C_BOLD" "$1" "$C_RST"; }

_by_module() {
  local -a mods=()
  local i m last="" col=0 left="" left_plain="" cell_w=20 name_w=12
  for i in "${!R_MOD[@]}"; do
    m="${R_MOD[$i]}"
    [ "$m" = "$last" ] && continue
    last="$m"; mods+=("$m")
  done
  [ "${#mods[@]}" -gt 0 ] || return 0
  _heading "by module"
  for m in "${mods[@]}"; do
    _module_cell "$m"
    if [ "$col" -eq 0 ]; then
      left_plain="$(printf '%-*s' "$name_w" "$m")$_LN"
      _ln_pad "$cell_w"; left="$(printf '%-*s' "$name_w" "$m")$_LN"; col=1
    else
      printf '  %s  %s%s\n' "$left" "$(printf '%-*s' "$name_w" "$m")" "$_LN"; col=0
    fi
  done
  [ "$col" -eq 1 ] && printf '  %s\n' "$left_plain"
  return 0
}

_fix_first() {
  local -a idx=()
  local i st shown=0 rest
  for st in FAIL WARN; do
    for i in "${!R_STATUS[@]}"; do [ "${R_STATUS[$i]}" = "$st" ] && idx+=("$i"); done
  done
  [ "${#idx[@]}" -gt 0 ] || return 0
  _heading "fix first"
  for i in "${idx[@]}"; do
    [ "$shown" -ge "$FIX_FIRST_MAX" ] && break
    st="${R_STATUS[$i]}"
    printf '  %s%s%s %s%-8s%s %s\n' "$(_st_color "$st")$C_BOLD" "$(_st_glyph "$st")" "$C_RST" "$C_LILAC" "${R_ID[$i]}" "$C_RST" "$(_utrunc "${R_TITLE[$i]}" 66)"
    shown=$((shown + 1))
  done
  rest=$((${#idx[@]} - shown))
  [ "$rest" -gt 0 ] && printf '  %s%s +%d more (scroll up for why and fix)%s\n' "$C_DIM" "$G_MORE" "$rest" "$C_RST"
  return 0
}

_verdict() {
  local f="$1" w="$2" s="$3" i nroot=0
  printf '\n'
  if [ "$f" -gt 0 ]; then
    printf '  %s=x.x=%s  %s%d hard failure(s). fix the FAIL items first!%s\n' "$C_FAIL$C_BOLD" "$C_RST" "$C_FAIL" "$f" "$C_RST"
  elif [ "$w" -gt 0 ]; then
    printf '  %s=o.o=%s  %sno hard failures. review the WARN items when you can.%s\n' "$C_WARN$C_BOLD" "$C_RST" "$C_WARN" "$C_RST"
  else
    printf '  %s=^.^=%s  %sall clear! this server looks cozy.%s\n' "$C_OK$C_BOLD" "$C_RST" "$C_OK" "$C_RST"
  fi
  if [ "$IS_ROOT" -ne 1 ] && [ "$s" -gt 0 ]; then
    for i in "${!R_STATUS[@]}"; do
      [ "${R_STATUS[$i]}" = "SKIP" ] && [[ "${R_DETAIL[$i]}" == *"needs root"* ]] && nroot=$((nroot + 1))
    done
    if [ "$nroot" -gt 0 ]; then
      local what
      if [ "$s" -eq 1 ]; then what="the only skipped check needs root"
      elif [ "$nroot" -eq "$s" ]; then what="all $s skipped checks need root"
      elif [ "$nroot" -eq 1 ]; then what="1 of $s skipped checks needs root"
      else what="$nroot of $s skipped checks need root"; fi
      printf '  %s%s; run with sudo for the full picture.%s\n' "$C_SKIP" "$what" "$C_RST"
    fi
  fi
  return 0
}

print_summary() {
  local o w f s ig
  o="$(count_status OK)"; w="$(count_status WARN)"; f="$(count_status FAIL)"; s="$(count_status SKIP)"; ig="$(count_status IGNORED)"
  printf '\n%s\n\n' "$(_rainbow "$G_DIV")"
  _summary_box "$f" "$w" "$o" "$s" "$ig"
  _by_module
  _fix_first
  _verdict "$f" "$w" "$s"
}

# render_text_full -> plain report (used for --output with text format)
render_text_full() {
  local i last=""
  printf '%s %s report for %s (%s)\n' "$NOSY_NAME" "$NOSY_VERSION" "$HOST_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'os=%s virt=%s provider=%s pkg=%s firewall=%s root=%s\n' "$OS_NAME" "$VIRT" "$PROVIDER" "$PKG_MGR" "$FW_ACTIVE" "$IS_ROOT"
  for i in "${!R_ID[@]}"; do
    if [ "${R_MOD[$i]}" != "$last" ]; then printf '\n%s %s\n' "$G_FLOWER" "${R_MOD[$i]}"; last="${R_MOD[$i]}"; fi
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
  printf '**summary:** %s OK · %s WARN · %s FAIL · %s SKIP%s\n' "$(count_status OK)" "$(count_status WARN)" "$(count_status FAIL)" "$(count_status SKIP)" "$(_ign_summary)"
  for i in "${!R_ID[@]}"; do
    if [ "${R_MOD[$i]}" != "$last" ]; then
      printf '\n## %s\n\n| status | id | check | why | fix |\n|---|---|---|---|---|\n' "${R_MOD[$i]}"
      last="${R_MOD[$i]}"
    fi
    local fx="${R_FIX[$i]}"; { [ "${R_STATUS[$i]}" = "OK" ] || [ "${R_STATUS[$i]}" = "IGNORED" ] || [ "${R_STATUS[$i]}" = "INFO" ]; } && fx=""
    printf '| %s | %s | %s | %s | %s |\n' "${R_STATUS[$i]}" "${R_ID[$i]}" "$(md_esc "${R_TITLE[$i]}")" "$(md_esc "${R_DETAIL[$i]}")" "${fx:+\`$(md_esc "$fx")\`}"
  done
}

render_json() {
  local i sep=""
  printf '{"tool":"%s","version":"%s","generated_at":"%s","host":"%s",' "$NOSY_NAME" "$NOSY_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_esc "$HOST_NAME")"
  printf '"environment":{"os":"%s","os_id":"%s","family":"%s","kernel":"%s","virt":"%s","virt_kind":"%s","provider":"%s","pkg_manager":"%s","init":"%s","firewall":"%s","root":%s},' \
    "$(json_esc "$OS_NAME")" "$(json_esc "$OS_ID")" "$OS_FAMILY" "$(uname -r)" "$(json_esc "$VIRT")" "$VIRT_KIND" "$(json_esc "$PROVIDER")" "$PKG_MGR" "$(json_esc "$INIT_SYS")" "$FW_ACTIVE" "$([ "$IS_ROOT" -eq 1 ] && echo true || echo false)"
  printf '"summary":{"ok":%d,"warn":%d,"fail":%d,"skip":%d,"ignored":%d,"info":%d},"checks":[' "$(count_status OK)" "$(count_status WARN)" "$(count_status FAIL)" "$(count_status SKIP)" "$(count_status IGNORED)" "$(count_status INFO)"
  for i in "${!R_ID[@]}"; do
    local extra=""
    if [ "${R_STATUS[$i]}" = "IGNORED" ]; then
      extra="$(printf ',"original_status":"%s","ignore_reason":"%s"' "${R_ORIG[$i]}" "$(json_esc "${R_NOTE[$i]}")")"
    fi
    printf '%s{"id":"%s","module":"%s","status":"%s","title":"%s","detail":"%s","fix":"%s"%s}' "$sep" \
      "${R_ID[$i]}" "${R_MOD[$i]}" "${R_STATUS[$i]}" "$(json_esc "${R_TITLE[$i]}")" "$(json_esc "${R_DETAIL[$i]}")" "$(json_esc "${R_FIX[$i]}")" "$extra"
    sep=","
  done
  printf ']}\n'
}
