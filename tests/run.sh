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

echo "passed $pass, failed $failed"
[[ $failed -eq 0 ]]
