#!/bin/sh
# Read repo.conf (REPO_CONF overrides its path).
#   repo.sh abi            the package ABI builds target, e.g. FreeBSD:15:amd64
#   repo.sh series         the series builds target, e.g. 26.7
#   repo.sh serve          the series the site serves, one per line
#   repo.sh tree [series]  site/<ABI>/<series>/latest (default: the target series;
#                          the series must be served)
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

serve() {
	target=$(series)
	list=$(value SERVE)
	found=no
	for s in $list; do
		is_series "$s" || die "$conf: malformed series $s in SERVE"
		[ "$s" != "$target" ] || found=yes
	done
	[ "$found" = yes ] || die "$conf: SERVE must include SERIES $target"
	for s in $list; do printf '%s\n' "$s"; done
}

case ${1:-} in
abi) abi ;;
series) series ;;
serve) serve ;;
tree)
	s=${2:-$(series)}
	serve | grep -qxF "$s" || die "series $s is not served"
	printf 'site/%s/%s/latest\n' "$(abi)" "$s"
	;;
*) die "usage: repo.sh abi | series | serve | tree [series]" ;;
esac
