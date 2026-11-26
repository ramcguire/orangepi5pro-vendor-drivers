#!/usr/bin/env bash
# The DKMS package (make deb) against Armbian's headers packages: installs it, builds it for
# each kernel, applies its overlays to the board's DTB from the matching linux-dtb package,
# then removes it. Needs arm64: the headers' scripts/ are arm64 binaries.
#
#   tools/dkms-check.sh [package[=version] ...]   # default: linux-headers-current-rockchip64
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${OUT_DIR:-$here/out}
repo=${ARMBIAN_APT:-https://apt.armbian.com}
suite=${ARMBIAN_SUITE:-trixie}
check=$out/dkms-check
name=orangepi5pro-vendor-drivers
board=rk3588s-orangepi-5-pro
specs=("$@")
[[ ${#specs[@]} -gt 0 ]] || specs=(linux-headers-current-rockchip64)

[[ $(uname -m) == aarch64 ]] || { echo "dkms-check.sh: needs arm64 (mise run dkms-check)" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
if ! command -v dkms > /dev/null || ! command -v fdtoverlay > /dev/null || ! command -v git > /dev/null; then
	apt-get update -qq
	# For the headers' postinst, pahole for BTF, dtc for the overlays, git for make deb.
	apt-get install -y -qq --no-install-recommends ca-certificates curl dkms gcc make bc \
		bison flex libssl-dev libelf-dev python3 kmod dwarves device-tree-compiler git > /dev/null
fi

mkdir -p "$check"
index=$check/Packages
# Not piped: a retry would append to a partial stream.
curl -fsSL --retry 5 --retry-all-errors -o "$index.gz" "$repo/dists/$suite/main/binary-arm64/Packages.gz"
gunzip -f "$index.gz"

# Version, Filename, SHA256 of package $1 at version $2 (default newest).
lookup() {
	awk -v p="$1" -v v="$2" '
		/^Package: / { ok = ($2 == p) }
		ok && /^Version: / { ver = $2 }
		ok && /^Filename: / { file = $2 }
		ok && /^SHA256: / { sha = $2 }
		/^$/ { if (ok && (v == "" || ver == v)) print ver, file, sha; ok = 0 }
	' "$index" | sort -V | tail -1
}

# fetch <package> [version]: the checked .deb's path.
fetch() {
	local ver file sha deb
	read -r ver file sha < <(lookup "$1" "${2:-}") || true
	[[ -n ${file:-} ]] || { echo "dkms-check.sh: $1${2:+=$2} not in $repo $suite" >&2; return 1; }
	deb=$check/${file##*/}
	[[ -f $deb ]] || curl -fsSL --retry 5 --retry-all-errors -o "$deb" "$repo/$file"
	echo "$sha  $deb" | sha256sum --check --quiet
	echo "$deb"
}

# Headers first: their postinst would autoinstall sources already added.
dpkg -r "$name" > /dev/null 2>&1 || true
kernels=()
dtbs=()
for spec in "${specs[@]}"; do
	pkg=${spec%%=*}
	want=
	[[ $spec == *=* ]] && want=${spec#*=}
	deb=$(fetch "$pkg" "$want")
	ver=$(dpkg-deb -f "$deb" Version)

	kernel=$(dpkg-deb --fsys-tarfile "$deb" | tar -t | sed -n 's|^\./usr/src/linux-headers-\([^/]*\)/$|\1|p' | head -1)
	if [[ ! -d /usr/src/linux-headers-$kernel ]]; then
		dkms status 2> /dev/null | awk -F'[/,: ]+' '{ print $1 "/" $2 }' | sort -u |
			while read -r m; do dkms remove "$m" --all > /dev/null 2>&1 || true; done
		dpkg -i "$deb" > "$check/headers-$kernel.log" 2>&1 || {
			cat "$check/headers-$kernel.log" >&2
			exit 1
		}
	fi
	echo "$pkg $ver: $kernel"
	kernels+=("$kernel")
	# The DTB package of the same branch and version.
	dtbs+=("$(fetch "linux-dtb-${pkg#linux-headers-}" "$ver")")
done

# A stand-in armbianEnv.txt with another overlay, which the package must keep.
mkdir -p /boot
printf 'verbosity=1\nuser_overlays=other\n' > /boot/armbianEnv.txt
version=$(bash "$here/tools/version.sh")
make -s -C "$here" deb OUT="$out" VERSION="$version" > /dev/null
ours=$out/${name}_${version}_all.deb
apt-get install -y -qq "$ours" > "$check/install.log" 2>&1 || { cat "$check/install.log" >&2; exit 1; }
echo "${ours##*/}: installed"

status=0
for kernel in "${kernels[@]}"; do
	logs=$check/$kernel
	rm -rf "$logs"
	mkdir -p "$logs"
	echo "== $kernel"
	for pkg in rk-vcodec rga3 rknpu; do
		make_log=/var/lib/dkms/$pkg/$version/build/make.log
		# --force: the postinst may have built it for the newest kernel already.
		if dkms build --force -m "$pkg" -v "$version" -k "$kernel" --kernelsourcedir "/usr/src/linux-headers-$kernel" \
			> "$logs/$pkg.log" 2>&1; then
			cp "/var/lib/dkms/$pkg/$version/$kernel/$(uname -m)/module/"*.ko* "$logs/"
			echo "$pkg $version: ok"
		else
			status=1
			echo "$pkg $version: FAILED ($logs/$pkg.log)"
		fi
		[[ -f $make_log ]] && cat "$make_log" >> "$logs/$pkg.log"
		grep -hE 'warning:|WARNING:|error:' "$make_log" 2> /dev/null |
			grep -v 'the compiler differs' | sed "s|^|  $pkg: |" || true
	done
done

# Fails on a label or path the overlays need that Armbian's DTB lacks.
for deb in "${dtbs[@]}"; do
	rm -rf "$check/dtb"
	dpkg-deb -x "$deb" "$check/dtb"
	dtb=$(find "$check/dtb" -name "$board.dtb" | head -1)
	if [[ -z $dtb ]]; then
		status=1
		echo "${deb##*/}: no $board.dtb"
	elif fdtoverlay -i "$dtb" -o "$check/merged.dtb" /boot/overlay-user/*.dtbo 2> "$check/overlays.log"; then
		echo "${deb##*/}: overlays ok"
	else
		status=1
		echo "${deb##*/}: overlays FAILED"
		sed 's/^/  /' "$check/overlays.log"
	fi
done
rm -rf "$check/dtb" "$check/merged.dtb"

overlays=$(sed -n 's/^user_overlays=//p' /boot/armbianEnv.txt)
[[ $overlays == "other ${board}-mpp ${board}-npu" ]] || { status=1; echo "user_overlays after install: $overlays"; }

# Its prerm: DKMS forgets ours, user_overlays keeps only the other.
apt-get remove -y -qq "$name" > "$check/remove.log" 2>&1 || { cat "$check/remove.log" >&2; status=1; }
overlays=$(sed -n 's/^user_overlays=//p' /boot/armbianEnv.txt)
[[ $overlays == other ]] || { status=1; echo "user_overlays after removal: $overlays"; }
if dkms status | grep -qE '^(rk-vcodec|rga3|rknpu)/'; then
	status=1
	echo "$name: still in DKMS after removal"
fi

if [[ $EUID -eq 0 ]]; then
	chown -R --reference="$here" "$check" "$out"/dtbo "$out/${name}_"*.deb
fi
exit "$status"
