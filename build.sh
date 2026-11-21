#!/usr/bin/env bash
# Build the opi5 kernel packages with Armbian into $OUT_DIR (default out/).
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
packages=(linux-image linux-dtb linux-headers)

# Logs to out/, where they outlive the container: ours, and Armbian's log and summary.
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
		*/log-*.log) cp "$f" "$out/build-armbian.log" ;;
		*/summary-*.md) cp "$f" "$out/build-summary.md" ;;
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
	rm -f "$debs/$package"-current-rockchip64_*.deb
done

(cd "$armbian" && ./compile.sh opi5 kernel "$@")

mkdir -p "$out"
rm -f "$out"/linux-*.deb "$out/SHA256SUMS"
for package in "${packages[@]}"; do
	found=("$debs/$package"-current-rockchip64_*.deb)
	[[ ${#found[@]} -eq 1 && -f ${found[0]} ]] || {
		echo "build.sh: expected one $package package in $debs, found ${#found[@]}" >&2
		exit 1
	}
	cp "${found[0]}" "$out/"
done
(cd "$out" && sha256sum linux-*.deb > SHA256SUMS)
cat "$out/SHA256SUMS"
