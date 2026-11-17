#!/usr/bin/env bats
# Text summary card: layout by display width, colors, ASCII fallback.

load helpers

# dwidth -> display width of each stdin line (strips ANSI, counts UTF-8 lead bytes).
dwidth() {
  local line esc
  esc="$(printf '\033')"
  while IFS= read -r line; do
    printf '%s' "$line" | sed "s/${esc}\[[0-9;]*m//g" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '
  done
}

# fake_results MODE -> fill the result store with a fixed set of checks.
fake_results() {
  local i
  CUR_MOD=environment; ok ENV-001 "distribution: Ubuntu 24.04"; warn ENV-007 "clock is 3 minutes off"; record INFO ENV-006 "running as deploy (not root)" "reduced visibility"
  CUR_MOD=access; ok SSH-002 "password auth off"; skip SSH-009 "empty passwords" "needs root to read /etc/shadow"
  CUR_MOD=network
  [ "$1" = fail ] && fail NET-002 "no host firewall" "INPUT policy accept" "sudo ufw enable"
  [ "$1" = ok ] || for i in 1 2 3 4 5 6 7 8 9; do warn "NET-10$i" "warning number $i with a rather long title that keeps going and going past the edge"; done
  ok NET-005 "ip_forward off"
  CUR_MOD=databases; ok DB-001 "databases bound to loopback only"
}

summary() { nosy print_summary; }

setup() {
  load_nosycat
  FORMAT=text LIVE_TEXT=0 IS_ROOT=0 COLOR_MODE=never NOSY_LOCALE=C.UTF-8 ASCII_MODE=auto
  setup_colors; setup_glyphs
}

@test "summary box rows all have the same display width and fit 80 columns" {
  fake_results fail
  run summary
  [ "$status" -eq 0 ]
  local box widths
  box="$(printf '%s\n' "$output" | grep -E '^  (╭|│|╰)')"
  [ "$(printf '%s\n' "$box" | wc -l)" -eq 4 ]
  widths="$(printf '%s\n' "$box" | dwidth | sort -u)"
  [ "$widths" = "$((SUM_W + 6))" ]
  while read -r w; do [ "$w" -le 80 ]; done < <(printf '%s\n' "$output" | dwidth)
}

@test "box alignment holds with colors on" {
  COLOR_MODE=always; setup_colors
  fake_results warn
  run summary
  [[ "$output" == *$'\033['* ]]
  [ "$(printf '%s\n' "$output" | grep -E $'^  (\033\\[[0-9;]*m)*(╭|│|╰)' | dwidth | sort -u)" = "$((SUM_W + 6))" ]
}

@test "bar is proportional, sums to the box width, and keeps tiny counts visible" {
  local -a w
  read -r -a w <<<"$(bar_widths 58 1 0 100 0 0)"
  [ "${w[0]}" -ge 1 ]; [ "${w[1]}" -eq 0 ]
  [ $((w[0] + w[1] + w[2] + w[3] + w[4])) -eq 58 ]
  read -r -a w <<<"$(bar_widths 58 2 6 16 5 0)"
  [ $((w[0] + w[1] + w[2] + w[3] + w[4])) -eq 58 ]
  [ "${w[2]}" -gt "${w[1]}" ]; [ "${w[1]}" -gt "${w[0]}" ]
  [ "$(bar_widths 58 0 0 0 0 0)" = "0 0 0 0 0" ]
}

@test "by module is two aligned columns" {
  fake_results warn
  run summary
  local rows
  rows="$(printf '%s\n' "$output" | sed -n '/^❀ by module$/,/^$/p' | sed '1d;/^$/d')"
  [ "$(printf '%s\n' "$rows" | wc -l)" -eq 2 ]
  [[ "$rows" == *"environment ! 1 warn"*"access      ✓ ok"* ]]
  # second column starts at the same display column on every row: 2 + name 12 + cell 20 + gap 2
  local starts
  starts="$(printf '%s\n' "$rows" | sed -E 's/^(.*  )(access|databases).*/\1/' | dwidth | sort -u)"
  [ "$starts" = "36" ]
}

@test "fix first lists FAIL before WARN and folds the rest" {
  fake_results fail
  run summary
  local ff
  ff="$(printf '%s\n' "$output" | sed -n '/^❀ fix first$/,/^$/p')"
  [ "$(printf '%s\n' "$ff" | sed -n 2p | grep -c 'NET-002')" -eq 1 ]
  [[ "$ff" == *"+3 more (scroll up for why and fix)"* ]]
  [ "$(printf '%s\n' "$ff" | grep -cE '^  (✗|!) ')" -eq "$FIX_FIRST_MAX" ]
}

@test "verdict face follows the worst status" {
  fake_results fail; run summary; [[ "$output" == *"=x.x="*"hard failure"* ]]
  R_STATUS=() R_ID=() R_MOD=() R_TITLE=() R_DETAIL=() R_FIX=() R_ORIG=() R_NOTE=()
  fake_results warn; run summary; [[ "$output" == *"=o.o=  no hard failures. review the WARN items when you can."* ]]
  R_STATUS=() R_ID=() R_MOD=() R_TITLE=() R_DETAIL=() R_FIX=() R_ORIG=() R_NOTE=()
  fake_results ok
  R_STATUS[0]=OK R_STATUS[1]=OK
  run summary
  [[ "$output" == *"=^.^="* ]]
  [[ "$output" != *"fix first"* ]]
}

@test "skip note says how many of the skipped checks need root" {
  fake_results warn
  run summary
  # 1 SKIP in the box, and it is the one that needs root
  [[ "$output" == *"1 SKIP"* ]]
  [[ "$output" == *"  the only skipped check needs root; run with sudo for the full picture."* ]]
  skip SYS-099 "swap" "no swap file"; skip SYS-098 "ntp" "needs root to read chrony"
  run summary
  [[ "$output" == *"3 SKIP"* ]]
  [[ "$output" == *"  2 of 3 skipped checks need root; run with sudo for the full picture."* ]]
  R_STATUS[${#R_STATUS[@]}-2]=OK
  run summary
  [[ "$output" == *"  all 2 skipped checks need root; run with sudo for the full picture."* ]]
  skip SYS-097 "x" "not applicable"; skip SYS-096 "y" "not applicable"; skip SYS-095 "z" "not applicable"
  run summary
  [[ "$output" == *"  2 of 5 skipped checks need root; run with sudo for the full picture."* ]]
  [[ "$output" != *"check(s) skipped without root"* ]]
  IS_ROOT=1
  run summary
  [[ "$output" != *"need root"* ]] && [[ "$output" != *"needs root;"* ]]
}

@test "summary indentation: headings at column 0, everything else at exactly 2" {
  fake_results fail
  run summary
  local line bad=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      "❀ "*|".·:*"*) ;;                 # section heading or divider
      "  "[!\ ]*) ;;                    # content
      *) echo "bad indent: [$line]"; bad=1 ;;
    esac
  done <<<"$output"
  [ "$bad" -eq 0 ]
  [[ "$output" == *$'\n❀ by module\n'* ]] && [[ "$output" == *$'\n❀ fix first\n'* ]]
}

@test "NO_COLOR, non-TTY and TERM=dumb disable colors in auto mode" {
  COLOR_MODE=auto
  NOSY_FX_TTY=1 NO_COLOR='' TERM=xterm-256color; setup_colors; [ -n "$C_OK" ]
  NOSY_FX_TTY=1 NO_COLOR=1; setup_colors; [ -z "$C_OK" ] && [ -z "$C_RST" ]
  NOSY_FX_TTY=1 NO_COLOR='' TERM=dumb; setup_colors; [ -z "$C_OK" ]
  NOSY_FX_TTY='' NO_COLOR='' TERM=xterm-256color; setup_colors; [ -z "$C_OK" ]
  COLOR_MODE=always NO_COLOR=1; setup_colors; [ -n "$C_OK" ]
  COLOR_MODE=never NOSY_FX_TTY=1 NO_COLOR=''; setup_colors; [ -z "$C_OK" ]
}

@test "palette depth follows COLORTERM / TERM" {
  COLOR_MODE=always
  COLORTERM=truecolor; setup_colors; [[ "$C_OK" == *"38;2;"* ]]
  COLORTERM='' TERM=xterm-256color; setup_colors; [[ "$C_OK" == *"38;5;"* ]]
  COLORTERM='' TERM=xterm; setup_colors; [ "$C_OK" = $'\033[32m' ]
}

@test "non-UTF-8 locale and --ascii fall back to plain ASCII" {
  fake_results fail
  NOSY_LOCALE=C; setup_glyphs
  run summary
  [ "$(printf '%s' "$output" | LC_ALL=C tr -d '\000-\177' | wc -c)" -eq 0 ]
  [[ "$output" == *$'\n  +- summary -'* ]]
  [[ "$output" == *$'\n@ by module\n'* ]]
  NOSY_LOCALE=C.UTF-8 ASCII_MODE=on; setup_glyphs
  run summary
  [ "$(printf '%s' "$output" | LC_ALL=C tr -d '\000-\177' | wc -c)" -eq 0 ]
}

@test "full run: piped output has no colors, --color always has, --ascii is pure ASCII" {
  run bash "$NOSY_SRC/nosycat.sh" --only environment,cloud_init
  [[ "$output" != *$'\033['* ]]
  [[ "$output" == *"summary"* ]]
  run bash "$NOSY_SRC/nosycat.sh" --only environment,cloud_init --color always
  [[ "$output" == *$'\033['* ]]
  LANG=C.UTF-8 run bash "$NOSY_SRC/nosycat.sh" --only environment,cloud_init --ascii
  [ "$(printf '%s' "$output" | LC_ALL=C tr -d '\000-\177' | wc -c)" -eq 0 ]
  run bash "$NOSY_SRC/nosycat.sh" --color sometimes
  [ "$status" -eq 3 ]
}

@test "md and json formats do not carry the text card" {
  run bash "$NOSY_SRC/nosycat.sh" --only environment --format md --color always
  [[ "$output" != *"by module"* ]] && [[ "$output" != *$'\033['* ]]
  [[ "$output" == *"**summary:**"* ]]
  run bash "$NOSY_SRC/nosycat.sh" --only environment --format json --color always
  printf '%s' "$output" | jq -e '.summary' >/dev/null
}
