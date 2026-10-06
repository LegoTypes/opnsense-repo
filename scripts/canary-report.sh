#!/usr/bin/env bash
# canary-report.sh <title> <findings-file> <run-url>
# Keep one open issue (label "canary") per title in step with canary-findings.sh
# output: any MATERIAL line opens the issue or replaces its body; none closes an
# open one with a comment. Prints opened, updated, closed or clean. An unreadable
# issue list fails the script, so it can never open a duplicate.
# gh takes the repository from GH_REPO and the token from GH_TOKEN.
set -euo pipefail

die() {
	echo "canary-report.sh: $*" >&2
	exit 1
}

[[ $# -eq 3 ]] || die "usage: canary-report.sh <title> <findings-file> <run-url>"
title=$1 findings=$2 run=$3
[[ -f $findings ]] || die "$findings: no such file"

list=$(gh issue list --label canary --state open --limit 200 --json number,title) ||
	die "cannot list the open canary issues"
number=$(jq -r --arg t "$title" '[.[] | select(.title == $t)] | if length > 1 then "many" else (.[0].number // "") end' \
	<<<"$list") || die "unreadable issue list"
[[ $number != many ]] || die "two open issues are titled $title; close one"

if grep -q '^MATERIAL: ' "$findings"; then
	body=$(printf '%s\n\n%s\n\nRun: %s\n' \
		"The canary found what is published differing from what a build would produce now." \
		"$(sed -E 's/^(MATERIAL|NOTE): /- **\1**: /' "$findings")" "$run")
	if [[ -n $number ]]; then
		gh issue edit "$number" --body "$body" >/dev/null
		echo updated
	else
		gh issue create --title "$title" --label canary --body "$body" >/dev/null
		echo opened
	fi
elif [[ -n $number ]]; then
	gh issue close "$number" --comment "Clean in $run." >/dev/null
	echo closed
else
	echo clean
fi
