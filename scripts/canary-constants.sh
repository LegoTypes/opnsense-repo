#!/usr/bin/env bash
# Copyright (C) 2026 cayossarian
# canary-constants.sh
# For the canary: what verify-payload.sh copies of Templates/ and Keywords/ to derive the install scripts
# (verify-payload.sh --copied) against both masters, opnsense/plugins and LegoTypes/plugins (gh api, at master):
# each directory's listing, then each copied file's content, a template byte for byte and a keyword as
# verify-payload.sh reads it (--model: its flags and script bodies, so a change to its comments is not
# reported, and a line outside the form modelled is). Prints a "MATERIAL: ..." line for a file that differs, is
# missing, is not a file or is not in the form modelled, for a file master adds (Templates/version aside:
# verify-payload.sh renders the version file itself), and for anything that cannot be read; nothing when all
# agree. Nothing read from upstream goes into the lines but plain file names. Exits 1 if it printed anything,
# 2 if it cannot run, any command failing unexpectedly included (the ERR trap: never 1 without a line). A difference fails no publish; a package built from a changed file fails the payload
# check until the copy is changed in a reviewed commit (README: The canary).
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

material=0
say() {
	echo "MATERIAL: $*"
	material=1
}
for repo in opnsense/plugins LegoTypes/plugins; do
	for d in Templates Keywords; do
		# one tab-separated line per entry; a type or name that is not plain arrives empty, never as text
		if ! listing=$(gh api "repos/$repo/contents/$d?ref=master" 2>/dev/null) ||
			! entries=$(jq -r 'if type == "array" then .[] else error("not a listing") end
				| [((.type | strings | select(test("\\A[a-z]+\\z"))) // ""), ((.name | strings | select(test("\\A[A-Za-z0-9._+-]+\\z"))) // "")]
				| @tsv' <<<"$listing" 2>/dev/null); then
			say "cannot read $d/ of $repo master: its copies were not compared"
			continue
		fi
		declare -A seen=()
		while IFS= read -r line; do
			[[ -n $line ]] || continue
			type=${line%%$'\t'*} name=${line#*$'\t'}
			if [[ -z $name ]]; then
				say "$repo master's $d/ holds a file whose name is not plain, which verify-payload.sh has no copy of"
				continue
			fi
			p=$d/$name
			seen[$p]=${type:-a type that is not plain}
			if [[ -z ${copied[$p]:-} && -z ${known[$p]:-} ]]; then
				say "$repo master's $d/ holds $name, which verify-payload.sh has no copy of"
			fi
		done <<<"$entries"
		for c in "${copies[@]}"; do
			[[ $c == "$d"/* ]] || continue
			if [[ -z ${seen[$c]:-} ]]; then
				say "$repo master's $d/ lacks ${c#*/}, which verify-payload.sh copies"
				continue
			fi
			if [[ ${seen[$c]} != file ]]; then
				say "$repo master's $c is not a file (${seen[$c]})"
				continue
			fi
			# the download itself is bounded: one byte past 64 KiB says it is larger, and gh is cut off there
			f=$work/upstream
			set +o pipefail
			gh api "repos/$repo/contents/$c?ref=master" -H 'Accept: application/vnd.github.raw' 2>/dev/null |
				head -c 65537 >"$f"
			got=("${PIPESTATUS[@]}")
			set -o pipefail
			if (($(wc -c <"$f") > 65536)); then
				say "$repo master's $c is over 64 KiB: it was not compared"
			elif ((got[0] != 0 || got[1] != 0)); then
				say "cannot read $c of $repo master: it was not compared"
			elif [[ $c == Templates/* ]]; then
				cmp -s "$f" "$work/copy/$c" || say "$repo master's $c differs from verify-payload.sh's copy"
			elif ! bash "$here/verify-payload.sh" --model "$f" >"$work/model" 2>/dev/null; then
				say "$repo master's $c is not in the form verify-payload.sh models (comments, actions: [file(1)], arguments: true and script bodies)"
			else
				cmp -s "$work/model" "$work/copy/$c.model" ||
					say "$repo master's $c differs from verify-payload.sh's copy in its flags or script bodies"
			fi
		done
		unset seen
	done
done
exit "$material"
