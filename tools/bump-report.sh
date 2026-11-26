#!/usr/bin/env bash
# A Markdown report for an Armbian or kernel bump, after tools/patch.sh (mise run check):
#
#   tools/bump-report.sh [build] [--update]   # build: modules.sh's O= tree, default work/check-build
#
# 1. Armbian patches that didn't apply, and whether each is already in the kernel (it
#    reverse-applies there): then the kernel ran ahead of Armbian's tag.
# 2. Armbian patches that touch files ours touch.
# 3. New commits in the vendor sources since the pins in our patches' Origin: lines, limited
#    to the files we import where the source has them.
# 4. The kernel config's MPP/RGA/NPU, IOMMU, devfreq and lockup-detector symbols against
#    tools/config-baseline.txt; --update rewrites that file from build/.config.
#
# Reads Armbian's last patching run (refs/opi5/attempt, kept by patch.sh, failed or not).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
armbian=${ARMBIAN_DIR:-$here/work/armbian}
conf=$here/userpatches/config-opi5.conf
baseline=$here/tools/config-baseline.txt
build=$here/work/check-build
update=
for arg; do
	case $arg in
		--update) update=1 ;;
		*) build=$arg ;;
	esac
done
patchdirs=("$here"/userpatches/kernel/archive/rockchip64-*)
dir=${patchdirs[0]##*/}
kernel=$(sed -n 's/^declare -g KERNELBRANCH=tag:v//p' "$conf")
bare=$(bash "$here/tools/kernel-git.sh" "$armbian" 2> /dev/null || true)
# The symbols whose drift matters for our drivers and for hangs.
symbols='ROCKCHIP|RK_|RKNPU|RGA|MPP|IOMMU|DEVFREQ|DMA_HEAP|DMABUF|LOCKUP|HUNG_TASK|WQ_WATCHDOG|RCU_CPU_STALL'

config_symbols() {
	grep -E "^(# )?CONFIG_[A-Z0-9_]*($symbols)[A-Z0-9_]*[= ]" "$1" | LC_ALL=C sort
}

if [[ -n $update ]]; then
	[[ -f $build/.config ]] || { echo "bump-report.sh: no $build/.config; run mise run check first" >&2; exit 1; }
	config_symbols "$build/.config" > "$baseline"
	[[ $EUID -ne 0 ]] || chown --reference="$here" "$baseline"
	echo "$(wc -l < "$baseline") symbols from $build/.config in ${baseline#"$here"/}"
	exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "## Bump report: Armbian $(sed -n 's/^ARMBIAN_TAG=//p' "$here/build.sh"), kernel $kernel"
echo

ref=
for r in refs/opi5/attempt refs/opi5/patched; do
	if [[ -n $bare ]] && git -C "$bare" rev-parse -q --verify "$r" > /dev/null 2>&1; then ref=$r; break; fi
done
base=
if [[ -n $ref ]]; then
	# The kernel's own release commit, under Armbian's patches. awk reads it all: an early exit
	# would fail git log under pipefail.
	base=$(git -C "$bare" log --format='%H %s' -n 2000 "$ref" | awk -v v="$kernel" '!b && $2 == "Linux" && $3 == v { b = $1 } END { print b }')
fi
if [[ -z $base ]]; then
	echo "No patching run of Linux $kernel in Armbian's kernel git (${bare:-no worktree yet}): run \`mise run check\` first. Sections 1 and 2 skipped."
	echo
else
	# One line per file each patch commit touches: user or core, the patch, the file.
	git -C "$bare" log --reverse --format='>>>opi5 %s%n%b%n<<<opi5' --name-only "$base..$ref" | awk '
		/^>>>opi5 / { name = substr($0, 9); sub(/\(:[0-9]+\)$/, "", name); root = "core"; body = 1; next }
		/^<<<opi5$/ { body = 0; next }
		body && /^X-Armbian: Patch-File: / { name = substr($0, 24) }
		body && /^X-Armbian: Patch-Root-Type: / { root = substr($0, 29) }
		!body && NF { print root "\t" name "\t" $0 }' > "$tmp/touched"

	echo "### 1. Patches that didn't apply"
	echo
	# Armbian's summary in the tree: | status | `name` | diffstat | files | author |. A patch
	# that applied, even with an offset, has a commit.
	git -C "$bare" show "$ref:README.md" > "$tmp/summary.md" 2> /dev/null || : > "$tmp/summary.md"
	cut -f2 "$tmp/touched" | sed 's|.*/||' | LC_ALL=C sort -u > "$tmp/applied"
	# shellcheck disable=SC2016 # The backticks are the summary's Markdown.
	awk -F'|' 'NF > 5 && $3 ~ /`/ { n = split($3, p, "`"); s = $2; gsub(/^ +| +$/, "", s); print p[n - 1] "\t" s }' \
		"$tmp/summary.md" | LC_ALL=C sort -t$'\t' -k1,1 | LC_ALL=C join -t$'\t' -v1 - "$tmp/applied" > "$tmp/failed"
	if [[ ! -s $tmp/summary.md ]]; then
		echo "No summary in $ref."
	elif [[ ! -s $tmp/failed ]]; then
		echo "None: $(grep -o '[0-9]* total patches; [0-9]* applied' "$tmp/summary.md" | head -1)."
	else
		GIT_INDEX_FILE=$tmp/index git -C "$bare" read-tree "$base"
		echo "| Patch | Status | In Linux $kernel already? |"
		echo "| --- | --- | --- |"
		while IFS=$'\t' read -r name status; do
			file=
			for d in "$here/userpatches/kernel/archive/$dir" "$armbian/patch/kernel/archive/$dir"; do
				if [[ -f $d/$name.patch ]]; then file=$d/$name.patch; break; fi
			done
			if [[ -z $file ]]; then
				upstream="? (no $name.patch)"
			elif GIT_INDEX_FILE=$tmp/index git -C "$bare" apply --cached --check -R "$file" 2> /dev/null; then
				upstream="**yes**: it reverse-applies, so the kernel is ahead of this Armbian tag"
			else
				upstream="no"
			fi
			echo "| \`$name\` | $status | $upstream |"
		done < "$tmp/failed"
	fi
	echo

	echo "### 2. Armbian patches touching our files"
	echo
	# Armbian's own commits (the summary, DT files) aren't patches; kernel-drivers is its
	# driver patches in one commit.
	# shellcheck disable=SC2016 # Markdown backticks.
	awk -F'\t' '
		$2 ~ /kernel-drivers\// { $2 = "kernel-drivers" }
		$2 ~ /^Armbian / { next }
		$1 == "user" { ours[$3] = ours[$3] (ours[$3] ? ", " : "") "`" $2 "`"; next }
		{ theirs[$3] = theirs[$3] (theirs[$3] ? ", " : "") "`" $2 "`" }
		END { for (f in ours) if (f in theirs) print "| `" f "` | " ours[f] " | " theirs[f] " |" }' \
		"$tmp/touched" | LC_ALL=C sort > "$tmp/overlap"
	if [[ -s $tmp/overlap ]]; then
		echo "Check that ours still fit next to theirs (a clean apply can still clash in meaning)."
		echo
		echo "| File | Ours | Armbian's |"
		echo "| --- | --- | --- |"
		cat "$tmp/overlap"
	else
		echo "None."
	fi
	echo
fi

echo "### 3. Vendor sources since our pins"
echo
# Origin: <url> <pin> [(<branch>)], and the files each patch adds or changes.
for f in "$here/userpatches/kernel/archive/$dir"/*.patch; do
	origin=$(grep -m1 -oE '^Origin: https://github\.com/[^ ]+ [0-9a-f]{7,40}( \([^)]+\))?' "$f") || continue
	sed -n 's|^+++ b/||p' "$f" | sed "s|^|${origin#Origin: }\t|"
done | LC_ALL=C sort -u > "$tmp/origins"
cut -f1 "$tmp/origins" | LC_ALL=C sort -u | while read -r url pin branch; do
	branch=${branch#(}
	branch=${branch%)}
	name=${url#https://github.com/}
	repo=$tmp/repo-${name//\//-}
	if [[ -n $branch ]]; then
		# A whole kernel: commits and trees from before the pin only. Commit dates there are out
		# of order, so from 90 days before its author date.
		since=$(curl -fsSL --retry 3 "https://api.github.com/repos/$name/commits/$pin" |
			grep -oE '"date": *"[^"]+"' | sed -n '1s/.*"\([^"]*\)"$/\1/p') || true
		[[ -n $since ]] || { echo "- $url: no date for \`$pin\`"; continue; }
		args=(--filter=blob:none --single-branch --branch "$branch" --shallow-since="$(date -ud "@$(($(date -ud "$since" +%s) - 90 * 86400))" +%F)")
	else
		args=(--filter=tree:0)
	fi
	if ! git clone -q --bare "${args[@]}" "$url" "$repo" 2> "$tmp/clone.log"; then
		echo "- $url: clone failed: $(tail -n1 "$tmp/clone.log")"
		continue
	fi
	head=$(git -C "$repo" rev-parse --short=12 HEAD)
	if ! git -C "$repo" rev-parse -q --verify "$pin^{commit}" > /dev/null; then
		echo "- $url: pin \`$pin\` not found (head \`$head\`)"
		continue
	fi
	# Our files at the source's paths (the vendor kernel keeps them in drivers/video/rockchip/).
	mapfile -t paths < <(awk -F'\t' -v o="$url $pin${branch:+ ($branch)}" '$1 == o { print $2 }' "$tmp/origins" |
		sed -e 's|^drivers/media/platform/rockchip/rga/rga3/|drivers/video/rockchip/rga3/|' \
			-e 's|^drivers/media/platform/rockchip/mpp/|drivers/video/rockchip/mpp/|' |
		grep -vE '(^|/)(Kconfig|Makefile|Kbuild)$' |
		xargs -r git -C "$repo" ls-tree -r --name-only "$pin" -- || true)
	count=$(git -C "$repo" rev-list --count "$pin..HEAD" -- "${paths[@]}")
	scope="all files"
	[[ ${#paths[@]} -eq 0 ]] || scope="${#paths[@]} of our files"
	echo "- [$name]($url)${branch:+ \`$branch\`}: $count new since \`$pin\` in $scope (head \`$head\`)"
	git -C "$repo" log --format="  - [\`%h\`]($url/commit/%H) %as %s" "$pin..HEAD" -- "${paths[@]}"
done
[[ -s $tmp/origins ]] || echo "No Origin: lines in our patches."
echo
echo "Mark each new commit applied or not applicable on the pull request."
echo

echo "### 4. Config drift"
echo
if [[ ! -f $build/.config ]]; then
	echo "No $build/.config (\`check\` didn't get to compile the drivers)."
elif [[ ! -f $baseline ]]; then
	echo "No ${baseline#"$here"/}: create it with \`mise run bump-report -- --update\`."
else
	config_symbols "$build/.config" > "$tmp/config"
	# diff exits 1 on a difference: not a failure here.
	diff -U0 "$baseline" "$tmp/config" > "$tmp/drift" || true
	if [[ -s $tmp/drift ]]; then
		echo "Against ${baseline#"$here"/} (\`-\` baseline, \`+\` this build). Explain each line, then refresh it with \`mise run bump-report -- --update\`:"
		echo
		echo '```diff'
		tail -n +3 "$tmp/drift" | grep -v "^@@"
		echo '```'
	else
		echo "No change in the $(wc -l < "$tmp/config") tracked symbols."
	fi
fi
