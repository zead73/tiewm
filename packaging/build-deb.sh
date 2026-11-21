#!/bin/bash
# Builds tiewm_<version>_<arch>.deb into dist/. Run it on a Debian / Ubuntu system that has fpc and the X11 dev packages
#   sudo apt install fpc libx11-dev libxft-dev libxext-dev libxrandr-dev libxtst-dev dpkg-dev
# or let packaging/docker-deb.sh do all of that in a Debian container.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
cd "$ROOT"
./build.sh >/dev/null
VERSION=$(./tiewm --version | awk '{print $2}')
ARCH=$(dpkg --print-architecture)
PKG="tiewm_${VERSION}_${ARCH}"
T="$ROOT/dist/$PKG"
rm -rf "$T"
install -d "$T/DEBIAN" "$T/usr/bin" "$T/usr/share/doc/tiewm" "$T/usr/share/xsessions"
install -m 0755 -s tiewm "$T/usr/bin/tiewm"
install -m 0644 README.md tiewm.conf.example "$T/usr/share/doc/tiewm/"
install -m 0644 "$HERE/deb/copyright" "$T/usr/share/doc/tiewm/copyright"
install -m 0644 "$HERE/tiewm.desktop" "$T/usr/share/xsessions/tiewm.desktop"
gzip -9n "$T/usr/share/doc/tiewm/README.md"
SIZE=$(du -sk "$T/usr" | cut -f1)
sed -e "s/@VERSION@/$VERSION/" -e "s/@ARCH@/$ARCH/" -e "s/@SIZE@/$SIZE/" "$HERE/deb/control.in" > "$T/DEBIAN/control"
dpkg-deb --root-owner-group --build "$T" "$ROOT/dist/$PKG.deb" >/dev/null
rm -rf "$T"
echo "$ROOT/dist/$PKG.deb"
