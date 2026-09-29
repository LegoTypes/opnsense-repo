#!/bin/sh
# In the FreeBSD VM, after build-package.sh: add out/'s package to the
# carried-forward ones, check the set is exactly the catalogue, sign it with
# .signing/key (removed on exit, whatever happens), and write the rest of the
# Pages site: the bootstrap os-legotypes.pkg, the public key and packages.txt.
set -eu

R="site/FreeBSD:15:amd64/26.7/latest"

die() {
	echo "sign-catalogue.sh: $*" >&2
	exit 1
}

trap 'rm -f .signing/key .signing/sign.sh' EXIT
[ -f .signing/key ] || die "no signing key staged"

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

# signing_command mode (pkg-repo(8)): the repository carries the signature and
# the public key, so clients check the key's sha256 against their trusted
# fingerprints (signature_type "fingerprints"). The lines are the literal text
# of the signing script: $sum expands when pkg runs it, not here.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'read -t 2 sum' '[ -n "$sum" ] || exit 1' 'echo SIGNATURE' \
	'printf %s "$sum" | /usr/bin/openssl dgst -sign .signing/key -sha256 -binary' 'echo' \
	'echo CERT' 'cat keys/legotypes-pkg-signing.pub' 'echo END' >.signing/sign.sh
pkg repo "$R" signing_command: /bin/sh .signing/sign.sh
rm -f .signing/key .signing/sign.sh

cp "$R"/All/os-legotypes-*.pkg site/os-legotypes.pkg
cp keys/legotypes-pkg-signing.pub site/legotypes-pkg-signing.pub
for p in "$R"/All/*.pkg; do
	pkg info -F "$p" | head -3
	echo
done >site/packages.txt
cat site/packages.txt
ls -l "$R"
