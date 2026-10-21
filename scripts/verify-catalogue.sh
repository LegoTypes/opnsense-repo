#!/usr/bin/env bash
# verify-catalogue.sh <package>
# After a publish, check what firewalls will check: every served tree's catalogue
# (data in data.pkg) is signed by the published key, every served tree's stamp
# (stamp, stamp.sig, stamp.pub) is there, signed by the published key as
# sign-catalogue.sh signs it, carries that key and names that tree; the target tree
# serves the package's newest release, and that release's asset matches the sha256 in
# its notes. The published key is keys/legotypes-pkg-signing.pub beside this script's
# directory, and nothing overrides it. LIVE_SITE (default
# https://legotypes.github.io/opnsense-repo) names the site to read.
# gh takes the repository from GH_REPO and the token from GH_TOKEN (or its login).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
site=${LIVE_SITE:-https://legotypes.github.io/opnsense-repo}
pub=$here/../keys/legotypes-pkg-signing.pub
# Pages caches each file for up to 10 minutes (cache-control: max-age=600), and a query
# string does not bypass it: straight after a deploy one file can be the new one and the
# file beside it still the previous deploy's
cached="straight after a publish, Pages may still serve the previous deploy for up to 10 minutes: retry then"

die() {
	echo "verify-catalogue.sh: $*" >&2
	exit 1
}

# verify <file> <signature>: the signature over the file's sha256 hex verifies with the
# published key, as pkg checks a catalogue file and os-legotypes the stamp
verify() {
	openssl dgst -sha256 -r "$1" | cut -d' ' -f1 | tr -d '\n' |
		openssl dgst -sha256 -verify "$pub" -signature "$2" >/dev/null
}

[[ $# -eq 1 ]] || die "usage: verify-catalogue.sh <package>"
pkg=$1
target=$(sh "$here/repo.sh" target)
served=$(sh "$here/repo.sh" serve) || die "cannot read the served trees"
mapfile -t entries <<<"$served"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for i in "${!entries[@]}"; do
	entry=${entries[i]}
	tree=$(sh "$here/repo.sh" tree "$entry")
	w=$work/$i
	mkdir "$w"
	url=$site/${tree#site/}
	curl -fsSL -o "$w/data.pkg" "$url/data.pkg" || die "cannot fetch $entry data.pkg"
	tar -xf "$w/data.pkg" -C "$w" data data.sig data.pub || die "$entry data.pkg holds no data, signature and key"
	cmp -s "$w/data.pub" "$pub" || die "the $entry catalogue carries a key other than $pub"
	verify "$w/data" "$w/data.sig" || die "the $entry catalogue's signature does not verify with $pub"
	echo "$entry: catalogue signature verified"
	for f in stamp stamp.sig stamp.pub; do
		curl -fsSL -o "$w/$f" "$url/$f" || die "cannot fetch $entry $f: the tree has no stamp"
	done
	cmp -s "$w/stamp.pub" "$pub" || die "the $entry stamp carries a key other than $pub"
	verify "$w/stamp" "$w/stamp.sig" || die "the $entry stamp's signature does not verify with $pub ($cached)"
	stamp_tree=$(sed -n 's/^tree: //p' "$w/stamp")
	[[ $stamp_tree == "$entry" ]] || die "the $entry stamp names the tree ${stamp_tree:-(none)}"
	echo "$entry: stamp verified, $(sed -n 's/^published: /published /p' "$w/stamp")"
done

tag=$(bash "$here/newest-release.sh" "$pkg" "$target")
[[ -n $tag ]] || die "$pkg has no release for $target"
live_version=$(curl -fsSL "$site/$(sh "$here/repo.sh" tree | sed 's#^site/##')/packages.txt" |
	awk -v p="$pkg" '$1 == "Name" && $3 == p { getline; if ($1 == "Version") print $3 }')
[[ $live_version == "${tag#"$pkg"-}" ]] ||
	die "$target serves $pkg ${live_version:-(nothing)}; its newest release is $tag ($cached)"
want=$(gh release view "$tag" --json body --jq .body | tr -d '\r' | sed -n 's/^sha256: \([0-9a-f]\{64\}\)$/\1/p')
gh release download "$tag" --pattern "$tag.pkg" --dir "$work" || die "cannot download $tag.pkg"
[[ $(sha256sum "$work/$tag.pkg" | awk '{print $1}') == "$want" ]] || die "$tag.pkg does not match its notes' sha256"
echo "$target serves $tag; its asset matches its notes"
