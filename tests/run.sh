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
	"os-wg-client-tunnels os-mac-alias-cache os-wan-failover os-unbound-upstream os-legotypes "

# --- repo.sh -----------------------------------------------------------------
rc() { printf '%s\n' "$@" >"$T/repo.conf"; }
rp() { REPO_CONF="$T/repo.conf" sh "$root/scripts/repo.sh" "$@"; }
rc '# served repository' 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7 FreeBSD:15:amd64/27.1'
expect_eq "repo abi" "$(rp abi)" "FreeBSD:15:amd64"
expect_eq "repo series" "$(rp series)" "26.7"
expect_eq "repo target" "$(rp target)" "FreeBSD:15:amd64/26.7"
expect_eq "repo serve" "$(rp serve | tr '\n' ' ')" "FreeBSD:15:amd64/26.7 FreeBSD:15:amd64/27.1 "
expect_eq "repo tree" "$(rp tree)" "site/FreeBSD:15:amd64/26.7/latest"
expect_eq "repo tree of a served entry" "$(rp tree FreeBSD:15:amd64/27.1)" "site/FreeBSD:15:amd64/27.1/latest"
expect_fail "repo tree of an entry not served" rp tree FreeBSD:15:amd64/25.1
rc 'ABI=FreeBSD:16:amd64' 'SERIES=27.7' 'SERVE=FreeBSD:15:amd64/26.7 FreeBSD:16:amd64/27.7'
expect_eq "an ABI change keeps the old tree where firewalls on the old ABI look for it" \
	"$(rp tree FreeBSD:15:amd64/26.7)" "site/FreeBSD:15:amd64/26.7/latest"
expect_eq "an ABI change builds the new tree under the new ABI" "$(rp tree)" "site/FreeBSD:16:amd64/27.7/latest"
rc 'ABI=FreeBSD:15:amd64' 'SERIES=27.1' 'SERVE=FreeBSD:15:amd64/26.7'
expect_fail "SERVE must include the target" rp serve
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=26.7'
expect_fail "a SERVE entry without its ABI" rp serve
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERIES=27.1' 'SERVE=FreeBSD:15:amd64/26.7'
expect_fail "SERIES set twice" rp series
rc 'ABI=freebsd15' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
expect_fail "malformed ABI" rp abi
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26' 'SERVE=FreeBSD:15:amd64/26'
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
# live [-s <series>] <name-version>...: the packages.txt the live site serves for a series (default 26.7)
live() {
	local s=26.7 nv d
	if [[ $1 == -s ]]; then s=$2 && shift 2; fi
	d="$T/livesite/FreeBSD:15:amd64/$s/latest"
	mkdir -p "$d"
	for nv in "$@"; do printf 'Name           : %s\nVersion        : %s\nOrigin         : opnsense/%s\n\n' "${nv%-*}" "${nv##*-}" "${nv%-*}"; done >"$d/packages.txt"
}
export LIVE_SITE=https://live.test STUB_LIVE_URL=https://live.test STUB_LIVE="$T/livesite"
names() { (cd "$1" && printf '%s ' *); }
# cf <built>: carry-forward in $T/cfw with $T/packages.conf and $T/repo.conf; trees land under $T/cfw/site
cf() { (rm -rf "$T/cfw" && mkdir -p "$T/cfw" && cd "$T/cfw" && PACKAGES_CONF="$T/packages.conf" REPO_CONF="$T/repo.conf" bash "$root/scripts/carry-forward.sh" "$@"); }
tree() { echo "$T/cfw/site/FreeBSD:15:amd64/${1:-26.7}/latest/All"; }
# cfok <built>: carry-forward that must succeed
cfok() { cf "$@" >/dev/null || bad "carry-forward $* exited non-zero"; }

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

rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
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
cfok os-vendor
expect_eq "carries the newest of each other catalogue package, never a release-only one" \
	"$(names "$(tree)")" "os-alpha-1.1.pkg os-alpha-extra-2.0.pkg "
expect_eq "carries the bytes" "$(cat "$(tree)/os-alpha-1.1.pkg")" "bytes of os-alpha-1.1"
cfok os-alpha
expect_eq "a name prefix does not capture another package's releases" \
	"$(names "$(tree)")" "os-alpha-extra-2.0.pkg os-vendor-1.0_1.pkg "
expect_fail "built package not in the catalogue" cf os-beta
live os-alpha-1.2 os-alpha-extra-2.0 os-vendor-1.0_1
expect_fail "live serves a build that has no release (a publish whose release job failed)" cf os-vendor
expect_fail "the same, for the package being built" cf os-alpha
live os-alpha-1.1 os-vendor-1.0_1
expect_fail "live lacks a catalogue package that has a release" cf os-vendor
rm -r "$T/livesite"
expect_fail "live catalogue unreadable" cf os-vendor
mkdir -p "$T/livesite/FreeBSD:15:amd64/26.7/latest"
echo 503 >"$T/livesite/FreeBSD:15:amd64/26.7/latest/packages.txt.status"
expect_eq "a live site that answers 503 is unreadable, not empty" \
	"$(cf os-vendor 2>&1 >/dev/null | grep -c 'cannot read')" "1"
rm "$T/livesite/FreeBSD:15:amd64/26.7/latest/packages.txt.status"
publish os-vendor-1.0_2 2026-01-06T00:00:00Z "$(printf '0%.0s' {1..64})"
live os-alpha-1.1 os-alpha-extra-2.0 os-vendor-1.0_2
expect_fail "sha256 mismatch" cf os-alpha
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
live os-alpha-1.0
expect_fail "missing release" cf os-alpha
reset_stub
publish os-alpha-extra-2.0 2026-01-02T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-extra-2.0 os-vendor-1.0
cfok os-alpha
expect_eq "a new package, not yet live or released, can be published" "$(names "$(tree)")" "os-alpha-extra-2.0.pkg os-vendor-1.0.pkg "
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-extra-2.0 2026-01-02T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-1.0 os-alpha-extra-2.0 os-vendor-1.0
cfok os-alpha
expect_eq "consistent live catalogue and releases carry forward" "$(names "$(tree)")" "os-alpha-extra-2.0.pkg os-vendor-1.0.pkg "
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z "" 2026-01-01T00:00:00Z
publish os-alpha-1.1 2026-01-02T00:00:00Z "" 2026-01-01T00:00:00Z
publish os-alpha-extra-2.0 2026-01-02T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-1.1 os-alpha-extra-2.0 os-vendor-1.0
cfok os-vendor
expect_eq "two releases tagged on one commit: the later published is the newest" "$(names "$(tree)")" "os-alpha-1.1.pkg os-alpha-extra-2.0.pkg "
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-extra-2.0 2026-01-02T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-1.0 os-alpha-extra-2.0 os-vendor-1.0
printf 'no checksum here\n' >"$STUB/notes/os-vendor-1.0"
expect_fail "notes without sha256" cf os-alpha
printf 'sha256: %s\nsha256: %s\n' "$(sum "$STUB/assets/os-vendor-1.0/os-vendor-1.0.pkg")" "$(sum "$STUB/assets/os-vendor-1.0/os-vendor-1.0.pkg")" >"$STUB/notes/os-vendor-1.0"
expect_fail "notes with two sha256 lines" cf os-alpha

# two served series: 27.1 is the target, 26.7 stays frozen at its last releases
rc 'ABI=FreeBSD:15:amd64' 'SERIES=27.1' 'SERVE=FreeBSD:15:amd64/26.7 FreeBSD:15:amd64/27.1'
reset_stub
rm -rf "$T/livesite"
publish os-alpha-1.1 2026-01-03T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
publish os-alpha-1.1_1 2026-02-01T00:00:00Z
printf 'Built.\n\nseries: 27.1\n\nsha256: %s\n' "$(sum "$STUB/assets/os-alpha-1.1_1/os-alpha-1.1_1.pkg")" >"$STUB/notes/os-alpha-1.1_1"
live -s 26.7 os-alpha-1.1 os-vendor-1.0
live -s 27.1 os-alpha-1.1_1
cfok os-vendor
expect_eq "series: the target tree carries the 27.1 builds" "$(names "$(tree 27.1)")" "os-alpha-1.1_1.pkg "
expect_eq "series: the frozen tree carries its own releases, the built package's included" "$(names "$(tree 26.7)")" "os-alpha-1.1.pkg os-vendor-1.0.pkg "
live -s 26.7 os-alpha-1.0 os-vendor-1.0
expect_fail "series: a frozen tree serving other than its newest releases" cf os-vendor
live -s 26.7 os-alpha-1.1 os-vendor-1.0
rm -rf "$T/livesite/FreeBSD:15:amd64/27.1"
reset_stub
publish os-alpha-1.1 2026-01-03T00:00:00Z
publish os-alpha-extra-2.0 2026-01-04T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live -s 26.7 os-alpha-1.1 os-alpha-extra-2.0 os-vendor-1.0
cfok os-vendor
expect_eq "series: the first publish into a new series succeeds with nothing else released for it" \
	"$(names "$(tree 27.1)" 2>/dev/null)" "* "
expect_eq "series: the first publish keeps the old series whole" "$(names "$(tree 26.7)")" \
	"os-alpha-1.1.pkg os-alpha-extra-2.0.pkg os-vendor-1.0.pkg "
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'

# --- newest-release.sh ----------------------------------------------------------
nr() { bash "$root/scripts/newest-release.sh" "$@"; }
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-1.1 2026-01-03T00:00:00Z
publish os-alpha-extra-2.0 2026-01-04T00:00:00Z
expect_eq "newest release" "$(nr os-alpha)" "os-alpha-1.1"
expect_eq "no release" "$(nr os-gamma)" ""
expect_eq "a release without a series line counts as 26.7" "$(nr os-alpha FreeBSD:15:amd64/26.7)" "os-alpha-1.1"
publish os-alpha-1.1_1 2026-01-05T00:00:00Z
printf 'Built from here.\n\nseries: 27.1\n\nsha256: %s\n' "$(sum "$STUB/assets/os-alpha-1.1_1/os-alpha-1.1_1.pkg")" >"$STUB/notes/os-alpha-1.1_1"
expect_eq "newest for 27.1" "$(nr os-alpha FreeBSD:15:amd64/27.1)" "os-alpha-1.1_1"
expect_eq "newest for 26.7 skips the 27.1 build" "$(nr os-alpha FreeBSD:15:amd64/26.7)" "os-alpha-1.1"
expect_eq "newest of any series" "$(nr os-alpha)" "os-alpha-1.1_1"
expect_eq "no release for a series" "$(nr os-alpha-extra FreeBSD:15:amd64/27.1)" ""
publish os-alpha-1.1_2 2026-01-06T00:00:00Z
printf 'Built.\n\nabi: FreeBSD:16:amd64\nseries: 27.1\n\nsha256: %s\n' "$(sum "$STUB/assets/os-alpha-1.1_2/os-alpha-1.1_2.pkg")" >"$STUB/notes/os-alpha-1.1_2"
expect_eq "the ABI counts too: a FreeBSD 16 build is not the FreeBSD 15 27.1 build" "$(nr os-alpha FreeBSD:15:amd64/27.1)" "os-alpha-1.1_1"
expect_eq "newest for the FreeBSD 16 entry" "$(nr os-alpha FreeBSD:16:amd64/27.1)" "os-alpha-1.1_2"
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
	printf 'ABI=FreeBSD:15:amd64\nSERIES=26.7\nSERVE=FreeBSD:15:amd64/26.7\n' >"$W/repo.conf"
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
	$'abi: FreeBSD:15:amd64\nseries: 26.7\nfreebsd: 15.1-RELEASE-p3\nphp: 85\npython: 313'
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
expect_eq "build: this repository's package names the last commit that changed it" "$(cat "$W/out/source")" \
	"Built from Org/repo, vendor/v, commit abcdef0123456789abcdef0123456789abcdef01 (workflow run at feedface), in LegoTypes/plugins master $commit."
expect_fail "build: this repository's package from a shallow checkout" \
	vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-vendor-1.0_2.pkg GITHUB_REPOSITORY=Org/repo GITHUB_SHA=feedface STUB_GIT_SHALLOW=1 -- build-package.sh os-vendor
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
signdir os-alpha-1.1.pkg
printf 'ABI=FreeBSD:15:amd64\nSERIES=26.7\nSERVE=FreeBSD:15:amd64/26.1 FreeBSD:15:amd64/26.7\n' >"$W/repo.conf"
mkdir -p "$W/site/FreeBSD:15:amd64/26.1/latest/All"
echo "old" >"$W/site/FreeBSD:15:amd64/26.1/latest/All/os-alpha-1.0.pkg"
vm sign-catalogue.sh >/dev/null
expect_eq "sign: a frozen tree is signed too" "$(cat "$W/site/FreeBSD:15:amd64/26.1/latest/meta.conf" 2>/dev/null)" "version = 2;"
expect_eq "sign: a frozen tree may lack a package" "$(grep -c '^Name' "$W/site/FreeBSD:15:amd64/26.1/latest/packages.txt" 2>/dev/null)" "1"
signdir
printf 'ABI=FreeBSD:15:amd64\nSERIES=26.7\nSERVE=FreeBSD:15:amd64/26.1 FreeBSD:15:amd64/26.7\n' >"$W/repo.conf"
mkdir -p "$W/site/FreeBSD:15:amd64/26.1/latest/All"
echo "old" >"$W/site/FreeBSD:15:amd64/26.1/latest/All/os-alpha-1.0.pkg"
expect_eq "sign: the first publish into a new series signs a target tree holding only the built package" \
	"$(vm sign-catalogue.sh >/dev/null 2>&1; echo "rc=$?")" "rc=0"
signdir
expect_fail "sign: with one series served, every catalogue package is still required" vm sign-catalogue.sh
signdir os-alpha-1.1.pkg
printf 'ABI=FreeBSD:15:amd64\nSERIES=26.7\nSERVE=FreeBSD:15:amd64/26.1 FreeBSD:15:amd64/26.7\n' >"$W/repo.conf"
mkdir -p "$W/site/FreeBSD:15:amd64/26.1/latest/All"
echo "old" >"$W/site/FreeBSD:15:amd64/26.1/latest/All/os-alpha-1.0.pkg"
vm sign-catalogue.sh >/dev/null
expect_eq "sign: the root keeps the target tree" "$(grep '^Name' "$W/site/packages.txt" | tr '\n' ' ')" \
	"Name : os-alpha-1.1 Name : os-legotypes-1.0_2 "

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
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
mirror 26.1 26.7
site 26.7 "$(core 26.7.5 1501000 php85-curl php85-xml py313-requests pkg)" '{"name":"php85","version":"8.5.10"}'
expect_eq "upstream facts" "$(up)" $'NEWEST=26.7\nNEXT_ABI=\nSERIES=26.7\nCORE=26.7.5\nPHP=85\nPYTHON=313\nFREEBSD=15.1'
mirror 26.7 27.1
site 26.7 "$(core 26.7.9 1501000 php85-curl py313-requests)"
site 27.1 "$(core 27.1 1502000 php86-curl py314-requests)"
expect_eq "newest series beside the target's facts" "$(up | grep -E '^(NEWEST|SERIES|PHP)=')" $'NEWEST=27.1\nSERIES=26.7\nPHP=85'
expect_eq "facts for a named series" "$(up 27.1 | grep -E '^(SERIES|PHP|PYTHON|FREEBSD)=')" $'SERIES=27.1\nPHP=86\nPYTHON=314\nFREEBSD=15.2'
printf '<a href="./FreeBSD:16:amd64/">FreeBSD:16:amd64/</a>\n' >>"$STUB_MIRROR/index.html"
mkdir -p "$STUB_MIRROR/FreeBSD:16:amd64"
printf '<a href="snapshots/">snapshots/</a>\n' >"$STUB_MIRROR/FreeBSD:16:amd64/index.html"
expect_eq "a next FreeBSD major with only snapshots is not reported yet" "$(up | grep '^NEXT_ABI=')" "NEXT_ABI="
printf '<a href="27.7/">27.7/</a>\n' >>"$STUB_MIRROR/FreeBSD:16:amd64/index.html"
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
mkpkg() { # mkpkg <file> <+MANIFEST json> [<path> <content>]...: a package with its manifest and those files
	local d out=$1 m=$2
	shift 2
	d=$(mktemp -d)
	printf '%s' "$m" >"$d/+MANIFEST"
	local names=(+MANIFEST)
	while [[ $# -ge 2 ]]; do
		mkdir -p "$d/$(dirname "${1#/}")"
		printf '%s' "$2" >"$d/${1#/}"
		names+=("${1#/}")
		shift 2
	done
	tar -cf "$out" -C "$d" "${names[@]}"
	rm -rf "$d"
}
base='{"name":"os-alpha","abi":"FreeBSD:15:amd64","arch":"freebsd:15:x86:64","flatsize":10,
 "annotations":{"product_abi":"26.7","FreeBSD_version":"1500068","product_hash":"aaaaaaa"},
 "scripts":{"post-install":"echo hi"},
 "files":{"/usr/local/a":{"sum":"1$x","perm":"0644","mtime":1},"/usr/local/b":{"sum":"1$y","perm":"0755","mtime":1}}}'
mod() { jq -c "$@" <<<"$base"; }
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
vf='/usr/local/opnsense/version/alpha'
vj() { printf '{"product_hash": "%s", "product_version": "%s"}' "$1" "$2"; }
mkpkg "$T/a.pkg" "$(mod --arg f "$vf" '.files[$f] = {"sum":"1$v1","perm":"0644"}')" "$vf" "$(vj aaaaaaa 1.0)"
mkpkg "$T/b.pkg" "$(mod --arg f "$vf" '.files[$f] = {"sum":"1$v2","perm":"0644"}')" "$vf" "$(vj bbbbbbb 1.0)"
expect_eq "compare: a version file differing only in its commit hash is not material" "$(cmpk)" "rc=0"
mkpkg "$T/b.pkg" "$(mod --arg f "$vf" '.files[$f] = {"sum":"1$v3","perm":"0644"}')" "$vf" "$(vj bbbbbbb 1.1)"
expect_eq "compare: a version file differing otherwise is" "$(cmpk)" $'file /usr/local/opnsense/version/alpha: content changed\nrc=1'
expect_eq "compare: not a package" "$(bash "$root/scripts/compare-package.sh" "$T/repo.conf" "$T/a.pkg" 2>/dev/null; echo "rc=$?")" "rc=2"

# --- verify-payload.sh -------------------------------------------------------------
# A synthetic plugin, net/alpha at $commit, and (written out by hand, not derived) what
# Mk/plugins.mk install makes of it: .in substituted, .shadow as .sample, both for .shadow.in,
# man/ gzipped, modes kept, top-level dot files and symlinks left out, the version file added.
umask 022 # the build VM's: staged files are 0644 or 0755
vp="$T/vp"
vs="$vp/net/alpha/src"
vu="$vp/stage/usr/local"
vhash=${commit:0:9}
vdef=($'PLUGIN_NAME=\t\talpha' $'PLUGIN_VERSION=\t\t1.0' $'PLUGIN_COMMENT=\t\tAlpha' \
	$'PLUGIN_MAINTAINER=\tmaintainer@example.org' $'PLUGIN_WWW=\t\thttps://example.org/alpha/')
vmk() { # vmk <line>...: net/alpha's Makefile, those lines and then the plugins.mk include
	{
		printf '%s\n' "$@"
		printf '\n.include "../../Mk/plugins.mk"\n'
	} >"$vp/net/alpha/Makefile"
}
vsrc() {
	rm -rf "$vp"
	mkdir -p "$vs/opnsense/scripts/Alpha" "$vs/opnsense/mvc/app/views/Alpha" "$vs/etc/pkg/repos" "$vs/man/man8"
	vmk "${vdef[@]}"
	printf '#!/usr/local/bin/python3\nprint("alpha")\n' >"$vs/opnsense/scripts/Alpha/run.py"
	chmod 755 "$vs/opnsense/scripts/Alpha/run.py"
	printf '<h1>alpha</h1>\n' >"$vs/opnsense/mvc/app/views/Alpha/index.volt"
	: >"$vs/opnsense/.placeholder"
	printf 'not installed\n' >"$vs/.hidden"
	ln -s scripts "$vs/opnsense/link"
	printf '%s\n' 'alpha %%PLUGIN_PKGVERSION%% %%PLUGIN_HASH%% %%PLUGIN_NAME%%%%PLUGIN_VARIANT%% %%PLUGIN_UNKNOWN%%' >"$vs/etc/alpha.conf.in"
	printf 'shadowed\n' >"$vs/etc/alpha.conf.shadow"
	printf '%s\n' 'url: %%PLUGIN_WWW%%' >"$vs/etc/pkg/repos/Alpha.conf.shadow.in"
	printf '.Dd October 1, 2026\n.Nm alpha\n' >"$vs/man/man8/alpha.8"
}
vver() { # vver [<jq filter>]: the version file Templates/version renders for net/alpha
	jq -n --arg h "$vhash" '{product_abi: "26.7", product_arch: "amd64", product_conflicts: "os-alpha-devel",
		product_email: "maintainer@example.org", product_hash: $h, product_id: "os-alpha", product_name: "alpha",
		product_tier: "3", product_version: "1.0", product_website: "https://example.org/alpha/"}' | jq "${1:-.}"
}
vstage() {
	rm -rf "$vp/stage"
	mkdir -p "$vu/opnsense/scripts/Alpha" "$vu/opnsense/mvc/app/views/Alpha" "$vu/etc/pkg/repos" "$vu/man/man8" "$vu/opnsense/version"
	printf '#!/usr/local/bin/python3\nprint("alpha")\n' >"$vu/opnsense/scripts/Alpha/run.py"
	chmod 755 "$vu/opnsense/scripts/Alpha/run.py"
	printf '<h1>alpha</h1>\n' >"$vu/opnsense/mvc/app/views/Alpha/index.volt"
	: >"$vu/opnsense/.placeholder"
	printf 'alpha 1.0 %s alpha %%%%PLUGIN_UNKNOWN%%%%\n' "$vhash" >"$vu/etc/alpha.conf"
	printf 'shadowed\n' >"$vu/etc/alpha.conf.sample"
	printf 'url: https://example.org/alpha/\n' >"$vu/etc/pkg/repos/Alpha.conf.sample"
	printf '.Dd October 1, 2026\n.Nm alpha\n' | gzip -n >"$vu/man/man8/alpha.8.gz"
	vver >"$vu/opnsense/version/alpha"
}
vbase='{"name":"os-alpha","origin":"opnsense/os-alpha","version":"1.0","comment":"Alpha",
 "maintainer":"maintainer@example.org","www":"https://example.org/alpha/","abi":"FreeBSD:15:amd64",
 "arch":"freebsd:15:x86:64","prefix":"/usr/local","flatsize":1,"licenselogic":"single","licenses":["BSD2CLAUSE"],
 "desc":"Alpha","categories":["net"],"scripts":{"pre-deinstall":"echo bye","post-install":"echo installed\nexit 0"}}'
# vpkg [<jq arguments and filter>]: $vp/alpha.pkg from the stage, as pkg create writes one: zstd, absolute member
# names (relative with VPKG_REL=1), owner VPKG_OWNER (default root:wheel); +MANIFEST lists each staged
# file (1$ sha256, mode, owner) and annotates the version file, then the filter applies;
# +COMPACT_MANIFEST is +MANIFEST without files and scripts unless VPKG_COMPACT gives a filter for it;
# VPKG_TWICE names a staged file to archive a second time
vpkg() {
	local d="$vp/pkgroot" f perm files='{}' m own=${VPKG_OWNER:-root:wheel} t=()
	rm -rf "$d"
	mkdir -p "$d"
	while IFS= read -r f; do
		perm=0644
		[[ -x $vp/stage/$f ]] && perm=0755
		files=$(jq -c --arg p "/$f" --arg s "1\$$(sum "$vp/stage/$f")" --arg m "$perm" \
			'.[$p] = {sum: $s, uname: "root", gname: "wheel", perm: $m, mtime: 1}' <<<"$files")
	done < <(cd "$vp/stage" && find usr -type f | sort)
	m=$(jq -c --argjson f "$files" --slurpfile v "$vu/opnsense/version/alpha" \
		'.files = $f | .annotations = ($v[0] + {FreeBSD_version: "1500068"})' <<<"$vbase" | jq -c "${@:-.}")
	printf '%s' "$m" >"$d/+MANIFEST"
	jq -c "del(.files, .scripts) | ${VPKG_COMPACT:-.}" <<<"$m" >"$d/+COMPACT_MANIFEST"
	if tar --version 2>/dev/null | grep -q bsdtar; then
		t=(--uname "${own%:*}" --gname "${own#*:}" --uid 0 --gid 0)
		[[ -n ${VPKG_REL:-} ]] || t+=(-P -s ',^usr/,/usr/,')
	else
		t=(--owner="${own%:*}:0" --group="${own#*:}:0")
		[[ -n ${VPKG_REL:-} ]] || t+=(-P --transform 's,^usr/,/usr/,')
	fi
	mapfile -t f < <(cd "$vp/stage" && find usr -type f | sort)
	[[ -z ${VPKG_TWICE:-} ]] || f+=("$VPKG_TWICE")
	tar -cf - "${t[@]}" -C "$d" +COMPACT_MANIFEST +MANIFEST -C "$vp/stage" "${f[@]}" | zstd -q -c >"$vp/alpha.pkg"
}
# vrun: verify-payload.sh on $vp/alpha.pkg, the name and version from VNAME and VVER (default os-alpha, 1.0)
vrun() { bash "$root/scripts/verify-payload.sh" "$vp/alpha.pkg" "$vp/net/alpha" "${VNAME:-os-alpha}" "${VVER:-1.0}" FreeBSD:15:amd64 26.7 "$commit"; }
vpass() { # vpass <name>: verify-payload.sh accepts the package
	local out
	if out=$(vrun 2>&1); then ok; else bad "$1: expected a pass, got [$out]"; fi
}
vfail() { # vfail <name> <reason>: verify-payload.sh refuses it with exactly that reason
	local err
	if err=$(vrun 2>&1 >/dev/null); then bad "$1: expected failure"; else expect_eq "$1" "$err" "verify-payload.sh: $2"; fi
}
# vrepack [<bsdtar arguments>...]: $vp/alpha.pkg again with bsdtar from $vp/pkgroot's manifests (as vpkg
# wrote them, or edited since) and the staged files, those arguments added: more members (an @<mtree spec>,
# a path under the stage) or options (-n for a directory itself)
vrepack() {
	local f
	mapfile -t f < <(cd "$vp/stage" && find usr -type f | sort)
	(cd "$vp/stage" && bsdtar -cf - --format=pax --uname root --gname wheel --uid 0 --gid 0 -P -s ',^usr/,/usr/,' \
		"$@" -C "$vp/pkgroot" +COMPACT_MANIFEST +MANIFEST -C "$vp/stage" "${f[@]}") | zstd -q -c >"$vp/alpha.pkg"
}
# vjson <file> <text>: <text> written before the first key of the JSON object in <file> (a repeated key)
vjson() {
	local j
	j=$(<"$1")
	printf '{%s,%s' "$2" "${j#\{}" >"$1"
}
vreset() { vsrc && vstage && vpkg; }
volt=/usr/local/opnsense/mvc/app/views/Alpha/index.volt
runpy=/usr/local/opnsense/scripts/Alpha/run.py

vreset
expect_eq "payload: identical, with .in, .shadow, .shadow.in and man/" "$(vrun 2>&1; echo "rc=$?")" \
	$'payload: OK (8 files)\nscript post-install:\n\techo installed\n\texit 0\nscript pre-deinstall:\n\techo bye\nrc=0'
VPKG_REL=1 vpkg
vpass "payload: relative member names"
vreset
printf '<h1>beta</h1>\n' >"$vu/opnsense/mvc/app/views/Alpha/index.volt"
vpkg
vfail "payload: a modified file" "$volt differs from src/opnsense/mvc/app/views/Alpha/index.volt"
vreset
printf 'alpha 1.0 %s alpha %%%%PLUGIN_UNKNOWN%%%%\n' fedcba987 >"$vu/etc/alpha.conf"
vpkg
vfail "payload: an .in file substituted with other values" "/usr/local/etc/alpha.conf differs from src/etc/alpha.conf.in"
vreset
printf '.Dd October 1, 2026\n.Nm beta\n' | gzip -n >"$vu/man/man8/alpha.8.gz"
vpkg
vfail "payload: a modified man page" "/usr/local/man/man8/alpha.8.gz differs from src/man/man8/alpha.8"
vreset
printf '.Dd October 1, 2026\n.Nm alpha\n' >"$vu/man/man8/alpha.8.gz"
vpkg
vfail "payload: a man page not gzipped" "/usr/local/man/man8/alpha.8.gz is not gzip data"
vreset
printf '<?php\n' >"$vu/opnsense/extra.php"
vpkg
vfail "payload: an extra packaged file" "/usr/local/opnsense/extra.php is packaged but has no source"
vreset
printf '<?php\n' >"$vs/opnsense/new.php"
vfail "payload: a source file missing from the package" "src/opnsense/new.php is not packaged (as /usr/local/opnsense/new.php)"
vreset
printf 'x\n' >"$vs/etc/alpha.conf"
vfail "payload: two source files that install one path" "src/etc/alpha.conf and src/etc/alpha.conf.in both install /usr/local/etc/alpha.conf"
vreset
mkdir -p "$vs/opnsense/version"
printf '{}\n' >"$vs/opnsense/version/alpha"
vfail "payload: a source file in the version file's place" "src/opnsense/version/alpha would replace the version file"
vreset
printf 'x\n' >"$vs/opnsense/bad*name"
vfail "payload: a source file name tar would read as a pattern" "src/opnsense/bad*name: unsupported file name"
vreset
chmod 644 "$vu/opnsense/scripts/Alpha/run.py"
vpkg
vfail "payload: an executable packaged without its exec bit" "$runpy: mode 0644 in +MANIFEST, expected 0755"
vreset
chmod 644 "$vu/opnsense/scripts/Alpha/run.py"
vpkg --arg p "$runpy" '.files[$p].perm = "0755"'
vfail "payload: the archive mode is what pkg installs" "$runpy: mode 0644 in the archive, expected 0755"
vreset
chmod 755 "$vu/opnsense/mvc/app/views/Alpha/index.volt"
vpkg
vfail "payload: a plain file packaged executable" "$volt: mode 0755 in +MANIFEST, expected 0644"
vreset
chmod 4755 "$vu/opnsense/scripts/Alpha/run.py"
vpkg --arg p "$runpy" '.files[$p].perm = "4755"'
vfail "payload: setuid in +MANIFEST" "$runpy: mode 4755 in +MANIFEST, expected 0755"
vpkg
vfail "payload: setuid in the archive" "$runpy: mode 4755 in the archive, expected 0755"
vreset
vpkg --arg p "$runpy" '.files[$p].uname = "nobody"'
vfail "payload: an owner other than root in +MANIFEST" "$runpy: owner nobody:wheel in +MANIFEST, expected root:wheel"
VPKG_OWNER=nobody:wheel vpkg
vfail "payload: an owner other than root in the archive" "/usr/local/etc/alpha.conf: owner nobody:wheel in the archive, expected root:wheel"
vreset
zero=$(printf '0%.0s' {1..64})
vpkg --arg p "$volt" --arg s "1\$$zero" '.files[$p].sum = $s'
vfail "payload: a +MANIFEST sum that does not match the content" "$volt: +MANIFEST sum does not match the content"
b2='2$18tyyndkxmop9pmun9a8fz6awebt6wz9bbiathkzggib3p81uudj8tuij8qwpgofq449qmdcu6fumzuijx1uzkgkn4eab6o1o6fokub'
vpkg --arg p "$volt" --arg s "$b2" '.files[$p].sum = $s'
vpass "payload: a 2\$ sum (BLAKE2b, pkg's base32), as pkg 2 writes them"
vpkg --arg p "$volt" --arg s "${b2/18ty/19ty}" '.files[$p].sum = $s'
vfail "payload: a 2\$ sum that does not match" "$volt: +MANIFEST sum does not match the content"
vpkg --arg p "$volt" '.files[$p].sum = "13$abc"'
vfail "payload: a sum type it cannot check" "$volt: +MANIFEST sum type 13 is not supported"
vreset
vver '.product_hash = "fedcba987"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: a version file with a foreign product_hash" "version file: product_hash is fedcba987, expected $vhash"
vver '.product_version = "1.1"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: a version file with the wrong product_version" "version file: product_version is 1.1, expected 1.0"
vver '.product_id = "os-beta"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: a version file with the wrong product_id" "version file: product_id is os-beta, expected os-alpha"
vver '.product_abi = "27.1"' >"$vu/opnsense/version/alpha"
vpkg '.annotations.product_abi = "26.7"'
vfail "payload: a version file with the wrong product_abi" "version file: product_abi is 27.1, expected 26.7"
vver '.product_extra = "x"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: a version file with an eleventh key" "version file: not exactly the ten product_* strings"
vver '.product_website = "https://example.org/?a&b"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: a version file value other than the Makefile's" "version file: product_website is https://example.org/?a&b, expected https://example.org/alpha/"
vmk "${vdef[@]}" 'PLUGIN_WWW= https://example.org/?a&b'
vfail "payload: a Makefile value sed would not copy literally" "Makefile: PLUGIN_WWW holds &, = or %%, which sed would not copy literally"
vreset
vpkg '.annotations.product_tier = "2"'
vfail "payload: annotations that differ from the version file" "+MANIFEST annotations differ from the version file"
vpkg --arg v /usr/local/opnsense/version/alpha 'del(.files[$v])'
vfail "payload: no version file" "+MANIFEST lists no /usr/local/opnsense/version/alpha"
vpkg '.name = "os-beta"'
vfail "payload: the wrong name" "+MANIFEST name is os-beta, expected os-alpha"
vpkg '.version = "1.1"'
vfail "payload: the wrong version" "+MANIFEST version is 1.1, expected 1.0"
vpkg '.abi = "FreeBSD:16:amd64"'
vfail "payload: the wrong ABI" "+MANIFEST abi is FreeBSD:16:amd64, expected FreeBSD:15:amd64"
vpkg '.annotations.product_abi = "27.1"'
vfail "payload: the wrong series" "+MANIFEST product_abi is 27.1, expected 26.7"
vpkg '.lua_scripts = {"post-install": ["print(1)"]}'
vfail "payload: a manifest key it does not check" "+MANIFEST key lua_scripts is not expected"
VPKG_COMPACT='.deps = {"php85-curl": {"origin": "ftp/php85-curl", "version": "8.5.0"}}' vpkg
vfail "payload: a compact manifest that differs" "+COMPACT_MANIFEST differs from +MANIFEST"
vpkg '.scripts["post-install"] = "echo \u001b[2Kinstalled"'
vfail "payload: a script with control characters" "script post-install holds characters other than printable ASCII, tab and newline"
vpkg --arg p "$volt" 'del(.files[$p])'
vfail "payload: a source file +MANIFEST does not list" "src/opnsense/mvc/app/views/Alpha/index.volt is not packaged (as $volt)"
printf '<?php\n' >"$vu/opnsense/extra.php"
vpkg 'del(.files["/usr/local/opnsense/extra.php"])'
vfail "payload: an archive member +MANIFEST does not list" "archive member /usr/local/opnsense/extra.php is not in +MANIFEST"
VPKG_TWICE=usr/local/opnsense/mvc/app/views/Alpha/index.volt vpkg
vfail "payload: an archive member twice" "archive member $volt appears twice"
vreset
printf '<?php\n' >"$vs/opnsense/new.php"
vpkg '.files["/usr/local/opnsense/new.php"] = {sum: "1$x", uname: "root", gname: "wheel", perm: "0644", mtime: 1}'
vfail "payload: a +MANIFEST file the archive lacks" "/usr/local/opnsense/new.php is not in the archive"
vreset
vpkg '.deps = {"php85-curl": {"origin": "ftp/php85-curl", "version": "8.5.0"}}'
vfail "payload: dependencies without PLUGIN_DEPENDS" "dependencies (php85-curl) differ from PLUGIN_DEPENDS (none)"
vmk "${vdef[@]}" $'PLUGIN_DEPENDS=\t\tphp85-curl \\\n\t\t\tphp85-xml'
vfail "payload: PLUGIN_DEPENDS without the dependencies" "dependencies (php85-curl) differ from PLUGIN_DEPENDS (php85-curl php85-xml)"
vpkg '.deps = {"php85-curl": {"origin": "ftp/php85-curl", "version": "8.5.0"}, "php85-xml": {"origin": "textproc/php85-xml", "version": "8.5.0"}}'
vpass "payload: dependencies equal to PLUGIN_DEPENDS"
vreset
vmk "${vdef[@]}" $'PLUGIN_VARIANTS=\tA B'
vfail "payload: plugin variants" "Makefile: PLUGIN_VARIANTS is not supported"
vreset
vmk "${vdef[@]}" '.if defined(X)' $'PLUGIN_DEPENDS=\tphp85-curl' '.endif'
vfail "payload: a conditional Makefile" "Makefile: .if defined(X) is not supported"
vreset
mkdir -p "$vp/net/alpha/contrib"
vfail "payload: contrib/" "contrib/ is not supported"
vreset
printf 'alpha \377 %%%%PLUGIN_NAME%%%%\n' >"$vs/etc/alpha.conf.in"
vfail "payload: an .in file that is not UTF-8" "src/etc/alpha.conf.in: not UTF-8 text, cannot substitute"
vreset
# every version file value from the Makefile, the ABI, the series and the commit (plugins.mk:44-122, defaults.mk:42-54)
vreset
vver '.product_arch = "i386"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: product_arch other than the ABI's" "version file: product_arch is i386, expected amd64"
vver '.product_conflicts = "os-alpha-devel os-beta"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: product_conflicts other than plugins.mk's" "version file: product_conflicts is os-alpha-devel os-beta, expected os-alpha-devel"
vver '.product_email = "other@example.org"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: product_email other than PLUGIN_MAINTAINER" "version file: product_email is other@example.org, expected maintainer@example.org"
vver '.product_tier = "1"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: product_tier other than PLUGIN_TIER" "version file: product_tier is 1, expected 3"
vver '.product_name = "beta"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: product_name other than PLUGIN_NAME" "version file: product_name is beta, expected alpha"
vreset
vmk "${vdef[@]}" $'PLUGIN_CONFLICTS=\tzeta beta'
vver '.product_conflicts = "os-alpha-devel os-beta os-beta-devel os-zeta os-zeta-devel"' >"$vu/opnsense/version/alpha"
vpkg
vpass "payload: PLUGIN_CONFLICTS as plugins.mk expands it"
vreset
vmk $'PLUGIN_NAME=\talpha' $'PLUGIN_VERSION=\t1.0' $'PLUGIN_COMMENT=\tAlpha'
vver '.product_email = "N/A" | .product_website = "https://opnsense.org/"' >"$vu/opnsense/version/alpha"
printf 'url: https://opnsense.org/\n' >"$vu/etc/pkg/repos/Alpha.conf.sample"
vpkg
vpass "payload: plugins.mk's defaults for PLUGIN_MAINTAINER, PLUGIN_WWW and PLUGIN_TIER"
vreset
vmk "${vdef[@]}" $'PLUGIN_TIER=\t2' $'PLUGIN_REVISION=\t1'
vver '.product_tier = "2" | .product_version = "1.0_1"' >"$vu/opnsense/version/alpha"
printf 'alpha 1.0_1 %s alpha %%%%PLUGIN_UNKNOWN%%%%\n' "$vhash" >"$vu/etc/alpha.conf"
vpkg '.version = "1.0_1"'
VVER=1.0_1 vpass "payload: PLUGIN_TIER and PLUGIN_REVISION from the Makefile, the .in substituted with them"
vfail "payload: a version other than the Makefile's" "the version 1.0 is not 1.0_1, as the Makefile gives it"
vreset
vmk "${vdef[@]}" $'PLUGIN_REVISION=\t0'
vpass "payload: PLUGIN_REVISION 0 adds no _0"
VNAME=os-beta vfail "payload: a name other than the Makefile's" "the name os-beta is not os-alpha, as the Makefile names it"
vmk "${vdef[@]}" 'PLUGIN_COMMENT= costs $$5'
vfail "payload: a Makefile value make would expand" 'Makefile: PLUGIN_COMMENT holds $, `, " or \, which make or sh would expand'
vmk "${vdef[@]}" 'PLUGIN_COMMENT= say "hi"'
vfail "payload: a Makefile value the shell would unquote" 'Makefile: PLUGIN_COMMENT holds $, `, " or \, which make or sh would expand'
vmk "${vdef[@]}" 'PLUGIN_COMMENT= a\tb'
vfail "payload: a Makefile value with a backslash" 'Makefile: PLUGIN_COMMENT holds $, `, " or \, which make or sh would expand'
vmk "${vdef[@]}" $'PLUGIN_DEVEL=\tyes'
vfail "payload: a Makefile variable plugins.mk reads that is not modelled" "Makefile: PLUGIN_DEVEL is not supported"
vmk "${vdef[@]}"
printf 'PLUGIN_TIER=\t2\n' >>"$vp/net/alpha/Makefile"
vfail "payload: an assignment after the include" "Makefile: PLUGIN_TIER is set after the plugins.mk include"
vmk $'PLUGIN_VERSION=\t1.0' $'PLUGIN_COMMENT=\tAlpha'
vfail "payload: no PLUGIN_NAME" "Makefile: PLUGIN_NAME is not set"
printf 'PLUGIN_NAME=\talpha\n' >"$vp/net/alpha/Makefile"
vfail "payload: no plugins.mk include" 'Makefile: no .include "../../Mk/plugins.mk"'

# repeated JSON keys: jq keeps the last, pkg (libucl) takes them all
vreset
vjson "$vp/pkgroot/+MANIFEST" '"scripts":{"pre-install":"echo hidden"}'
vrepack
vfail "payload: a second scripts object" "+MANIFEST repeats a key"
vreset
vpkg '.deps = {}'
vjson "$vp/pkgroot/+MANIFEST" '"deps":{"evil":{"origin":"x/evil","version":"1"}}'
vrepack
vfail "payload: a second deps object" "+MANIFEST repeats a key"
vreset
j=$(<"$vp/pkgroot/+MANIFEST")
printf '%s' "${j/\"scripts\":\{/\"scripts\":\{\"pre-deinstall\":\"echo hidden\",}" >"$vp/pkgroot/+MANIFEST"
vrepack
vfail "payload: a repeated script name inside scripts" "+MANIFEST repeats a key"
vreset
vjson "$vp/pkgroot/+COMPACT_MANIFEST" '"name":"os-evil"'
vrepack
vfail "payload: a repeated key in +COMPACT_MANIFEST" "+COMPACT_MANIFEST repeats a key"
vreset
vjson "$vu/opnsense/version/alpha" '"product_tier":"1"'
vpkg
vfail "payload: a repeated key in the version file" "version file repeats a key"
vreset
j=$(<"$vp/pkgroot/+MANIFEST")
printf '%s' "${j/\"desc\":\"Alpha\"/\"desc\":\"Alph$'\377'\"}" >"$vp/pkgroot/+MANIFEST"
vrepack
vfail "payload: a +MANIFEST that is not UTF-8" "+MANIFEST is not UTF-8 text"

# script names and text
vreset
vpkg '.scripts["post-install\n```\nrm -rf /"] = "x"'
vfail "payload: a script name pkg does not run" 'script "post-install\n```\nrm -rf /" is not a pkg script name'
vpkg '.scripts["pre-upgrade"] = "x"'
vfail "payload: pre-upgrade, not a pkg script name" 'script "pre-upgrade" is not a pkg script name'
vpkg '.scripts["post-install"] = "echo ‮evil"'
vfail "payload: a script with a bidi override" "script post-install holds characters other than printable ASCII, tab and newline"
vpkg '.scripts["post-install"] = "echo %72m"'
vfail "payload: a %-escape pkg would decode" "script post-install holds a %-escape other than %25, which pkg would decode"
vpkg '.scripts = {"post-install": "echo 100%25"}'
expect_eq "payload: a script is shown as pkg decodes it" "$(vrun 2>&1 | tail -2)" $'script post-install:\n\techo 100%'

# member types and flags, from libarchive's own view
vreset
mv "$vu/opnsense/mvc/app/views/Alpha/index.volt" "$vp/index.volt"
printf '#mtree\nusr/local/opnsense/mvc/app/views/Alpha/index.volt type=file mode=0644 uname=root gname=wheel flags=nodump contents=%s\n' \
	"$vp/index.volt" >"$vp/spec"
vrepack "@$vp/spec"
vfail "payload: file flags, which tar -tv does not show and pkg applies" "archive member $volt has file flags (nodump)"
vreset
rm "$vu/opnsense/mvc/app/views/Alpha/index.volt"
ln -s ../../../scripts/Alpha/run.py "$vu/opnsense/mvc/app/views/Alpha/index.volt"
vrepack usr/local/opnsense/mvc/app/views/Alpha/index.volt
vfail "payload: a symbolic link at a packaged path" "archive member $volt is a symbolic link, not a regular file"
vreset
mkdir -p "$vu/evil /usr/local/opnsense/mvc/app/views/Alpha"
mv "$vu/opnsense/mvc/app/views/Alpha/index.volt" "$vu/evil /usr/local/opnsense/mvc/app/views/Alpha/index.volt"
ln "$vu/evil /usr/local/opnsense/mvc/app/views/Alpha/index.volt" "$vu/opnsense/mvc/app/views/Alpha/index.volt"
vrepack
vfail "payload: a hard link at a packaged path, its target ending in that path" "archive member $volt is a hard link, not a regular file"
vreset
vrepack -n usr/local/opnsense
vfail "payload: a directory member" "archive member /usr/local/opnsense/ is a directory, not a regular file"
vreset
printf '#mtree\n./usr/local/opnsense/mvc/app/views/Alpha/index.volt type=file mode=0644 uname=root gname=wheel contents=%s\n' \
	"$vu/opnsense/mvc/app/views/Alpha/index.volt" >"$vp/spec"
vrepack "@$vp/spec"
vfail "payload: a ./usr/local alias of a packaged file" "archive member ./usr/local/opnsense/mvc/app/views/Alpha/index.volt is not in +MANIFEST"
printf '#mtree\nusr/local/../usr/local/opnsense/mvc/app/views/Alpha/index.volt type=file mode=0644 uname=root gname=wheel contents=%s\n' \
	"$vu/opnsense/mvc/app/views/Alpha/index.volt" >"$vp/spec"
vrepack "@$vp/spec"
vfail "payload: a /usr/local/.. alias of a packaged file" "archive member /usr/local/../usr/local/opnsense/mvc/app/views/Alpha/index.volt is not in +MANIFEST"
vreset
vrepack
vpass "payload: the same package written by bsdtar as pax"
vreset
expect_fail "payload: a commit that is not 40 hex digits" bash "$root/scripts/verify-payload.sh" "$vp/alpha.pkg" "$vp/net/alpha" os-alpha 1.0 FreeBSD:15:amd64 26.7 "$vhash"
expect_fail "payload: usage" bash "$root/scripts/verify-payload.sh" "$vp/alpha.pkg"
expect_fail "payload: not a package" bash "$root/scripts/verify-payload.sh" "$T/repo.conf" "$vp/net/alpha" os-alpha 1.0 FreeBSD:15:amd64 26.7 "$commit"

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
expect_eq "findings: a failed build is material, with the end of its log" "$(fd)" \
	$'MATERIAL: building the branch as a publish would failed; the end of its log:\nLOG: make: error 1\nrc=1'
cfdir
echo "garbage" >"$T/cf/fresh.pkg"
mkpkg "$T/cf/rebased.pkg" "$(mod '.annotations.product_abi = "27.1"')"
expect_eq "findings: when the as-published build cannot be compared, rebased differences are not blamed on Mk/" "$(fd)" \
	$'MATERIAL: the build as a publish would make it could not be compared with the release\nMATERIAL: a build with upstream Mk/ differs from the release in product_abi: "26.7" -> "27.1" (the as-published build could not be compared)\nrc=1'
cfdir
echo "Built from Org/plugins, branch b, commit 2222222bbbb." >"$T/cf/fresh.source"
expect_eq "findings: unreleased commits are a note" "$(fd)" \
	$'NOTE: the branch has commits after its release (release 1111111aaaa, branch head 2222222bbbb)\nrc=0'
cfdir
rm "$T/cf/published.pkg" "$T/cf/notes"
expect_eq "findings: no release yet is a note" "$(fd)" $'NOTE: os-alpha has no release yet; nothing to compare\nrc=0'

crep() { bash "$root/scripts/canary-report.sh" "canary: os-alpha" "$T/findings" "https://run/1"; }
reset_stub
printf 'MATERIAL: build failed\nLOG: cc: error one\nLOG: *** Error code 1\n' >"$T/findings"
crep >/dev/null
expect_eq "report: log lines become one code block" "$(sed -n '/^```$/,/^```$/p' "$STUB/issue_calls" | tr '\n' '|')" \
	'```|cc: error one|*** Error code 1|```|'
: >"$STUB/issue_calls"
{ echo "MATERIAL: build failed"; for i in $(seq 1 3000); do printf 'LOG: %050d\n' "$i"; done; } >"$T/findings"
crep >/dev/null
expect_eq "report: the body stays under GitHub's limit" "$(($(wc -c <"$STUB/issue_calls") < 65000))" "1"
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

# --- canary-vm.sh and canary.sh --------------------------------------------------
conf 'os-alpha  Org/plugins br net/alpha yes' \
	'os-beta   Org/plugins br net/beta  yes'
vmdir
vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_FAIL_DIR=net/beta -- canary-vm.sh >/dev/null
expect_eq "canary-vm: both builds of a good package" "$(names "$W/canary/os-alpha")" "fresh.pkg fresh.source rebased.pkg "
expect_eq "canary-vm: a failing package does not stop the rest, and keeps its logs" "$(names "$W/canary/os-beta")" "fresh.log fresh.tail rebased.log rebased.tail "

cw="$T/cw"
rm -rf "$cw"
mkdir -p "$cw"
cp -R "$W/canary" "$cw/"
printf 'ABI=FreeBSD:15:amd64\nSERIES=26.7\nSERVE=FreeBSD:15:amd64/26.7\n' >"$T/repo.conf"
printf 'NEWEST=26.7\nNEXT_ABI=\nSERIES=26.7\nCORE=26.7.5\nPHP=85\nPYTHON=313\nFREEBSD=15.1\n' >"$cw/upstream.env"
reset_stub
canary_run() { (cd "$cw" && PACKAGES_CONF="$T/packages.conf" REPO_CONF="$T/repo.conf" bash "$root/scripts/canary.sh" https://run/2); }
out=$(canary_run)
rc=$?
expect_eq "canary: a failed build makes the run fail" "$rc" "1"
expect_eq "canary: one report per package, then the series" "$out" $'clean\nopened\nclean'
expect_eq "canary: the failing package's issue" "$(cut -s -d'|' -f1,2 "$STUB/issue_calls")" "create|canary: os-beta"
expect_eq "canary: package issues carry the upstream facts" "$(grep -c 'NOTE\*\*: upstream PHP=85' "$STUB/issue_calls")" "1"
publish os-alpha-1.0 2026-01-01T00:00:00Z
rm "$STUB/assets/os-alpha-1.0/os-alpha-1.0.pkg"
: >"$STUB/issue_calls"
out=$(canary_run)
expect_eq "canary: a release that cannot be fetched is reported and the run goes on" "$out" $'opened\nopened\nclean'
expect_eq "canary: the fetch failure is in the issue" "$(grep -c 'could not fetch os-alpha-1.0' "$STUB/issue_calls")" "1"
reset_stub
printf 'NEWEST=27.1\nNEXT_ABI=FreeBSD:16:amd64\nSERIES=26.7\nCORE=26.7.9\nPHP=85\nPYTHON=313\nFREEBSD=15.1\n' >"$cw/upstream.env"
: >"$STUB/issue_calls"
canary_run >/dev/null
expect_eq "canary: a new series and a new FreeBSD major open the series issue" \
	"$(grep -c '^create|canary: upstream series|' "$STUB/issue_calls")" "1"
expect_eq "canary: the series issue names both" \
	"$(grep -c -e 'ships series 27.1' -e 'publishes FreeBSD:16:amd64' "$STUB/issue_calls")" "2"
rm "$cw/upstream.env"
expect_fail "canary: refuses to run without upstream facts" canary_run

# --- verify-catalogue.sh -------------------------------------------------------------
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
reset_stub
rm -rf "$T/livesite"
publish os-alpha-1.1 2026-01-03T00:00:00Z
live os-alpha-1.1
d="$T/livesite/FreeBSD:15:amd64/26.7/latest"
echo "catalogue data" >"$T/data"
openssl dgst -sha256 -r "$T/data" | cut -d' ' -f1 | tr -d '\n' | openssl dgst -sha256 -sign "$T/key.pem" -binary >"$T/data.sig"
cp "$T/pub.pem" "$T/data.pub"
tar -cf "$d/data.pkg" -C "$T" data data.sig data.pub
vc() { REPO_CONF="$T/repo.conf" PUB_KEY="$T/pub.pem" bash "$root/scripts/verify-catalogue.sh" "$@"; }
expect_eq "verify: a good publish" "$(vc os-alpha >/dev/null; echo "rc=$?")" "rc=0"
live os-alpha-1.0
expect_fail "verify: the tree serves an older build" vc os-alpha
live os-alpha-1.1
openssl dgst -sha256 -r "$T/data" | cut -d' ' -f1 | tr -d '\n' | openssl dgst -sha256 -sign "$T/other.pem" -binary >"$T/data.sig"
tar -cf "$d/data.pkg" -C "$T" data data.sig
expect_fail "verify: a signature the published key does not verify" vc os-alpha
openssl dgst -sha256 -r "$T/data" | cut -d' ' -f1 | tr -d '\n' | openssl dgst -sha256 -sign "$T/key.pem" -binary >"$T/data.sig"
openssl rsa -in "$T/other.pem" -pubout -out "$T/data.pub" 2>/dev/null
tar -cf "$d/data.pkg" -C "$T" data data.sig data.pub
expect_fail "verify: a catalogue carrying a key other than the published one" vc os-alpha

echo "passed $pass, failed $failed"
[[ $failed -eq 0 ]]
