#!/usr/bin/env bash
# DKMS sources of rk_vcodec, rga3 and rknpu from the patched tree, into $OUT_DIR/dkms/.
#
#   tools/dkms-src.sh [src]   # default work/kernel
#
# Version: v6.18.63-1 gives 6.18.63.1, then +<n>.g<commit>[.dirty]. $DKMS_VERSION
# overrides it; $GIT_DESCRIBE replaces git describe where git can't read the repository.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
src=${1:-$here/work/kernel}
out=${OUT_DIR:-$here/out}/dkms
armbian=${ARMBIAN_DIR:-$here/work/armbian}

# package module [make arguments]
packages=(
	"rk-vcodec rk_vcodec"
	"rga3 rga3"
	"rknpu rknpu CONFIG_ROCKCHIP_RKNPU=m"
)

version=${DKMS_VERSION:-}
if [[ -z $version ]]; then
	describe=${GIT_DESCRIBE:-$(git -C "$here" describe --tags --match 'v*' --dirty 2> /dev/null || true)}
	re='^v([0-9.]+)-([0-9]+)(-([0-9]+)-g([0-9a-f]+))?(-dirty)?$'
	[[ $describe =~ $re ]] || { echo "dkms-src.sh: no version from '$describe'; set DKMS_VERSION" >&2; exit 1; }
	version=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}
	extra=()
	[[ -n ${BASH_REMATCH[3]} ]] && extra+=("${BASH_REMATCH[4]}" "g${BASH_REMATCH[5]}")
	[[ -n ${BASH_REMATCH[6]} ]] && extra+=(dirty)
	if [[ ${#extra[@]} -gt 0 ]]; then
		version+=+$(IFS=.; echo "${extra[*]}")
	fi
fi

if [[ -d $src/.git ]]; then
	bash "$here/tools/queue.sh" check "$src"
else
	ARMBIAN_DIR=$armbian bash "$here/tools/queue.sh" import "$src"
fi

# copy <package> <tree path> [package path]: a directory's contents go to the top.
copy() {
	local dst=$out/$1-$version
	if [[ -n ${3:-} ]]; then
		mkdir -p "$(dirname "$dst/$3")"
		cp "$src/$2" "$dst/$3"
	else
		mkdir -p "$dst"
		cp -R "$src/$2/." "$dst"
	fi
}

rm -rf "$out"
mkdir -p "$out"

copy rk-vcodec drivers/media/platform/rockchip/mpp
copy rk-vcodec include/uapi/linux/rk-mpp.h include/uapi/linux/rk-mpp.h
copy rga3 drivers/media/platform/rockchip/rga/rga3
copy rknpu drivers/rknpu
# Headers packages don't ship drivers/.
copy rknpu drivers/devfreq/governor.h src/include/compat/linux/governor.h
cp "$here/dkms/rknpu/devfreq-governor.h" "$out/rknpu-$version/src/include/compat/linux/"

for entry in "${packages[@]}"; do
	read -r pkg module make_args <<< "$entry"
	dir=$out/$pkg-$version
	rm -f "$dir/Kconfig" "$dir"/*_kunit.c
	if [[ -f $here/dkms/$pkg/Kbuild ]]; then
		cp "$here/dkms/$pkg/Kbuild" "$dir/"
	fi
	sed -e "s/@PACKAGE@/$pkg/" -e "s/@MODULE@/$module/" -e "s/@VERSION@/$version/" \
		-e "s/@MAKE_ARGS@/${make_args:+$make_args }/" "$here/dkms/dkms.conf.in" > "$dir/dkms.conf"
done

if [[ $EUID -eq 0 ]]; then
	chown -R --reference="$here" "$out"
fi
echo "$(cd "$out" && echo *) in $out"
