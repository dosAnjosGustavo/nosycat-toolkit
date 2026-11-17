#!/usr/bin/env bash
# scripts/bundle.sh - build a single-file nosycat.sh with lib/ and modules/ inlined.
# usage: scripts/bundle.sh [OUT]   (default: dist/nosycat.sh)
#
# Every `. "$NOSY_ROOT/<file>"` line in nosycat.sh is replaced by that file
# (minus its shebang); the preceding `# shellcheck source=` hint is dropped.
# The output is reproducible: same tree, same bytes.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-dist/nosycat.sh}"
ver="$(sed -n 's/^NOSY_VERSION="\(.*\)"$/\1/p' lib/common.sh)"
[ -n "$ver" ] || { echo "bundle: NOSY_VERSION not found in lib/common.sh" >&2; exit 1; }
mkdir -p "$(dirname "$out")"
tmp="$(mktemp "${out}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

awk -v ver="$ver" '
  NR == 1 { print; print "# Single-file build of nosycat-toolkit " ver " (lib/ and modules/ inlined by scripts/bundle.sh)."; next }
  /^# shellcheck source=/ { held = $0; next }
  /^NOSY_ROOT=/ { next }   # only used to find lib/ and modules/
  /^\. "\$NOSY_ROOT\/[^"]+"$/ {
    f = $0; sub(/^\. "\$NOSY_ROOT\//, "", f); sub(/"$/, "", f)
    if ((getline line < f) <= 0) { print "bundle: cannot read " f > "/dev/stderr"; exit 1 }
    print "# ---- begin " f
    do { if (!(first_done[f]++ == 0 && line ~ /^#!/)) print line } while ((getline line < f) > 0)
    close(f)
    print "# ---- end " f
    held = ""; next
  }
  { if (held != "") { print held; held = "" } print }
' nosycat.sh >"$tmp"

# shellcheck disable=SC2016  # literal $NOSY_ROOT in the pattern
if grep -q '^\. "\$NOSY_ROOT/' "$tmp"; then echo "bundle: unresolved source lines left" >&2; exit 1; fi
bash -n "$tmp"
chmod 0755 "$tmp"
mv "$tmp" "$out"
trap - EXIT
echo "bundle: wrote $out ($(wc -l <"$out") lines, version $ver)"
