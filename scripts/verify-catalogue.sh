#!/usr/bin/env bash
# verify-catalogue.sh <package>
# After a publish, check what firewalls will check: every served tree's catalogue
# (data in data.pkg) is signed by the published key, the target tree serves the
# package's newest release, and that release's asset matches the sha256 in its
# notes. LIVE_SITE (default https://legotypes.github.io/opnsense-repo) and
# PUB_KEY (default keys/legotypes-pkg-signing.pub) can be overridden.
# gh takes the repository from GH_REPO and the token from GH_TOKEN (or its login).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
site=${LIVE_SITE:-https://legotypes.github.io/opnsense-repo}
pub=${PUB_KEY:-$here/../keys/legotypes-pkg-signing.pub}

die() {
	echo "verify-catalogue.sh: $*" >&2
	exit 1
}

[[ $# -eq 1 ]] || die "usage: verify-catalogue.sh <package>"
pkg=$1
target=$(sh "$here/repo.sh" target)
served=$(sh "$here/repo.sh" serve) || die "cannot read the served trees"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for entry in $served; do
	tree=$(sh "$here/repo.sh" tree "$entry")
	curl -fsSL -o "$work/data.pkg" "$site/${tree#site/}/data.pkg" || die "cannot fetch $entry data.pkg"
	tar -xf "$work/data.pkg" -C "$work" data data.sig data.pub || die "$entry data.pkg holds no data, signature and key"
	cmp -s "$work/data.pub" "$pub" || die "the $entry catalogue carries a key other than $pub"
	openssl dgst -sha256 -r "$work/data" | cut -d' ' -f1 | tr -d '\n' |
		openssl dgst -sha256 -verify "$pub" -signature "$work/data.sig" >/dev/null ||
		die "the $entry catalogue's signature does not verify with $pub"
	echo "$entry: catalogue signature verified"
done

tag=$(bash "$here/newest-release.sh" "$pkg" "$target")
[[ -n $tag ]] || die "$pkg has no release for $target"
live_version=$(curl -fsSL "$site/$(sh "$here/repo.sh" tree | sed 's#^site/##')/packages.txt" |
	awk -v p="$pkg" '$1 == "Name" && $3 == p { getline; if ($1 == "Version") print $3 }')
[[ $live_version == "${tag#"$pkg"-}" ]] ||
	die "$target serves $pkg ${live_version:-(nothing)}; its newest release is $tag (straight after a publish, Pages may still serve the previous deploy: retry in a minute)"
want=$(gh release view "$tag" --json body --jq .body | tr -d '\r' | sed -n 's/^sha256: \([0-9a-f]\{64\}\)$/\1/p')
gh release download "$tag" --pattern "$tag.pkg" --dir "$work" || die "cannot download $tag.pkg"
[[ $(sha256sum "$work/$tag.pkg" | awk '{print $1}') == "$want" ]] || die "$tag.pkg does not match its notes' sha256"
echo "$target serves $tag; its asset matches its notes"
