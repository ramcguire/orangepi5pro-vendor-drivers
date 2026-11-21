#!/usr/bin/env bash
# Apply every kernel patch with Armbian's own patcher (compile.sh opi5 kernel-patches-to-git):
#
#   tools/patch.sh [dir] [compile.sh parameters]
#
# Fails if our board .dts isn't Armbian's above our includes, if a patch doesn't apply, or
# if one of ours needs an offset or fuzz. Each patch becomes a commit; the result is kept
# as refs/opi5/patched in Armbian's kernel git (tools/kernel-git.sh; a build resets its branch)
# and reused while Armbian's patch hashes stay the same. Delete cache/opi5-patch.key to
# force a run.
#
# dir gets a clean shallow checkout of the result, updated in place: an O= build fails
# from Armbian's worktree, which it builds in.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
armbian=${ARMBIAN_DIR:-$here/work/armbian}
conf=$here/userpatches/config-opi5.conf
tree=
if [[ $# -gt 0 && $1 != *=* ]]; then
	tree=$1
	shift
fi
patchdirs=("$here"/userpatches/kernel/archive/rockchip64-*)
family=${patchdirs[0]##*/}
family=${family%-*}
branch=kernel-$family-$(sed -n 's/^declare -g KERNELBRANCH=tag:v\([0-9]*\.[0-9]*\).*/\1/p' "$conf")
keyfile=$armbian/cache/opi5-patch.key
ref=refs/opi5/patched

# Patching to git doesn't fail on a patch that doesn't apply: read the run's summary.
check_summary() {
	local summary f counts total applied status row name problems
	# Not written when CI=true (unless GHA_EXPORT_MD_SUMMARY=yes); the tasks don't pass CI.
	summary=
	for f in "$armbian"/output/logs/summary-kernel-patches-to-git-*.md; do
		if [[ -f $f && $f -nt $stamp ]]; then summary=$f; fi
	done
	[[ -n $summary ]] || { echo "patch.sh: no summary from Armbian in $armbian/output/logs" >&2; return 1; }

	# "kernel patching: 282 total patches; 282 applied; ..."
	counts=$(grep -o '[0-9]* total patches; [0-9]* applied' "$summary" || true)
	read -r total _ _ applied _ <<< "$counts"
	status=0
	if [[ -z $total || $total != "$applied" ]]; then
		echo "::error::Armbian applied ${applied:-?} of ${total:-?} patches (see the failed patches table above)"
		status=1
	fi
	# Rows of ours are marked `[user]`, problems `[name]`. Armbian only warns on needs_rebase
	# (offset or fuzz) and not_mbox; for ours, every problem fails.
	# shellcheck disable=SC2016 # The backticks are the summary's Markdown.
	while IFS= read -r row; do
		name=$(grep -o '`zz-[^`]*`' <<< "$row" | tr -d '`' || true)
		problems=$(grep -oE '`\[[a-z_]+\]`' <<< "$row" | tr -d '`[]' | grep -vx user | paste -sd' ' || true)
		[[ -n $problems ]] || continue
		echo "::error::${name:-a user patch}: $problems (refresh it with tools/queue.sh import and export)"
		status=1
	done < <(grep '\[user\]' "$summary" || true)

	[[ $status -eq 0 ]] || return "$status"
	echo "all $total patches apply ($(sed -n 's/^ARMBIAN_TAG=//p' "$here/build.sh"), kernel $(sed -n 's/^declare -g KERNELBRANCH=tag://p' "$conf"))"
}

# A dt/ file replaces Armbian's whole, so ours must stay Armbian's file up to our marker.
check_dt() {
	local ours theirs marker status=0
	for ours in "$here"/userpatches/kernel/archive/*/dt/*.dts; do
		marker=$(grep -n "^ \* opi5: Armbian's file up to here" "$ours" | cut -d: -f1 || true)
		[[ -n $marker ]] || continue
		theirs=$armbian/patch/kernel/archive/${ours#"$here"/userpatches/kernel/archive/}
		# The marker's comment starts 2 lines up, after a blank line.
		if ! diff -u --label "armbian/${theirs#"$armbian"/}" --label "ours (to the opi5 marker)" \
			"$theirs" <(head -n "$((marker - 3))" "$ours"); then
			echo "::error::${ours#"$here"/} differs from Armbian's above the opi5 marker: take Armbian's and keep our includes"
			status=1
		fi
	done
	return "$status"
}

bash "$here/tools/armbian.sh" "$armbian"
check_dt
rm -rf "$armbian/userpatches"
cp -R "$here/userpatches" "$armbian/userpatches"

# The key: hashes from Armbian's kernel artifact version (kernel revision, driver patches,
# every patch file).
dump=$(mktemp)
trap 'rm -f "$dump"' EXIT
(cd "$armbian" && ./compile.sh opi5 artifact-config-dump-json WHAT=kernel "$@") > "$dump" 2> "$dump.log" ||
	{ cat "$dump.log" >&2; rm -f "$dump.log"; exit 1; }
rm -f "$dump.log"
key=$(grep -oE '(git revision|drivers hash|patches hash) \\"[^\\]*\\"' "$dump" | tr -d '\\"' | paste -sd' ')
[[ $key == "git revision "*" drivers hash "*" patches hash "* ]] ||
	{ echo "patch.sh: no patch hashes in Armbian's artifact version: $(head -c 500 "$dump")" >&2; exit 1; }
# No worktree yet (a fresh cache): no tip, so it runs.
bare=$(bash "$here/tools/kernel-git.sh" "$armbian" 2> /dev/null || true)
tip=
if [[ -n $bare ]]; then tip=$(git -C "$bare" rev-parse -q --verify "$ref" 2> /dev/null || true); fi
if [[ -n $tip && -f $keyfile && $(head -n1 "$keyfile") == "$tip $key" ]]; then
	tail -n +2 "$keyfile"
	echo "(cached: same $key as the last passing run; delete $keyfile to rerun it)"
else
	rm -f "$keyfile"
	stamp=$(mktemp)
	messages=$(mktemp)
	trap 'rm -f "$dump" "$stamp" "$messages"' EXIT
	(cd "$armbian" && ./compile.sh opi5 kernel-patches-to-git "$@")
	bare=$(bash "$here/tools/kernel-git.sh" "$armbian")
	# For tools/bump-report.sh, which reads a failed run too.
	git -C "$bare" update-ref refs/opi5/attempt "refs/heads/$branch"
	status=0
	check_summary > "$messages" || status=$?
	cat "$messages"
	[[ $status -eq 0 ]] || exit "$status"
	{
		git -C "$bare" update-ref "$ref" "refs/heads/$branch"
		echo "$(git -C "$bare" rev-parse "$ref") $key"
		cat "$messages"
	} > "$keyfile"
fi

if [[ -n $tree ]]; then
	[[ -d $tree/.git ]] || git init -q "$tree"
	# Git drops the GIT_CONFIG_* safe.directory setting for the other end of a local fetch.
	git -C "$tree" fetch -q --depth=1 --upload-pack="git -c safe.directory=* upload-pack" \
		"file://$bare" "$ref"
	git -C "$tree" -c advice.detachedHead=false checkout -q --force --detach FETCH_HEAD
	git -C "$tree" clean -q -fdx
	echo "$branch (as $ref) in $tree"
fi
