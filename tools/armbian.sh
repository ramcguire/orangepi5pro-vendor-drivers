#!/usr/bin/env bash
# Check out armbian/build at build.sh's ARMBIAN_COMMIT, keeping local changes:
#
#   tools/armbian.sh <dir>
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dir=${1:?usage: armbian.sh <dir>}
url=$(sed -n 's/^ARMBIAN_URL=//p' "$here/build.sh")
commit=$(sed -n 's/^ARMBIAN_COMMIT=//p' "$here/build.sh")

if [[ ! -d $dir/.git ]]; then
	# cache/ may be there already: CI restores ccache into it.
	shopt -s nullglob dotglob
	for entry in "$dir"/*; do
		if [[ ${entry##*/} != cache ]]; then
			echo "armbian.sh: $dir is not empty and not a git checkout; remove it (mise run clean)" >&2
			exit 1
		fi
	done
	shopt -u nullglob dotglob
	mkdir -p "$dir"
	git -C "$dir" init -q
fi
# Armbian records origin's URL in its build info.
git -C "$dir" remote get-url origin > /dev/null 2>&1 || git -C "$dir" remote add origin "$url"
if ! git -C "$dir" cat-file -e "$commit^{commit}" 2> /dev/null; then
	git -C "$dir" fetch -q --depth=1 origin "$commit"
fi
git -C "$dir" checkout -q --detach "$commit"
