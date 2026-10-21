#!/usr/bin/env bash
# provenance.sh <package> <out dir> <review dir>
# In the review job: write <review dir>/source and <review dir>/build, the lines the release
# notes carry, from trusted inputs instead of the build VM's out/source and out/build, which
# are read only as far as said here (out-dir.sh checks their shape first).
#   source  a plugin: "Built from <repository>, branch <branch>, commit <COMMIT>." from
#           packages.conf and the approved commit. This repository's package:
#           "Built from <GITHUB_REPOSITORY>, <dir>, commit <last change> (workflow run at
#           <COMMIT>), in LegoTypes/plugins master <commit>.", the last commit that changed
#           <dir> from this checkout (which must be at COMMIT, with its full history), and the
#           LegoTypes/plugins master commit the VM reported, taken only from a line of exactly
#           build-package.sh's shape and only once it is a commit of LegoTypes/plugins master
#           (an ancestor of its tip, in a commits-only clone).
#   build   abi and series from repo.conf, php and python from UPSTREAM_PHP and UPSTREAM_PYTHON
#           (upstream.sh, run again in the review job); the VM's must be the same. freebsd is
#           the VM's, marked "(reported by the build VM)".
# <review dir> must not exist. Prints both files. A value from the VM in an error is quoted
# (printf %q), so it never reaches the log as a line of its own.
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)

die() {
	echo "provenance.sh: $*" >&2
	exit 1
}
q() { printf %q "$1"; }

[[ $# -eq 3 ]] || die "usage: provenance.sh <package> <out dir> <review dir>"
pkg=$1 out=$2 rev=$3
[[ ${COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || die "COMMIT must be the approved commit, 40 lower-case hex digits"
[[ -n ${UPSTREAM_PHP:-} && -n ${UPSTREAM_PYTHON:-} ]] ||
	die "UPSTREAM_PHP and UPSTREAM_PYTHON must be set (bash scripts/upstream.sh)"
[[ ! -e $rev ]] || die "$rev exists"
bash "$here/out-dir.sh" "$pkg" "$out" >/dev/null
row=$(sh "$here/packages.sh" row "$pkg")
read -r repo branch dir _ <<<"$row"

# the VM's build lines (out-dir.sh: exactly abi, series, freebsd, php, python)
declare -A vm=()
while IFS= read -r l; do vm[${l%%: *}]=${l#*: }; done <"$out/build"
want_abi=$(sh "$here/repo.sh" abi)
want_series=$(sh "$here/repo.sh" series)
[[ ${vm[abi]} == "$want_abi" ]] || die "the build VM built for ABI $(q "${vm[abi]}"), not $want_abi"
[[ ${vm[series]} == "$want_series" ]] || die "the build VM built for series $(q "${vm[series]}"), not $want_series"
[[ ${vm[php]} == "$UPSTREAM_PHP" ]] || die "the build VM built with PHP $(q "${vm[php]}"); upstream.sh now says $UPSTREAM_PHP"
[[ ${vm[python]} == "$UPSTREAM_PYTHON" ]] ||
	die "the build VM built with Python $(q "${vm[python]}"); upstream.sh now says $UPSTREAM_PYTHON"

if [[ $repo == . ]]; then
	[[ ${GITHUB_REPOSITORY:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "GITHUB_REPOSITORY must name this repository"
	head=$(git rev-parse HEAD) || die "this is not a checkout"
	[[ $head == "$COMMIT" ]] || die "this checkout is at $head, not the approved $COMMIT"
	changed=$(git log -1 --format=%H -- "$dir")
	[[ $changed =~ ^[0-9a-f]{40}$ ]] ||
		die "cannot find the last commit that changed $dir (a shallow checkout? check out with fetch-depth: 0)"
	line=$(<"$out/source")
	shape="^Built from [^ ,]+, [^ ,]+, commit [0-9a-f]{40} \\(workflow run at $COMMIT\\), in LegoTypes/plugins master ([0-9a-f]{40})\\.$"
	[[ $line =~ $shape ]] || die "the build VM's source line is not the one build-package.sh writes for $COMMIT"
	master=${BASH_REMATCH[1]}
	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT
	git clone --quiet --filter=tree:0 --no-checkout --single-branch --branch master \
		https://github.com/LegoTypes/plugins.git "$work/plugins" 2>/dev/null ||
		die "cannot clone LegoTypes/plugins master"
	if ! git -C "$work/plugins" cat-file -e "$master^{commit}" 2>/dev/null ||
		! git -C "$work/plugins" merge-base --is-ancestor "$master" refs/remotes/origin/master; then
		die "the build VM's LegoTypes/plugins commit $master is not on LegoTypes/plugins master"
	fi
	source="Built from $GITHUB_REPOSITORY, $dir, commit $changed (workflow run at $COMMIT), in LegoTypes/plugins master $master."
else
	source="Built from $repo, branch $branch, commit $COMMIT."
fi

mkdir -p "$rev"
printf '%s\n' "$source" >"$rev/source"
printf 'abi: %s\nseries: %s\nfreebsd: %s (reported by the build VM)\nphp: %s\npython: %s\n' \
	"$want_abi" "$want_series" "${vm[freebsd]}" "$UPSTREAM_PHP" "$UPSTREAM_PYTHON" >"$rev/build"
cat "$rev/source" "$rev/build"
