#!/usr/bin/env bash
# carry-forward.sh <built-package>
# Fill every served <ABI>/<series> tree (repo.sh serve, repo.sh tree) with the
# current release of each catalogue package for that tree, byte for byte, except
# <built> in the target tree, which the build adds. "Current" is the newest
# release for that tree (newest-release.sh); its .pkg must match the sha256 its
# notes record. A frozen tree holds only the packages released for it. With one
# tree served, the target needs every catalogue package; while a series or ABI
# change serves two, the new target holds what has been released for it so far,
# so its first publish can succeed.
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
			die "$entry serves $pkg ${live_version:-(nothing)} but its newest release for $entry is ${tag:-(none)}: re-run the failed jobs of the publish that deployed it; do not publish again"
	done 3<<<"$catalogue"

	mkdir -p "$tree/All"
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
		tmp=$(mktemp -d)
		gh release download "$tag" --pattern "$tag.pkg" --dir "$tmp" || die "cannot download $tag.pkg"
		got=$(sha256sum "$tmp/$tag.pkg" | awk '{print $1}')
		[[ $got == "$want" ]] || die "$tag.pkg has sha256 $got; its release notes say $want"
		mv "$tmp/$tag.pkg" "$tree/All/"
		rmdir "$tmp"
		echo "carried forward $tag into $entry"
	done 3<<<"$catalogue"
done
