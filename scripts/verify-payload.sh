#!/usr/bin/env bash
# Copyright (C) 2026 cayossarian
# verify-payload.sh <pkg> <plugin dir> <name> <version> <abi> <series> <commit>
# Check, before a package is signed, that it holds exactly what Mk/plugins.mk install
# makes of the plugin directory at the approved commit, without running Mk/: every
# regular file under src/ (but top-level dot files, as "find *" skips them) lands
# under /usr/local/, a .in file sed-substituted and without .in, a .shadow file as
# .sample (.shadow.in both), a man/ file gzipped; modes are kept (0755 or 0644, a
# man page 0644); /usr/local/opnsense/version/<PLUGIN_NAME> is rendered from
# Templates/version. Its ten values, which are also the .in substitutions, are
# derived here as plugins.mk derives them (plugins.mk:39-122, defaults.mk:42-54,
# with build-package.sh's PLUGIN_DEVEL= and PLUGIN_ABI=<series>): PLUGIN_NAME,
# PLUGIN_VERSION[_PLUGIN_REVISION], PLUGIN_MAINTAINER (N/A), PLUGIN_WWW
# (https://opnsense.org/), PLUGIN_TIER (3) and PLUGIN_CONFLICTS from the Makefile,
# the arch from the ABI, product_abi from the series, the hash from the commit (as
# Scripts/version.sh abbreviates it, 9 characters).
# Checks, failing on the first problem:
# 0. The Makefile: plain assignments to the variables modelled, then the include;
#    <name> is os-<PLUGIN_NAME> and <version> the version it gives. The archive, as
#    libarchive (bsdtar, the parser pkg installs with) reads it: each member once
#    and a regular file; any message from bsdtar is a failure.
# 1. +MANIFEST, +COMPACT_MANIFEST: UTF-8 JSON with no key repeated (jq keeps the
#    last, pkg takes them all); only the keys pkg create writes for a plugin; the
#    compact one is +MANIFEST without files and scripts; name, version, abi and
#    annotation product_abi as given; every other value plugins.mk's manifest target
#    (plugins.mk:125-150) and pkg create write, derived: origin opnsense/<name>,
#    comment PLUGIN_COMMENT, maintainer and www as in the version file, categories the
#    plugin directory's parent (.CURDIR's second last word), prefix /usr/local,
#    licenselogic single, licenses PLUGIN_LICENSE (BSD2CLAUSE), arch the ABI's legacy
#    form (libpkg pkg_arch_to_legacy), desc pkg-descr trimmed of blanks at both ends
#    (UCL_STRING_TRIM) and compared as pkg reads it, url-decoded (STRING_FLAG_URLDECODE);
#    dependency names equal PLUGIN_DEPENDS, each entry exactly an origin and a version;
#    scripts only under pkg's script names, printable ASCII, tab and newline, no
#    %-escape but %25 (pkg url-decodes scripts). Not derivable, so not compared: a
#    dependency's origin and version (what the build VM had installed) and each file's
#    mtime; the scripts are shown to the approver.
# 2. The version file: no key repeated, exactly the derived ten values; the
#    annotations repeat it, and add FreeBSD_version: all digits, of the ABI's major.
# 3. The files: +MANIFEST's map one to one onto src/, each entry exactly the keys
#    pkg create writes (pkg reads them in any case, so no other may stand beside
#    them), and the archive holds exactly those and the two manifests.
# 4. Each file: mode and owner (root:wheel) in +MANIFEST and in the archive, which
#    is what pkg installs, and no file flags; the mode 0755 when the source's owner
#    execute bit is set (as git records it; read with stat), else 0644; the +MANIFEST
#    sum (1$ sha256 or 2$ BLAKE2b in pkg's base32) matches the content; the content
#    equals the source after substitution (.in) and gunzip (man/); flatsize is the
#    packaged files' size.
# On success prints "payload: OK (<n> files)" (<n> counts the version file) and then
# each install script as pkg will run it (url-decoded), its name on a line
# ("script post-install:") and its lines indented by a tab; on the first problem
# exits 1 with the reason on stderr.
# Not modelled, so refused: contrib/, Makefile variables other than those above
# and PLUGIN_COMMENT, PLUGIN_DEPENDS and PLUGIN_LICENSE, values holding $, `, " or
# \ (make or sh would expand them) or &, = or %% (sed would not copy them
# literally), a PLUGIN_LICENSE of more than one word, a man page with .shadow, file
# names outside [A-Za-z0-9._+,@=~-], a .in file that is not UTF-8, and a pkg-descr
# that is missing, a symbolic link or other than printable ASCII, tab and newline.
# Needs bash 4, jq, bsdtar (libarchive; on Ubuntu the libarchive-tools package) with
# zstd, sha256sum, openssl (BLAKE2b), gzip, cmp, stat (GNU or BSD).
set -euo pipefail

die() {
	echo "verify-payload.sh: $*" >&2
	exit 1
}

[[ $# -eq 7 ]] || die "usage: verify-payload.sh <pkg> <plugin dir> <name> <version> <abi> <series> <commit>"
pkg=$1 dir=${2%/} name=$3 version=$4 abi=$5 series=$6 commit=$7
[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "the commit must be 40 lowercase hex digits: $commit"
[[ $abi =~ ^FreeBSD:[0-9]+:[a-z0-9_]+$ ]] || die "the ABI must read FreeBSD:<major>:<arch>: $abi"
[[ $series =~ ^[0-9]+\.[0-9]+$ ]] || die "the series must read <year>.<month>: $series"
hash=${commit:0:9}
[[ -f $pkg ]] || die "$pkg: no such file"
[[ -f $dir/Makefile ]] || die "$dir: no Makefile"
[[ -d $dir/src ]] || die "$dir: no src/"
[[ ! -e $dir/contrib ]] || die "contrib/ is not supported"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 0. the Makefile: lines joined as make joins continuations, plain assignments, then the include
awk '{ while (/\\$/) { sub(/[ \t]*\\$/, ""); l = $0; if ((getline n) <= 0) break; sub(/^[ \t]+/, "", n); $0 = l " " n } print }' \
	"$dir/Makefile" >"$work/makefile" || die "cannot read $dir/Makefile"
modelled=" PLUGIN_NAME PLUGIN_VERSION PLUGIN_REVISION PLUGIN_COMMENT PLUGIN_MAINTAINER PLUGIN_WWW PLUGIN_TIER
	PLUGIN_CONFLICTS PLUGIN_DEPENDS PLUGIN_LICENSE "
declare -A mk=()
included=''
while IFS= read -r l; do
	case $l in
	'' | '#'*) continue ;;
	'.include "../../Mk/plugins.mk"')
		[[ -z $included ]] || die "Makefile: the plugins.mk include is repeated"
		included=1
		continue
		;;
	esac
	[[ $l =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*([?+:!]?)=(.*)$ ]] || die "Makefile: $l is not supported"
	var=${BASH_REMATCH[1]} op=${BASH_REMATCH[2]} val=${BASH_REMATCH[3]%%#*}
	[[ -z $included ]] || die "Makefile: $var is set after the plugins.mk include"
	[[ $modelled == *[[:space:]]${var}[[:space:]]* ]] || die "Makefile: $var is not supported"
	[[ $op != '!' ]] || die "Makefile: $var is set with !=, which is not supported"
	case $val in
	*'$'* | *'`'* | *'"'* | *\\*) die "Makefile: $var holds \$, \`, \" or \\, which make or sh would expand" ;;
	esac
	val=${val#"${val%%[![:space:]]*}"}
	val=${val%"${val##*[![:space:]]}"}
	case $op in
	'+') mk[$var]=${mk[$var]:+${mk[$var]} }$val ;;
	'?') [[ -n ${mk[$var]+set} ]] || mk[$var]=$val ;;
	*) mk[$var]=$val ;;
	esac
done <"$work/makefile"
[[ -n $included ]] || die 'Makefile: no .include "../../Mk/plugins.mk"'
for v in PLUGIN_NAME PLUGIN_VERSION PLUGIN_COMMENT; do
	[[ -n ${mk[$v]:-} ]] || die "Makefile: $v is not set"
done
for v in PLUGIN_NAME PLUGIN_VERSION PLUGIN_REVISION PLUGIN_TIER PLUGIN_LICENSE; do
	[[ -z ${mk[$v]:-} || ${mk[$v]} =~ ^[A-Za-z0-9._+-]+$ ]] || die "Makefile: $v is not one plain word"
done
for v in PLUGIN_MAINTAINER PLUGIN_WWW PLUGIN_CONFLICTS; do
	case ${mk[$v]:-} in
	*'&'* | *'='* | *'%%'*) die "Makefile: $v holds &, = or %%, which sed would not copy literally" ;;
	esac
done
# pkg-descr, which plugins.mk's description target writes as +DESC (PLUGIN_DESC is not the
# Makefile's to change): printable ASCII, tab and newline, so jq reads it byte for byte
descr=$dir/pkg-descr
[[ -f $descr && ! -L $descr ]] || die "$dir: no pkg-descr"
if LC_ALL=C grep -q $'[^\t -~]' "$descr"; then
	die "pkg-descr: not printable ASCII text, tab and newline, which is not supported"
fi
# trimmed as UCL_STRING_TRIM trims (libucl: space, tab, newline, VT, FF, CR)
want_desc=$(jq -Rs 'sub("\\A[ \t\n\u000b\f\r]+"; "") | sub("[ \t\n\u000b\f\r]+\\z"; "")' "$descr")
# the category: the second last word of the directory make runs in (.CURDIR), the
# plugin's directory resolved as make resolves it
real=$(CDPATH='' cd -- "$dir" && pwd -P) || die "cannot resolve $dir"
category=${real%/*}
category=${category##*/}
[[ $category =~ ^[A-Za-z0-9._+-]+$ ]] || die "$dir: the category ${category:-(none)} is not one plain word"
# the legacy arch pkg create writes beside the ABI (libpkg pkg_abi.c pkg_arch_to_legacy and
# machine_arch_translation at pkg 2.8.4): the OS in lower case, the major, then the machine
# as its ELF type, or as it is when the table has none
declare -A elf=([i386]=x86:32 [amd64]=x86:64 [powerpc]=powerpc:32:eb [powerpc64]=powerpc:64:eb
	[powerpc64le]=powerpc:64:el [sparc64]=sparc64:64 [ia64]=ia64:64 [armv6]=armv6:32:el:eabi:hardfp
	[armv7]=armv7:32:el:eabi:hardfp [aarch64]=aarch64:64 [aarch64c]=aarch64:64:cheri
	[aarch64cb]=aarch64:64:cheri:benchmark [mipsel]=mips:32:el:o32 [mipsn32el]=mips:32:el:n32
	[mips]=mips:32:eb:o32 [mipsn32]=mips:32:eb:n32 [mips64el]=mips:64:el:n64 [mips64]=mips:64:eb:n64
	[riscv32]=riscv:32:hf [riscv32sf]=riscv:32:sf [riscv64]=riscv:64:hf [riscv64c]=riscv:64:cheri:hf
	[riscv64sf]=riscv:64:sf)
machine=${abi##*:}
major=${abi#FreeBSD:}
major=${major%%:*}
legacy=freebsd:$major:${elf[$machine]:-$machine}
pname=${mk[PLUGIN_NAME]}
pkgversion=${mk[PLUGIN_VERSION]}
[[ ${mk[PLUGIN_REVISION]:-0} == 0 ]] || pkgversion+=_${mk[PLUGIN_REVISION]}
[[ $name == "os-$pname" ]] || die "the name $name is not os-$pname, as the Makefile names it"
[[ $version == "$pkgversion" ]] || die "the version $version is not $pkgversion, as the Makefile gives it"
vfile=/usr/local/opnsense/version/$pname
# plugins.mk:77-79,110,114: each conflict and its -devel, the plugin's own -devel, os- before each, sorted
read -ra words <<<"${mk[PLUGIN_CONFLICTS]:-}"
clist=()
for c in "${words[@]}"; do
	[[ $c =~ ^[A-Za-z0-9._+-]+$ ]] || die "Makefile: PLUGIN_CONFLICTS holds $c, not a plain word"
	clist+=("os-$c" "os-$c-devel")
done
clist+=("os-$pname-devel")
conflicts=$(printf '%s\n' "${clist[@]}" | LC_ALL=C sort | paste -sd' ' -)
want=$(jq -cn --arg abi "$series" --arg arch "${abi##*:}" --arg conflicts "$conflicts" \
	--arg email "${mk[PLUGIN_MAINTAINER]:-N/A}" --arg hash "$hash" --arg id "$name" --arg name "$pname" \
	--arg tier "${mk[PLUGIN_TIER]:-3}" --arg version "$pkgversion" --arg www "${mk[PLUGIN_WWW]:-https://opnsense.org/}" \
	'{product_abi: $abi, product_arch: $arch, product_conflicts: $conflicts, product_email: $email,
	product_hash: $hash, product_id: $id, product_name: $name, product_tier: $tier, product_version: $version,
	product_website: $www}')
read -ra words <<<"${mk[PLUGIN_DEPENDS]:-}"
want_deps=$(jq -rn '$ARGS.positional | unique | join(" ")' --args "${words[@]}")

# 0. the archive: names, types and attributes as libarchive reads them; bsdtar must say nothing on stderr
bt() { # bt <output file> <bsdtar arguments>...
	local out=$1
	shift
	bsdtar "$@" >"$out" 2>"$work/err" || die "$pkg: bsdtar failed: $(head -n 1 "$work/err")"
	[[ ! -s $work/err ]] || die "$pkg: bsdtar: $(head -n 1 "$work/err")"
}
bt "$work/list" -tf "$pkg"
bt "$work/verbose" -tvf "$pkg"
mapfile -t listed <"$work/list"
mapfile -t verbose <"$work/verbose"
[[ ${#listed[@]} -gt 0 && ${#listed[@]} -eq ${#verbose[@]} ]] || die "$pkg: not a readable archive"
declare -A member=()
for i in "${!listed[@]}"; do
	m=${listed[i]}
	k=${m#/}
	[[ -z ${member[$k]:-} ]] || die "archive member $m appears twice"
	member[$k]=$m
	# a hard link is told from a regular file here or nowhere: libarchive's mtree output
	# (step 4) writes a hard link as type=file, as mtree has no hard link type (its link
	# keyword is a symbolic link's target), while bsdtar -tv marks it "h"
	case ${verbose[i]:0:1} in
	-) ;;
	h) die "archive member $m is a hard link, not a regular file" ;;
	l) die "archive member $m is a symbolic link, not a regular file" ;;
	d) die "archive member $m is a directory, not a regular file" ;;
	*) die "archive member $m is not a regular file" ;;
	esac
done
[[ -n ${member[+MANIFEST]:-} && -n ${member[+COMPACT_MANIFEST]:-} ]] || die "$pkg: lacks +MANIFEST or +COMPACT_MANIFEST"
extract() { bt "$2" -xOPf "$pkg" "${member[$1]}"; }
# json <file> <what>: one JSON value, UTF-8 (jq would read invalid bytes as U+FFFD), no key repeated (the
# streamed leaves of the text outnumber those of the parsed value exactly when a key repeats)
json() {
	jq -es 'length == 1' "$1" >/dev/null 2>&1 || die "$2 is not one JSON value"
	jq -Rsj . "$1" | cmp -s - "$1" || die "$2 is not UTF-8 text"
	[[ $(jq -n --stream '[inputs | select(length == 2)] | length' "$1") == $(jq '[tostream | select(length == 2)] | length' "$1") ]] ||
		die "$2 repeats a key"
}
is() { [[ $2 == "$3" ]] || die "$1 is $2, expected $3"; }

# 1. +MANIFEST
extract +MANIFEST "$work/manifest"
extract +COMPACT_MANIFEST "$work/compact"
json "$work/manifest" +MANIFEST
json "$work/compact" +COMPACT_MANIFEST
jq -e 'type == "object"' "$work/manifest" >/dev/null || die "+MANIFEST is not a JSON object"
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
# field <key> <want>: +MANIFEST's string <key> is <want>; list <key> <want JSON>: its value is <want>
field() {
	local v
	v=$(jq -r --arg k "$1" '.[$k] | strings' <<<"$M")
	[[ $v == "$2" ]] || die "+MANIFEST $1 is ${v:-none}, expected $2"
}
list() {
	local v
	v=$(jq -c --arg k "$1" '.[$k]' <<<"$M")
	[[ $v == "$2" ]] || die "+MANIFEST $1 is $v, expected $2"
}
field origin "opnsense/$name"
field comment "${mk[PLUGIN_COMMENT]}"
field maintainer "${mk[PLUGIN_MAINTAINER]:-N/A}"
field www "${mk[PLUGIN_WWW]:-https://opnsense.org/}"
list categories "$(jq -cn --arg c "$category" '[$c]')"
field prefix /usr/local
field licenselogic single
list licenses "$(jq -cn --arg l "${mk[PLUGIN_LICENSE]:-BSD2CLAUSE}" '[$l]')"
field arch "$legacy"
# desc as pkg reads it: libpkg's url_decode, a % and two hex digits one byte (pkg create
# writes % and every byte beyond ASCII so); pkg-descr is ASCII, so a byte decoded beyond it
# never compares equal
jq -e --argjson d "$want_desc" '
	def hexv: if . >= 97 then . - 87 elif . >= 65 then . - 55 else . - 48 end;
	def isx: (. >= 48 and . <= 57) or (. >= 65 and . <= 70) or (. >= 97 and . <= 102);
	(.desc | strings | explode) as $c | ($c | length) as $n
	| [foreach range(0; $n) as $i ({s: 0, o: null};
		if .s > 0 then {s: (.s - 1), o: null}
		elif $c[$i] == 37 and $i + 2 < $n and ($c[$i + 1] | isx) and ($c[$i + 2] | isx)
		then {s: 2, o: (($c[$i + 1] | hexv) * 16 + ($c[$i + 2] | hexv))}
		else {s: 0, o: $c[$i]} end;
		.o | values)] | implode == $d' <<<"$M" >/dev/null || die "+MANIFEST desc, as pkg decodes it, is not pkg-descr"
jq -e '.scripts // {} | type == "object" and all(.[]; type == "string")' <<<"$M" >/dev/null ||
	die "+MANIFEST scripts are not an object of strings"
# pkg_manifest.c script_type_str: the names pkg runs; pkg url-decodes each script, and pkg create
# encodes only % (as %25) and bytes beyond ASCII
v=$(jq -r '.scripts // {} | keys - ["pre-install", "install", "post-install", "pre-deinstall", "deinstall",
	"post-deinstall"] | .[0] // empty | tojson' <<<"$M")
[[ -z $v ]] || die "script $v is not a pkg script name"
v=$(jq -r '.scripts // {} | to_entries
	| map(select(.value | explode | any(. != 9 and . != 10 and (. < 32 or . > 126))))[0].key // empty' <<<"$M")
[[ -z $v ]] || die "script $v holds characters other than printable ASCII, tab and newline"
v=$(jq -r '.scripts // {} | to_entries | map(select(.value | test("%(?!25)")))[0].key // empty' <<<"$M")
[[ -z $v ]] || die "script $v holds a %-escape other than %25, which pkg would decode"
# pkg reads a dependency's origin and version keys in any case: exactly those two, as strings
jq -e '.deps // {} | type == "object" and all(.[]; type == "object" and keys == ["origin", "version"] and all(.[]; type == "string"))' \
	<<<"$M" >/dev/null || die "+MANIFEST dependencies are not entries of exactly an origin and a version"
have_deps=$(jq -r '.deps // {} | keys | join(" ")' <<<"$M")
[[ $have_deps == "$want_deps" ]] ||
	die "dependencies (${have_deps:-none}) differ from PLUGIN_DEPENDS (${want_deps:-none})"

# 2. the version file
jq -e --arg v "$vfile" '.files | type == "object" and has($v)' <<<"$M" >/dev/null || die "+MANIFEST lists no $vfile"
[[ -n ${member[${vfile#/}]:-} ]] || die "$vfile is not in the archive"
extract "${vfile#/}" "$work/version"
json "$work/version" "version file"
jq -e --argjson w "$want" 'type == "object" and keys == ($w | keys) and all(.[]; type == "string")' \
	"$work/version" >/dev/null || die "version file: not exactly the ten product_* strings"
V=$(jq -c . "$work/version")
for k in $(jq -r 'keys[]' <<<"$want"); do
	is "version file: $k" "$(jq -r --arg k "$k" '.[$k]' <<<"$V")" "$(jq -r --arg k "$k" '.[$k]' <<<"$want")"
done
jq -e --argjson v "$V" '.annotations | type == "object" and del(.FreeBSD_version) == $v' <<<"$M" >/dev/null ||
	die "+MANIFEST annotations differ from the version file"
# FreeBSD_version: pkg create's "%d" of the build host's osversion, whose major is the ABI's
fv=$(jq -c '.annotations.FreeBSD_version' <<<"$M")
[[ $fv =~ ^\"[0-9]+\"$ ]] || die "+MANIFEST annotation FreeBSD_version is $fv, not all digits"
fv=${fv//\"/}
[[ ${#fv} -gt 5 && ${fv:0:${#fv}-5} == "$major" ]] || die "+MANIFEST annotation FreeBSD_version is \"$fv\", not FreeBSD $major's"
# the tokens in Mk/defaults.mk REPLACEMENTS order (sed applies them in turn), with the derived values;
# PLUGIN_VARIANT is empty without variants
map=$(jq -c '[["PLUGIN_ABI", .product_abi], ["PLUGIN_ARCH", .product_arch], ["PLUGIN_CONFLICTS", .product_conflicts],
	["PLUGIN_HASH", .product_hash], ["PLUGIN_MAINTAINER", .product_email], ["PLUGIN_NAME", .product_name],
	["PLUGIN_PKGNAME", .product_id], ["PLUGIN_PKGVERSION", .product_version], ["PLUGIN_TIER", .product_tier],
	["PLUGIN_VARIANT", ""], ["PLUGIN_WWW", .product_website]] | map(["%%" + .[0] + "%%", .[1]])' <<<"$want")

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
# pkg reads a file entry's keys in any case and also takes fflags and symlink_target: exactly
# the five pkg create writes, mtime a number and the rest strings
v=$(jq -r '.files | to_entries | map(select(.value | (keys != ["gname", "mtime", "perm", "sum", "uname"])
	or ((.mtime | type) != "number") or ([.gname, .perm, .sum, .uname] | any(type != "string"))))[0].key // empty' <<<"$M")
[[ -z $v ]] || die "+MANIFEST file $v is not exactly gname, mtime, perm, sum and uname"
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
		die "archive member ${member[$k]} is not in +MANIFEST"
done
for p in "${files[@]}"; do
	[[ -n ${member[${p#/}]:-} ]] || die "$p is not in the archive"
done

# 4. each member's attributes as libarchive gives them to pkg (mtree keywords, names escaped as \ooo);
# every member now has a plain name of its own, so the listing maps onto them one to one
bt "$work/mtree" -cPf - --format=mtree --options '!all,type,mode,uname,gname,flags,link' "@$pkg"
declare -A attrs=()
while IFS= read -r l; do
	[[ $l != '#'* ]] || continue
	[[ $l != /* ]] || die "$pkg: unexpected listing line $l"
	n=${l%% *}
	printf -v n '%b' "${n//\\/\\0}"
	n=${n#./}
	[[ -n ${member[$n]:-} && -z ${attrs[$n]:-} ]] || die "$pkg: the archive's listings disagree on $n"
	attrs[$n]=" ${l#* } "
	[[ ${attrs[$n]} != *' flags='* ]] || { v=${attrs[$n]#* flags=}; die "archive member ${member[$n]} has file flags (${v%% *})"; }
done <"$work/mtree"
[[ ${#attrs[@]} -eq ${#member[@]} ]] || die "$pkg: the archive's listings disagree"
attr() { # attr <member> <keyword>: its value, or none
	local a=${attrs[$1]}
	if [[ $a == *" $2="* ]]; then a=${a#* "$2"=} && echo "${a%% *}"; else echo none; fi
}
for k in +MANIFEST +COMPACT_MANIFEST; do
	[[ $(attr "$k" type) == file && $(attr "$k" link) == none ]] || die "archive member $k is not a regular file"
done

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
# mode <file>: its permission bits in octal, from GNU stat or else BSD stat
mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp -- "$1"; }
flat=0
for p in "${files[@]}"; do
	k=${p#/}
	if [[ $p == "$vfile" || -n ${gz[$p]:-} ]]; then
		perm=0644
	else
		# git records a file executable by its owner execute bit, and the build checks the
		# source out with umask 022: 0755 or 0644 (test -x would ask whether this user may run it)
		m=$(mode "$dir/src/${from[$p]}") || die "cannot read the mode of src/${from[$p]}"
		[[ $m =~ ^[0-7]{1,4}$ ]] || die "src/${from[$p]}: stat gives the mode $m"
		if ((8#$m & 8#100)); then perm=0755; else perm=0644; fi
	fi
	v=$(jq -r --arg p "$p" '.files[$p].perm // empty' <<<"$M")
	[[ $v == "$perm" ]] || die "$p: mode ${v:-none} in +MANIFEST, expected $perm"
	[[ $(attr "$k" type) == file && $(attr "$k" link) == none ]] || die "archive member $p is not a regular file"
	v=$(attr "$k" mode)
	while [[ ${#v} -lt 4 ]]; do v=0$v; done
	[[ $v == "$perm" ]] || die "$p: mode $v in the archive, expected $perm"
	v=$(jq -r --arg p "$p" '.files[$p] | "\(.uname // ""):\(.gname // "")"' <<<"$M")
	[[ $v == root:wheel ]] || die "$p: owner $v in +MANIFEST, expected root:wheel"
	v=$(attr "$k" uname):$(attr "$k" gname)
	[[ $v == root:wheel ]] || die "$p: owner $v in the archive, expected root:wheel"
	extract "$k" "$work/packaged"
	flat=$((flat + $(wc -c <"$work/packaged")))
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

# flatsize: pkg create's sum of the packaged files' sizes (no hard links: each counts once)
v=$(jq -r '.flatsize | numbers' <<<"$M")
[[ $v == "$flat" ]] || die "+MANIFEST flatsize is ${v:-none}, expected $flat"

echo "payload: OK (${#files[@]} files)"
jq -r '.scripts // {} | to_entries | sort_by(.key)[]
	| "script \(.key):", (.value | split("%25") | join("%") | split("\n")[] | "\t" + .)' <<<"$M"
