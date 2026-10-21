#!/usr/bin/env bash
# carry-forward.sh <built-package>
# Fill every served <ABI>/<series> tree (repo.sh serve, repo.sh tree) with the
# current release of each catalogue package for that tree, byte for byte, except
# <built> in the target tree, which the build adds. carry-plan.sh decides what is
# carried (and checks it against LIVE_SITE, the live site's base URL); each .pkg
# must match the sha256 its release notes record. A frozen tree holds only the
# packages released for it.
# The carry lines of the plan (see carry-plan.sh) are written to manifest.carry in
# the working directory, beside site/, never under site/, which is published.
# With MANIFEST=<file> (the build job's manifest.sh output), the carry lines of
# that file must equal this plan's, ignoring order and a missing final newline, or
# nothing is carried: a release changed between approval and signing.
# repo.conf's REQUIRE_IMMUTABLE_RELEASES=yes refuses any release that is not
# immutable.
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

need_immutable=$(sh "$here/repo.sh" immutable) || die "cannot read REQUIRE_IMMUTABLE_RELEASES"
plan=$(bash "$here/carry-plan.sh" "$built") || exit 1
# normalised: the carry lines only, sorted, each ending with a newline
carry_lines() { { grep '^carry ' || true; } | LC_ALL=C sort; }
carry_lines <<<"$plan" >manifest.carry
if [[ -n ${MANIFEST:-} ]]; then
	[[ -f $MANIFEST ]] || die "cannot read the manifest $MANIFEST"
	approved=$(carry_lines <"$MANIFEST")
	[[ $approved == "$(cat manifest.carry)" ]] ||
		die "the releases to carry differ from the approved manifest $MANIFEST: $(diff <(printf '%s\n' "$approved") manifest.carry | grep '^[<>]' | tr '\n' ';')"
fi
if [[ $need_immutable == yes ]]; then
	notimm=$(awk '$5 != "immutable=yes" { print $3 }' manifest.carry | tr '\n' ' ')
	[[ -z $notimm ]] || die "REQUIRE_IMMUTABLE_RELEASES=yes but not immutable: $notimm"
fi

for entry in $(sh "$here/repo.sh" serve); do
	tree=$(sh "$here/repo.sh" tree "$entry")
	mkdir -p "$tree/All"
done
while read -r _ entry tag want _; do
	tree=$(sh "$here/repo.sh" tree "$entry")
	tmp=$(mktemp -d)
	gh release download "$tag" --pattern "$tag.pkg" --dir "$tmp" </dev/null || die "cannot download $tag.pkg"
	got=$(sha256sum "$tmp/$tag.pkg" | awk '{print $1}')
	[[ $got == "$want" ]] || die "$tag.pkg has sha256 $got; its release notes say $want"
	mv "$tmp/$tag.pkg" "$tree/All/"
	rmdir "$tmp"
	echo "carried forward $tag into $entry"
done <manifest.carry
