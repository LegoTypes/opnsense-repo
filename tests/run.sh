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
expect_eq "real file: catalogue" "$(sh "$root/scripts/packages.sh" catalogue | tr '\n' ' ')" \
	"os-wg-client-tunnels os-mac-alias-cache os-wan-failover os-legotypes "

# --- repo.sh -----------------------------------------------------------------
rc() { printf '%s\n' "$@" >"$T/repo.conf"; }
rp() { REPO_CONF="$T/repo.conf" sh "$root/scripts/repo.sh" "$@"; }
rc '# served repository' 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=26.7 27.1'
expect_eq "repo abi" "$(rp abi)" "FreeBSD:15:amd64"
expect_eq "repo series" "$(rp series)" "26.7"
expect_eq "repo serve" "$(rp serve | tr '\n' ' ')" "26.7 27.1 "
expect_eq "repo tree" "$(rp tree)" "site/FreeBSD:15:amd64/26.7/latest"
expect_eq "repo tree of a served series" "$(rp tree 27.1)" "site/FreeBSD:15:amd64/27.1/latest"
expect_fail "repo tree of a series not served" rp tree 25.1
rc 'ABI=FreeBSD:15:amd64' 'SERIES=27.1' 'SERVE=26.7'
expect_fail "SERVE must include SERIES" rp serve
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERIES=27.1' 'SERVE=26.7'
expect_fail "SERIES set twice" rp series
rc 'ABI=freebsd15' 'SERIES=26.7' 'SERVE=26.7'
expect_fail "malformed ABI" rp abi
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26' 'SERVE=26'
expect_fail "malformed series" rp series
expect_eq "real file: tree" "$(sh "$root/scripts/repo.sh" tree)" "site/FreeBSD:15:amd64/26.7/latest"
choices=$(awk '/^ *options:/ { o = 1; next } o && /^ *- / { print $2; next } o { exit }' \
	"$root/.github/workflows/publish.yml" | sort | tr '\n' ' ')
expect_eq "publish.yml offers exactly the catalogue" "$choices" \
	"$(sh "$root/scripts/packages.sh" catalogue | sort | tr '\n' ' ')"

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
	echo '[]' >"$STUB/issues.json"
	: >"$STUB/issue_calls"
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
printf 'series: 26.7\nphp: 85\n' >"$T/out/build"
echo two >"$T/out/os-alpha-1.2.pkg"
rel create "$T/out/os-alpha-1.2.pkg" "Built from here." "$T/out/build" >/dev/null
expect_eq "create with the build environment" "$(sed -n '/^os-alpha-1.2|/,$p' "$STUB/created" | sed -n '2,5p')" \
	$'Built from here.\n\nseries: 26.7\nphp: 85'
expect_fail "create with a missing build file" rel create "$T/out/os-alpha-1.2.pkg" "src" "$T/out/none"
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

# --- newest-release.sh ----------------------------------------------------------
nr() { bash "$root/scripts/newest-release.sh" "$@"; }
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-1.1 2026-01-03T00:00:00Z
publish os-alpha-extra-2.0 2026-01-04T00:00:00Z
expect_eq "newest release" "$(nr os-alpha)" "os-alpha-1.1"
expect_eq "no release" "$(nr os-gamma)" ""
expect_eq "a release without a series line counts as 26.7" "$(nr os-alpha 26.7)" "os-alpha-1.1"
publish os-alpha-1.1_1 2026-01-05T00:00:00Z
printf 'Built from here.\n\nseries: 27.1\n\nsha256: %s\n' "$(sum "$STUB/assets/os-alpha-1.1_1/os-alpha-1.1_1.pkg")" >"$STUB/notes/os-alpha-1.1_1"
expect_eq "newest for 27.1" "$(nr os-alpha 27.1)" "os-alpha-1.1_1"
expect_eq "newest for 26.7 skips the 27.1 build" "$(nr os-alpha 26.7)" "os-alpha-1.1"
expect_eq "newest of any series" "$(nr os-alpha)" "os-alpha-1.1_1"
expect_eq "no release for a series" "$(nr os-alpha-extra 27.1)" ""
expect_eq "from RELEASES_JSON" "$(RELEASES_JSON='[{"tagName":"os-alpha-9.0","publishedAt":"2026-02-01T00:00:00Z"}]' nr os-alpha)" "os-alpha-9.0"
touch "$STUB/fail_list"
expect_fail "release list unreadable" nr os-alpha
rm "$STUB/fail_list"

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
	printf 'ABI=FreeBSD:15:amd64\nSERIES=26.7\nSERVE=26.7\n' >"$W/repo.conf"
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
vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-alpha-1.1.pkg -- build-package.sh os-alpha >/dev/null
expect_eq "build: one package in out/" "$(names "$W/out")" "build os-alpha-1.1.pkg source "
expect_eq "build: source line" "$(cat "$W/out/source")" "Built from Org/plugins, branch br-alpha, commit $commit."
expect_eq "build: the build environment" "$(cat "$W/out/build")" \
	$'series: 26.7\nfreebsd: 15.1-RELEASE-p3\nphp: 85\npython: 313'
expect_fail "build: no upstream PHP" vmenv UPSTREAM_PYTHON=313 STUB_PKGS=os-alpha-1.1.pkg -- build-package.sh os-alpha
vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-alpha-1.1.pkg MK_FROM=upstream -- build-package.sh os-alpha >/dev/null
expect_eq "build: with upstream Mk/" "$(cat "$W/out/source")" \
	"Built from Org/plugins, branch br-alpha, commit $commit. Mk/ from opnsense/plugins master $commit."
expect_fail "build: an unknown MK_FROM" vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-alpha-1.1.pkg MK_FROM=elsewhere -- build-package.sh os-alpha
expect_fail "build: a -devel package" vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-alpha-devel-1.1.pkg -- build-package.sh os-alpha
expect_fail "build: two packages" vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 "STUB_PKGS=os-alpha-1.1.pkg os-alpha-1.0.pkg" -- build-package.sh os-alpha
expect_fail "build: no package" vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS= -- build-package.sh os-alpha
expect_fail "build: not in packages.conf" vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-gamma-1.0.pkg -- build-package.sh os-gamma
vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-vendor-1.0_2.pkg GITHUB_REPOSITORY=Org/repo GITHUB_SHA=feedface -- build-package.sh os-vendor >/dev/null
expect_eq "build: this repository's package" "$(cat "$W/out/source")" \
	"Built from Org/repo, vendor/v, commit feedface, in LegoTypes/plugins master $commit."
expect_fail "build: this repository's package without GITHUB_SHA" \
	vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-vendor-1.0_2.pkg GITHUB_REPOSITORY=Org/repo -- build-package.sh os-vendor

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
expect_eq "sign: the tree has its own packages.txt" "$(cat "$W/$R/packages.txt")" "$(cat "$W/site/packages.txt")"
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

# --- upstream.sh (stub curl serves a fake mirror) -----------------------------
# mirror <series...>: a fake OPNsense mirror with those series under FreeBSD:15:amd64; the root
# index links ABI directories as Apache does for names with a colon ("./FreeBSD:15:amd64/")
mirror() {
	export STUB_MIRROR="$T/mirror" STUB_MIRROR_URL=https://mirror.test UPSTREAM_MIRROR=https://mirror.test
	rm -rf "$STUB_MIRROR"
	mkdir -p "$STUB_MIRROR/FreeBSD:15:amd64"
	printf '<a href="./FreeBSD:14:amd64/">FreeBSD:14:amd64/</a>\n<a href="./FreeBSD:15:amd64/">FreeBSD:15:amd64/</a>\n<a href="sets/">sets/</a>\n' \
		>"$STUB_MIRROR/index.html"
	local s
	printf '<a href="snapshots/">snapshots/</a>\n' >"$STUB_MIRROR/FreeBSD:15:amd64/index.html"
	for s in "$@"; do
		printf '<a href="%s/">%s/</a>\n' "$s" "$s" >>"$STUB_MIRROR/FreeBSD:15:amd64/index.html"
		mkdir -p "$STUB_MIRROR/FreeBSD:15:amd64/$s/latest"
	done
}
# site <series> <json line...>: that series' catalogue (packagesite.pkg holding packagesite.yaml)
site() {
	local s=$1 d
	shift
	d=$(mktemp -d)
	printf '%s\n' "$@" >"$d/packagesite.yaml"
	tar -cf "$STUB_MIRROR/FreeBSD:15:amd64/$s/latest/packagesite.pkg" -C "$d" packagesite.yaml
	rm -rf "$d"
}
core() { # core <version> <FreeBSD_version> <dependency names...>
	local v=$1 f=$2
	shift 2
	jq -cn --arg v "$v" --arg f "$f" --args '{name: "opnsense", version: $v,
		annotations: {FreeBSD_version: $f}, deps: ($ARGS.positional | map({key: ., value: {}}) | from_entries)}' "$@"
}
up() { REPO_CONF="$T/repo.conf" bash "$root/scripts/upstream.sh" "$@"; }
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=26.7'
mirror 26.1 26.7
site 26.7 "$(core 26.7.5 1501000 php85-curl php85-xml py313-requests pkg)" '{"name":"php85","version":"8.5.10"}'
expect_eq "upstream facts" "$(up)" $'NEWEST=26.7\nNEXT_ABI=\nSERIES=26.7\nCORE=26.7.5\nPHP=85\nPYTHON=313\nFREEBSD=15.1'
mirror 26.7 27.1
site 26.7 "$(core 26.7.9 1501000 php85-curl py313-requests)"
site 27.1 "$(core 27.1 1502000 php86-curl py314-requests)"
expect_eq "newest series beside the target's facts" "$(up | grep -E '^(NEWEST|SERIES|PHP)=')" $'NEWEST=27.1\nSERIES=26.7\nPHP=85'
expect_eq "facts for a named series" "$(up 27.1 | grep -E '^(SERIES|PHP|PYTHON|FREEBSD)=')" $'SERIES=27.1\nPHP=86\nPYTHON=314\nFREEBSD=15.2'
printf '<a href="./FreeBSD:16:amd64/">FreeBSD:16:amd64/</a>\n' >>"$STUB_MIRROR/index.html"
expect_eq "next FreeBSD major" "$(up | grep '^NEXT_ABI=')" "NEXT_ABI=FreeBSD:16:amd64"
mirror 26.7
expect_fail "target series without a catalogue" up
site 26.7 "$(core 26.7.5 1501000 php84-curl php85-xml py313-requests)"
expect_fail "core naming two PHP versions" up
site 26.7 '{"name":"php85","version":"8.5.10"}'
expect_fail "no core package" up
site 26.7 "$(core 26.7.5 1501000 php85-curl)"
expect_fail "core naming no Python" up
mirror 26.7
printf '<a href="sets/">sets/</a>\n' >"$STUB_MIRROR/index.html"
expect_fail "mirror without our ABI" up
rm -rf "$STUB_MIRROR"
expect_fail "mirror unreachable" up
unset STUB_MIRROR STUB_MIRROR_URL UPSTREAM_MIRROR

# --- compare-package.sh -------------------------------------------------------
mkpkg() { # mkpkg <file> <+MANIFEST json>: a package holding only its manifest, as compare reads it
	local d
	d=$(mktemp -d)
	printf '%s' "$2" >"$d/+MANIFEST"
	tar -cf "$1" -C "$d" +MANIFEST
	rm -rf "$d"
}
base='{"name":"os-alpha","abi":"FreeBSD:15:amd64","arch":"freebsd:15:x86:64","flatsize":10,
 "annotations":{"product_abi":"26.7","FreeBSD_version":"1500068","product_hash":"aaaaaaa"},
 "scripts":{"post-install":"echo hi"},
 "files":{"/usr/local/a":{"sum":"1$x","perm":"0644","mtime":1},"/usr/local/b":{"sum":"1$y","perm":"0755","mtime":1}}}'
mod() { jq -c "$1" <<<"$base"; }
cmpk() { bash "$root/scripts/compare-package.sh" "$T/a.pkg" "$T/b.pkg"; echo "rc=$?"; }
mkpkg "$T/a.pkg" "$base"
mkpkg "$T/b.pkg" "$(mod '.annotations.product_hash = "bbbbbbb" | .annotations.FreeBSD_version = "1501000" | .flatsize = 99 | .files["/usr/local/a"].mtime = 9')"
expect_eq "compare: commit, FreeBSD minor, flatsize and mtimes are not material" "$(cmpk)" "rc=0"
mkpkg "$T/b.pkg" "$(mod '.annotations.product_abi = "27.1"')"
expect_eq "compare: series" "$(cmpk)" $'product_abi: "26.7" -> "27.1"\nrc=1'
mkpkg "$T/b.pkg" "$(mod '.annotations.FreeBSD_version = "1600010" | .abi = "FreeBSD:16:amd64"')"
expect_eq "compare: FreeBSD major and ABI" "$(cmpk)" $'abi: "FreeBSD:15:amd64" -> "FreeBSD:16:amd64"\nfreebsd_major: 15 -> 16\nrc=1'
mkpkg "$T/b.pkg" "$(mod '.deps = {"php86":{"origin":"lang/php86","version":"8.6.0"}}')"
expect_eq "compare: a dependency appears" "$(cmpk)" $'deps: [] -> ["php86"]\nrc=1'
mkpkg "$T/b.pkg" "$(mod '.scripts["post-install"] = "echo bye" | .scripts["pre-deinstall"] = "x"')"
expect_eq "compare: scripts" "$(cmpk)" $'script post-install: changed\nscript pre-deinstall: added\nrc=1'
mkpkg "$T/b.pkg" "$(mod '.files["/usr/local/a"].perm = "0755" | .files["/usr/local/b"].sum = "1$z" | .files["/usr/local/c"] = {"sum":"1$c","perm":"0644"}')"
expect_eq "compare: files" "$(cmpk)" $'file /usr/local/a: mode 0644 -> 0755\nfile /usr/local/b: content changed\nfile /usr/local/c: added\nrc=1'
expect_eq "compare: not a package" "$(bash "$root/scripts/compare-package.sh" "$T/repo.conf" "$T/a.pkg" 2>/dev/null; echo "rc=$?")" "rc=2"

# --- canary-findings.sh and canary-report.sh ----------------------------------------
fd() { bash "$root/scripts/canary-findings.sh" os-alpha "$T/cf"; echo "rc=$?"; }
cfdir() {
	rm -rf "$T/cf"
	mkdir -p "$T/cf"
	mkpkg "$T/cf/published.pkg" "$base"
	printf 'Built from Org/plugins, branch b, commit 1111111aaaa.\n\nsha256: x\n' >"$T/cf/notes"
	mkpkg "$T/cf/fresh.pkg" "$base"
	mkpkg "$T/cf/rebased.pkg" "$base"
	echo "Built from Org/plugins, branch b, commit 1111111aaaa." >"$T/cf/fresh.source"
}
cfdir
expect_eq "findings: all the same" "$(fd)" "rc=0"
mkpkg "$T/cf/rebased.pkg" "$(mod '.scripts["post-install"] = "echo new"')"
expect_eq "findings: upstream Mk/ changes a script" "$(fd)" \
	$'MATERIAL: upstream Mk/ would change script post-install: changed\nrc=1'
cfdir
mkpkg "$T/cf/fresh.pkg" "$(mod '.annotations.product_abi = "27.1"')"
mkpkg "$T/cf/rebased.pkg" "$(mod '.annotations.product_abi = "27.1"')"
expect_eq "findings: a difference both builds show is reported once" "$(fd)" \
	$'MATERIAL: a publish now would change product_abi: "26.7" -> "27.1"\nrc=1'
cfdir
rm "$T/cf/fresh.pkg"
echo "make: error 1" >"$T/cf/fresh.tail"
expect_eq "findings: a failed build is material" "$(fd)" \
	$'MATERIAL: building the branch as a publish would failed: make: error 1\nrc=1'
cfdir
echo "Built from Org/plugins, branch b, commit 2222222bbbb." >"$T/cf/fresh.source"
expect_eq "findings: unreleased commits are a note" "$(fd)" \
	$'NOTE: the branch has commits after its release (release 1111111aaaa, branch head 2222222bbbb)\nrc=0'
cfdir
rm "$T/cf/published.pkg" "$T/cf/notes"
expect_eq "findings: no release yet is a note" "$(fd)" $'NOTE: os-alpha has no release yet; nothing to compare\nrc=0'

crep() { bash "$root/scripts/canary-report.sh" "canary: os-alpha" "$T/findings" "https://run/1"; }
reset_stub
printf 'MATERIAL: x\nNOTE: y\n' >"$T/findings"
expect_eq "report: opens an issue" "$(crep)" "opened"
expect_eq "report: the issue" "$(cut -s -d'|' -f1,2 "$STUB/issue_calls")" "create|canary: os-alpha"
expect_eq "report: the body lists the findings" "$(grep -c '^- \*\*MATERIAL\*\*: x$' "$STUB/issue_calls")" "1"
echo '[{"number":7,"title":"canary: os-alpha"},{"number":8,"title":"canary: os-beta"}]' >"$STUB/issues.json"
: >"$STUB/issue_calls"
expect_eq "report: updates the open one" "$(crep)" "updated"
expect_eq "report: the edit" "$(cut -s -d'|' -f1,2 "$STUB/issue_calls")" "edit|7"
printf 'NOTE: y\n' >"$T/findings"
: >"$STUB/issue_calls"
expect_eq "report: closes it when clean" "$(crep)" "closed"
expect_eq "report: the close" "$(cut -s -d'|' -f1,2 "$STUB/issue_calls")" "close|7"
echo '[]' >"$STUB/issues.json"
expect_eq "report: clean, nothing open" "$(crep)" "clean"
printf 'MATERIAL: x\n' >"$T/findings"
touch "$STUB/fail_issues"
: >"$STUB/issue_calls"
expect_fail "report: the issue list unreadable" crep
expect_eq "report: no duplicate opened when the list fails" "$(cat "$STUB/issue_calls")" ""
rm "$STUB/fail_issues"
echo '[{"number":7,"title":"canary: os-alpha"},{"number":9,"title":"canary: os-alpha"}]' >"$STUB/issues.json"
expect_fail "report: two open issues with one title" crep

echo "passed $pass, failed $failed"
[[ $failed -eq 0 ]]
