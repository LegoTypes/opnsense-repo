#!/bin/sh
# In the FreeBSD VM, after build-package.sh and carry-forward.sh: add out/'s
# package to the target series' tree, check every served tree (repo.sh serve) is
# exactly its catalogue (the target tree one package per catalogue row, a frozen
# tree at most one), sign each with .signing/key (removed on exit, whatever
# happens), verify both signatures of each against keys/legotypes-pkg-signing.pub,
# write each tree's packages.txt, and only then write the rest of the Pages site
# from the target tree: the bootstrap os-legotypes.pkg, the public key and
# packages.txt.
set -eu

PUB=keys/legotypes-pkg-signing.pub
TRUSTED=vendor/legotypes/src/etc/pkg/fingerprints/LegoTypes/trusted
target=$(sh scripts/repo.sh series)
R=$(sh scripts/repo.sh tree)

die() {
	echo "sign-catalogue.sh: $*" >&2
	exit 1
}

trap 'rm -f .signing/key .signing/sign.sh .signing/sig' EXIT
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
# signing_command mode (pkg-repo(8)): pkg feeds the sha256 (hex) of each
# catalogue file to the command and stores the signature and the public key
# beside it, so clients check the key's sha256 against their trusted
# fingerprints (signature_type "fingerprints"). The command stops before
# answering if openssl produced no signature. The lines are the literal text
# of the signing script: $sum expands when pkg runs it, not here.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'set -e' 'read -t 2 sum' '[ -n "$sum" ]' \
	'printf %s "$sum" | /usr/bin/openssl dgst -sign .signing/key -sha256 -binary >.signing/sig' \
	'[ -s .signing/sig ]' 'echo SIGNATURE' 'cat .signing/sig' 'echo' \
	'echo CERT' "cat $PUB" 'echo END' >.signing/sign.sh

for series in $(sh scripts/repo.sh serve); do
	tree=$(sh scripts/repo.sh tree "$series")
	mkdir -p "$tree/All"
	# the target tree holds exactly one package per catalogue row; a frozen tree at
	# most one (only what was released for it); neither holds anything else
	expected=0
	for p in $catalogue; do
		set -- "$tree/All/$p"-[0-9]*.pkg
		if [ -f "$1" ]; then
			[ $# -eq 1 ] || die "$p: expected one package in $tree/All, found: $*"
			expected=$((expected + 1))
		elif [ "$series" = "$target" ]; then
			die "$p: expected one package in $tree/All, found none"
		fi
	done
	set -- "$tree"/All/*
	[ -f "$1" ] || set --
	[ $# -eq "$expected" ] || die "$tree/All holds $# files, the catalogue $expected: $*"
	pkg repo "$tree" signing_command: /bin/sh .signing/sign.sh
	# check what clients will check: the published key beside each file, and the
	# signature over the file's sha256 verifying with it
	for pair in data:data packagesite.yaml:packagesite; do
		file=${pair%%:*} archive=${pair#*:}
		v=$(mktemp -d)
		tar -xf "$tree/$archive.pkg" -C "$v" "$file" "$file.sig" "$file.pub" ||
			die "$tree/$archive.pkg does not hold $file, its signature and its key"
		cmp -s "$v/$file.pub" "$PUB" || die "$tree/$archive.pkg carries a public key other than $PUB"
		openssl dgst -sha256 -r "$v/$file" | cut -d' ' -f1 | tr -d '\n' |
			openssl dgst -sha256 -verify "$PUB" -signature "$v/$file.sig" >/dev/null ||
			die "the signature of $tree/$file does not verify with $PUB"
		rm -rf "$v"
	done
	for p in "$tree"/All/*.pkg; do
		pkg info -F "$p" | head -3
		echo
	done >"$tree/packages.txt"
done
rm -f .signing/key .signing/sign.sh .signing/sig

cp "$R"/All/os-legotypes-*.pkg site/os-legotypes.pkg
cp "$PUB" site/legotypes-pkg-signing.pub
cp "$R/packages.txt" site/packages.txt
cat site/packages.txt
ls -l "$R"
