#!/usr/bin/env bash
# newest-release.sh <package> [<ABI>/<series>]
# The tag of the package's newest release by publish time (createdAt is the
# date of the tagged commit, which two publishes from one commit share), or
# nothing when it has none. With an <ABI>/<series> entry, only releases built for
# it count: the "abi:" and "series:" lines of the notes, and FreeBSD:15:amd64 and
# 26.7 for releases from before those lines existed (all were built for them). RELEASES_JSON may hold the output of
# "gh release list --json tagName,publishedAt" so a caller lists only once.
# gh takes the repository from GH_REPO and the token from GH_TOKEN (or its login).
set -euo pipefail

die() {
	echo "newest-release.sh: $*" >&2
	exit 1
}

[[ $# -eq 1 || $# -eq 2 ]] || die "usage: newest-release.sh <package> [<ABI>/<series>]"
pkg=$1 want=${2:-}
legacy_abi=FreeBSD:15:amd64 legacy_series=26.7
[[ -z $want || $want == */* ]] || die "$want is not <ABI>/<series>"
releases=${RELEASES_JSON:-}
if [[ -z $releases ]]; then
	releases=$(gh release list --limit 1000 --json tagName,publishedAt) || die "cannot list releases"
fi
# Package names never contain "-<digit>" (packages.sh), so this matches only that package's tags.
tags=$(jq -r --arg p "$pkg" \
	'[.[] | select(.tagName | test("^" + $p + "-[0-9]"))] | sort_by(.publishedAt) | reverse | .[].tagName' \
	<<<"$releases") || die "unreadable release list"
for tag in $tags; do
	if [[ -z $want ]]; then
		printf '%s\n' "$tag"
		exit 0
	fi
	notes=$(gh release view "$tag" --json body --jq .body) || die "cannot read the notes of $tag"
	series=$(tr -d '\r' <<<"$notes" | sed -n 's/^series: \([0-9][0-9]*\.[0-9][0-9]*\)$/\1/p')
	abi=$(tr -d '\r' <<<"$notes" | sed -n 's/^abi: \(FreeBSD:[0-9][0-9]*:[a-z0-9_]*\)$/\1/p')
	[[ $series != *$'\n'* && $abi != *$'\n'* ]] || die "$tag records more than one series or ABI"
	if [[ ${abi:-$legacy_abi}/${series:-$legacy_series} == "$want" ]]; then
		printf '%s\n' "$tag"
		exit 0
	fi
done
