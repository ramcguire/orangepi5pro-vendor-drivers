#!/usr/bin/env bash
# Build $OUT_DIR/dkms/ with DKMS against Armbian's headers packages.
# Needs arm64: the headers' scripts/ are arm64 binaries.
#
#   tools/dkms-check.sh [package[=version] ...]   # default: linux-headers-current-rockchip64
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${OUT_DIR:-$here/out}
repo=${ARMBIAN_APT:-https://apt.armbian.com}
suite=${ARMBIAN_SUITE:-trixie}
check=$out/dkms-check
specs=("$@")
[[ ${#specs[@]} -gt 0 ]] || specs=(linux-headers-current-rockchip64)

[[ $(uname -m) == aarch64 ]] || { echo "dkms-check.sh: needs arm64 (mise run dkms-check)" >&2; exit 1; }
shopt -s nullglob
srcs=("$out"/dkms/*/dkms.conf)
shopt -u nullglob
[[ ${#srcs[@]} -gt 0 ]] || { echo "dkms-check.sh: no sources in $out/dkms: run tools/dkms-src.sh" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
if ! command -v dkms > /dev/null; then
	apt-get update -qq
	# For the headers' postinst, and pahole for BTF.
	apt-get install -y -qq --no-install-recommends ca-certificates curl dkms gcc make bc \
		bison flex libssl-dev libelf-dev python3 kmod dwarves > /dev/null
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

# Headers first: their postinst would autoinstall sources already added.
kernels=()
for spec in "${specs[@]}"; do
	name=${spec%%=*}
	want=
	[[ $spec == *=* ]] && want=${spec#*=}
	read -r ver file sha < <(lookup "$name" "$want") || true
	[[ -n ${file:-} ]] || { echo "dkms-check.sh: $spec not in $repo $suite" >&2; exit 1; }
	deb=$check/${file##*/}
	[[ -f $deb ]] || curl -fsSL --retry 5 --retry-all-errors -o "$deb" "$repo/$file"
	echo "$sha  $deb" | sha256sum --check --quiet

	kernel=$(dpkg-deb --fsys-tarfile "$deb" | tar -t | sed -n 's|^\./usr/src/linux-headers-\([^/]*\)/$|\1|p' | head -1)
	if [[ ! -d /usr/src/linux-headers-$kernel ]]; then
		dkms status 2> /dev/null | awk -F'[/,: ]+' '{ print $1 "/" $2 }' | sort -u |
			while read -r m; do dkms remove "$m" --all > /dev/null 2>&1 || true; done
		dpkg -i "$deb" > "$check/headers-$kernel.log" 2>&1 || {
			cat "$check/headers-$kernel.log" >&2
			exit 1
		}
	fi
	echo "$name $ver: $kernel"
	kernels+=("$kernel")
done

for conf in "${srcs[@]}"; do
	dir=${conf%/dkms.conf}
	pkg=$(sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' "$conf")
	pkgver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$conf")
	dkms remove -m "$pkg" -v "$pkgver" --all > /dev/null 2>&1 || true
	rm -rf "/usr/src/$pkg-$pkgver"
	cp -R "$dir" "/usr/src/$pkg-$pkgver"
	dkms add -m "$pkg" -v "$pkgver" > /dev/null
done

status=0
for kernel in "${kernels[@]}"; do
	logs=$check/$kernel
	rm -rf "$logs"
	mkdir -p "$logs"
	echo "== $kernel"
	for conf in "${srcs[@]}"; do
		pkg=$(sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' "$conf")
		pkgver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$conf")
		make_log=/var/lib/dkms/$pkg/$pkgver/build/make.log
		if dkms build -m "$pkg" -v "$pkgver" -k "$kernel" --kernelsourcedir "/usr/src/linux-headers-$kernel" \
			> "$logs/$pkg.log" 2>&1; then
			cp "/var/lib/dkms/$pkg/$pkgver/$kernel/$(uname -m)/module/"*.ko* "$logs/"
			echo "$pkg $pkgver: ok"
		else
			status=1
			echo "$pkg $pkgver: FAILED ($logs/$pkg.log)"
		fi
		[[ -f $make_log ]] && cat "$make_log" >> "$logs/$pkg.log"
		grep -hE 'warning:|WARNING:|error:' "$make_log" 2> /dev/null |
			grep -v 'the compiler differs' | sed "s|^|  $pkg: |" || true
	done
done

if [[ $EUID -eq 0 ]]; then
	chown -R --reference="$here" "$check"
fi
exit "$status"
