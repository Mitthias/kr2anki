#!/usr/bin/env bash
# Everything that can be checked without the Tango 2:
#   1. every Lua file compiles (LuaJIT)
#   2. luacheck (undefined globals, unused values)
#   3. busted unit tests for the pure-logic modules (tests/)
#   4. KOReader-side flows on stand-in widgets at five screen sizes (dev/run_ui.sh)
#   5. the .apkg packages imported by the official Anki library (if .ankienv exists)
# First run: dev/setup.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
status=0
step() { printf "\n== %s\n" "$1"; }

step "compile"
n=0; bad=0
while IFS= read -r f; do
  n=$((n+1))
  if ! out=$(luajit -bl "$f" /dev/null 2>&1 >/dev/null); then echo "FAIL $f: $out"; bad=$((bad+1)); fi
done < <(find kr2anki.koplugin tests dev -name "*.lua")
echo "$n files, $bad failed"; [[ $bad -eq 0 ]] || status=1

step "luacheck"
.rocks/bin/luacheck kr2anki.koplugin tests dev --formatter plain --codes -q > /tmp/kr2anki-luacheck.txt; lc=$?
grep -c . /tmp/kr2anki-luacheck.txt | xargs -I{} echo "{} warnings (plugin: $(grep -c '^kr2anki.koplugin' /tmp/kr2anki-luacheck.txt))"
grep '^kr2anki.koplugin' /tmp/kr2anki-luacheck.txt && status=1

step "busted"
.rocks/bin/busted -o TAP | tail -3 || status=1
.rocks/bin/busted > /dev/null 2>&1 || { echo "busted failed"; status=1; }

step "UI flows"
dev/run_ui.sh || status=1

if [[ -x .ankienv/bin/python ]]; then
  step "official Anki import"
  tmp="$(mktemp -d)"
  luajit dev/make_apkg.lua "$tmp/a.apkg" > /dev/null
  LATER=60 luajit dev/make_apkg.lua "$tmp/b.apkg" "UPDATED meaning" > /dev/null
  .ankienv/bin/python -I dev/check_apkg.py "$tmp/a.apkg" "$tmp/b.apkg" | tail -4 || status=1
  .ankienv/bin/python -I dev/check_apkg.py kr2anki.koplugin/assets/kr2anki_notetypes.apkg | head -1 || status=1
  rm -rf "$tmp"
fi

echo
[[ $status -eq 0 ]] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $status
