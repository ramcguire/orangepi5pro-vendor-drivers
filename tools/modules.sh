#!/usr/bin/env bash
# Build only rk_vcodec.ko, rga3.ko, rknpu.ko, their KUnit tests and the board's DTB into
# $OUT_DIR/drivers/.
#
#   tools/modules.sh [src] [build]   # defaults: work/kernel and work/build
#
# src is a patched kernel tree, imported with tools/queue.sh if missing; build is the O=
# tree. With a kernel package in $OUT_DIR (default out/), its config and release are used,
# so the modules load on that kernel (there's no MODVERSIONS, so only the release must
# match). Without one it's Armbian's config: a compile check only.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
src=${1:-$here/work/kernel}
build=${2:-$here/work/build}
out=${OUT_DIR:-$here/out}
armbian=${ARMBIAN_DIR:-$here/work/armbian}
conf=$here/userpatches/config-opi5.conf
patchdirs=("$here"/userpatches/kernel/archive/rockchip64-*)
[[ ${#patchdirs[@]} -eq 1 ]] || { echo "modules.sh: expected one rockchip64-* patch dir" >&2; exit 1; }
patchdir=${patchdirs[0]}
family=${patchdir##*/}
family=${family%-*}
branch=$(sed -n 's/^declare -g BRANCH=//p' "$conf")
modules=(
	drivers/media/platform/rockchip/mpp/rk_vcodec.ko
	drivers/media/platform/rockchip/rga/rga3/rga3.ko
	drivers/rknpu/rknpu.ko
	drivers/media/platform/rockchip/mpp/mpp_kunit.ko
	drivers/media/platform/rockchip/rga/rga3/rga_kunit.ko
)
dtb=rockchip/rk3588s-orangepi-5-pro.dtb

bash "$here/tools/armbian.sh" "$armbian"
[[ -d $src/.git ]] || ARMBIAN_DIR=$armbian bash "$here/tools/queue.sh" import "$src"
# dt/ holds whole files, not patches. A new .dts also needs its Makefile line: re-import.
for f in "$patchdir"/dt/*; do
	cmp -s "$f" "$src/arch/arm64/boot/dts/rockchip/${f##*/}" || cp "$f" "$src/arch/arm64/boot/dts/rockchip/"
done

# ARCH and LOCALVERSION as Armbian's kernel-make.sh.
cross=
[[ $(uname -m) == aarch64 ]] || cross=aarch64-linux-gnu-
export CCACHE_DIR=${CCACHE_DIR:-$armbian/cache/ccache}
mk=(make -C "$src" O="$build" ARCH=arm64 "LOCALVERSION=-$branch-$family"
	"CROSS_COMPILE=ccache $cross" -j"$(nproc)")

# Only a changed input replaces .config, so an unchanged one rebuilds nothing.
mkdir -p "$build"
images=("$out/linux-image-$branch-$family"_*.deb)
release=
if [[ -f ${images[0]} ]]; then
	[[ ${#images[@]} -eq 1 ]] || { echo "modules.sh: more than one kernel package in $out" >&2; exit 1; }
	# Read the whole stream: a reader that stops early fails dpkg-deb under pipefail.
	rm -rf "$build/package"
	mkdir -p "$build/package"
	dpkg-deb --fsys-tarfile "${images[0]}" | tar -x -C "$build/package" --wildcards './boot/config-*'
	configs=("$build"/package/boot/config-*)
	[[ ${#configs[@]} -eq 1 && -f ${configs[0]} ]] || { echo "modules.sh: no single /boot/config-* in ${images[0]##*/}" >&2; exit 1; }
	release=${configs[0]##*/config-}
	cp "${configs[0]}" "$build/.config.input"
	echo "config: ${images[0]##*/} ($release)"
else
	cp "$armbian/config/kernel/linux-$family-$branch.config" "$build/.config.input"
	echo "config: Armbian's linux-$family-$branch.config (no kernel package in $out: compile check only)"
fi

# shellcheck disable=SC1091 # Checked on its own.
source "$here/userpatches/extensions/opi5.sh"
# LOCALVERSION_AUTO: as Armbian. DEBUG_INFO_BTF_MODULES needs vmlinux, which isn't built.
declare -a opts_y=() opts_m=() opts_n=(LOCALVERSION_AUTO DEBUG_INFO_BTF_MODULES)
declare -A opts_val=()
custom_kernel_config__opi5
args=()
for s in "${opts_y[@]}"; do args+=(-e "$s"); done
for s in "${opts_m[@]}"; do args+=(-m "$s"); done
for s in "${opts_n[@]}"; do args+=(-d "$s"); done
for s in "${!opts_val[@]}"; do args+=(--set-val "$s" "${opts_val[$s]}"); done
"$src/scripts/config" --file "$build/.config.input" "${args[@]}"
# A changed tree can add Kconfig symbols, so it reruns olddefconfig too.
printf '# source %s %s\n' "$(git -C "$src" rev-parse HEAD)" \
	"$(git -C "$src" diff HEAD -- '*Kconfig*' | sha1sum | cut -d' ' -f1)" >> "$build/.config.input"
if ! cmp -s "$build/.config.input" "$build/.config.last"; then
	cp "$build/.config.input" "$build/.config"
	"${mk[@]}" -s olddefconfig
	cp "$build/.config.input" "$build/.config.last"
fi

# The extension's check, with stand-ins for the Armbian functions it calls.
exit_with_error() { echo "modules.sh: $*" >&2; exit 1; }
display_alert() { echo "$1: $2"; }
kernel_work_dir=$build
pre_package_kernel_image__opi5_check_config

built=$("${mk[@]}" -s kernelrelease)
if [[ -n $release && $built != "$release" ]]; then
	echo "modules.sh: building $built, but the package is $release" >&2
	exit 1
fi

"${mk[@]}" -s modules_prepare
# A separate make: mixed with .ko goals, the modules' final link misses objects.
# The DTB builds without dtc warnings, so any warning fails.
"${mk[@]}" -s "$dtb" 2> "$build/dtc.log" || { cat "$build/dtc.log" >&2; exit 1; }
if [[ -s $build/dtc.log ]]; then
	cat "$build/dtc.log" >&2
	echo "modules.sh: dtc warnings in $dtb" >&2
	exit 1
fi
# Without vmlinux.o, modpost reports every kernel symbol as undefined: warn, and drop those.
"${mk[@]}" -s KBUILD_MODPOST_WARN=1 "${modules[@]}" 2> "$build/modpost.log" || {
	cat "$build/modpost.log" >&2
	exit 1
}
grep -v 'undefined!$\|unresolved symbol warnings\|vmlinux.o is missing\|Modules may not have\|unresolved symbol errors\|KBUILD_MODPOST_WARN=1\|at your own risk' \
	"$build/modpost.log" >&2 || true

mkdir -p "$out/drivers"
for f in "${modules[@]}" "arch/arm64/boot/dts/$dtb"; do
	cp "$build/$f" "$out/drivers/"
done
if [[ $EUID -eq 0 ]]; then
	chown -R --reference="$here" "$out/drivers"
fi
echo "$built: $(cd "$out/drivers" && echo *) in $out/drivers"
