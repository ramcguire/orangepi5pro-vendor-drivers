#!/usr/bin/env bash
# Delete main's GitHub Actions caches whose key starts with <prefix>, except <key>: once a
# newer one is saved they're superseded, and would only crowd out the others under the
# repository's cache limit.
#
#   tools/cache-prune.sh <prefix> <key>   # in CI, with GH_TOKEN allowed actions: write
set -euo pipefail

prefix=${1:?usage: cache-prune.sh <prefix> <key>}
keep=${2:?usage: cache-prune.sh <prefix> <key>}
repo=${GITHUB_REPOSITORY:?cache-prune.sh: GITHUB_REPOSITORY is not set}

gh cache list --repo "$repo" --ref refs/heads/main --key "$prefix" --limit 100 --json id,key \
	--jq ".[] | select(.key != \"$keep\") | \"\(.id) \(.key)\"" |
	while read -r id key; do
		echo "deleting superseded cache $key"
		gh cache delete --repo "$repo" "$id"
	done
