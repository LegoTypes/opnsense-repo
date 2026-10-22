#!/usr/bin/env bash
# Copyright (C) 2026 cayossarian
# plugin-source.sh <package> <dest>
# The package's directory at COMMIT (the approved commit, 40 lower-case hex digits), for
# verify-payload.sh to read; nothing in it is run. Prints the directory.
# A LegoTypes/plugins row: a blob-less clone of the row's repository into <dest>, which must
# not exist, with COMMIT checked out; COMMIT must be on the row's branch (an ancestor of its
# tip), as build-package.sh checks in the VM, so the check holds without the VM. The "." row:
# the directory as COMMIT's tree holds it, exported into <dest>, which must not exist, blob by blob
# (git ls-tree and cat-file, with --no-replace-objects: no attribute, filter, export-subst or
# refs/replace/ entry changes a byte), with each file's
# mode and symbolic links as committed; this checkout must be at COMMIT. Nothing in the working tree
# (where the build's artifact is unpacked) counts as source: a file there that the commit lacks, or
# one changed since, never reaches the check.
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

[[ ! -e $dest ]] || die "$dest exists"
if [[ $repo == . ]]; then
	head=$(git rev-parse HEAD) || die "this is not a checkout"
	[[ $head == "$COMMIT" ]] || die "this checkout is at $head, not the approved $COMMIT"
	top=$(git rev-parse --show-toplevel) || die "this is not a checkout"
	list=$(mktemp)
	trap 'rm -f "$list"' EXIT
	git --no-replace-objects -C "$top" ls-tree -r -z --full-tree "$COMMIT" -- "$dir" >"$list" ||
		die "cannot list $dir at $COMMIT"
	[[ -s $list ]] || die "the commit $COMMIT has no $dir"
	mkdir -p "$dest"
	while IFS= read -r -d '' e; do
		path=${e#*$'\t'}
		read -r mode type obj <<<"${e%%$'\t'*}"
		[[ $path == "$dir"/* ]] || die "$path is not under $dir"
		mkdir -p "$dest/${path%/*}"
		case $mode in
		100644 | 100755)
			git --no-replace-objects -C "$top" cat-file blob "$obj" >"$dest/$path" || die "cannot read $path at $COMMIT"
			chmod "${mode:3}" "$dest/$path"
			;;
		120000)
			target=$(git --no-replace-objects -C "$top" cat-file blob "$obj") || die "cannot read $path at $COMMIT"
			ln -s "$target" "$dest/$path"
			;;
		*) die "$path: a $type of mode $mode is not supported" ;;
		esac
	done <"$list"
	printf '%s\n' "$dest/$dir"
	exit 0
fi

git clone --quiet --filter=blob:none --no-checkout "https://github.com/$repo.git" "$dest" >&2
git -C "$dest" cat-file -e "$COMMIT^{commit}" 2>/dev/null || die "$repo has no commit $COMMIT"
git -C "$dest" merge-base --is-ancestor "$COMMIT" "refs/remotes/origin/$branch" ||
	die "the commit $COMMIT is not on branch $branch of $repo"
git -C "$dest" -c advice.detachedHead=false checkout --quiet "$COMMIT"
[[ $(git -C "$dest" rev-parse HEAD) == "$COMMIT" ]] || die "checked out $(git -C "$dest" rev-parse HEAD), not $COMMIT"
[[ -d $dest/$dir ]] || die "$repo has no $dir at $COMMIT"
printf '%s\n' "$dest/$dir"
