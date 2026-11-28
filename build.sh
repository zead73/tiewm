#!/bin/bash
# Builds tiewm and the test tools with FPC. Units go to a temp dir, binaries stay in place.
#   ./build.sh        tiewm and every tool in tools/
#   ./build.sh main   only tiewm (what the distribution packages need)
set -e
cd "$(dirname "$0")"
U="${TMPDIR:-/tmp}/tiewm-units"; mkdir -p "$U"
fpc -Mobjfpc -Sh -O2 -Fu. -FE. -FU"$U" tiewm.pas
[ "${1:-}" = main ] && exit 0
for t in monset testwin xdo xgeom themetest themescan framecheck shapewin paintbench imgdiff palettecheck hintrecv; do
  (cd tools && fpc -Mobjfpc -Sh -O2 -Fu.. -FE. -FU"$U" "$t.pas")
done
