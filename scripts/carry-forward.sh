#!/usr/bin/env bash
# Put the current release of every catalogue package except <built> into <dir>,
# byte for byte, so a publish rebuilds only the package it was run for.
# "Current" is the newest release tagged <package>-<version>; its .pkg must match
# the sha256 its notes record (release.sh create writes it).
#   carry-forward.sh <built-package> <dir>
# gh takes the repository from GH_REPO and the token from GH_TOKEN (or its login).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

die() {
	echo "carry-forward.sh: $*" >&2
	exit 1
}

[[ $# -eq 2 ]] || die "usage: carry-forward.sh <built-package> <dir>"
built=$1 dir=$2

catalogue=$(sh "$here/packages.sh" catalogue) || die "cannot read the catalogue"
grep -qxF -- "$built" <<<"$catalogue" || die "$built is not a catalogue package"
releases=$(gh release list --limit 1000 --json tagName,createdAt) || die "cannot list releases"
mkdir -p "$dir"

while read -r pkg <&3; do
	[[ $pkg != "$built" ]] || continue
	# package names never contain "-<digit>" (packages.sh), so this matches
	# only this package's own tags
	tag=$(jq -r --arg p "$pkg" \
		'[.[] | select(.tagName | test("^" + $p + "-[0-9]"))] | sort_by(.createdAt) | last | .tagName // empty' \
		<<<"$releases")
	[[ -n $tag ]] || die "$pkg has no release to carry forward"
	want=$(gh release view "$tag" --json body --jq .body | tr -d '\r' |
		sed -n 's/^sha256: \([0-9a-f]\{64\}\)$/\1/p')
	[[ -n $want && $want != *$'\n'* ]] || die "release $tag does not record exactly one sha256"
	tmp=$(mktemp -d)
	gh release download "$tag" --pattern "$tag.pkg" --dir "$tmp" || die "cannot download $tag.pkg"
	got=$(sha256sum "$tmp/$tag.pkg" | awk '{print $1}')
	[[ $got == "$want" ]] || die "$tag.pkg has sha256 $got; its release notes say $want"
	mv "$tmp/$tag.pkg" "$dir/"
	rmdir "$tmp"
	echo "carried forward $tag"
done 3<<<"$catalogue"
