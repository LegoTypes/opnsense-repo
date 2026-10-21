#!/usr/bin/env bash
# Copyright (C) 2026 cayossarian
# payload.sh <package> <out dir> <plugin dir>
# verify-payload.sh on the build in <out dir> (out-dir.sh) against <plugin dir>, the
# plugin's directory at COMMIT (plugin-source.sh): the version is the built file's, which
# verify-payload.sh checks against the plugin's Makefile, the ABI and series are
# repo.conf's, the commit is COMMIT. The output and exit status are verify-payload.sh's.
# The sign job runs it to refuse a build that is not exactly the source at the approved
# commit; the build job's summary shows its result.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

die() {
	echo "payload.sh: $*" >&2
	exit 1
}

[[ $# -eq 3 ]] || die "usage: payload.sh <package> <out dir> <plugin dir>"
pkg=$1 out=$2 dir=$3
[[ ${COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || die "COMMIT must be the approved commit, 40 lower-case hex digits"
file=$(bash "$here/out-dir.sh" "$pkg" "$out")
version=${file##*/}
version=${version#"$pkg"-}
version=${version%.pkg}
abi=$(sh "$here/repo.sh" abi)
series=$(sh "$here/repo.sh" series)
exec bash "$here/verify-payload.sh" "$file" "$dir" "$pkg" "$version" "$abi" "$series" "$COMMIT"
