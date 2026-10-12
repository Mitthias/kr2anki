#!/usr/bin/env bash
# KOReader-side flows on stand-in widgets, at several screen sizes.
#   dev/run_ui.sh             all sizes
#   dev/run_ui.sh --previews  also renders dev/previews/index.html (Tango 2 portrait + landscape)
set -euo pipefail
DEV="$(cd "$(dirname "$0")" && pwd)"
export KR2_ROOT="$(cd "$DEV/.." && pwd)" PLUGIN="$DEV/../kr2anki.koplugin"
status=0
for cfg in 824x1648@1.875 1648x824@1.875 1072x1448@1.875 600x800@1.0 1264x1680@2.0; do
  size="${cfg%@*}"; scale="${cfg#*@}"; w="${size%x*}"; h="${size#*x}"
  out="$(mktemp -d)"
  snap=""
  if [[ "${1:-}" == "--previews" && ( "$size" == "824x1648" || "$size" == "1648x824" ) ]]; then
    snap="$DEV/out/snap_$size"; rm -rf "$snap"; mkdir -p "$snap"
  fi
  printf "== UI %-10s " "$size"
  if ! SCREEN_W="$w" SCREEN_H="$h" DPI_SCALE="$scale" HARNESS_OUT="$out" SNAP_DIR="$snap" luajit "$DEV/test_ui.lua" > "$out/log.txt" 2>&1; then
    status=1
  fi
  tail -1 "$out/log.txt"
  grep -E "^FAIL|^luajit|error|traceback" "$out/log.txt" | head -20 || true
  rm -rf "$out"
done
if [[ "${1:-}" == "--previews" ]]; then
  python3 - "$DEV/out" "$DEV/previews/index.html" <<'PY'
import glob, os, re, sys
out, dest = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(dest), exist_ok=True)
html = ['<!doctype html><meta charset=utf-8><title>KR2Anki previews</title><style>body{background:#bbb;margin:0;padding:8px;font:12px sans-serif}figure{display:inline-block;margin:6px;vertical-align:top}figcaption{margin:2px 0}svg{display:block;box-shadow:0 0 0 1px #888}</style>']
for size, scale in (("824x1648", 0.42), ("1648x824", 0.42)):
    html.append(f"<h3>{size}</h3>")
    for f in sorted(glob.glob(f"{out}/snap_{size}/*.svg")):
        s = open(f).read()
        m = re.search(r'width="(\d+)" height="(\d+)"', s); w, h = int(m.group(1)), int(m.group(2))
        s = s.replace(f'width="{w}" height="{h}"', f'width="{int(w*scale)}" height="{int(h*scale)}"', 1)
        html.append(f"<figure><figcaption>{os.path.basename(f)[:-4]}</figcaption>{s}</figure>")
open(dest, "w").write("\n".join(html))
print("previews:", dest)
PY
fi
exit $status
