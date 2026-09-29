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
	"os-wg-client-tunnels os-mac-alias-cache os-legotypes "

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
# publish <tag> <created-at> [notes-sha]: a release holding <tag>.pkg
publish() {
	local tag=$1 at=$2 f
	mkdir -p "$STUB/assets/$tag"
	f="$STUB/assets/$tag/$tag.pkg"
	echo "bytes of $tag" >"$f"
	printf 'Built from Org/plugins, branch b, commit 0000000.\n\nsha256: %s\n' "${3:-$(sum "$f")}" >"$STUB/notes/$tag"
	echo "$tag" >>"$STUB/tags"
	jq --arg t "$tag" --arg c "$at" '. + [{tagName: $t, createdAt: $c}]' "$STUB/releases.json" >"$STUB/r"
	mv "$STUB/r" "$STUB/releases.json"
}
rel() { bash "$root/scripts/release.sh" "$@"; }
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
cf os-vendor "$T/cat1" >/dev/null
expect_eq "carries the newest of each other catalogue package, never a release-only one" \
	"$(names "$T/cat1")" "os-alpha-1.1.pkg os-alpha-extra-2.0.pkg "
expect_eq "carries the bytes" "$(cat "$T/cat1/os-alpha-1.1.pkg")" "bytes of os-alpha-1.1"
cf os-alpha "$T/cat2" >/dev/null
expect_eq "a name prefix does not capture another package's releases" \
	"$(names "$T/cat2")" "os-alpha-extra-2.0.pkg os-vendor-1.0_1.pkg "
expect_fail "built package not in the catalogue" cf os-beta "$T/cat3"
publish os-vendor-1.0_2 2026-01-06T00:00:00Z "$(printf '0%.0s' {1..64})"
expect_fail "sha256 mismatch" cf os-alpha "$T/cat4"
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
expect_fail "missing release" cf os-alpha "$T/cat5"
publish os-alpha-extra-2.0 2026-01-02T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
printf 'no checksum here\n' >"$STUB/notes/os-vendor-1.0"
expect_fail "notes without sha256" cf os-alpha "$T/cat6"
printf 'sha256: %s\nsha256: %s\n' "$(sum "$STUB/assets/os-vendor-1.0/os-vendor-1.0.pkg")" "$(sum "$STUB/assets/os-vendor-1.0/os-vendor-1.0.pkg")" >"$STUB/notes/os-vendor-1.0"
expect_fail "notes with two sha256 lines" cf os-alpha "$T/cat7"

echo "passed $pass, failed $failed"
[[ $failed -eq 0 ]]
