#!/usr/bin/env bash
# Print the kernel git repository of Armbian's kernel worktree, the one its last kernel run
# patched in:
#
#   tools/kernel-git.sh <armbian dir>
#
# Armbian keeps either cache/git-bare/kernel (full history) or, with KERNEL_GIT=shallow as
# in CI, cache/git-bare/shallow-kernel-<x.y>, and keeps using the one the worktree has.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
armbian=${1:?usage: kernel-git.sh <armbian dir>}
patchdirs=("$here"/userpatches/kernel/archive/rockchip64-*)
family=${patchdirs[0]##*/}
family=${family%-*}
version=$(sed -n 's/^declare -g KERNELBRANCH=tag:v\([0-9]*\.[0-9]*\).*/\1/p' "$here/userpatches/config-opi5.conf")
# Armbian's LINUXSOURCEDIR: <major.minor>__<family>__<arch>.
worktree=$armbian/cache/sources/linux-kernel-worktree/${version}__${family}__arm64
[[ -e $worktree/.git ]] || { echo "kernel-git.sh: no Armbian kernel worktree at $worktree" >&2; exit 1; }
git -C "$worktree" rev-parse --path-format=absolute --git-common-dir
