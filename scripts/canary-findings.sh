#!/usr/bin/env bash
# canary-findings.sh <package> <dir>
# One package's canary findings, from what the canary gathered in <dir>:
#   published.pkg, notes, tag     its newest release (notes: the source line first), and its tag
#   fresh.pkg, fresh.source       a build of main's head as a publish would make it
#   rebased.pkg                   the same in opnsense/plugins master's head, not the pin
#   fresh.tail, rebased.tail      the end of a failed build's log, instead of its .pkg
# Prints "MATERIAL: ..." lines (a rebuild, a move of the framework pin or a look is needed) and
# "NOTE: ..." lines (for information). Exits 1 if any line is MATERIAL.
# A plugin package's NOTE is by directory: the tree of the package's directory at the commit the release's
# source line names, against its tree at main's head (gh api git/trees, read on the runner, no clone), and the
# newest commit that changed the directory. Order: main's tree first (any failure is MATERIAL "cannot read",
# so a repository that cannot be read is never the NOTE); then the release commit, by gh api git/commits/<sha>,
# which answers 404 for a commit the repository does not hold (git/trees/<sha>?recursive=1 answers 422 there);
# then the tree that commit names. A call's status is its HTTP status line (gh api -i), never gh's exit code.
# Only the release commit's 404 is the NOTE; every other status (403, 429, 422, 5xx, ...), no status line, a
# tree whose "truncated" is not false, or a missing directory is MATERIAL "cannot read". The "." row (this
# repository's own package) compares the release's commit with fresh.source's.
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
[[ -f $d/fresh.pkg ]] || failed "building main as a publish would failed" "$d/fresh.tail"
[[ -f $d/rebased.pkg ]] || failed "building in upstream master's framework failed" "$d/rebased.tail"
if [[ ! -f $d/published.pkg ]]; then
	say NOTE "$pkg has no release yet; nothing to compare"
	exit "$material"
fi

as=''
as_ok=no
if [[ -f $d/fresh.pkg ]]; then
	rc=0
	as=$(bash "$here/compare-package.sh" "$d/published.pkg" "$d/fresh.pkg") || rc=$?
	if ((rc > 1)); then
		say MATERIAL "the build as a publish would make it could not be compared with the release"
		as=''
	else
		as_ok=yes
	fi
	while IFS= read -r l; do
		[[ -z $l ]] || say MATERIAL "a publish now would change $l"
	done <<<"$as"
fi

if [[ -f $d/rebased.pkg ]]; then
	rc=0
	rb=$(bash "$here/compare-package.sh" "$d/published.pkg" "$d/rebased.pkg") || rc=$?
	if ((rc > 1)); then
		say MATERIAL "the build in upstream master's framework could not be compared with the release"
	fi
	# a difference in the upstream-master build is upstream's doing only when the as-published build was compared and lacks it
	while IFS= read -r l; do
		[[ -n $l ]] || continue
		if [[ $as_ok == yes ]]; then
			grep -qxF -- "$l" <<<"$as" || say MATERIAL "upstream master's framework would change $l"
		else
			say MATERIAL "a build in upstream master's framework differs from the release in $l (the as-published build could not be compared)"
		fi
	done <<<"$rb"
fi

row=$(sh "$here/packages.sh" row "$pkg") || {
	echo "canary-findings.sh: $pkg is not in packages.conf" >&2
	exit 2
}
read -r repo _ dir _ <<<"$row"
tag=$(head -n 1 "$d/tag" 2>/dev/null || true)
tag=${tag:-$pkg}

if [[ $repo == . ]]; then
	head=$(sed -n 's/.*commit \([0-9a-f]\{7,40\}\).*/\1/p' "$d/fresh.source" 2>/dev/null | head -n 1 || true)
	rel=$(sed -n '1s/.*commit \([0-9a-f]\{7,40\}\).*/\1/p' "$d/notes" 2>/dev/null || true)
	if [[ -z $rel ]]; then
		say MATERIAL "cannot read the commit of release $tag: its source line holds no commit"
	elif [[ -n $head && $head != "$rel"* && $rel != "$head"* ]]; then
		say NOTE "main has commits after its release (release $rel, main head $head)"
	fi
	exit "$material"
fi

# the release's commit: the one "commit <40 hex digits>" of the source line, the first line of the notes
src=$(head -n 1 "$d/notes" 2>/dev/null || true)
rel=$(grep -oE 'commit [0-9a-f]{40}([^0-9a-f]|$)' <<<"$src" | sed 's/^commit \([0-9a-f]*\).*/\1/') || rel=''
if [[ $(grep -oEw 'commit' <<<"$src" | wc -l | tr -d ' ') != 1 || $(wc -l <<<"$rel" | tr -d ' ') != 1 || ${#rel} != 40 ]]; then
	say MATERIAL "cannot read the commit of release $tag: its source line must hold exactly one commit <40 hex digits>"
	exit "$material"
fi

# ghi <endpoint>: gh api -i; sets code (three digits, or empty with no status line), stat (for a message) and body
ghi() {
	local out first
	out=$(gh api -i "$1" 2>/dev/null) || true
	first=$(head -n 1 <<<"$out" | tr -d '\r')
	code=$(awk '$1 ~ /^HTTP/ && $2 ~ /^[0-9][0-9][0-9]$/ { print $2 }' <<<"$first")
	body=$(awk 'f { print } !f && /^\r?$/ { f = 1 }' <<<"$out")
	stat=${code:+HTTP $code}
	stat=${stat:-no HTTP status}
}
# tree_of <ref> <what>: the sha of $dir's tree in the tree <ref> (main, or a tree sha) of $repo into tsha; returns 1
# with a MATERIAL line, "cannot read $dir at <what>", when it cannot be read
tsha=''
tree_of() {
	local why=''
	ghi "repos/$repo/git/trees/$1?recursive=1"
	if [[ $code != 200 ]]; then
		why=$stat
	elif [[ $(jq -r 'if .truncated == false then "complete" else "no" end' <<<"$body" 2>/dev/null) != complete ]]; then
		why="the answer is truncated"
	else
		tsha=$(jq -r --arg p "$dir" '[.tree[]? | select(.path == $p and .type == "tree") | .sha | strings | select(test("\\A[0-9a-f]+\\z"))] | if length == 1 then .[0] else empty end' \
			<<<"$body" 2>/dev/null) || tsha=''
		[[ -n $tsha ]] || why="no such directory in the tree"
	fi
	if [[ -n $why ]]; then
		say MATERIAL "cannot read $dir at $2 in $repo ($why)"
		return 1
	fi
}
tree_of main main || exit "$material"
at_main=$tsha
at="the commit ${rel:0:9} of release $tag"
ghi "repos/$repo/git/commits/$rel"
if [[ $code == 404 ]]; then
	say NOTE "release $tag was built from a commit this repository does not hold (the retired fork); its next publish replaces it"
	exit "$material"
fi
if [[ $code != 200 ]]; then
	say MATERIAL "cannot read $dir at $at in $repo ($stat)"
	exit "$material"
fi
reltree=$(jq -r '.tree.sha | strings | select(test("\\A[0-9a-f]+\\z"))' <<<"$body" 2>/dev/null) || reltree=''
if [[ -z $reltree ]]; then
	say MATERIAL "cannot read $dir at $at in $repo (no tree in the commit)"
	exit "$material"
fi
tree_of "$reltree" "$at" || exit "$material"
if [[ $tsha != "$at_main" ]]; then
	ghi "repos/$repo/commits?sha=main&path=$dir&per_page=1"
	if [[ $code != 200 ]]; then
		say MATERIAL "cannot read the newest commit that changed $dir on main in $repo ($stat)"
	else
		newest=$(jq -r '[.[]? | .sha | strings | select(test("\\A[0-9a-f]{40}\\z"))] | .[0] // empty' <<<"$body" 2>/dev/null) || newest=''
		if [[ -z $newest ]]; then
			say MATERIAL "cannot read the newest commit that changed $dir on main in $repo (no commit in the answer)"
		else
			say NOTE "$dir has changed on main since release $tag (built from ${rel:0:9}); the newest change is ${newest:0:9}"
		fi
	fi
fi
exit "$material"
