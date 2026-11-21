#!/bin/bash
# Builds tiewm and the test tools with FPC. Units go to a temp dir, binaries stay in place.
set -e
cd "$(dirname "$0")"
U="${TMPDIR:-/tmp}/tiewm-units"; mkdir -p "$U"
fpc -Mobjfpc -Sh -O2 -Fu. -FE. -FU"$U" tiewm.pas
for t in testwin xdo xgeom themetest themescan framecheck shapewin paintbench imgdiff palettecheck; do
  (cd tools && fpc -Mobjfpc -Sh -O2 -Fu.. -FE. -FU"$U" "$t.pas")
done
