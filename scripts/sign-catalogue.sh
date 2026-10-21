#!/bin/sh
# On the runner, in the sign job, after carry-forward.sh: add out/'s package to the
# target tree, check every served tree (repo.sh serve) is exactly its catalogue (with
# one tree served, the target holds one package per catalogue row; while two are
# served, the target and a frozen tree each hold at most one, the target always the
# built package), sign each with .signing/key (removed on exit, whatever happens),
# verify both signatures of each against keys/legotypes-pkg-signing.pub, stamp each,
# write each tree's packages.txt, and only then write the rest of the Pages site from
# the target tree: the public key and packages.txt. The site root serves no package:
# os-legotypes installs from the signed repository.
#
# The stamp: a pkg catalogue carries no date, so a replayed old one verifies like a new
# one. Each tree gets, beside data.pkg and packagesite.pkg, "stamp" (three lines:
# "published: <UTC ISO-8601>", one time for the whole run, "run: <GITHUB_RUN_ID>",
# "tree: <ABI>/<series>"), "stamp.sig" (the signing command's signature over the
# stamp's sha256 hex, exactly as pkg has it sign a catalogue file) and "stamp.pub" (the
# published key). os-legotypes checks sha256(stamp.pub) against its trusted
# fingerprints and then
#   openssl dgst -sha256 -r stamp | cut -d' ' -f1 | tr -d '\n' |
#     openssl dgst -sha256 -verify stamp.pub -signature stamp.sig
# which is what is checked here right after each stamp is written.
#
# Environment: GITHUB_RUN_ID, required (the workflow run's id, digits only); PKG, the
# pkg to run, by default pkg on PATH: the sign job passes the one scripts/pkg-tool.sh
# built (pkg repo needs no FreeBSD host). Runs under dash (Ubuntu's /bin/sh) and macOS's
# sh, with GNU or BSD tools, and needs openssl and bsdtar reading zstd, as pkg packs both
# archives: on the runner the libarchive-tools and zstd packages from Ubuntu's archive,
# nothing from /usr/local.
set -eu

PUB=keys/legotypes-pkg-signing.pub
TRUSTED=vendor/legotypes/src/etc/pkg/fingerprints/LegoTypes/trusted
PKG=${PKG:-pkg}

die() {
	echo "sign-catalogue.sh: $*" >&2
	exit 1
}

# the staged key and everything derived from it, removed on exit, whatever happens
unstage() {
	rm -f .signing/key .signing/sign.sh .signing/sig .signing/reply .signing/trailer
}
trap unstage EXIT

run=${GITHUB_RUN_ID:-}
# digits only: the stamp is read line by line, so the value must not add a line
case $run in
'' | *[!0-9]*) die "GITHUB_RUN_ID must be the workflow run's id, not \"$run\"" ;;
esac
published=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# a path must be an executable file (dash's command -v accepts any existing one)
case $PKG in
*/*) [ -f "$PKG" ] && [ -x "$PKG" ] ;;
*) command -v "$PKG" >/dev/null ;;
esac || die "no pkg to run: $PKG"
target=$(sh scripts/repo.sh target)
R=$(sh scripts/repo.sh tree)
served=$(sh scripts/repo.sh serve)
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
catalogue=$(sh scripts/packages.sh catalogue)
# signing_command mode (pkg-repo(8)): pkg feeds the sha256 (hex) of each catalogue
# file, and a newline, to the command and stores the signature and the public key
# beside it, so clients check the key's sha256 against their trusted fingerprints
# (signature_type "fingerprints"). The command stops before answering if openssl
# produced no signature. pkg writes the line and then waits for the answer, so a
# plain read returns at once (POSIX sh has no read timeout; dash refuses "read -t").
# The lines are the literal text of the signing script: $sum expands when it runs.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'set -e' 'read -r sum' '[ -n "$sum" ]' \
	'printf %s "$sum" | /usr/bin/openssl dgst -sign .signing/key -sha256 -binary >.signing/sig' \
	'[ -s .signing/sig ]' 'echo SIGNATURE' 'cat .signing/sig' 'echo' \
	'echo CERT' "cat $PUB" 'echo END' >.signing/sign.sh

# verify <file> <signature> <key>: the signature over the file's sha256 hex verifies
# with the key, as clients check a catalogue file and the stamp
verify() {
	openssl dgst -sha256 -r "$1" | cut -d' ' -f1 | tr -d '\n' |
		openssl dgst -sha256 -verify "$3" -signature "$2" >/dev/null
}

# stamp <tree dir> <ABI/series>: write the tree's stamp, have the signing command sign
# it as pkg has it sign a catalogue file, and check it as os-legotypes will
stamp() {
	printf 'published: %s\nrun: %s\ntree: %s\n' "$published" "$run" "$2" >"$1/stamp"
	openssl dgst -sha256 -r "$1/stamp" | cut -d' ' -f1 | /bin/sh .signing/sign.sh >.signing/reply ||
		die "the signing command failed for $1/stamp"
	# the answer is "SIGNATURE\n", the signature, then "\nCERT\n<key>END\n", which
	# must hold exactly the published key
	{
		printf '\nCERT\n'
		cat "$PUB"
		printf 'END\n'
	} >.signing/trailer
	size=$(wc -c <.signing/reply | tr -d ' ')
	trailer=$(wc -c <.signing/trailer | tr -d ' ')
	siglen=$((size - 10 - trailer))
	{ [ "$siglen" -gt 0 ] && [ "$(head -c 10 .signing/reply)" = SIGNATURE ] &&
		tail -c "$trailer" .signing/reply | cmp -s - .signing/trailer; } ||
		die "the signing command's answer for $1/stamp is not SIGNATURE, a signature, CERT, $PUB, END"
	tail -c +11 .signing/reply | head -c "$siglen" >"$1/stamp.sig"
	cp "$PUB" "$1/stamp.pub"
	verify "$1/stamp" "$1/stamp.sig" "$1/stamp.pub" ||
		die "the signature of $1/stamp does not verify with $PUB"
}

for entry in $served; do
	tree=$(sh scripts/repo.sh tree "$entry")
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
