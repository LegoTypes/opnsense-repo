#!/usr/bin/env bash
# What OPNsense ships now, from its package mirror (UPSTREAM_MIRROR, default
# https://pkg.opnsense.org), which is authoritative for what a firewall gets: core
# derives its PHP and Python versions from installed packages, so nothing in core's
# source declares them.
#   upstream.sh [series]   (default: repo.sh series)
# Prints:
#   NEWEST=   the newest series for our FreeBSD major
#   NEXT_ABI= FreeBSD:<major+1>:<arch> when the mirror has it, else empty
#   SERIES=   the series asked for, and from its catalogue:
#   CORE=     the opnsense package version
#   PHP=      the PHP version core depends on (php<NN>-*)
#   PYTHON=   the Python version core depends on (py<NNN>-*)
#   FREEBSD=  the FreeBSD release core was built on (major.minor)
# Any fetch or parse failure fails the script: a build or the canary must never
# fall back to stale values.
# The catalogue is verified as pkg verifies it (signature_type "fingerprints"): the
# sha256 of packagesite.yaml.pub must be a fingerprint in a file under keys/upstream/
# (OPNsense's, copied from opnsense/core; found from this script's own location, with
# no environment override), and packagesite.yaml.sig must verify over the sha256 hex
# of packagesite.yaml with that key, as sign-catalogue.sh checks our own catalogue. A
# key rotation upstream fails here: add the new fingerprint file, copied from core.
# Runs on the runner (build.yml, canary.yml), with tar reading zstd (Ubuntu's GNU tar
# with zstd installed, or bsdtar) and openssl.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
keys="$here/../keys/upstream"
mirror=${UPSTREAM_MIRROR:-https://pkg.opnsense.org}

die() {
	echo "upstream.sh: $*" >&2
	exit 1
}

[[ $# -le 1 ]] || die "usage: upstream.sh [series]"
abi=$(sh "$here/repo.sh" abi)
want=${1:-$(sh "$here/repo.sh" series)}
major=$(cut -d: -f2 <<<"$abi")
arch=$(cut -d: -f3 <<<"$abi")
next="FreeBSD:$((major + 1)):$arch"

# the directory names an Apache index links ("NAME/", or "./NAME/" for a name with a colon)
listing() {
	local page
	page=$(curl -fsSL "$1") || die "cannot read $1"
	grep -oE 'href="(\./)?[^"/?]+/"' <<<"$page" | sed -E 's/^href="(\.\/)?//; s/\/"$//' || true
}

root=$(listing "$mirror/")
grep -qxF "$abi" <<<"$root" || die "$mirror/ has no $abi"
# the next ABI counts once it holds a series, not while it holds only snapshots
next_abi=''
if grep -qxF "$next" <<<"$root"; then
	page=$(curl -fsSL "$mirror/$next/" 2>/dev/null || true)
	if grep -oE 'href="(\./)?[0-9]+\.[0-9]+/"' <<<"$page" >/dev/null; then next_abi=$next; fi
fi
newest=$(listing "$mirror/$abi/" | grep -E '^[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n | tail -n 1 || true)
[[ -n $newest ]] || die "$mirror/$abi/ lists no series"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/packagesite.pkg" "$mirror/$abi/$want/latest/packagesite.pkg" ||
	die "cannot fetch the $want catalogue"
tar -xf "$work/packagesite.pkg" -C "$work" packagesite.yaml packagesite.yaml.sig packagesite.yaml.pub 2>/dev/null ||
	die "the $want catalogue lacks packagesite.yaml, its signature or its key"
[[ -s $work/packagesite.yaml.sig && -s $work/packagesite.yaml.pub ]] || die "the $want catalogue's signature or key is empty"
fingerprint=$(openssl dgst -sha256 -r "$work/packagesite.yaml.pub" | cut -d' ' -f1)
[[ $fingerprint =~ ^[0-9a-f]{64}$ ]] || die "cannot fingerprint the $want catalogue's key"
grep -qxF "fingerprint: \"$fingerprint\"" "$keys"/* 2>/dev/null ||
	die "the $want catalogue is signed with a key (sha256 $fingerprint) that is no fingerprint in $keys"
openssl dgst -sha256 -r "$work/packagesite.yaml" | cut -d' ' -f1 | tr -d '\n' |
	openssl dgst -sha256 -verify "$work/packagesite.yaml.pub" -signature "$work/packagesite.yaml.sig" >/dev/null 2>&1 ||
	die "the $want catalogue's signature does not verify"
core=$(jq -c 'select(.name == "opnsense")' "$work/packagesite.yaml") || die "the $want catalogue does not parse"
[[ -n $core && $core != *$'\n'* ]] || die "the $want catalogue does not hold exactly one opnsense package"

# the single version number among core's dependency names that match <regex> (one group)
one() {
	local v
	v=$(jq -r '.deps // {} | keys[]' <<<"$core" | sed -nE "s/$2/\1/p" | sort -u)
	[[ -n $v && $v != *$'\n'* ]] || die "core's dependencies name no single $1 version (${v//$'\n'/ })"
	printf '%s\n' "$v"
}
php=$(one PHP '^php([0-9]+)-.*$')
python=$(one Python '^py([0-9]+)-.*$')
fbsd=$(jq -r '.annotations.FreeBSD_version // empty' <<<"$core")
[[ $fbsd =~ ^[0-9]{7}$ ]] || die "core in $want has no FreeBSD_version"

printf 'NEWEST=%s\nNEXT_ABI=%s\nSERIES=%s\nCORE=%s\nPHP=%s\nPYTHON=%s\nFREEBSD=%s.%s\n' \
	"$newest" "$next_abi" "$want" "$(jq -r .version <<<"$core")" "$php" "$python" \
	"$((fbsd / 100000))" "$((fbsd / 1000 % 100))"
