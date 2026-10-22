#!/bin/sh
# On the runner, in the sign job, after carry-forward.sh: add out/'s package to the
# target tree, check every served tree (repo.sh serve) is exactly its catalogue (with
# one tree served, the target holds one package per catalogue row; while two are
# served, the target and a frozen tree each hold at most one, the target always the
# built package), sign each with .signing/key (removed on exit, whatever happens),
# verify both signatures of each against keys/legotypes-pkg-signing.pub, stamp each and
# check the stamp with stamp-check.sh as os-legotypes checks it, write each tree's
# packages.txt, and only then write the rest of the Pages site from
# the target tree: the public key and packages.txt. The site root serves no package:
# os-legotypes installs from the signed repository.
#
# The stamp: a pkg catalogue carries no date, so a replayed old one verifies like a new
# one. Each tree gets, beside data.pkg and packagesite.pkg, ONE file "stamp", which the
# Pages CDN caches whole (it caches each file on its own, so two files could come from
# two deploys). Its lines, each LF-terminated, printable ASCII:
#   published: <YYYY-MM-DDTHH:MM:SSZ>   one UTC time for the whole run
#   run: <GITHUB_RUN_ID>
#   tree: <ABI>/<series>
#   -----BEGIN PUBLIC KEY-----          keys/legotypes-pkg-signing.pub, byte for byte:
#   ...                                 os-legotypes checks its sha256 against its
#   -----END PUBLIC KEY-----            trusted fingerprints
#   signature: <base64>                 last, nothing after it
# The signature is the signing command's, over the sha256 hex of every byte before the
# signature line, exactly as pkg has it sign a catalogue file. stamp-check.sh beside this
# script holds the full grammar and checks each stamp the moment it is written, as
# os-legotypes will.
#
# What signs and what is checked is this script's own checkout's, found from its location and
# never from the working directory or the environment: the published key
# (keys/legotypes-pkg-signing.pub), the fingerprints os-legotypes trusts, repo.conf and
# packages.conf (through repo.sh and packages.sh beside it). The working directory holds only
# what the job made: out/, .signing/ and site/.
#
# Environment: GITHUB_RUN_ID, required (the workflow run's id, digits only); PKG, the
# pkg to run, by default pkg on PATH: the sign job passes the one scripts/pkg-tool.sh
# built (pkg repo needs no FreeBSD host). PKG is resolved to an absolute path, and then
# everything runs with PATH=/usr/bin:/bin, so no openssl, bsdtar or other tool from
# /usr/local (first on the runner's PATH) or anywhere else touches the key or checks the
# result. Runs under dash (Ubuntu's /bin/sh) and macOS's sh, with GNU or BSD tools, and
# needs /usr/bin/openssl and /usr/bin/bsdtar reading zstd, as pkg packs both archives:
# on the runner the libarchive-tools and zstd packages from Ubuntu's archive (macOS's
# bsdtar reads no zstd, so on a Mac only the tests run it).
set -eu

here=$(dirname "$0")
PUB=$here/../keys/legotypes-pkg-signing.pub
TRUSTED=$here/../vendor/legotypes/src/etc/pkg/fingerprints/LegoTypes/trusted
PKG=${PKG:-pkg}

die() {
	echo "sign-catalogue.sh: $*" >&2
	exit 1
}

# the staged key and everything derived from it, removed on exit, whatever happens: a
# signal (a cancelled job) exits through the EXIT trap, which dash skips on a signal
# that is not trapped
unstage() {
	/bin/rm -f .signing/key .signing/sign.sh .signing/sig .signing/stamp
}
trap unstage EXIT
trap 'exit 1' HUP INT TERM

# pkg is the one tool taken from PATH (or PKG=): an absolute path, an executable file
case $PKG in
*/*) ;;
*) PKG=$(command -v "$PKG") || die "no pkg on PATH" ;;
esac
case $PKG in
/*) ;;
*) PKG=$(pwd)/$PKG ;;
esac
[ -f "$PKG" ] && [ -x "$PKG" ] || die "no pkg to run: $PKG"
PATH=/usr/bin:/bin
export PATH

run=${GITHUB_RUN_ID:-}
# digits only: the stamp is read line by line, so the value must not add a line
case $run in
'' | *[!0-9]*) die "GITHUB_RUN_ID must be the workflow run's id, not \"$run\"" ;;
esac
published=$(date -u +%Y-%m-%dT%H:%M:%SZ)
target=$(sh "$here/repo.sh" target)
R=$(sh "$here/repo.sh" tree)
served=$(sh "$here/repo.sh" serve)
count=$(printf '%s\n' "$served" | wc -l)

[ -f .signing/key ] || die "no signing key staged"
# an empty secret stages a file holding only a newline
openssl pkey -in .signing/key -noout 2>/dev/null || die "the staged signing key is not a private key"
# the key stored beside each catalogue file must be the published key, and its
# sha256 a fingerprint os-legotypes trusts: a key and a fingerprint left out of
# step by a half-done rotation would deploy a catalogue every client refuses
fingerprint=$(openssl dgst -sha256 -r "$PUB" | cut -d' ' -f1)
cat "$TRUSTED"/* 2>/dev/null | grep -qx "fingerprint: \"$fingerprint\"" ||
	die "$PUB (sha256 $fingerprint) is not a fingerprint in $TRUSTED"
mkdir -p "$R/All"
cp out/*.pkg "$R/All/"
catalogue=$(sh "$here/packages.sh" catalogue)
# signing_command mode (pkg-repo(8)): pkg feeds the sha256 (hex) of each catalogue
# file, and a newline, to the command and stores the signature and the public key
# beside it, so clients check the key's sha256 against their trusted fingerprints
# (signature_type "fingerprints"). The command signs only a sha256 digest: a line of
# exactly 64 lowercase hex digits, read whole (IFS= keeps any blank around it), or it
# exits non-zero with no answer; it stops before answering if openssl produced no
# signature. pkg writes the line and then waits for the answer, so a plain read returns
# at once (POSIX sh has no read timeout; dash refuses "read -t"). The lines are the
# literal text of the signing script: $sum expands when it runs, not here. The key's path is
# quoted for it, as the script's location may hold any character.
qpub=$(printf '%s\n' "$PUB" | sed "s/'/'\\\\''/g")
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'set -e' 'IFS= read -r sum' \
	'case $sum in *[!0123456789abcdef]*) exit 1 ;; esac' '[ "${#sum}" -eq 64 ] || exit 1' \
	'printf %s "$sum" | /usr/bin/openssl dgst -sign .signing/key -sha256 -binary >.signing/sig' \
	'[ -s .signing/sig ]' 'echo SIGNATURE' 'cat .signing/sig' 'echo' \
	'echo CERT' "cat '$qpub'" 'echo END' >.signing/sign.sh

# verify <file> <signature> <key>: the signature over the file's sha256 hex verifies
# with the key, as clients check a catalogue file
verify() {
	openssl dgst -sha256 -r "$1" | cut -d' ' -f1 | tr -d '\n' |
		openssl dgst -sha256 -verify "$3" -signature "$2" >/dev/null
}

# stamp <tree dir> <ABI/series>: write the tree's stamp: its body and the published key,
# signed by the signing command as pkg has it sign a catalogue file (the signature is
# .signing/sig, the bytes the command answers between SIGNATURE and CERT), then the
# signature line; then check it as os-legotypes will (stamp-check.sh). The body is put
# together in .signing/, never under site/.
stamp() {
	{
		printf 'published: %s\nrun: %s\ntree: %s\n' "$published" "$run" "$2"
		cat "$PUB"
	} >.signing/stamp
	openssl dgst -sha256 -r .signing/stamp | cut -d' ' -f1 | /bin/sh .signing/sign.sh >/dev/null ||
		die "the signing command failed for $1/stamp"
	sig=$(openssl base64 -A <.signing/sig) || die "cannot encode the signature of $1/stamp"
	{
		cat .signing/stamp
		printf 'signature: %s\n' "$sig"
	} >"$1/stamp"
	/bin/rm -f .signing/stamp
	sh "$here/stamp-check.sh" "$1/stamp" "$PUB" "$2" >/dev/null ||
		die "$1/stamp is not a stamp that verifies with $PUB"
}

for entry in $served; do
	tree=$(sh "$here/repo.sh" tree "$entry")
	mkdir -p "$tree/All"
	# with one tree served the target holds exactly one package per catalogue row;
	# otherwise each tree holds at most one (only what was released for it); none
	# holds anything else
	expected=0
	for p in $catalogue; do
		set -- "$tree/All/$p"-[0-9]*.pkg
		if [ -f "$1" ]; then
			[ $# -eq 1 ] || die "$p: expected one package in $tree/All, found: $*"
			expected=$((expected + 1))
		elif [ "$entry" = "$target" ] && [ "$count" -eq 1 ]; then
			die "$p: expected one package in $tree/All, found none"
		fi
	done
	set -- "$tree"/All/*
	[ -f "$1" ] || set --
	[ $# -eq "$expected" ] || die "$tree/All holds $# files, the catalogue $expected: $*"
	"$PKG" repo "$tree" signing_command: /bin/sh .signing/sign.sh
	# check what clients will check: the published key beside each file, and the
	# signature over the file's sha256 verifying with it
	for pair in data:data packagesite.yaml:packagesite; do
		file=${pair%%:*} archive=${pair#*:}
		v=$(mktemp -d)
		bsdtar -xf "$tree/$archive.pkg" -C "$v" "$file" "$file.sig" "$file.pub" ||
			die "$tree/$archive.pkg does not hold $file, its signature and its key"
		cmp -s "$v/$file.pub" "$PUB" || die "$tree/$archive.pkg carries a public key other than $PUB"
		verify "$v/$file" "$v/$file.sig" "$PUB" || die "the signature of $tree/$file does not verify with $PUB"
		rm -rf "$v"
	done
	stamp "$tree" "$entry"
	for p in "$tree"/All/*.pkg; do
		"$PKG" info -F "$p" | head -3
		echo
	done >"$tree/packages.txt"
done
unstage

cp "$PUB" site/legotypes-pkg-signing.pub
cp "$R/packages.txt" site/packages.txt
cat site/packages.txt
ls -l "$R"
