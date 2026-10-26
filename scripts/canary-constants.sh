#!/usr/bin/env bash
# Copyright (C) 2026 cayossarian
# canary-constants.sh
# For the canary: what verify-payload.sh copies of Templates/ and Keywords/ to derive the install scripts
# (verify-payload.sh --copied) against opnsense/plugins at the pinned framework commit (repo.conf FRAMEWORK,
# gh api ?ref=<pin>) and at master: each directory's listing, then each copied file's content, a template byte
# for byte and a keyword as verify-payload.sh reads it (--model: its flags and script bodies, so a change to
# its comments is not reported, and a line outside the form modelled is). Packages build in the pin, so a copy
# that differs from the pin is "MATERIAL: ..." (as is a file the pin adds, lacks, or holds in a form not
# modelled, and anything that cannot be read or compared); the same at master is a "NOTE: ..." naming both
# (upstream moved past the pin; to adopt it, review the change and move FRAMEWORK), unless the pin shows
# the same. The pin must also be an ancestor of master (gh api compare: ahead or identical), or it is
# MATERIAL: GitHub serves a commit of any fork in the network by its SHA from the upstream's URL. Nothing
# else is read: no copy of the plugin repository. Nothing read from upstream goes into the lines but plain
# file names. Templates/version is left out: verify-payload.sh renders the version file itself. Exits 1 if it
# printed a MATERIAL line, 2 if it cannot run, any command failing unexpectedly included (the ERR trap: never 1
# without a line). A difference fails no publish; a package built from a changed file fails the payload check
# until the copy is changed in a reviewed commit (README: The canary).
# gh takes the token from GH_TOKEN.
set -eEuo pipefail
trap 'exit 2' ERR

here=$(cd "$(dirname "$0")" && pwd)
die() {
	echo "canary-constants.sh: $*" >&2
	exit 2
}

[[ $# -eq 0 ]] || die "usage: canary-constants.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
list=$(bash "$here/verify-payload.sh" --copied) || die "cannot list verify-payload.sh's copies"
mapfile -t copies <<<"$list"
for c in "${copies[@]}"; do
	mkdir -p "$work/copy/${c%/*}"
	bash "$here/verify-payload.sh" --copied "$c" >"$work/copy/$c" || die "cannot read the copy of $c"
	if [[ $c == Keywords/* ]]; then
		bash "$here/verify-payload.sh" --model "$work/copy/$c" >"$work/copy/$c.model" ||
			die "verify-payload.sh cannot read its own copy of $c"
	fi
done
declare -A copied=() known=([Templates/version]=1)
for c in "${copies[@]}"; do copied[$c]=1; done

pin=$(sh "$here/repo.sh" framework) || die "cannot read the pinned framework"
repo=opnsense/plugins
material=0
say() {
	echo "MATERIAL: $*"
	material=1
}
# ghi <endpoint>: gh api -i, whose status line is the status (the exit code says only that it is not 2xx);
# sets code (three digits, or empty when there is no status line), stat (for a message) and body
ghi() {
	local out first
	out=$(gh api -i "$1" 2>/dev/null) || true
	first=$(head -n 1 <<<"$out" | tr -d '\r')
	code=$(awk '$1 ~ /^HTTP/ && $2 ~ /^[0-9][0-9][0-9]$/ { print $2 }' <<<"$first")
	body=$(awk 'f { print } !f && /^\r?$/ { f = 1 }' <<<"$out")
	stat=${code:+HTTP $code}
	stat=${stat:-no HTTP status}
}
# ghraw <endpoint> <file>: a file's raw content into <file>, byte for byte, with the status from gh api -i's status
# line: sets code. The download is bounded: gh is cut off after 80 KiB (the headers and one byte past 64 KiB of
# content at least), and a file larger than 64 KiB is reported over by its caller.
ghraw() {
	local first off
	set +o pipefail
	gh api -i "$1" -H 'Accept: application/vnd.github.raw' 2>/dev/null | head -c 81920 >"$work/raw"
	set -o pipefail
	first=$(head -n 1 "$work/raw" | tr -d '\r')
	code=$(awk '$1 ~ /^HTTP/ && $2 ~ /^[0-9][0-9][0-9]$/ { print $2 }' <<<"$first")
	# the content starts after the header block's empty line (a lone CR line; headers hold no NUL)
	off=$(LC_ALL=C grep -abxm1 $'\r' "$work/raw" | cut -d: -f1) || off=''
	if [[ -n $off ]]; then
		tail -c +$((off + 3)) "$work/raw" >"$2"
	else
		: >"$2"
		code=''
	fi
}
# the pin must be an ancestor of master: ahead (master is past it) or identical
ghi "repos/$repo/compare/$pin...master?per_page=1"
if [[ $code != 200 ]]; then
	say "cannot compare the pinned framework $pin with $repo master ($stat)"
else
	st=$(jq -r '.status | strings | select(test("\\A[a-z]+\\z"))' <<<"$body" 2>/dev/null) || st=''
	case $st in
	ahead | identical) ;;
	*) say "the pinned framework $pin is not an ancestor of $repo master (compare says ${st:-something that is not plain})" ;;
	esac
fi

# what the pin shows is material and is said first; master's difference is a note unless the pin shows it too
declare -A flagged=()
# finding <key> <message>
finding() {
	if [[ $ref == "$pin" ]]; then
		flagged[$1]=1
		say "$2"
	elif [[ -z ${flagged[$1]:-} ]]; then
		echo "NOTE: $2; master is past the pinned framework $pin"
	fi
}
for ref in "$pin" master; do
	if [[ $ref == master ]]; then label="$repo master"; else label="the pinned $repo $pin"; fi
	for d in Templates Keywords; do
		# one tab-separated line per entry; a type or name that is not plain arrives empty, never as text
		ghi "repos/$repo/contents/$d?ref=$ref"
		listing=$body
		if [[ $code != 200 ]] ||
			! entries=$(jq -r 'if type == "array" then .[] else error("not a listing") end
				| [((.type | strings | select(test("\\A[a-z]+\\z"))) // ""), ((.name | strings | select(test("\\A[A-Za-z0-9._+-]+\\z"))) // "")]
				| @tsv' <<<"$listing" 2>/dev/null); then
			say "cannot read $d/ of $label: its copies were not compared"
			continue
		fi
		declare -A seen=()
		while IFS= read -r line; do
			[[ -n $line ]] || continue
			type=${line%%$'\t'*} name=${line#*$'\t'}
			if [[ -z $name ]]; then
				finding "$d/ not plain: $line" "$label's $d/ holds a file whose name is not plain, which verify-payload.sh has no copy of"
				continue
			fi
			p=$d/$name
			seen[$p]=${type:-a type that is not plain}
			if [[ -z ${copied[$p]:-} && -z ${known[$p]:-} ]]; then
				finding "$p" "$label's $d/ holds $name, which verify-payload.sh has no copy of"
			fi
		done <<<"$entries"
		for c in "${copies[@]}"; do
			[[ $c == "$d"/* ]] || continue
			if [[ -z ${seen[$c]:-} ]]; then
				finding "$c" "$label's $d/ lacks ${c#*/}, which verify-payload.sh copies"
				continue
			fi
			if [[ ${seen[$c]} != file ]]; then
				finding "$c" "$label's $c is not a file (${seen[$c]})"
				continue
			fi
			# the download itself is bounded: one byte past 64 KiB says it is larger, and gh is cut off there
			f=$work/upstream
			ghraw "repos/$repo/contents/$c?ref=$ref" "$f"
			if [[ $code != 200 ]]; then
				say "cannot read $c of $label: it was not compared"
			elif (($(wc -c <"$f") > 65536)); then
				say "$label's $c is over 64 KiB: it was not compared"
			elif [[ $c == Templates/* ]]; then
				cmp -s "$f" "$work/copy/$c" || finding "$c" "$label's $c differs from verify-payload.sh's copy"
			elif ! bash "$here/verify-payload.sh" --model "$f" >"$work/model" 2>/dev/null; then
				finding "$c" "$label's $c is not in the form verify-payload.sh models (comments, actions: [file(1)], arguments: true and script bodies)"
			else
				cmp -s "$work/model" "$work/copy/$c.model" ||
					finding "$c" "$label's $c differs from verify-payload.sh's copy in its flags or script bodies"
			fi
		done
		unset seen
	done
done
exit "$material"
