#!/usr/bin/env bash
# Put the current release of every catalogue package except <built> into <dir>,
# byte for byte, so a publish rebuilds only the package it was run for.
# "Current" is the newest release tagged <package>-<version>; its .pkg must match
# the sha256 its notes record (release.sh create writes it).
#   carry-forward.sh <built-package> <dir>
# LIVE_PACKAGES_TXT is the URL of the live catalogue's packages.txt. gh takes the
# repository from GH_REPO and the token from GH_TOKEN (or its login).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

die() {
	echo "carry-forward.sh: $*" >&2
	exit 1
}

[[ $# -eq 2 ]] || die "usage: carry-forward.sh <built-package> <dir>"
built=$1 dir=$2
[[ -n ${LIVE_PACKAGES_TXT:-} ]] || die "LIVE_PACKAGES_TXT must name the live catalogue's packages.txt"

catalogue=$(sh "$here/packages.sh" catalogue) || die "cannot read the catalogue"
grep -qxF -- "$built" <<<"$catalogue" || die "$built is not a catalogue package"
releases=$(gh release list --limit 1000 --json tagName,publishedAt) || die "cannot list releases"
live=$(curl -fsSL "$LIVE_PACKAGES_TXT") || die "cannot read the live catalogue at $LIVE_PACKAGES_TXT"

# the newest release tag of a package, by when it was published: createdAt is the date of the tagged
# commit, which two publishes from one commit share. Package names never contain "-<digit>"
# (packages.sh), so this matches only that package's own tags
newest() {
	jq -r --arg p "$1" \
		'[.[] | select(.tagName | test("^" + $p + "-[0-9]"))] | sort_by(.publishedAt) | last | .tagName // empty' \
		<<<"$releases"
}

# Before anything is carried, the live catalogue must serve exactly each
# package's newest release. It does not when a publish deployed a build and its
# release job then failed: carrying the previous release would silently roll
# that package back. Recover by re-running that publish's failed jobs (its
# artifact still holds the deployed build), never by publishing again.
while read -r pkg <&3; do
	tag=$(newest "$pkg")
	served=$(awk -v p="$pkg" '$1 == "Name" && $3 == p { getline; if ($1 == "Version") print $3 }' <<<"$live")
	[[ -n $tag || -n $served ]] || continue # new: neither released nor live yet
	[[ -n $tag && $served == "${tag#"$pkg"-}" ]] ||
		die "the live catalogue serves $pkg ${served:-(nothing)} but its newest release is ${tag:-(none)}: re-run the failed jobs of the publish that deployed it; do not publish again"
done 3<<<"$catalogue"

mkdir -p "$dir"
while read -r pkg <&3; do
	[[ $pkg != "$built" ]] || continue
	tag=$(newest "$pkg")
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
