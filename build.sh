#!/usr/bin/env bash
# Build the opi5 kernel and U-Boot packages with Armbian into $OUT_DIR (default out/).
#
#   ./build.sh [compile.sh parameters]
#
# Needs Linux with Docker (Armbian starts its own container); `mise run build` runs it in
# Armbian's builder image on any OS.
set -euo pipefail

# shellcheck disable=SC2034 # Read by tools/armbian.sh.
ARMBIAN_URL=https://github.com/armbian/build
# renovate: datasource=github-tags depName=armbian/build
ARMBIAN_TAG=v26.11.0-trunk.133
ARMBIAN_COMMIT=910bf7b2ea91c86b95b8673fc655d22d285d446c

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
armbian=${ARMBIAN_DIR:-$here/work/armbian}
out=${OUT_DIR:-$here/out}
board=$(sed -n "s/^declare -g BOARD=//p" "$here/userpatches/config-opi5.conf")
packages=(
	linux-image-current-rockchip64
	linux-dtb-current-rockchip64
	linux-headers-current-rockchip64
	"linux-u-boot-${board:?no BOARD in config-opi5.conf}-current"
)

# Logs to out/, where they outlive the container: ours, and Armbian's logs and summaries.
mkdir -p "$out"
rm -f "$out/build.log" "$out/build-armbian.log" "$out/build-summary.md"
exec > >(tee "$out/build.log") 2>&1
tee_pid=$!
stamp=$(mktemp)
finish() {
	local f
	for f in "$armbian"/output/logs/*; do
		[[ -f $f && $f -nt $stamp ]] || continue
		case $f in
		*/log-*.log) cat "$f" >> "$out/build-armbian.log" ;;
		*/summary-*.md) cat "$f" >> "$out/build-summary.md" ;;
		esac
	done
	rm -f "$stamp"
	if [[ $EUID -eq 0 ]]; then
		for f in "$out" "$out"/linux-*.deb "$out/SHA256SUMS" "$out"/build*; do
			if [[ -e $f ]]; then chown --reference="$here" "$f"; fi
		done
	fi
	exec >&- 2>&-
	wait "$tee_pid" || true
}
trap finish EXIT

bash "$here/tools/armbian.sh" "$armbian"
echo "armbian/build $ARMBIAN_TAG ($ARMBIAN_COMMIT) in $armbian"

rm -rf "$armbian/userpatches"
cp -R "$here/userpatches" "$armbian/userpatches"

debs=$armbian/output/debs
for package in "${packages[@]}"; do
	rm -f "$debs/$package"_*.deb
done

(cd "$armbian" && ./compile.sh opi5 kernel "$@")
(cd "$armbian" && ./compile.sh opi5 uboot "$@")

mkdir -p "$out"
rm -f "$out"/linux-*.deb "$out/SHA256SUMS"
for package in "${packages[@]}"; do
	found=("$debs/$package"_*.deb)
	[[ ${#found[@]} -eq 1 && -f ${found[0]} ]] || {
		echo "build.sh: expected one $package package in $debs, found ${#found[@]}" >&2
		exit 1
	}
	cp "${found[0]}" "$out/"
done
(cd "$out" && sha256sum linux-*.deb > SHA256SUMS)
cat "$out/SHA256SUMS"
