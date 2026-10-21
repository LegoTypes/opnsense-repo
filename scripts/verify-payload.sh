#!/usr/bin/env bash
# verify-payload.sh <pkg> <plugin dir> <name> <version> <abi> <series> <commit>
# Check, before a package is signed, that it holds exactly what Mk/plugins.mk install
# makes of the plugin directory at the approved commit, without running Mk/: every
# regular file under src/ (but top-level dot files, as "find *" skips them) lands
# under /usr/local/, a .in file sed-substituted and without .in, a .shadow file as
# .sample (.shadow.in both), a man/ file gzipped; modes are kept (0755 or 0644, a
# man page 0644); /usr/local/opnsense/version/<name without os-> is rendered from
# Templates/version and its ten values are the substitution map.
# Checks, failing on the first problem:
# 1. +MANIFEST: only the keys pkg create writes for a plugin; +COMPACT_MANIFEST is
#    it without files and scripts; name, version, abi and annotation product_abi
#    (the series) as given; dependency names equal PLUGIN_DEPENDS in the Makefile.
# 2. The version file: exactly the ten product_* strings, product_hash the commit as
#    Scripts/version.sh abbreviates it (9 characters), product_version, product_id,
#    product_name and product_abi as expected; the annotations repeat it.
# 3. The files: +MANIFEST's map one to one onto src/, and the archive holds exactly
#    those and the two manifests, each once, regular files.
# 4. Each file: mode and owner (root:wheel) in +MANIFEST and in the archive, which
#    is what pkg installs; the +MANIFEST sum (1$ sha256 or 2$ BLAKE2b in pkg's
#    base32) matches the content; the content equals the source after substitution
#    (.in) and gunzip (man/).
# On success prints "payload: OK (<n> files)" (<n> counts the version file) and then
# each install script, its name on a line ("script post-install:") and its lines
# indented by a tab; on the first problem exits 1 with the reason on stderr.
# Not modelled, so refused: contrib/, plugin variants, Makefile lines other than
# plain assignments and the plugins.mk include, a man page with .shadow, file names
# outside [A-Za-z0-9._+,@=~-], a .in file that is not UTF-8, and substitution
# values sed would not copy literally. Needs bash 4, jq, tar (bsdtar or GNU tar)
# with zstd, sha256sum, openssl (BLAKE2b), gzip and cmp.
set -euo pipefail

die() {
	echo "verify-payload.sh: $*" >&2
	exit 1
}

[[ $# -eq 7 ]] || die "usage: verify-payload.sh <pkg> <plugin dir> <name> <version> <abi> <series> <commit>"
pkg=$1 dir=${2%/} name=$3 version=$4 abi=$5 series=$6 commit=$7
[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "the commit must be 40 lowercase hex digits: $commit"
[[ $name == os-?* ]] || die "the name must start with os-: $name"
hash=${commit:0:9}
pname=${name#os-}
vfile=/usr/local/opnsense/version/$pname
[[ -f $pkg ]] || die "$pkg: no such file"
[[ -f $dir/Makefile ]] || die "$dir: no Makefile"
[[ -d $dir/src ]] || die "$dir: no src/"
[[ ! -e $dir/contrib ]] || die "contrib/ is not supported"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# the archive's members, as tar prints them (pkg writes absolute names, which bsdtar
# lists with their / and GNU tar without), keyed by the name without a leading /
tar -tf "$pkg" >"$work/list" 2>/dev/null || die "$pkg: not a readable archive"
tar -tvf "$pkg" >"$work/verbose" 2>/dev/null || die "$pkg: not a readable archive"
mapfile -t listed <"$work/list"
mapfile -t verbose <"$work/verbose"
[[ ${#listed[@]} -gt 0 && ${#listed[@]} -eq ${#verbose[@]} ]] || die "$pkg: not a readable archive"
declare -A member=() line=()
for i in "${!listed[@]}"; do
	m=${listed[i]}
	k=${m#/}
	[[ -z ${member[$k]:-} ]] || die "archive member /$k appears twice"
	member[$k]=$m
	line[$k]=${verbose[i]}
done
[[ -n ${member[+MANIFEST]:-} && -n ${member[+COMPACT_MANIFEST]:-} ]] || die "$pkg: lacks +MANIFEST or +COMPACT_MANIFEST"
extract() { tar -xOf "$pkg" "${member[$1]}" 2>/dev/null; }
is() { [[ $2 == "$3" ]] || die "$1 is $2, expected $3"; }

# 1. +MANIFEST
extract +MANIFEST >"$work/manifest" || die "cannot read +MANIFEST"
extract +COMPACT_MANIFEST >"$work/compact" || die "cannot read +COMPACT_MANIFEST"
jq -es 'length == 1 and (.[0] | type == "object")' "$work/manifest" >/dev/null 2>&1 || die "+MANIFEST is not one JSON object"
jq -es 'length == 1' "$work/compact" >/dev/null 2>&1 || die "+COMPACT_MANIFEST is not one JSON value"
M=$(jq -c . "$work/manifest")
unexpected=$(jq -r '(keys - ["abi", "annotations", "arch", "categories", "comment", "deps", "desc", "files", "flatsize",
	"licenselogic", "licenses", "maintainer", "name", "origin", "prefix", "scripts", "version", "www"])[0] // empty' <<<"$M")
[[ -z $unexpected ]] || die "+MANIFEST key $unexpected is not expected"
jq -es --argjson m "$M" '.[0] == ($m | del(.files, .scripts))' "$work/compact" >/dev/null ||
	die "+COMPACT_MANIFEST differs from +MANIFEST"
is "+MANIFEST name" "$(jq -r '.name | strings' <<<"$M")" "$name"
is "+MANIFEST version" "$(jq -r '.version | strings' <<<"$M")" "$version"
is "+MANIFEST abi" "$(jq -r '.abi | strings' <<<"$M")" "$abi"
is "+MANIFEST product_abi" "$(jq -r '.annotations.product_abi? | strings' <<<"$M")" "$series"
jq -e '.scripts // {} | type == "object" and all(.[]; type == "string")' <<<"$M" >/dev/null ||
	die "+MANIFEST scripts are not an object of strings"
v=$(jq -r '.scripts // {} | to_entries
	| map(select(.value | explode | any(. < 9 or (. > 10 and . < 32) or . == 127)))[0].key // empty' <<<"$M")
[[ -z $v ]] || die "script $v holds control characters"

# PLUGIN_DEPENDS from the Makefile, which may hold only plain assignments and the include
awk '{ while (/\\$/) { sub(/\\$/, " "); l = $0; if ((getline n) <= 0) break; $0 = l n } print }' \
	"$dir/Makefile" >"$work/makefile" || die "cannot read $dir/Makefile"
plugin_depends='' deps_set=''
while IFS= read -r l; do
	case $l in
	'' | '#'* | '.include "../../Mk/plugins.mk"') continue ;;
	esac
	[[ $l =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*([?+:!]?)=(.*)$ ]] || die "Makefile: $l is not supported"
	var=${BASH_REMATCH[1]} op=${BASH_REMATCH[2]} val=${BASH_REMATCH[3]%%#*}
	[[ $var != PLUGIN_VARIANT && $var != PLUGIN_VARIANTS ]] || die "Makefile: PLUGIN_VARIANT and PLUGIN_VARIANTS are not supported"
	[[ $var == PLUGIN_DEPENDS ]] || continue
	[[ $op != '!' && $val != *'$'* ]] || die "Makefile: PLUGIN_DEPENDS is not a plain list"
	case $op in
	'+') plugin_depends+=" $val" ;;
	'?') [[ -n $deps_set ]] || plugin_depends=$val ;;
	*) plugin_depends=$val ;;
	esac
	deps_set=1
done <"$work/makefile"
read -ra words <<<"$plugin_depends"
want_deps=$(jq -rn '$ARGS.positional | unique | join(" ")' --args "${words[@]}")
have_deps=$(jq -r '.deps // {} | keys | join(" ")' <<<"$M")
[[ $have_deps == "$want_deps" ]] ||
	die "dependencies (${have_deps:-none}) differ from PLUGIN_DEPENDS (${want_deps:-none})"

# 2. the version file
jq -e --arg v "$vfile" '.files | type == "object" and has($v)' <<<"$M" >/dev/null || die "+MANIFEST lists no $vfile"
[[ -n ${member[${vfile#/}]:-} ]] || die "$vfile is not in the archive"
extract "${vfile#/}" >"$work/version" || die "cannot extract $vfile"
keys='["product_abi", "product_arch", "product_conflicts", "product_email", "product_hash", "product_id",
	"product_name", "product_tier", "product_version", "product_website"]'
jq -es --argjson k "$keys" 'length == 1 and (.[0] | type == "object" and keys == $k and all(.[]; type == "string"))' \
	"$work/version" >/dev/null 2>&1 || die "version file: not exactly the ten product_* strings"
V=$(jq -c . "$work/version")
vget() { jq -r --arg k "$1" '.[$k]' <<<"$V"; }
is "version file: product_hash" "$(vget product_hash)" "$hash"
is "version file: product_version" "$(vget product_version)" "$version"
is "version file: product_id" "$(vget product_id)" "$name"
is "version file: product_name" "$(vget product_name)" "$pname"
is "version file: product_abi" "$(vget product_abi)" "$series"
# sed takes each value as the replacement of s=%%TOKEN%%=value=g, so only plain text is copied as is
v=$(jq -r 'to_entries | map(select(.value | test("[&\\\\=\n]|%%")))[0].key // empty' <<<"$V")
[[ -z $v ]] || die "version file: $v holds a character sed would not copy literally"
jq -e --argjson v "$V" '.annotations | type == "object" and del(.FreeBSD_version) == $v' <<<"$M" >/dev/null ||
	die "+MANIFEST annotations differ from the version file"
# the tokens in Mk/defaults.mk REPLACEMENTS order (sed applies them in turn); PLUGIN_VARIANT is
# empty without variants
map=$(jq -c '[["PLUGIN_ABI", .product_abi], ["PLUGIN_ARCH", .product_arch], ["PLUGIN_CONFLICTS", .product_conflicts],
	["PLUGIN_HASH", .product_hash], ["PLUGIN_MAINTAINER", .product_email], ["PLUGIN_NAME", .product_name],
	["PLUGIN_PKGNAME", .product_id], ["PLUGIN_PKGVERSION", .product_version], ["PLUGIN_TIER", .product_tier],
	["PLUGIN_VARIANT", ""], ["PLUGIN_WWW", .product_website]] | map(["%%" + .[0] + "%%", .[1]])' <<<"$V")

# 3. the file set: what install makes of src/, keyed by installed path
(cd "$dir/src" && find . -type f -print0) >"$work/found" || die "cannot list $dir/src"
LC_ALL=C sort -z "$work/found" >"$work/src"
declare -A from=() subst=() gz=()
while IFS= read -r -d '' f; do
	f=${f#./}
	[[ $f != .* ]] || continue
	[[ $f =~ ^[A-Za-z0-9._+,@=~-]+(/[A-Za-z0-9._+,@=~-]+)*$ ]] || die "src/$f: unsupported file name"
	d=$f s='' z=''
	if [[ $d == *.in ]]; then d=${d%.in} s=1; fi
	[[ $d != */ ]] || die "src/$f: unsupported file name"
	if [[ ${d%%/*} == man ]]; then
		[[ $d != *.shadow ]] || die "src/$f: a man page with .shadow is not supported"
		z=1
	fi
	if [[ $d == *.shadow ]]; then d=${d%.shadow}.sample; fi
	[[ -n $z ]] && d=$d.gz
	d=/usr/local/$d
	[[ $d != "$vfile" ]] || die "src/$f would replace the version file"
	[[ -z ${from[$d]:-} ]] || die "src/${from[$d]} and src/$f both install $d"
	from[$d]=$f subst[$d]=$s gz[$d]=$z
done <"$work/src"

jq -e '.files | all(.[]; type == "object") and all(keys[]; test("^/[A-Za-z0-9._+,@=~/-]+$"))' <<<"$M" >/dev/null ||
	die "+MANIFEST files are not entries with plain names"
mapfile -t files < <(jq -r '.files | keys[]' <<<"$M")
declare -A listed_in_manifest=()
for p in "${files[@]}"; do
	listed_in_manifest[$p]=1
	[[ $p == "$vfile" || -n ${from[$p]:-} ]] || die "$p is packaged but has no source"
done
mapfile -t installed < <(printf '%s\n' "${!from[@]}" | LC_ALL=C sort)
for p in "${installed[@]}"; do
	[[ -z $p || -n ${listed_in_manifest[$p]:-} ]] || die "src/${from[$p]} is not packaged (as $p)"
done
mapfile -t members < <(printf '%s\n' "${!member[@]}" | LC_ALL=C sort)
for k in "${members[@]}"; do
	[[ $k == +MANIFEST || $k == +COMPACT_MANIFEST || -n ${listed_in_manifest[/$k]:-} ]] ||
		die "archive member /$k is not in +MANIFEST"
done
for p in "${files[@]}"; do
	[[ -n ${member[${p#/}]:-} ]] || die "$p is not in the archive"
done

# 4. each file: mode, owner, sum, content
b32=ybndrfg8ejkmcpqxot1uwisza345h769
blake2() { # pkg's 2$ sum: BLAKE2b-512, base32 taking the bits least significant first
	local acc=0 n=0 out='' b
	for b in $(openssl dgst -blake2b512 -binary <"$1" | od -An -v -tu1); do
		acc=$((acc | b << n)) n=$((n + 8))
		while ((n >= 5)); do
			out+=${b32:acc & 31:1}
			acc=$((acc >> 5)) n=$((n - 5))
		done
	done
	((n == 0)) || out+=${b32:acc:1}
	echo "$out"
}
for p in "${files[@]}"; do
	k=${p#/}
	if [[ $p == "$vfile" || -n ${gz[$p]:-} ]]; then
		perm=0644
	elif [[ -x $dir/src/${from[$p]} ]]; then
		perm=0755
	else
		perm=0644
	fi
	mode=-rw-r--r--
	[[ $perm == 0755 ]] && mode=-rwxr-xr-x
	v=$(jq -r --arg p "$p" '.files[$p].perm // empty' <<<"$M")
	[[ $v == "$perm" ]] || die "$p: mode ${v:-none} in +MANIFEST, expected $perm"
	read -r amode f2 f3 f4 _ <<<"${line[$k]}"
	[[ ${line[$k]} == *" ${member[$k]}" ]] || die "archive member $p: cannot read its listing"
	[[ $amode == "$mode" ]] || die "$p: mode $amode in the archive, expected $mode"
	v=$(jq -r --arg p "$p" '.files[$p] | "\(.uname // ""):\(.gname // "")"' <<<"$M")
	[[ $v == root:wheel ]] || die "$p: owner $v in +MANIFEST, expected root:wheel"
	if [[ $f2 == */* ]]; then v=${f2/\//:}; else v=$f3:$f4; fi
	[[ $v == root:wheel ]] || die "$p: owner $v in the archive, expected root:wheel"
	extract "$k" >"$work/packaged" || die "cannot extract $p"
	v=$(jq -r --arg p "$p" '.files[$p].sum // ""' <<<"$M")
	case $v in
	1\$*) got=$(sha256sum <"$work/packaged" | cut -d' ' -f1) ;;
	2\$*) got=$(blake2 "$work/packaged") ;;
	*\$*) die "$p: +MANIFEST sum type ${v%%\$*} is not supported" ;;
	*) die "$p: +MANIFEST sum ${v:-none} has no type" ;;
	esac
	[[ ${v#*\$} == "$got" ]] || die "$p: +MANIFEST sum does not match the content"
	[[ $p != "$vfile" ]] || continue
	src=$dir/src/${from[$p]}
	if [[ -n ${subst[$p]} ]]; then
		jq -Rsj . "$src" | cmp -s - "$src" || die "src/${from[$p]}: not UTF-8 text, cannot substitute"
		jq -Rsj --argjson m "$map" 'reduce $m[] as $r (.; split($r[0]) | join($r[1]))' "$src" >"$work/expected"
		src=$work/expected
	fi
	if [[ -n ${gz[$p]} ]]; then
		gzip -dc <"$work/packaged" >"$work/unpacked" 2>/dev/null || die "$p is not gzip data"
		mv "$work/unpacked" "$work/packaged"
	fi
	cmp -s "$work/packaged" "$src" || die "$p differs from src/${from[$p]}"
done

echo "payload: OK (${#files[@]} files)"
jq -r '.scripts // {} | to_entries | sort_by(.key)[] | "script \(.key):", (.value | split("\n")[] | "\t" + .)' <<<"$M"
