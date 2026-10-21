#!/usr/bin/env bash
# canary-report.sh <title> <findings-file> <run-url>
# Keep one open issue (label "canary") per title in step with canary-findings.sh
# output: any MATERIAL line opens the issue or replaces its body; none closes an
# open one with a comment. LOG lines (a failed build's log) become one code block,
# fenced by more backticks than any line holds. The findings are cut to stay within
# GitHub's limit; a cut inside a code block closes it with its own fence, and the note
# saying so follows outside it. Prints opened, updated, closed or clean. An unreadable
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
	# a LOG block is fenced by a backtick run one longer than the longest run in its lines
	# (three at least), so no log line can close it
	findings_md=$(awk '
		function flush(   fence, i) {
			if (!n) return
			fence = "```"
			while (length(fence) <= longest) fence = fence "`"
			print fence
			for (i = 1; i <= n; i++) print buf[i]
			print fence
			n = 0; longest = 0
		}
		/^LOG: / {
			line = substr($0, 6); buf[++n] = line
			rest = line
			while (match(rest, /`+/)) {
				if (RLENGTH > longest) longest = RLENGTH
				rest = substr(rest, RSTART + RLENGTH)
			}
			next
		}
		{ flush(); sub(/^MATERIAL: /, "- **MATERIAL**: "); sub(/^NOTE: /, "- **NOTE**: "); print }
		END { flush() }
	' "$findings")
	limit=60000
	if [[ ${#findings_md} -gt $limit ]]; then
		note="(cut: the full log is in the run's canary artifact)"
		cut=$limit
		while :; do
			head=${findings_md:0:cut}
			# the fence that closes a block still open where the text is cut, as CommonMark reads
			# fences (up to three spaces, then three or more backticks or tildes; a backtick
			# fence's info string holds none; it closes on a line of as many or more and blanks)
			close=$(awk '
				f == "" {
					if (match($0, /^ ? ? ?(```+|~~~+)/)) {
						f = substr($0, RSTART, RLENGTH)
						sub(/^ +/, "", f)
						c = substr(f, 1, 1)
						n = length(f)
						if (c == "`" && index(substr($0, RSTART + RLENGTH), "`")) f = ""
					}
					next
				}
				{
					rest = $0
					sub(/^ ? ? ?/, "", rest)
					m = 0
					while (substr(rest, m + 1, 1) == c) m++
					if (m >= n && substr(rest, m + 1) ~ /^[ \t]*$/) f = ""
				}
				END { if (f != "") { s = ""; for (i = 0; i < n; i++) s = s c; print s } }
			' <<<"$head")
			((cut + ${#close} + ${#note} + 2 > limit)) || break
			# the closing fence is long: cut earlier, so the whole still fits
			cut=$((limit - ${#close} - ${#note} - 2))
			((cut > 0)) || cut=0
		done
		findings_md=$head${close:+$'\n'$close}$'\n'$note
	fi
	body=$(printf '%s\n\n%s\n\nRun: %s\n' \
		"The canary found what is published differing from what a build would produce now." \
		"$findings_md" "$run")
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
