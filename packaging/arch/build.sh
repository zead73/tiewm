#!/bin/bash
# Builds tiewm-<version>-<rel>-x86_64.pkg.tar.zst into dist/. Run it on Arch Linux (needs fpc and base-devel).
# The source tarball comes from `git archive` of the checked-out commit, so commit your changes first.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"
cd "$ROOT"
VERSION=$(sed -n "s/^  Version = '\(.*\)';/\1/p" tiewm.pas)
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
git archive --format=tar.gz --prefix="tiewm-$VERSION/" -o "$W/tiewm-$VERSION.tar.gz" HEAD
sed "s/^pkgver=.*/pkgver=$VERSION/" "$HERE/PKGBUILD" > "$W/PKGBUILD"
(cd "$W" && makepkg -f --noconfirm >&2)
mkdir -p "$ROOT/dist"
cp "$W"/tiewm-*.pkg.tar.zst "$ROOT/dist/"
ls "$ROOT"/dist/tiewm-*.pkg.tar.zst
