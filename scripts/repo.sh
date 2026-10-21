#!/bin/sh
# Read repo.conf, beside this script's directory and nowhere else: it pins the source of the pkg
# that signs the catalogue (PKG_TOOL_SHA256), so no environment variable moves it.
#   repo.sh abi            the package ABI builds target, e.g. FreeBSD:15:amd64
#   repo.sh series         the series builds target, e.g. 26.7
#   repo.sh target         the target tree, <ABI>/<series>
#   repo.sh serve          the trees the site serves, <ABI>/<series>, one per line
#   repo.sh immutable      yes or no: REQUIRE_IMMUTABLE_RELEASES, whether carrying
#                          forward refuses a release that is not immutable
#   repo.sh pkg-tool-commit  PKG_TOOL_COMMIT: the full freebsd/pkg commit
#                          pkg-tool.sh builds pkg from
#   repo.sh pkg-tool-sha256  PKG_TOOL_SHA256: the sha256 of GitHub's archive of
#                          that commit, which pkg-tool.sh refuses to build without
#   repo.sh tree [entry]   site/<entry>/latest (default: the target; the entry must
#                          be served)
# A malformed file fails every command.
set -eu

conf=$(dirname "$0")/../repo.conf

die() {
	echo "repo.sh: $*" >&2
	exit 1
}

# the value of KEY=VALUE, which must be set exactly once
value() {
	awk -v k="$1" '
		/^[[:space:]]*(#|$)/ { next }
		index($0, k "=") == 1 { print substr($0, length(k) + 2); n++ }
		END { exit n == 1 ? 0 : 1 }
	' "$conf" || die "$conf: $1 must be set exactly once"
}

is_series() { printf '%s\n' "$1" | grep -Eqx '[0-9]+\.[0-9]+'; }

abi() {
	v=$(value ABI)
	printf '%s\n' "$v" | grep -Eqx 'FreeBSD:[0-9]+:[a-z0-9_]+' || die "$conf: malformed ABI $v"
	printf '%s\n' "$v"
}

series() {
	v=$(value SERIES)
	is_series "$v" || die "$conf: malformed SERIES $v"
	printf '%s\n' "$v"
}

target() { printf '%s/%s\n' "$(abi)" "$(series)"; }

immutable() {
	v=$(value REQUIRE_IMMUTABLE_RELEASES)
	case $v in
	yes | no) printf '%s\n' "$v" ;;
	*) die "$conf: REQUIRE_IMMUTABLE_RELEASES must be yes or no, not $v" ;;
	esac
}

pkg_tool_commit() {
	v=$(value PKG_TOOL_COMMIT)
	printf '%s\n' "$v" | grep -Eqx '[0-9a-f]{40}' ||
		die "$conf: PKG_TOOL_COMMIT must be a full commit (40 lower-case hex digits), not $v"
	printf '%s\n' "$v"
}

pkg_tool_sha256() {
	v=$(value PKG_TOOL_SHA256)
	printf '%s\n' "$v" | grep -Eqx '[0-9a-f]{64}' ||
		die "$conf: PKG_TOOL_SHA256 must be a sha256 (64 lower-case hex digits), not $v"
	printf '%s\n' "$v"
}

serve() {
	t=$(target)
	list=$(value SERVE)
	found=no
	for e in $list; do
		printf '%s\n' "$e" | grep -Eqx 'FreeBSD:[0-9]+:[a-z0-9_]+/[0-9]+\.[0-9]+' ||
			die "$conf: SERVE entry $e is not <ABI>/<series>"
		[ "$e" != "$t" ] || found=yes
	done
	[ "$found" = yes ] || die "$conf: SERVE must include the target $t"
	for e in $list; do printf '%s\n' "$e"; done
}

case ${1:-} in
abi) abi ;;
series) series ;;
target) target ;;
serve) serve ;;
immutable) immutable ;;
pkg-tool-commit) pkg_tool_commit ;;
pkg-tool-sha256) pkg_tool_sha256 ;;
tree)
	e=${2:-$(target)}
	list=$(serve)
	printf '%s\n' "$list" | grep -qxF "$e" || die "$e is not served"
	printf 'site/%s/latest\n' "$e"
	;;
*) die "usage: repo.sh abi | series | target | serve | immutable | pkg-tool-commit | pkg-tool-sha256 | tree [entry]" ;;
esac
