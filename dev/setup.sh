#!/usr/bin/env bash
# One-time: test tools for a desktop with Homebrew.
#   busted + luacheck under LuaJIT (into ./.rocks), and the official Anki
#   Python package (into ./.ankienv) for import checks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v luajit >/dev/null || brew install luajit
command -v luarocks >/dev/null || brew install luarocks
LJ="$(brew --prefix luajit)"
for rock in busted luacheck; do
  luarocks --lua-version=5.1 --lua-dir="$LJ" --tree=.rocks install "$rock"
done
python3 -m venv .ankienv && .ankienv/bin/pip install -q anki
echo "done"
