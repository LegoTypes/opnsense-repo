#!/usr/bin/env bash
# Copyright (C) 2026 cayossarian
# plugin-source.sh <package> <dest>
# The package's directory at COMMIT (the approved commit, 40 lower-case hex digits), for
# verify-payload.sh to read; nothing in it is run. Prints the directory.
# A LegoTypes/plugins row: a blob-less clone of the row's repository into <dest>, which must
# not exist, with COMMIT checked out; COMMIT must be on the row's branch (an ancestor of its
# tip), as build-package.sh checks in the VM, so the check holds without the VM. The "." row:
# this checkout, which must be at COMMIT; <dest> is not used.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

die() {
	echo "plugin-source.sh: $*" >&2
	exit 1
}

[[ $# -eq 2 ]] || die "usage: plugin-source.sh <package> <dest>"
pkg=$1 dest=$2
[[ ${COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || die "COMMIT must be the approved commit, 40 lower-case hex digits"
row=$(sh "$here/packages.sh" row "$pkg")
read -r repo branch dir _ <<<"$row"

if [[ $repo == . ]]; then
	head=$(git rev-parse HEAD) || die "this is not a checkout"
	[[ $head == "$COMMIT" ]] || die "this checkout is at $head, not the approved $COMMIT"
	[[ -d $dir ]] || die "this checkout has no $dir"
	printf '%s\n' "$dir"
	exit 0
fi

[[ ! -e $dest ]] || die "$dest exists"
git clone --quiet --filter=blob:none --no-checkout "https://github.com/$repo.git" "$dest" >&2
git -C "$dest" cat-file -e "$COMMIT^{commit}" 2>/dev/null || die "$repo has no commit $COMMIT"
git -C "$dest" merge-base --is-ancestor "$COMMIT" "refs/remotes/origin/$branch" ||
	die "the commit $COMMIT is not on branch $branch of $repo"
git -C "$dest" -c advice.detachedHead=false checkout --quiet "$COMMIT"
[[ $(git -C "$dest" rev-parse HEAD) == "$COMMIT" ]] || die "checked out $(git -C "$dest" rev-parse HEAD), not $COMMIT"
[[ -d $dest/$dir ]] || die "$repo has no $dir at $COMMIT"
printf '%s\n' "$dest/$dir"
