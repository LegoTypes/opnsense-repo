#!/usr/bin/env bash
# Copyright (C) 2026 cayossarian
# ubuntu-apt.sh <package>...
# Install Ubuntu packages on the runner from the image's own Ubuntu archive only:
# /etc/apt/sources.list.d/ubuntu.sources, whose Release files apt checks against Ubuntu's
# archive key; every other apt source the image configures is ignored, and nothing else is
# downloaded. Through sudo unless run as root. Package maintainer scripts run as root, so a
# job runs this before any secret is staged. Prints each package's installed version.
set -euo pipefail

UBUNTU_SOURCES=/etc/apt/sources.list.d/ubuntu.sources

die() {
	echo "ubuntu-apt.sh: $*" >&2
	exit 1
}

[[ $# -ge 1 ]] || die "usage: ubuntu-apt.sh <package>..."
for p in "$@"; do
	# a Debian package name, so no argument reads as an apt-get option
	[[ $p =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "not a package name: $(printf %q "$p")"
done
[[ -f $UBUNTU_SOURCES ]] ||
	die "$UBUNTU_SOURCES is missing: packages come from the image's Ubuntu archive only"

none=$(mktemp -d)
trap 'rm -rf "$none"' EXIT
sudo=()
[[ $(id -u) -eq 0 ]] || sudo=(sudo)
apt=("${sudo[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -q
	-o "Dir::Etc::SourceList=$UBUNTU_SOURCES" -o "Dir::Etc::SourceParts=$none")
"${apt[@]}" update >&2
"${apt[@]}" -y --no-install-recommends install "$@" >&2
dpkg-query -W -f '${Package} ${Version}\n' "$@"
