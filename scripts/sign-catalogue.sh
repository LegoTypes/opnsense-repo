#!/bin/sh
# In the FreeBSD VM, after build-package.sh: add out/'s package to the
# carried-forward ones, check the set is exactly the catalogue, sign it with
# .signing/key (removed on exit, whatever happens), verify both signatures
# against keys/legotypes-pkg-signing.pub, and only then write the rest of the
# Pages site: the bootstrap os-legotypes.pkg, the public key and packages.txt.
set -eu

R="site/FreeBSD:15:amd64/26.7/latest"
PUB=keys/legotypes-pkg-signing.pub

die() {
	echo "sign-catalogue.sh: $*" >&2
	exit 1
}

trap 'rm -f .signing/key .signing/sign.sh .signing/sig' EXIT
[ -f .signing/key ] || die "no signing key staged"
# an empty secret stages a file holding only a newline
openssl pkey -in .signing/key -noout 2>/dev/null || die "the staged signing key is not a private key"

mkdir -p "$R/All"
cp out/*.pkg "$R/All/"

# exactly one package per catalogue row, and nothing else
catalogue=$(sh scripts/packages.sh catalogue)
expected=0
for p in $catalogue; do
	set -- "$R/All/$p"-[0-9]*.pkg
	[ $# -eq 1 ] && [ -f "$1" ] || die "$p: expected one package in $R/All, found: $*"
	expected=$((expected + 1))
done
set -- "$R"/All/*
[ $# -eq "$expected" ] || die "$R/All holds $# files, the catalogue $expected: $*"

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
pkg repo "$R" signing_command: /bin/sh .signing/sign.sh
rm -f .signing/key .signing/sign.sh .signing/sig

# check what clients will check: each catalogue file's signature, over its
# sha256, verifies with the published key, and the key stored beside it is
# that key
for pair in data:data packagesite.yaml:packagesite; do
	file=${pair%%:*} archive=${pair#*:}
	v=$(mktemp -d)
	tar -xf "$R/$archive.pkg" -C "$v" "$file" "$file.sig" "$file.pub" ||
		die "$archive.pkg does not hold $file, its signature and its key"
	cmp -s "$v/$file.pub" "$PUB" || die "$archive.pkg carries a public key other than $PUB"
	openssl dgst -sha256 -r "$v/$file" | cut -d' ' -f1 | tr -d '\n' |
		openssl dgst -sha256 -verify "$PUB" -signature "$v/$file.sig" >/dev/null ||
		die "the signature of $file does not verify with $PUB"
	rm -rf "$v"
done

cp "$R"/All/os-legotypes-*.pkg site/os-legotypes.pkg
cp "$PUB" site/legotypes-pkg-signing.pub
for p in "$R"/All/*.pkg; do
	pkg info -F "$p" | head -3
	echo
done >site/packages.txt
cat site/packages.txt
ls -l "$R"
