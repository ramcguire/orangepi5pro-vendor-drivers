#!/usr/bin/env bash
# Whether HEAD needs a release, for release.yml: prints tag=<tag>, or tag= for none, and
# why on stderr.
#
#   tools/release-plan.sh
#
# A release is due when what the packages are built from changed since the last release:
# userpatches/, build.sh (Armbian's pin), the DKMS package's own files and scripts or mise.toml's
# builder image (the compiler). The tag is v<kernel>-<n>, n counting from 1 for each kernel.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here"
kernel=$(sed -n 's/^declare -g KERNELBRANCH=tag:v//p' userpatches/config-opi5.conf)
[[ -n $kernel ]] || { echo "release-plan.sh: no kernel tag in userpatches/config-opi5.conf" >&2; exit 1; }

last=$(git describe --tags --abbrev=0 --match 'v[0-9]*-[0-9]*' HEAD 2> /dev/null || true)
if [[ -z $last ]]; then
	why="no release yet"
elif ! git diff --quiet "$last" HEAD -- userpatches build.sh Makefile dkms udev overlays tools/dkms-src.sh tools/version.sh; then
	why="userpatches/, build.sh or the DKMS package changed since $last"
elif git diff "$last" HEAD -- mise.toml | grep -q '^[-+]builder = '; then
	why="the builder image changed since $last"
else
	echo "no release: nothing the packages are built from changed since $last" >&2
	echo "tag="
	exit 0
fi

# Every tag counts, merged or not, so a number is never reused.
max=$(git tag --list "v$kernel-*" | sed -n "s/^v${kernel//./\\.}-\([0-9][0-9]*\)$/\1/p" | sort -n | tail -n 1)
tag=v$kernel-$((${max:-0} + 1))
echo "release $tag: $why" >&2
echo "tag=$tag"
