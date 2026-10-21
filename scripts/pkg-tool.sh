#!/usr/bin/env bash
# Build FreeBSD's pkg from source, for "pkg repo" on the runner (the sign job):
#   bash scripts/pkg-tool.sh <dest dir>
# installs <dest dir>/sbin/pkg and prints that path (everything else goes to stderr).
# The source is GitHub's archive of freebsd/pkg at PKG_TOOL_COMMIT (repo.conf), refused
# before anything is unpacked or built unless its sha256 is PKG_TOOL_SHA256.
#
# On Linux the build dependencies are installed by ubuntu-apt.sh, from the image's own
# Ubuntu archive only, and nothing else is downloaded. Run it before the signing key is
# staged: package maintainer scripts run as root. Elsewhere (local testing) the
# dependencies must already be installed.
#
# The binary holds libpkg and pkg's bundled libraries (sqlite, lua, libucl, ...) and links
# libarchive, OpenSSL, libbsd and the compression libraries dynamically, so it runs where it
# was built. Only sbin/pkg is installed: no libpkg, man pages or pkg.conf (pkg reads
# <dest dir>/etc/pkg.conf if one is ever put there).
set -euo pipefail

# what configure and make need on Ubuntu, from freebsd/pkg's own CI
# (.github/workflows/build.yaml) less its test suite, compiler choice and the libraries
# only a static link of libarchive would want; m4 generates the bundled libelf
DEPS=(build-essential m4 libarchive-dev libssl-dev libbsd-dev zlib1g-dev libbz2-dev liblzma-dev)

die() {
	echo "pkg-tool.sh: $*" >&2
	exit 1
}

[[ $# -eq 1 && -n $1 ]] || die "usage: pkg-tool.sh <dest dir>"
here=$(cd "$(dirname "$0")" && pwd)
commit=$(sh "$here/repo.sh" pkg-tool-commit)
want=$(sh "$here/repo.sh" pkg-tool-sha256)
# stdout carries only the installed path
exec 3>&1 1>&2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

url=https://github.com/freebsd/pkg/archive/$commit.tar.gz
curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$work/pkg.tar.gz" "$url" || die "could not download $url"
got=$(sha256sum "$work/pkg.tar.gz" | cut -d' ' -f1)
# GitHub generates the archive on request; a change in its output (compression, tar
# headers) shows here as a different sha256 for the same commit, and nothing is built
[[ $got == "$want" ]] ||
	die "$url has sha256 $got, not the pinned $want (repo.conf PKG_TOOL_SHA256): refusing to build it"
echo "pkg-tool.sh: freebsd/pkg $commit, sha256 $got"

mkdir "$work/src" "$work/build"
tar -xzf "$work/pkg.tar.gz" -C "$work/src"
src=$work/src/pkg-$commit
[[ -x $src/configure ]] || die "the archive of $commit holds no pkg-$commit/configure"

if [[ $(uname -s) == Linux ]]; then
	bash "$here/ubuntu-apt.sh" "${DEPS[@]}"
else
	echo "pkg-tool.sh: not Linux: building with the dependencies already installed"
fi

mkdir -p "$1"
dest=$(cd "$1" && pwd)
(
	cd "$work/build"
	"$src/configure" --prefix="$dest"
	make -j"$(getconf _NPROCESSORS_ONLN)"
)
install -d "$dest/sbin"
install -m 0755 "$work/build/src/pkg" "$dest/sbin/pkg"
version=$("$dest/sbin/pkg" -v) || die "the built $dest/sbin/pkg does not run"
echo "pkg-tool.sh: built pkg $version"
echo "$dest/sbin/pkg" >&3
