#!/usr/bin/env bash
# carry-forward.sh <built-package>
# Fill every served series' tree (repo.sh serve, repo.sh tree) with the current
# release of each catalogue package for that series, byte for byte, except
# <built> in the target series, which the build adds. "Current" is the newest
# release for that series (newest-release.sh); its .pkg must match the sha256 its
# notes record. A frozen series holds only the packages released for it.
# LIVE_SITE is the live site's base URL: each tree's packages.txt there must list
# exactly each package's newest release for that series, or carrying forward
# would silently roll a package back.
# gh takes the repository from GH_REPO and the token from GH_TOKEN (or its login).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

die() {
	echo "carry-forward.sh: $*" >&2
	exit 1
}

[[ $# -eq 1 ]] || die "usage: carry-forward.sh <built-package>"
built=$1
[[ -n ${LIVE_SITE:-} ]] || die "LIVE_SITE must name the live site's base URL"

catalogue=$(sh "$here/packages.sh" catalogue) || die "cannot read the catalogue"
grep -qxF -- "$built" <<<"$catalogue" || die "$built is not a catalogue package"
target=$(sh "$here/repo.sh" series)
releases=$(gh release list --limit 1000 --json tagName,publishedAt) || die "cannot list releases"

for series in $(sh "$here/repo.sh" serve); do
	tree=$(sh "$here/repo.sh" tree "$series")
	# what that tree serves now (nothing yet for a series being added)
	live=$(curl -fsSL "$LIVE_SITE/${tree#site/}/packages.txt" 2>/dev/null || true)
	while read -r pkg <&3; do
		tag=$(RELEASES_JSON="$releases" bash "$here/newest-release.sh" "$pkg" "$series")
		served=$(awk -v p="$pkg" '$1 == "Name" && $3 == p { getline; if ($1 == "Version") print $3 }' <<<"$live")
		[[ -n $tag || -n $served ]] || continue # neither released nor live for this series
		[[ -n $tag && $served == "${tag#"$pkg"-}" ]] ||
			die "series $series serves $pkg ${served:-(nothing)} but its newest release for $series is ${tag:-(none)}: re-run the failed jobs of the publish that deployed it; do not publish again"
	done 3<<<"$catalogue"

	mkdir -p "$tree/All"
	while read -r pkg <&3; do
		[[ $series != "$target" || $pkg != "$built" ]] || continue
		tag=$(RELEASES_JSON="$releases" bash "$here/newest-release.sh" "$pkg" "$series")
		if [[ -z $tag ]]; then
			[[ $series != "$target" ]] || die "$pkg has no release for $series to carry forward"
			continue
		fi
		want=$(gh release view "$tag" --json body --jq .body | tr -d '\r' |
			sed -n 's/^sha256: \([0-9a-f]\{64\}\)$/\1/p')
		[[ -n $want && $want != *$'\n'* ]] || die "release $tag does not record exactly one sha256"
		tmp=$(mktemp -d)
		gh release download "$tag" --pattern "$tag.pkg" --dir "$tmp" || die "cannot download $tag.pkg"
		got=$(sha256sum "$tmp/$tag.pkg" | awk '{print $1}')
		[[ $got == "$want" ]] || die "$tag.pkg has sha256 $got; its release notes say $want"
		mv "$tmp/$tag.pkg" "$tree/All/"
		rmdir "$tmp"
		echo "carried forward $tag into $series"
	done 3<<<"$catalogue"
done
