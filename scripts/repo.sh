#!/bin/sh
# Read repo.conf (REPO_CONF overrides its path).
#   repo.sh abi            the package ABI builds target, e.g. FreeBSD:15:amd64
#   repo.sh series         the series builds target, e.g. 26.7
#   repo.sh target         the target tree, <ABI>/<series>
#   repo.sh serve          the trees the site serves, <ABI>/<series>, one per line
#   repo.sh tree [entry]   site/<entry>/latest (default: the target; the entry must
#                          be served)
# A malformed file fails every command.
set -eu

conf=${REPO_CONF:-$(dirname "$0")/../repo.conf}

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
tree)
	e=${2:-$(target)}
	list=$(serve)
	printf '%s\n' "$list" | grep -qxF "$e" || die "$e is not served"
	printf 'site/%s/latest\n' "$e"
	;;
*) die "usage: repo.sh abi | series | target | serve | tree [entry]" ;;
esac
