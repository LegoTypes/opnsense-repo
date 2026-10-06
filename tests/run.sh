#!/usr/bin/env bash
# Unit tests for scripts/: bash tests/run.sh (from the repository root or anywhere).
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
pass=0 failed=0
ok() { pass=$((pass + 1)); }
bad() {
	failed=$((failed + 1))
	echo "FAIL: $*"
}
expect_eq() { if [[ $2 == "$3" ]]; then ok; else bad "$1: expected [$3], got [$2]"; fi; }
expect_fail() {
	local name=$1
	shift
	if "$@" >/dev/null 2>&1; then bad "$name: expected failure"; else ok; fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

conf() { printf '%s\n' "$@" >"$T/packages.conf"; }
pk() { PACKAGES_CONF="$T/packages.conf" sh "$root/scripts/packages.sh" "$@"; }

# --- packages.sh -------------------------------------------------------------
conf '# comment' '' \
	'os-alpha  Org/plugins  br-alpha  net/alpha  yes' \
	'os-beta   Org/plugins  br-beta   net/beta   no' \
	'os-vendor .            main      vendor/v   yes'
expect_eq "row known" "$(pk row os-beta)" "Org/plugins br-beta net/beta no"
expect_fail "row unknown" pk row os-gamma
expect_eq "catalogue" "$(pk catalogue | tr '\n' ' ')" "os-alpha os-vendor "
conf 'os-alpha Org/plugins br net/alpha'
expect_fail "four fields" pk catalogue
conf 'os-alpha Org/plugins br net/alpha maybe'
expect_fail "bad catalogue flag" pk catalogue
conf 'os-alpha Org/plugins br net/a yes' 'os-alpha Org/plugins br net/b no'
expect_fail "duplicate" pk catalogue
conf 'os-alpha-2 Org/plugins br net/a yes'
expect_fail "name with -digit" pk row os-alpha-2
expect_fail "usage" pk
expect_eq "real file: avahi is release-only" \
	"$(sh "$root/scripts/packages.sh" row os-avahi-reflector | awk '{print $4}')" "no"
expect_eq "real file: catalogue" "$(sh "$root/scripts/packages.sh" catalogue | tr '\n' ' ')" \
	"os-wg-client-tunnels os-mac-alias-cache os-wan-failover os-legotypes "

# --- release.sh and carry-forward.sh -----------------------------------------
export PATH="$root/tests/stub:$PATH" GH_REPO=Org/repo
unset GITHUB_SHA
sum() { sha256sum "$1" | awk '{print $1}'; }
reset_stub() {
	export STUB="$T/stub"
	rm -rf "$STUB"
	mkdir -p "$STUB/notes" "$STUB/assets"
	: >"$STUB/tags"
	echo '[]' >"$STUB/releases.json"
}
# publish <tag> <published-at> [notes-sha] [created-at]: a release holding <tag>.pkg. As on GitHub,
# createdAt is the date of the tagged commit (so two releases of one commit share it), publishedAt is
# when the release was made, and gh lists the newest first.
publish() {
	local tag=$1 at=$2 created=${4:-$2} f
	mkdir -p "$STUB/assets/$tag"
	f="$STUB/assets/$tag/$tag.pkg"
	echo "bytes of $tag" >"$f"
	printf 'Built from Org/plugins, branch b, commit 0000000.\n\nsha256: %s\n' "${3:-$(sum "$f")}" >"$STUB/notes/$tag"
	echo "$tag" >>"$STUB/tags"
	jq --arg t "$tag" --arg p "$at" --arg c "$created" '[{tagName: $t, createdAt: $c, publishedAt: $p}] + .' "$STUB/releases.json" >"$STUB/r"
	mv "$STUB/r" "$STUB/releases.json"
}
rel() { bash "$root/scripts/release.sh" "$@"; }
# live <name-version>...: the packages.txt the live catalogue serves
live() {
	local nv
	for nv in "$@"; do printf 'Name           : %s\nVersion        : %s\nOrigin         : opnsense/%s\n\n' "${nv%-*}" "${nv##*-}" "${nv%-*}"; done >"$T/live.txt"
}
export LIVE_PACKAGES_TXT="file://$T/live.txt"
names() { (cd "$1" && printf '%s ' *); }
cf() { PACKAGES_CONF="$T/packages.conf" bash "$root/scripts/carry-forward.sh" "$@"; }

reset_stub
mkdir -p "$T/out"
echo new >"$T/out/os-alpha-1.1.pkg"
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-1.1_1 2026-01-02T00:00:00Z
expect_eq "check new (a longer tag with the same prefix exists)" "$(rel check "$T/out/os-alpha-1.1.pkg")" "os-alpha-1.1"
echo x >"$T/out/os-alpha-1.0.pkg"
expect_fail "check existing" rel check "$T/out/os-alpha-1.0.pkg"
expect_fail "check two files" rel check "$T/out/os-alpha-1.0.pkg" "$T/out/os-alpha-1.1.pkg"
expect_fail "check no file" rel check "$T/out/missing.pkg"
expect_fail "check not a .pkg" rel check "$T/packages.conf"
touch "$STUB/fail_api"
expect_fail "check with the api down" rel check "$T/out/os-alpha-1.1.pkg"
rm "$STUB/fail_api"
GITHUB_SHA=abc123 rel create "$T/out/os-alpha-1.1.pkg" "Built from Org/plugins, branch b, commit 1234567." >/dev/null
expect_eq "create header" "$(head -1 "$STUB/created")" "os-alpha-1.1|os-alpha-1.1.pkg|abc123"
expect_eq "create source line" "$(sed -n 2p "$STUB/created")" "Built from Org/plugins, branch b, commit 1234567."
expect_eq "create sha line" "$(grep '^sha256: ' "$STUB/created")" "sha256: $(sum "$T/out/os-alpha-1.1.pkg")"
expect_fail "create existing" rel create "$T/out/os-alpha-1.0.pkg" "src"
expect_fail "create empty source" rel create "$T/out/os-alpha-1.1.pkg" ""
expect_fail "create two-line source" rel create "$T/out/os-alpha-1.1.pkg" $'a\nb'

conf 'os-alpha        Org/plugins br   net/alpha yes' \
	'os-alpha-extra  Org/plugins br   net/extra yes' \
	'os-beta         Org/plugins br   net/beta  no' \
	'os-vendor       .           main vendor/v  yes'
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-1.1 2026-01-03T00:00:00Z
publish os-alpha-extra-2.0 2026-01-04T00:00:00Z
publish os-beta-9.0 2026-01-05T00:00:00Z
publish os-vendor-1.0_1 2026-01-02T00:00:00Z
live os-alpha-1.1 os-alpha-extra-2.0 os-vendor-1.0_1
cf os-vendor "$T/cat1" >/dev/null
expect_eq "carries the newest of each other catalogue package, never a release-only one" \
	"$(names "$T/cat1")" "os-alpha-1.1.pkg os-alpha-extra-2.0.pkg "
expect_eq "carries the bytes" "$(cat "$T/cat1/os-alpha-1.1.pkg")" "bytes of os-alpha-1.1"
cf os-alpha "$T/cat2" >/dev/null
expect_eq "a name prefix does not capture another package's releases" \
	"$(names "$T/cat2")" "os-alpha-extra-2.0.pkg os-vendor-1.0_1.pkg "
expect_fail "built package not in the catalogue" cf os-beta "$T/cat3"
live os-alpha-1.2 os-alpha-extra-2.0 os-vendor-1.0_1
expect_fail "live serves a build that has no release (a publish whose release job failed)" cf os-vendor "$T/cat8"
expect_fail "the same, for the package being built" cf os-alpha "$T/cat9"
live os-alpha-1.1 os-vendor-1.0_1
expect_fail "live lacks a catalogue package that has a release" cf os-vendor "$T/cat10"
rm "$T/live.txt"
expect_fail "live catalogue unreadable" cf os-vendor "$T/cat11"
publish os-vendor-1.0_2 2026-01-06T00:00:00Z "$(printf '0%.0s' {1..64})"
live os-alpha-1.1 os-alpha-extra-2.0 os-vendor-1.0_2
expect_fail "sha256 mismatch" cf os-alpha "$T/cat4"
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
live os-alpha-1.0
expect_fail "missing release" cf os-alpha "$T/cat5"
reset_stub
publish os-alpha-extra-2.0 2026-01-02T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-extra-2.0 os-vendor-1.0
cf os-alpha "$T/cat12" >/dev/null
expect_eq "a new package, not yet live or released, can be published" "$(names "$T/cat12")" "os-alpha-extra-2.0.pkg os-vendor-1.0.pkg "
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-extra-2.0 2026-01-02T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-1.0 os-alpha-extra-2.0 os-vendor-1.0
cf os-alpha "$T/cat13" >/dev/null
expect_eq "consistent live catalogue and releases carry forward" "$(names "$T/cat13")" "os-alpha-extra-2.0.pkg os-vendor-1.0.pkg "
rm -r "$T/cat13"
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z "" 2026-01-01T00:00:00Z
publish os-alpha-1.1 2026-01-02T00:00:00Z "" 2026-01-01T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-1.1 os-vendor-1.0
cf os-vendor "$T/cat14" >/dev/null
expect_eq "two releases tagged on one commit: the later published is the newest" "$(names "$T/cat14")" "os-alpha-1.1.pkg "
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-extra-2.0 2026-01-02T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-1.0 os-alpha-extra-2.0 os-vendor-1.0
printf 'no checksum here\n' >"$STUB/notes/os-vendor-1.0"
expect_fail "notes without sha256" cf os-alpha "$T/cat6"
printf 'sha256: %s\nsha256: %s\n' "$(sum "$STUB/assets/os-vendor-1.0/os-vendor-1.0.pkg")" "$(sum "$STUB/assets/os-vendor-1.0/os-vendor-1.0.pkg")" >"$STUB/notes/os-vendor-1.0"
expect_fail "notes with two sha256 lines" cf os-alpha "$T/cat7"

# --- build-package.sh and sign-catalogue.sh (VM scripts, stub git/make/pkg) --
# a throwaway signing key (the stub pkg signs with the real openssl), and a second
# one the published public key does not match
openssl genrsa -out "$T/key.pem" 2048 2>/dev/null
openssl rsa -in "$T/key.pem" -pubout -out "$T/pub.pem" 2>/dev/null
openssl genrsa -out "$T/other.pem" 2048 2>/dev/null
# vmdir: a fresh workspace like the VM's, with scripts/, $T/packages.conf and the public key
vmdir() {
	W="$T/vm"
	rm -rf "$W"
	mkdir -p "$W/keys" "$W/vendor/v"
	cp -R "$root/scripts" "$W/"
	cp "$T/packages.conf" "$W/packages.conf"
	cp "$T/pub.pem" "$W/keys/legotypes-pkg-signing.pub"
	trust "$T/pub.pem"
}
# trust <pem>: the fingerprint os-legotypes ships, as clients will check it
trust() {
	mkdir -p "$W/vendor/legotypes/src/etc/pkg/fingerprints/LegoTypes/trusted"
	printf 'function: "sha256"\nfingerprint: "%s"\n' "$(sum "$1")" \
		>"$W/vendor/legotypes/src/etc/pkg/fingerprints/LegoTypes/trusted/test.1"
}
vm() { (cd "$W" && PATH="$root/tests/stub-vm:$PATH" sh "scripts/$1" "${@:2}"); }
# vmenv VAR=value... -- <script> <args>: vm with those variables exported
vmenv() {
	local a=()
	while [[ $1 != -- ]]; do
		a+=("$1")
		shift
	done
	shift
	(
		export "${a[@]}"
		vm "$@"
	)
}
commit=0123456789abcdef0123456789abcdef01234567

conf 'os-alpha   Org/plugins br-alpha net/alpha yes' \
	'os-vendor  .           main     vendor/v  yes'
vmdir
vmenv STUB_PKGS=os-alpha-1.1.pkg -- build-package.sh os-alpha >/dev/null
expect_eq "build: one package in out/" "$(names "$W/out")" "os-alpha-1.1.pkg source "
expect_eq "build: source line" "$(cat "$W/out/source")" "Built from Org/plugins, branch br-alpha, commit $commit."
expect_fail "build: a -devel package" vmenv STUB_PKGS=os-alpha-devel-1.1.pkg -- build-package.sh os-alpha
expect_fail "build: two packages" vmenv "STUB_PKGS=os-alpha-1.1.pkg os-alpha-1.0.pkg" -- build-package.sh os-alpha
expect_fail "build: no package" vmenv STUB_PKGS= -- build-package.sh os-alpha
expect_fail "build: not in packages.conf" vmenv STUB_PKGS=os-gamma-1.0.pkg -- build-package.sh os-gamma
vmenv STUB_PKGS=os-vendor-1.0_2.pkg GITHUB_REPOSITORY=Org/repo GITHUB_SHA=feedface -- build-package.sh os-vendor >/dev/null
expect_eq "build: this repository's package" "$(cat "$W/out/source")" \
	"Built from Org/repo, vendor/v, commit feedface, in LegoTypes/plugins master $commit."
expect_fail "build: this repository's package without GITHUB_SHA" \
	vmenv STUB_PKGS=os-vendor-1.0_2.pkg GITHUB_REPOSITORY=Org/repo -- build-package.sh os-vendor

conf 'os-alpha      Org/plugins br   net/alpha        yes' \
	'os-beta       Org/plugins br   net/beta         no' \
	'os-legotypes  .           main vendor/legotypes yes'
R="site/FreeBSD:15:amd64/26.7/latest"
# signdir <carried file...>: out/ holds the built os-legotypes, All/ the carried files
signdir() {
	vmdir
	mkdir -p "$W/out" "$W/$R/All" "$W/.signing"
	echo "built" >"$W/out/os-legotypes-1.0_2.pkg"
	echo "Built from here." >"$W/out/source"
	cp "$T/key.pem" "$W/.signing/key"
	local f
	for f in "$@"; do echo "carried" >"$W/$R/All/$f"; done
}
signdir os-alpha-1.1.pkg
vm sign-catalogue.sh >/dev/null
expect_eq "sign: catalogue written" "$(cat "$W/$R/meta.conf")" "version = 2;"
tar -xf "$W/$R/data.pkg" -C "$T" data.sig
expect_eq "sign: signature not empty" "$([[ -s $T/data.sig ]] && echo yes)" "yes"
expect_eq "sign: bootstrap package" "$(cat "$W/site/os-legotypes.pkg")" "built"
expect_eq "sign: public key published" "$(cat "$W/site/legotypes-pkg-signing.pub")" "$(cat "$T/pub.pem")"
expect_eq "sign: packages.txt names both" "$(grep '^Name' "$W/site/packages.txt" | tr '\n' ' ')" \
	"Name : os-alpha-1.1 Name : os-legotypes-1.0_2 "
expect_eq "sign: key removed" "$(names "$W/.signing")" "* "
signdir os-alpha-1.1.pkg os-beta-9.0.pkg
expect_fail "sign: a release-only package in the catalogue" vm sign-catalogue.sh
expect_eq "sign: key removed after a failure" "$(names "$W/.signing")" "* "
signdir
expect_fail "sign: a catalogue package missing" vm sign-catalogue.sh
signdir os-alpha-1.1.pkg os-alpha-1.0.pkg
expect_fail "sign: two versions of one package" vm sign-catalogue.sh
signdir os-alpha-1.1.pkg
rm "$W/.signing/key"
expect_fail "sign: no key" vm sign-catalogue.sh
signdir os-alpha-1.1.pkg
echo >"$W/.signing/key"
expect_fail "sign: an empty key (the secret did not arrive)" vm sign-catalogue.sh
expect_eq "sign: nothing published after a failed signing" "$([[ -e $W/site/os-legotypes.pkg ]] && echo yes || echo no)" "no"
signdir os-alpha-1.1.pkg
cp "$T/other.pem" "$W/.signing/key"
expect_fail "sign: a key the published public key does not match" vm sign-catalogue.sh
expect_eq "sign: key removed after a mismatch" "$(names "$W/.signing")" "* "
signdir os-alpha-1.1.pkg
openssl rsa -in "$T/other.pem" -pubout -out "$T/other.pub" 2>/dev/null
trust "$T/other.pub"
expect_fail "sign: a key os-legotypes does not trust (a half-done rotation)" vm sign-catalogue.sh
expect_eq "sign: nothing published for an untrusted key" "$([[ -e $W/site/os-legotypes.pkg ]] && echo yes || echo no)" "no"

echo "passed $pass, failed $failed"
[[ $failed -eq 0 ]]
