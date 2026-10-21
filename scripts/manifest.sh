#!/usr/bin/env bash
# manifest.sh <package> <out dir>
# Write <out dir>/manifest, what the owner reads before approving a publish and
# what carry-forward.sh must reproduce at signing time. One entry per line, sorted
# (LC_ALL=C), ending with a newline:
#   carry <ABI>/<series> <tag> <sha256> immutable=yes|no   each release carry-forward will carry
#   built <file name> <sha256>                             the built package in <out dir>
#   commit <40 hex digits>                                 COMMIT, the commit the owner approved
# The carry lines come from carry-plan.sh, the selection carry-forward.sh uses.
# Needs LIVE_SITE as carry-plan.sh does; <out dir> holds the one built <package>-*.pkg.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

die() {
	echo "manifest.sh: $*" >&2
	exit 1
}

[[ $# -eq 2 ]] || die "usage: manifest.sh <package> <out dir>"
pkg=$1 out=$2
[[ -d $out ]] || die "$out is not a directory"
[[ ${COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || die "COMMIT must be the approved commit, 40 lower-case hex digits"

files=("$out"/"$pkg"-[0-9]*.pkg)
[[ ${#files[@]} -eq 1 && -f ${files[0]} ]] || die "$out must hold exactly one $pkg-<version>.pkg"
sum=$(sha256sum "${files[0]}" | awk '{print $1}')

plan=$(bash "$here/carry-plan.sh" "$pkg") || exit 1
{
	[[ -z $plan ]] || printf '%s\n' "$plan"
	printf 'built %s %s\n' "$(basename "${files[0]}")" "$sum"
	printf 'commit %s\n' "$COMMIT"
} | LC_ALL=C sort >"$out/manifest"
