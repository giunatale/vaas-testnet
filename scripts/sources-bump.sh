#!/usr/bin/env bash
# sources-bump.sh FILE: sets each <X>_REF in FILE to the head of <X>_BRANCH
# on <X>_REPO, for every source with a repository. Prints what moved.
set -euo pipefail
file=$1
for name in $(sed -n 's/^\([A-Z]*\)_REPO=.\{1,\}$/\1/p' "$file"); do
	repo=$(sed -n "s/^${name}_REPO=//p" "$file")
	branch=$(sed -n "s/^${name}_BRANCH=//p" "$file")
	old=$(sed -n "s/^${name}_REF=//p" "$file")
	new=$(git ls-remote "$repo" "refs/heads/$branch" | cut -f1)
	[ -n "$new" ] || { echo "$name: no branch $branch on $repo" >&2; exit 1; }
	if [ "$new" != "$old" ]; then
		sed -i.bak "s/^${name}_REF=.*/${name}_REF=$new/" "$file" && rm -f "$file.bak"
		echo "$name: ${old:0:8} -> ${new:0:8} ($branch)"
	else
		echo "$name: ${new:0:8} ($branch), unchanged"
	fi
done
