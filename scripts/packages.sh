#!/bin/sh
# Read packages.conf (PACKAGES_CONF overrides its path).
#   packages.sh row <package>   print "<repository> <branch> <directory> <catalogue>"
#   packages.sh catalogue       print the catalogue packages, one per line
# A malformed file fails every command, so a typo stops a run instead of
# silently dropping a package from the catalogue.
set -eu

conf=${PACKAGES_CONF:-$(dirname "$0")/../packages.conf}

die() {
	echo "packages.sh: $*" >&2
	exit 1
}

# The data lines, validated: five fields; a package name without "-<digit>", so
# "<name>-<digit>" starts only that package's release tags; catalogue yes or no;
# no package twice.
rows() {
	awk '
		/^[[:space:]]*(#|$)/ { next }
		NF != 5 { printf "line %d: expected 5 fields, got %d\n", NR, NF > "/dev/stderr"; bad = 1; next }
		$1 !~ /^[a-z0-9]+(-[a-z][a-z0-9]*)*$/ { printf "line %d: bad package name %s\n", NR, $1 > "/dev/stderr"; bad = 1; next }
		$5 != "yes" && $5 != "no" { printf "line %d: catalogue must be yes or no, not %s\n", NR, $5 > "/dev/stderr"; bad = 1; next }
		seen[$1]++ { printf "line %d: %s is listed twice\n", NR, $1 > "/dev/stderr"; bad = 1; next }
		{ print $1, $2, $3, $4, $5 }
		END { exit bad }
	' "$conf"
}

case ${1:-} in
row)
	[ $# -eq 2 ] || die "usage: packages.sh row <package>"
	all=$(rows) || die "$conf is malformed"
	line=$(printf '%s\n' "$all" | awk -v p="$2" '$1 == p { print $2, $3, $4, $5 }')
	[ -n "$line" ] || die "$2 is not in $conf"
	printf '%s\n' "$line"
	;;
catalogue)
	[ $# -eq 1 ] || die "usage: packages.sh catalogue"
	all=$(rows) || die "$conf is malformed"
	printf '%s\n' "$all" | awk '$5 == "yes" { print $1 }'
	;;
*)
	die "usage: packages.sh row <package> | packages.sh catalogue"
	;;
esac
