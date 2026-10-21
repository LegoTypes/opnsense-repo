#!/usr/bin/env bash
# Copyright (C) 2026 cayossarian
# carry-plan.sh <built-package>
# What carry-forward.sh will carry, one "carry" line per package and served tree:
#   carry <ABI>/<series> <tag> <sha256 the release notes record> immutable=yes|no
# The one place that decides it, so the manifest the approver reads (manifest.sh)
# and the carrying at signing time (carry-forward.sh) cannot differ in what they
# select. For each served tree, the current release of each catalogue package
# for that tree is the newest (newest-release.sh) and must be what the live
# site's packages.txt lists, or carrying forward would silently roll a package
# back. <built> is not carried into the target tree, which the build adds. With
# one tree served, the target needs every catalogue package; while a series or
# ABI change serves two, the new target holds what has been released for it so
# far, so its first publish can succeed. Nothing is downloaded.
# LIVE_SITE is the live site's base URL.
# gh takes the repository from GH_REPO and the token from GH_TOKEN (or its login).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

die() {
	echo "carry-plan.sh: $*" >&2
	exit 1
}

[[ $# -eq 1 ]] || die "usage: carry-plan.sh <built-package>"
built=$1
[[ -n ${LIVE_SITE:-} ]] || die "LIVE_SITE must name the live site's base URL"

catalogue=$(sh "$here/packages.sh" catalogue) || die "cannot read the catalogue"
grep -qxF -- "$built" <<<"$catalogue" || die "$built is not a catalogue package"
target=$(sh "$here/repo.sh" target)
served=$(sh "$here/repo.sh" serve) || die "cannot read the served trees"
count=$(wc -l <<<"$served")
releases=$(gh release list --limit 1000 --json tagName,publishedAt) || die "cannot list releases"

for entry in $served; do
	tree=$(sh "$here/repo.sh" tree "$entry")
	# what that tree serves now: nothing yet (404) for a tree being added; any other
	# answer than 200 or 404 means the site cannot be read, which is not "empty"
	url="$LIVE_SITE/${tree#site/}/packages.txt"
	livef=$(mktemp)
	code=$(curl -sSL -o "$livef" -w '%{http_code}' "$url") || die "cannot reach $url"
	case $code in
	200) live=$(cat "$livef") ;;
	404) live='' ;;
	*) die "cannot read $url (HTTP $code): the site may be down; run the publish again later" ;;
	esac
	rm -f "$livef"
	while read -r pkg <&3; do
		tag=$(RELEASES_JSON="$releases" bash "$here/newest-release.sh" "$pkg" "$entry")
		live_version=$(awk -v p="$pkg" '$1 == "Name" && $3 == p { getline; if ($1 == "Version") print $3 }' <<<"$live")
		[[ -n $tag || -n $live_version ]] || continue # neither released nor live for this tree
		[[ -n $tag && $live_version == "${tag#"$pkg"-}" ]] ||
			die "$entry serves $pkg ${live_version:-(nothing)} but its newest release for $entry is ${tag:-(none)}: if a publish deployed in the last 10 minutes, this can be the site's cache (Pages caches each file for up to 10 minutes): wait, then re-run this run's failed jobs; otherwise the publish that deployed it has no release yet: re-run its failed jobs; do not publish again"
	done 3<<<"$catalogue"

	while read -r pkg <&3; do
		[[ $entry != "$target" || $pkg != "$built" ]] || continue
		tag=$(RELEASES_JSON="$releases" bash "$here/newest-release.sh" "$pkg" "$entry")
		if [[ -z $tag ]]; then
			[[ $entry != "$target" || $count -gt 1 ]] || die "$pkg has no release for $entry to carry forward"
			continue
		fi
		want=$(gh release view "$tag" --json body --jq .body | tr -d '\r' |
			sed -n 's/^sha256: \([0-9a-f]\{64\}\)$/\1/p')
		[[ -n $want && $want != *$'\n'* ]] || die "release $tag does not record exactly one sha256"
		flag=$(gh release view "$tag" --json isImmutable --jq .isImmutable) || die "cannot read whether $tag is immutable"
		case $flag in
		true) flag=yes ;;
		false) flag=no ;;
		*) die "cannot tell whether $tag is immutable (got $flag)" ;;
		esac
		printf 'carry %s %s %s immutable=%s\n' "$entry" "$tag" "$want" "$flag"
	done 3<<<"$catalogue"
done
