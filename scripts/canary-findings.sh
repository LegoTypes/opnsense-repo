#!/usr/bin/env bash
# canary-findings.sh <package> <dir>
# One package's canary findings, from what the canary gathered in <dir>:
#   published.pkg, notes          its newest release and that release's notes
#   fresh.pkg, fresh.source       a build of the branch head as a publish would make it
#   rebased.pkg                   the same with opnsense/plugins master's Mk/
#   fresh.tail, rebased.tail      the end of a failed build's log, instead of its .pkg
# Prints "MATERIAL: ..." lines (a rebuild, a rebase or a look is needed) and
# "NOTE: ..." lines (for information). Exits 1 if any line is MATERIAL.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
[[ $# -eq 2 ]] || {
	echo "usage: canary-findings.sh <package> <dir>" >&2
	exit 2
}
pkg=$1 d=$2 material=0

say() {
	printf '%s: %s\n' "$1" "$2"
	[[ $1 != MATERIAL ]] || material=1
}
# a failed build: the finding, then the last 20 lines of its log as LOG lines
failed() {
	if [[ -s $2 ]]; then
		say MATERIAL "$1; the end of its log:"
		tail -n 20 "$2" | sed 's/^/LOG: /'
	else
		say MATERIAL "$1; no log was kept"
	fi
}

# a failed build is material whether or not there is a release to compare with
[[ -f $d/fresh.pkg ]] || failed "building the branch as a publish would failed" "$d/fresh.tail"
[[ -f $d/rebased.pkg ]] || failed "building with upstream Mk/ failed" "$d/rebased.tail"
if [[ ! -f $d/published.pkg ]]; then
	say NOTE "$pkg has no release yet; nothing to compare"
	exit "$material"
fi

as=''
if [[ -f $d/fresh.pkg ]]; then
	rc=0
	as=$(bash "$here/compare-package.sh" "$d/published.pkg" "$d/fresh.pkg") || rc=$?
	if ((rc > 1)); then
		say MATERIAL "the build as a publish would make it could not be compared with the release"
	fi
	while IFS= read -r l; do
		[[ -z $l ]] || say MATERIAL "a publish now would change $l"
	done <<<"$as"
fi

if [[ -f $d/rebased.pkg ]]; then
	rc=0
	rb=$(bash "$here/compare-package.sh" "$d/published.pkg" "$d/rebased.pkg") || rc=$?
	if ((rc > 1)); then
		say MATERIAL "the build with upstream Mk/ could not be compared with the release"
	fi
	while IFS= read -r l; do
		[[ -z $l ]] || grep -qxF -- "$l" <<<"$as" || say MATERIAL "upstream Mk/ would change $l"
	done <<<"$rb"
fi

head=$(sed -n 's/.*commit \([0-9a-f]\{7,40\}\).*/\1/p' "$d/fresh.source" 2>/dev/null | head -n 1 || true)
rel=$(sed -n '1s/.*commit \([0-9a-f]\{7,40\}\).*/\1/p' "$d/notes" 2>/dev/null || true)
if [[ -n $head && -n $rel && $head != "$rel"* && $rel != "$head"* ]]; then
	say NOTE "the branch has commits after its release (release $rel, branch head $head)"
fi
exit "$material"
