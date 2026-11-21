#!/bin/bash
# Builds the .deb inside a Debian container (default debian:bookworm, so the package also runs on newer releases:
# the binary needs glibc 2.36 or newer). Needs docker. Output: dist/tiewm_<version>_<arch>.deb
#   packaging/docker-deb.sh [debian-image-tag]
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
IMG="debian:${1:-bookworm}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# build from a copy so root-owned build products never land in the working tree
mkdir -p "$WORK/src/tools" "$WORK/src/packaging"
cp "$ROOT"/*.pas "$ROOT"/build.sh "$ROOT"/README.md "$ROOT"/tiewm.conf.example "$ROOT"/LICENSE "$WORK/src/"
cp "$ROOT"/tools/*.pas "$WORK/src/tools/"
cp -r "$HERE"/* "$WORK/src/packaging/"
mkdir -p "$WORK/src/dist"
docker run --rm -v "$WORK/src:/src" -e DEBIAN_FRONTEND=noninteractive "$IMG" bash -c '
  set -e
  apt-get update -qq >/dev/null
  apt-get install -y -qq fpc libx11-dev libxft-dev libxext-dev libxrandr-dev libxtst-dev dpkg-dev >/dev/null
  cd /src && packaging/build-deb.sh
  chown -R '"$(id -u):$(id -g)"' /src/dist'
mkdir -p "$ROOT/dist"
cp "$WORK"/src/dist/*.deb "$ROOT/dist/"
ls -l "$ROOT"/dist/*.deb
