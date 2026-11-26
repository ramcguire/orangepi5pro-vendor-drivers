#!/usr/bin/env bash
# Edit the zz-opi5-* patches as git commits.
#
#   tools/queue.sh import [dir]  # Armbian's patched kernel up to ours (tag opi5-base), then ours;
#                                # replaces a queue only if it's all in userpatches/
#   tools/queue.sh export [dir]  # opi5-base.. back into userpatches/
#   tools/queue.sh check [dir]   # fails unless the queue matches userpatches/
#
# dir defaults to work/kernel. Export maps commits to files by position, so the counts must
# match: to add a patch, put it in userpatches/ as zz-opi5-<n>-<name>.patch and re-import.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tree=${2:-$here/work/kernel}
armbian=${ARMBIAN_DIR:-$here/work/armbian}
patchdirs=("$here"/userpatches/kernel/archive/rockchip64-*)
[[ ${#patchdirs[@]} -eq 1 ]] || { echo "queue.sh: expected one rockchip64-* patch dir" >&2; exit 1; }
patchdir=${patchdirs[0]}

# The queue's commits as patch files, in $1.
format_patches() {
	git -C "$tree" format-patch -q -N --zero-commit --no-signature --abbrev=12 -o "$1" opi5-base..
}

# Whether the queue in $tree has nothing userpatches/ doesn't: no uncommitted changes (but
# the dt/ files modules.sh copies in) and every commit byte-identical to its patch file.
in_userpatches() {
	local out f status=0
	local -a old new skip=()
	git -C "$tree" rev-parse -q --verify opi5-base > /dev/null || return 1
	for f in "$patchdir"/dt/*; do
		skip+=(":!arch/arm64/boot/dts/rockchip/${f##*/}")
	done
	[[ -z $(git -C "$tree" status --porcelain -- . "${skip[@]}") ]] || return 1
	out=$(mktemp -d)
	format_patches "$out"
	old=("$patchdir"/zz-opi5-*.patch)
	new=("$out"/*.patch)
	if [[ ${#new[@]} -ne ${#old[@]} ]]; then
		status=1
	else
		for f in "${!new[@]}"; do
			cmp -s "${new[f]}" "${old[f]}" || { status=1; break; }
		done
	fi
	rm -rf "$out"
	return "$status"
}

import() {
	local bare ref log ours f
	local -a dt
	if [[ -e $tree ]] && ! in_userpatches; then
		echo "queue.sh: $tree has changes or commits not in userpatches/: export them, or delete it" >&2
		exit 1
	fi

	ARMBIAN_DIR=$armbian bash "$here/tools/patch.sh"
	rm -rf "$tree"
	bare=$(bash "$here/tools/kernel-git.sh" "$armbian")
	ref=refs/opi5/patched

	# Newest first: the device tree commits, ours, then Armbian's. ours is the depth of our
	# oldest commit.
	log=$(git -C "$bare" log --max-count=2000 --format='%H %s' "$ref")
	ours=$(awk '$2 ~ /^zz-opi5-/ { n = NR } END { print n + 0 }' <<< "$log")
	[[ $ours -gt 0 ]] || { echo "queue.sh: no zz-opi5 commits in $ref" >&2; exit 1; }
	mapfile -t dt < <(awk '$2 ~ /^zz-opi5-/ { exit } / Armbian (Bare Device Tree|automatic DT Makefile)/ { print $1 }' <<< "$log" | tac)

	git init -q "$tree"
	# Git drops the GIT_CONFIG_* safe.directory setting for the other end of a local fetch.
	git -C "$tree" fetch -q --depth=$((ours + 1)) --upload-pack="git -c safe.directory=* upload-pack" \
		"file://$bare" "$ref"
	git -C "$tree" config user.name opi5
	git -C "$tree" config user.email noreply@example.invalid
	git -C "$tree" checkout -q -b opi5 "FETCH_HEAD~$ours"
	git -C "$tree" cherry-pick --allow-empty "${dt[@]}" > /dev/null
	git -C "$tree" tag opi5-base
	# From the files: Armbian's commits of them have rewritten messages.
	for f in "$patchdir"/zz-opi5-*.patch; do
		git -C "$tree" am -q -3 "$f"
	done
	echo "$tree: $(git -C "$tree" rev-list --count opi5-base..) patches on opi5-base"
}

export_() {
	local -a old new
	local out i
	old=("$patchdir"/zz-opi5-*.patch)
	out=$(mktemp -d)
	format_patches "$out"
	new=("$out"/*.patch)
	[[ ${#new[@]} -eq ${#old[@]} ]] || {
		echo "queue.sh: ${#new[@]} commits but ${#old[@]} patch files (see tools/queue.sh)" >&2
		exit 1
	}
	rm "${old[@]}"
	for i in "${!new[@]}"; do
		# zz-opi5-<n>- from the old name, the rest from format-patch's.
		mv "${new[i]}" "$patchdir/$(cut -d- -f1-3 <<< "${old[i]##*/}")-$(cut -d- -f2- <<< "${new[i]##*/}")"
	done
	rmdir "$out"
	# As root in a container, give the files back to the repository's owner.
	if [[ $EUID -eq 0 ]]; then
		chown --reference="$patchdir" "$patchdir"/zz-opi5-*.patch
	fi
}

case ${1:-} in
import) import ;;
export) export_ ;;
check)
	in_userpatches || {
		echo "queue.sh: $tree differs from userpatches/" >&2
		exit 1
	}
	;;
*) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
