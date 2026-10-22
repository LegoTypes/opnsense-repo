#!/bin/sh
# Copyright (C) 2026 cayossarian
# stamp-check.sh <stamp> <key> <ABI/series>
# Check a catalogue stamp as os-legotypes checks it, against the published key <key>
# (keys/legotypes-pkg-signing.pub) and the tree it was served for; on success print
# "published <time>". sign-catalogue.sh runs it on each stamp it writes, and
# verify-catalogue.sh on each one the live site serves. os-legotypes' lib.php reads the
# same format (legotypes_stamp_findings).
#
# The stamp: ONE file, <tree>/stamp, beside data.pkg and packagesite.pkg, so a CDN that
# caches each file on its own can never serve parts of two deploys. At most 65536 bytes of
# printable ASCII and LF (no CR, tab or byte beyond ASCII), every line LF-terminated, and
# exactly these lines in this order:
#   published: <YYYY-MM-DDTHH:MM:SSZ>   the publication time, UTC: a real date (the
#                                       Gregorian calendar, leap years included) and
#                                       time of day (00-23, 00-59, 00-59)
#   run: <digits>                       the workflow run that signed it
#   tree: <printable, no space>         <ABI>/<series>, the tree it stamps
#   -----BEGIN PUBLIC KEY-----          the published key, byte for byte as
#   <1 to 64 base64 characters>         keys/legotypes-pkg-signing.pub (one key block,
#   ...                                 at least one line inside it): its sha256 is the
#   -----END PUBLIC KEY-----            fingerprint os-legotypes trusts
#   signature: <base64, one line>       the last line; nothing follows it
# The signature is the signing command's (RSA, sha256) over the sha256 hex of every byte
# before the signature line, exactly as pkg has it sign a catalogue file:
#   <the lines before the signature line> | openssl dgst -sha256 -r | cut -d' ' -f1 |
#     tr -d '\n' | openssl dgst -sha256 -verify <key> -signature <the decoded signature>
# A field missing, repeated or out of order, a date or time that does not exist, a second
# key block, anything after the signature line, a CR or a byte beyond ASCII, or a size over
# the cap: not a stamp. lib.php's grammar and date check are the same, tested on one list
# of dates (vendor/legotypes/tests/stamp-dates.txt).
# Runs under dash and macOS's sh, with what /usr/bin and /bin hold (sign-catalogue.sh runs
# it so): awk, grep, head, sed, tail, od, wc, cmp, mktemp, openssl.
set -eu

die() {
	echo "stamp-check.sh: $*" >&2
	exit 1
}

[ $# -eq 3 ] || die "usage: stamp-check.sh <stamp> <key> <ABI/series>"
stamp=$1 key=$2 tree=$3
[ -f "$stamp" ] || die "$stamp: no such file"
size=$(wc -c <"$stamp")
[ "$size" -le 65536 ] || die "$stamp is not a stamp: over 65536 bytes"
if LC_ALL=C grep -q '[^ -~]' "$stamp"; then
	die "$stamp is not a stamp: a byte other than printable ASCII and LF"
fi
[ "$(tail -c 1 "$stamp" | od -An -tx1 | tr -d ' \n')" = 0a ] || die "$stamp is not a stamp: its last line has no LF"
# the lines, in order; prints the number of the signature line
n=$(LC_ALL=C awk '
	function bad() { failed = 1; exit 1 }
	NR == 1 {
		if ($0 !~ "^published: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$") bad()
		# a real UTC time, as the round trip in lib.php (DateTimeImmutable) demands: the
		# month 01-12, the day within the month (February 29 in a Gregorian leap year),
		# 00-23 hours, 00-59 minutes and seconds
		y = substr($0, 12, 4) + 0; m = substr($0, 17, 2) + 0; d = substr($0, 20, 2) + 0
		mdays = substr("312831303130313130313031", 2 * m - 1, 2) + 0
		if (m == 2 && y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) mdays = 29
		if (m < 1 || m > 12 || d < 1 || d > mdays) bad()
		if (substr($0, 23, 2) + 0 > 23 || substr($0, 26, 2) + 0 > 59 || substr($0, 29, 2) + 0 > 59) bad()
		next
	}
	NR == 2 { if ($0 !~ "^run: [0-9]+$") bad(); next }
	NR == 3 { if ($0 !~ "^tree: [!-~]+$") bad(); next }
	NR == 4 { if ($0 != "-----BEGIN PUBLIC KEY-----") bad(); next }
	state == 0 {
		if ($0 == "-----END PUBLIC KEY-----") {
			if (NR == 5) bad()
			state = 1
		} else if ($0 !~ "^[A-Za-z0-9+/=]+$" || length($0) > 64) bad()
		next
	}
	state == 1 {
		if ($0 !~ "^signature: [A-Za-z0-9+/]+=?=?$") bad()
		state = 2
		sig = NR
		next
	}
	{ bad() }
	END { if (failed || state != 2) exit 1; print sig }
' "$stamp") || die "$stamp is not a stamp: not its lines in their order"
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT
head -n "$((n - 1))" "$stamp" >"$w/signed"
sed -n "4,$((n - 1))p" "$stamp" | cmp -s - "$key" || die "$stamp carries a key other than $key"
sed -n "${n}s/^signature: //p" "$stamp" | openssl base64 -d -A >"$w/sig" || die "$stamp: cannot decode its signature"
openssl dgst -sha256 -r "$w/signed" | cut -d' ' -f1 | tr -d '\n' |
	openssl dgst -sha256 -verify "$key" -signature "$w/sig" >/dev/null 2>&1 ||
	die "$stamp: its signature does not verify with $key"
got=$(sed -n '3s/^tree: //p' "$stamp")
[ "$got" = "$tree" ] || die "$stamp names the tree $got, not $tree"
sed -n '1s/^published: /published /p' "$stamp"
