#!/usr/bin/env bash
# The drivers' version: v6.18.63-1 gives 6.18.63.1, then +<n>.g<commit>[.dirty]. Without
# tags, 0+g<commit>; without git, 0. $GIT_DESCRIBE replaces git describe (e.g. a tag to be).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
describe=${GIT_DESCRIBE:-$(git -C "$here" -c safe.directory="$here" describe --tags --match 'v*' --dirty 2> /dev/null || true)}
re='^v([0-9.]+)-([0-9]+)(-([0-9]+)-g([0-9a-f]+))?(-dirty)?$'
if [[ $describe =~ $re ]]; then
	version=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}
	extra=()
	[[ -n ${BASH_REMATCH[3]} ]] && extra+=("${BASH_REMATCH[4]}" "g${BASH_REMATCH[5]}")
	[[ -n ${BASH_REMATCH[6]} ]] && extra+=(dirty)
	if [[ ${#extra[@]} -gt 0 ]]; then
		version+=+$(IFS=.; echo "${extra[*]}")
	fi
elif commit=$(git -C "$here" -c safe.directory="$here" rev-parse --short=12 HEAD 2> /dev/null); then
	version=0+g$commit
else
	version=0
fi
echo "$version"
