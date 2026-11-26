#!/usr/bin/env bash
# The three drivers' DKMS sources, from our patches alone: each zz-opi5-*.patch applied to an
# empty tree, only the drivers' paths. The Makefile runs it; needs git and bash.
#
#   tools/dkms-src.sh [out] [--against tree]   # out defaults to out/src
#
# --against: also take the same files from a patched kernel tree (the queue, or check's),
# and fail unless both agree, and unless dkms/rknpu/governor.h is still the tree's.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$here/out/src
against=
while [[ $# -gt 0 ]]; do
	case $1 in
		--against) against=${2:?tree}; shift 2 ;;
		*) out=$1; shift ;;
	esac
done
patchdirs=("$here"/userpatches/kernel/archive/rockchip64-*)
[[ ${#patchdirs[@]} -eq 1 ]] || { echo "dkms-src.sh: expected one rockchip64-* patch dir" >&2; exit 1; }

# package <tree path> [package path]: a directory's contents go to the top.
files=(
	"rk-vcodec drivers/media/platform/rockchip/mpp"
	"rk-vcodec include/uapi/linux/rk-mpp.h include/uapi/linux/rk-mpp.h"
	"rga3 drivers/media/platform/rockchip/rga/rga3"
	"rknpu drivers/rknpu"
)

# sources <tree> <dst>: the packages from a patched tree, plus ours from dkms/.
sources() {
	local tree=$1 dst=$2 entry pkg path to dir
	rm -rf "$dst"
	for entry in "${files[@]}"; do
		read -r pkg path to <<< "$entry"
		if [[ -n $to ]]; then
			mkdir -p "$(dirname "$dst/$pkg/$to")"
			cp "$tree/$path" "$dst/$pkg/$to"
		else
			mkdir -p "$dst/$pkg"
			cp -R "$tree/$path/." "$dst/$pkg"
		fi
	done
	# Headers packages don't ship drivers/.
	cp "$here/dkms/rknpu/governor.h" "$here/dkms/rknpu/devfreq-governor.h" "$dst/rknpu/src/include/compat/linux/"
	for dir in "$dst"/*/; do
		rm -f "$dir/Kconfig" "$dir"/*_kunit.c
		pkg=$(basename "$dir")
		[[ -f $here/dkms/$pkg/Kbuild ]] || continue
		# Ours includes the driver's, as Makefile.
		[[ -f $dir/Makefile ]] || mv "$dir/Kbuild" "$dir/Makefile"
		cp "$here/dkms/$pkg/Kbuild" "$dir"
	done
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
includes=()
for entry in "${files[@]}"; do
	read -r pkg path to <<< "$entry"
	# A file, or a directory's files (* crosses /).
	if [[ -n $to ]]; then includes+=("--include=$path"); else includes+=("--include=$path/*"); fi
done
# Outside any repository, so paths are the tree's.
mkdir "$tmp/tree"
for p in "${patchdirs[0]}"/zz-opi5-*.patch; do
	git -C "$tmp/tree" apply --whitespace=nowarn "${includes[@]}" "$p" ||
		{ echo "dkms-src.sh: ${p##*/} doesn't apply" >&2; exit 1; }
done
sources "$tmp/tree" "$out"

if [[ -n $against ]]; then
	sources "$against" "$tmp/against"
	diff -r "$tmp/against" "$out" || { echo "dkms-src.sh: the patches alone differ from $against" >&2; exit 1; }
	# Our copy, which sources() puts on both sides, against the kernel's.
	diff "$against/drivers/devfreq/governor.h" "$here/dkms/rknpu/governor.h" ||
		{ echo "dkms-src.sh: dkms/rknpu/governor.h differs from $against's; copy it" >&2; exit 1; }
	echo "dkms-src: the patches alone match $against"
fi
if [[ $EUID -eq 0 ]]; then
	chown -R --reference="$here" "$out"
fi
echo "$(cd "$out" && echo *) in $out"
