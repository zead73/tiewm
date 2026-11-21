#!/bin/bash
# Builds tiewm-<version>-1.<dist>.x86_64.rpm into dist/ inside a container (needs docker). Default image is AlmaLinux 9 (with
# EPEL and CRB for fpc): its glibc is old enough that the package also installs on Fedora and on RHEL / Rocky 9 and newer.
#   packaging/rpm/docker-rpm.sh [image]       e.g. fedora:latest
# The source tarball comes from `git archive` of the checked-out commit, so commit your changes first.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"
IMG="${1:-almalinux:9}"
cd "$ROOT"
VERSION=$(sed -n "s/^  Version = '\(.*\)';/\1/p" tiewm.pas)
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
git archive --format=tar.gz --prefix="tiewm-$VERSION/" -o "$W/tiewm-$VERSION.tar.gz" HEAD
sed "s/@VERSION@/$VERSION/g" "$HERE/tiewm.spec.in" > "$W/tiewm.spec"
mkdir -p "$W/out"
docker run --rm -v "$W:/w" "$IMG" bash -c '
  set -e
  dnf -y -q install epel-release >/dev/null 2>&1 || true
  dnf -y -q --enablerepo=crb --enablerepo=epel install rpm-build fpc glibc-devel libX11-devel libXft-devel libXext-devel libXrandr-devel >/dev/null 2>&1 \
    || dnf -y -q install rpm-build fpc glibc-devel libX11-devel libXft-devel libXext-devel libXrandr-devel >/dev/null
  mkdir -p /root/rpmbuild/SOURCES
  cp /w/tiewm-*.tar.gz /root/rpmbuild/SOURCES/
  rpmbuild -bb /w/tiewm.spec >/dev/null
  cp /root/rpmbuild/RPMS/*/tiewm-*.rpm /w/out/
  chown -R '"$(id -u):$(id -g)"' /w/out'
mkdir -p "$ROOT/dist"
cp "$W"/out/*.rpm "$ROOT/dist/"
ls "$ROOT"/dist/*.rpm
