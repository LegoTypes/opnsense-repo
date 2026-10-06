#!/usr/bin/env bash
# Releases of this repository: one per build, tagged <name>-<version> (the .pkg
# file name without .pkg) and holding that one .pkg. The notes say where it was
# built from and carry its sha256, which carry-forward.sh checks.
#   release.sh check <file.pkg>            fail if the tag exists; print the tag
#   release.sh create <file.pkg> <source> [<build>]   create the release (<source>: one line; <build>: key: value lines)
# gh takes the repository from GH_REPO and the token from GH_TOKEN (or its login).
set -euo pipefail

die() {
	echo "release.sh: $*" >&2
	exit 1
}

tag_of() {
	[[ -f $1 ]] || die "$1: no such file"
	local base
	base=$(basename "$1")
	[[ $base == *.pkg ]] || die "$1: not a .pkg"
	printf '%s\n' "${base%.pkg}"
}

# A git tag of that exact name, with or without a release, is a conflict: gh
# would attach the new release to the old tag's commit. A failed lookup fails
# the run rather than passing as "not found".
tag_exists() {
	local refs rc=0
	refs=$(gh api "repos/{owner}/{repo}/git/matching-refs/tags/$1") || die "cannot list the repository's tags"
	jq -e --arg r "refs/tags/$1" 'any(.[]; .ref == $r)' <<<"$refs" >/dev/null || rc=$?
	case $rc in
	0) return 0 ;;
	1) return 1 ;;
	*) die "unreadable tag list" ;;
	esac
}

check() {
	local tag
	tag=$(tag_of "$1")
	if tag_exists "$tag"; then
		die "release $tag already exists: bump PLUGIN_VERSION or PLUGIN_REVISION"
	fi
	printf '%s\n' "$tag"
}

create() {
	local file=$1 source=$2 build=${3:-} tag sum notes
	[[ -n $source && $source != *$'\n'* ]] || die "the source must be one non-empty line"
	tag=$(check "$file")
	sum=$(sha256sum "$file" | awk '{print $1}')
	notes=$source
	if [[ -n $build ]]; then
		[[ -s $build ]] || die "$build: no build environment"
		notes=$(printf '%s\n\n%s' "$notes" "$(cat "$build")")
	fi
	local target=()
	[[ -z ${GITHUB_SHA:-} ]] || target=(--target "$GITHUB_SHA")
	gh release create "$tag" "$file" --title "$tag" "${target[@]}" \
		--notes "$(printf '%s\n\nsha256: %s' "$notes" "$sum")"
	printf '%s\n' "$tag"
}

case ${1:-} in
check)
	[[ $# -eq 2 ]] || die "usage: release.sh check <file.pkg>"
	check "$2"
	;;
create)
	[[ $# -eq 3 || $# -eq 4 ]] || die "usage: release.sh create <file.pkg> <source> [<build>]"
	create "$2" "$3" "${4:-}"
	;;
*)
	die "usage: release.sh check <file.pkg> | release.sh create <file.pkg> <source> [<build>]"
	;;
esac
