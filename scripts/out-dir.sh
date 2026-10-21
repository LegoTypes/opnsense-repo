#!/usr/bin/env bash
# Copyright (C) 2026 cayossarian
# out-dir.sh <package> <dir>
# Check a build's output, which the build VM wrote, before anything reads it or uploads it
# (upload-artifact follows symlinks): <dir> holds exactly <package>-<version>.pkg, source and
# build, each a regular file (not a symlink). <version> is [0-9][0-9A-Za-z._,]*, so the tag
# release.sh derives from the file name is one plain word; source is one line of printable
# ASCII; build is the five lines build-package.sh writes, "abi:", "series:", "freebsd:",
# "php:" and "python:", each value of [A-Za-z0-9._:-] (provenance.sh reads both, and composes
# the release notes' own lines). Prints the package's path. A name in an error is quoted
# (printf %q), so no name the VM chose reaches the log as a line of its own.
set -euo pipefail
export LC_ALL=C

die() {
	echo "out-dir.sh: $*" >&2
	exit 1
}
q() { printf %q "$1"; }

[[ $# -eq 2 ]] || die "usage: out-dir.sh <package> <dir>"
pkg=$1 dir=$2
[[ $pkg =~ ^[a-z0-9]+(-[a-z][a-z0-9]*)*$ ]] || die "not a package name: $(q "$pkg")"
[[ -d $dir && ! -L $dir ]] || die "$(q "$dir") is not a directory"

found=''
shopt -s dotglob nullglob
for f in "$dir"/*; do
	b=${f##*/}
	[[ -f $f && ! -L $f ]] || die "$(q "$b") in $(q "$dir") is not a regular file"
	case $b in
	source | build) ;;
	*)
		[[ $b =~ ^$pkg-[0-9][0-9A-Za-z._,]*\.pkg$ ]] || die "$(q "$dir") holds $(q "$b"), not a build of $pkg"
		[[ -z $found ]] || die "$(q "$dir") holds more than one $pkg package"
		found=$f
		;;
	esac
done
[[ -n $found ]] || die "$(q "$dir") holds no $pkg-<version>.pkg"
[[ -f $dir/source && -f $dir/build ]] || die "$(q "$dir") must hold source and build"

mapfile -t lines <"$dir/source"
[[ ${#lines[@]} -eq 1 && ${lines[0]} =~ ^[\ -~]+$ ]] || die "source must be one line of printable ASCII"
mapfile -t lines <"$dir/build"
keys=(abi series freebsd php python)
[[ ${#lines[@]} -eq ${#keys[@]} ]] || die "build must be the ${#keys[@]} lines build-package.sh writes"
for i in "${!keys[@]}"; do
	[[ ${lines[i]} =~ ^${keys[i]}:\ [A-Za-z0-9._:-]+$ ]] || die "build line $((i + 1)) is not \"${keys[i]}: <value>\""
done
printf '%s\n' "$found"
