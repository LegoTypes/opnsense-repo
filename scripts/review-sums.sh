#!/usr/bin/env bash
# Copyright (C) 2026 cayossarian
# review-sums.sh print|check <package> <out dir> <review dir>
# What binds the files sign signs and release publishes to what the review job showed the
# approver. <out dir> is the build (out-dir.sh), <review dir> exactly the review job's manifest,
# source and build, each a regular file.
#   print  in the review job, once those files are final: the sha256 of the package and of
#          review/manifest, review/source and review/build, as the job's outputs
#          (pkg_sha256=, manifest_sha256=, source_sha256=, build_sha256=, one per line), each
#          checked to be 64 lower-case hex digits before anything is printed. Job outputs are
#          set only by the review job's own runner.
#   check  in sign and release, with those outputs in PKG_SHA256, MANIFEST_SHA256,
#          SOURCE_SHA256 and BUILD_SHA256 and the approved commit in COMMIT: each file's sha256
#          is its output, the manifest's one built line names this package's file and sha256,
#          and its one commit line is COMMIT.
# A refusal is a fixed message: no value from the files is repeated.
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)

die() {
	echo "review-sums.sh: $*" >&2
	exit 1
}
sha() { sha256sum "$1" | cut -d' ' -f1; }
hex64() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

[[ $# -eq 4 ]] || die "usage: review-sums.sh print|check <package> <out dir> <review dir>"
cmd=$1 pkg=$2 out=$3 rev=$4
case $cmd in
print | check) ;;
*) die "usage: review-sums.sh print|check <package> <out dir> <review dir>" ;;
esac

file=$(bash "$here/out-dir.sh" "$pkg" "$out")
[[ -d $rev && ! -L $rev ]] || die "the review files are missing"
shopt -s dotglob nullglob
entries=("$rev"/*)
[[ ${#entries[@]} -eq 3 ]] || die "review/ must hold exactly manifest, source and build"
for f in manifest source build; do
	[[ -f $rev/$f && ! -L $rev/$f ]] || die "review/ must hold exactly manifest, source and build"
done

got_pkg=$(sha "$file")
got_manifest=$(sha "$rev/manifest")
got_source=$(sha "$rev/source")
got_build=$(sha "$rev/build")

if [[ $cmd == print ]]; then
	for v in "$got_pkg" "$got_manifest" "$got_source" "$got_build"; do
		hex64 "$v" || die "a sha256 is not 64 lower-case hex digits"
	done
	printf 'pkg_sha256=%s\nmanifest_sha256=%s\nsource_sha256=%s\nbuild_sha256=%s\n' \
		"$got_pkg" "$got_manifest" "$got_source" "$got_build"
	exit 0
fi

for v in "${PKG_SHA256:-}" "${MANIFEST_SHA256:-}" "${SOURCE_SHA256:-}" "${BUILD_SHA256:-}"; do
	hex64 "$v" || die "the review job's sums are missing or not 64 lower-case hex digits"
done
[[ ${COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || die "COMMIT must be the approved commit, 40 lower-case hex digits"
[[ $got_pkg == "$PKG_SHA256" ]] || die "the package is not the one the review job showed"
[[ $got_manifest == "$MANIFEST_SHA256" ]] || die "review/manifest is not the one the review job wrote"
[[ $got_source == "$SOURCE_SHA256" ]] || die "review/source is not the one the review job wrote"
[[ $got_build == "$BUILD_SHA256" ]] || die "review/build is not the one the review job wrote"
built=$(awk '$1 == "built"' "$rev/manifest")
[[ $built == "built ${file##*/} $got_pkg" ]] || die "the manifest's built line is not this package and its sha256"
commits=$(awk '$1 == "commit"' "$rev/manifest")
[[ $commits == "commit $COMMIT" ]] || die "the manifest's commit line is not the approved commit"
echo "review-sums.sh: the package and the review files are the ones the review job showed"
