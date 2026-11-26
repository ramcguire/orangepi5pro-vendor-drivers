#!/usr/bin/env bash
# Run the KUnit suites of a built kernel package under QEMU, without a board:
#
#   tools/kunit.sh [linux-image .deb]   # default: the one in $OUT_DIR (out/)
#
# Boots the package's own vmlinuz on qemu-system-aarch64's virt machine with an initramfs
# of the test modules (every module that needs kunit.ko) and tools/kunit-init.c as /init,
# which loads them (KUnit runs a module's suites as it loads) and prints each suite's
# results. Fails unless every module loads, there are at least as many suites as test
# modules, no test fails, and the kernel logs no BUG:, Oops, panic, or KASAN, UBSAN, lockdep
# or DMA-API report.
#
# The console log and the results are kept in $OUT_DIR/kunit/. Needs the builder image's
# cross compiler and cpio; installs qemu-system-arm from Debian if it's missing.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${OUT_DIR:-$here/out}
deb=${1:-}
if [[ -z $deb ]]; then
	found=("$out"/linux-image-*.deb)
	[[ ${#found[@]} -eq 1 && -f ${found[0]} ]] ||
		{ echo "kunit.sh: expected one linux-image package in $out, found ${#found[@]}" >&2; exit 1; }
	deb=${found[0]}
fi
results=$out/kunit
timeout=${KUNIT_TIMEOUT:-900}

if ! command -v qemu-system-aarch64 > /dev/null; then
	echo "installing qemu-system-arm"
	apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -qq -y --no-install-recommends qemu-system-arm > /dev/null
fi
cross=
[[ $(uname -m) == aarch64 ]] || cross=aarch64-linux-gnu-

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dpkg-deb -x "$deb" "$work/pkg"
vmlinuz=("$work"/pkg/boot/vmlinuz-*)
release=${vmlinuz[0]##*/vmlinuz-}
moddir=$work/pkg/lib/modules/$release
[[ -f $moddir/modules.dep ]] || depmod -b "$work/pkg" "$release"

# The test modules: those that need kunit.ko, but not KUnit's helper libraries. Each comes
# after its dependencies, which modules.dep lists last first.
mapfile -t tests < <(grep -E ' kernel/lib/kunit/kunit\.ko( |$)' "$moddir/modules.dep" |
	cut -d: -f1 | grep -v '_kunit_helpers\.ko$' | sort)
[[ ${#tests[@]} -gt 0 ]] || { echo "kunit.sh: no KUnit test modules in $deb" >&2; exit 1; }
declare -A seen=()
order=()
for t in "${tests[@]}"; do
	read -r -a deps <<< "$(grep -m1 "^$t:" "$moddir/modules.dep" | cut -d: -f2)"
	for ((i = ${#deps[@]} - 1; i >= -1; i--)); do
		m=${deps[i]:-}
		[[ $i -ge 0 ]] || m=$t
		[[ -z ${seen[$m]:-} ]] || continue
		seen[$m]=1
		order+=("$m")
	done
done

root=$work/root
mkdir -p "$root/dev" "$root/debugfs" "$root/lib/modules"
for m in "${order[@]}"; do
	mkdir -p "$root/lib/modules/${m%/*}"
	cp "$moddir/$m" "$root/lib/modules/$m"
	echo "/lib/modules/$m"
done > "$root/modules"
"${cross}gcc" -O2 -Wall -Wextra -Werror -static -o "$root/init" "$here/tools/kunit-init.c"
(cd "$root" && find . | cpio -o -H newc --quiet --owner 0:0) | gzip -1 > "$work/initramfs.gz"
echo "$release: ${#tests[@]} test modules (${#order[@]} modules with their dependencies)"

# loglevel=5: warnings and worse on the console, not KUnit's own KTAP lines (info).
rm -rf "$results"
mkdir -p "$results"
status=0
timeout "$timeout" qemu-system-aarch64 \
	-machine virt,gic-version=3 -cpu max,pauth-impdef=on -smp 2 -m 2G \
	-nographic -no-reboot -nic none -serial mon:stdio \
	-kernel "${vmlinuz[0]}" -initrd "$work/initramfs.gz" \
	-append "console=ttyAMA0 loglevel=5 panic=-1" < /dev/null |
	tr -d '\r' > "$results/console.log" || status=$?
case $status in
0) ;;
124) echo "::error::QEMU timed out after ${timeout}s (KUNIT_TIMEOUT)" ;;
*) echo "::error::QEMU exited with $status" ;;
esac

# Each suite's results file, from its marker to the next.
awk -v dir="$results" '
	/^kunit-init: suite / { f = dir "/" $3 ".ktap"; next }
	/^kunit-init: / { f = ""; next }
	f { print > f }
' "$results/console.log"

fail() { echo "::error::$*"; status=1; }
grep -q '^kunit-init: done$' "$results/console.log" || fail "/init didn't finish (see $results/console.log)"
while IFS= read -r line; do fail "${line#kunit-init: error: }"; done < <(grep '^kunit-init: error: ' "$results/console.log" || true)
while IFS= read -r line; do fail "kernel: $line"; done < <(
	grep -E 'BUG:|Oops|Kernel panic|Unable to handle kernel|KASAN|kernel BUG at|UBSAN:|DMA-API:|possible (circular|recursive) locking|inconsistent lock state|suspicious RCU usage' 		"$results/console.log" || true)

suites=("$results"/*.ktap)
[[ -f ${suites[0]} ]] || suites=()
[[ ${#suites[@]} -ge ${#tests[@]} ]] || fail "${#suites[@]} suites reported for ${#tests[@]} test modules"
printf '| Suite | Passed | Skipped | Failed |\n| --- | --- | --- | --- |\n'
for f in "${suites[@]}"; do
	suite=${f##*/}
	suite=${suite%.ktap}
	# Test lines are indented; the suite's own line isn't. Parameterized cases nest deeper.
	passed=$(grep -E '^    ok [0-9]+ ' "$f" | grep -cv '# SKIP' || true)
	skipped=$(grep -cE '^    ok [0-9]+ .*# SKIP' "$f" || true)
	failed=$(grep -cE '^    not ok [0-9]+ ' "$f" || true)
	echo "| $suite | $passed | $skipped | $failed |"
	grep -qE '^(ok|not ok) [0-9]+ ' "$f" || fail "$suite: no result line"
	if grep -qE '^ *not ok ' "$f"; then
		fail "$suite: $(grep -E '^ *not ok ' "$f" | sed 's/^ *//' | paste -sd';')"
	fi
done
[[ $EUID -ne 0 ]] || chown -R --reference="$here" "$results"
[[ $status -eq 0 ]] && echo "all ${#suites[@]} KUnit suites pass ($release)"
exit "$status"
