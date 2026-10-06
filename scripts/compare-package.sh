#!/usr/bin/env bash
# compare-package.sh <published.pkg> <fresh.pkg>
# The material differences between two builds of one package, one per line; exit 0
# when there are none, 1 when there are some, 2 on an error. Material: abi, arch,
# product_abi, the FreeBSD major, dependency names, options, install and deinstall
# scripts, and each file's path, mode and sha256. Not material: the commit hash,
# timestamps, flatsize, dependency versions and the FreeBSD minor (a 15.0 build
# installs on 15.1).
set -uo pipefail

die() {
	echo "compare-package.sh: $*" >&2
	exit 2
}

[[ $# -eq 2 ]] || die "usage: compare-package.sh <published.pkg> <fresh.pkg>"

canon() {
	tar -xOf "$1" +MANIFEST 2>/dev/null | jq -S '{
		abi, arch,
		product_abi: (.annotations.product_abi // null),
		freebsd_major: ((.annotations.FreeBSD_version // "0") | tonumber / 100000 | floor),
		deps: ((.deps // {}) | keys),
		options: (.options // {}),
		scripts: (.scripts // {}),
		files: ((.files // {}) | with_entries(.value |= {perm, sum}))
	}'
}

a=$(canon "$1") && [[ -n $a ]] || die "$1: no readable +MANIFEST"
b=$(canon "$2") && [[ -n $b ]] || die "$2: no readable +MANIFEST"

out=$(jq -rn --argjson a "$a" --argjson b "$b" '
	def what(x; y): if x == null then "added" elif y == null then "removed" else "changed" end;
	(["abi", "arch", "product_abi", "freebsd_major", "deps", "options"][] as $k
		| select($a[$k] != $b[$k]) | "\($k): \($a[$k] | tojson) -> \($b[$k] | tojson)"),
	(($a.scripts + $b.scripts) | keys[] as $s
		| select($a.scripts[$s] != $b.scripts[$s])
		| "script \($s): \(what($a.scripts[$s]; $b.scripts[$s]))"),
	(($a.files + $b.files) | keys[] as $f
		| select($a.files[$f] != $b.files[$f])
		| if $a.files[$f] == null or $b.files[$f] == null then "file \($f): \(what($a.files[$f]; $b.files[$f]))"
		  elif $a.files[$f].perm != $b.files[$f].perm then "file \($f): mode \($a.files[$f].perm) -> \($b.files[$f].perm)"
		  else "file \($f): content changed" end)
') || die "cannot compare the manifests"

[[ -z $out ]] && exit 0
printf '%s\n' "$out"
exit 1
