#!/bin/sh
# Build one packages.conf package in the FreeBSD VM. Leaves exactly one
# out/<name>-<version>.pkg and out/source, one line saying where it came from.
#   build-package.sh <package>
# For the "." row (this repository), GITHUB_REPOSITORY and GITHUB_SHA name the
# commit being built.
set -eu

die() {
	echo "build-package.sh: $*" >&2
	exit 1
}

[ $# -eq 1 ] || die "usage: build-package.sh <package>"
package=$1
row=$(sh scripts/packages.sh row "$package")
read -r repo branch dir _catalogue <<ROW
$row
ROW

# outside the workspace, so the plugins tree is not copied back to the runner
work=$(mktemp -d /tmp/legotypes-build.XXXXXX)
trap 'rm -rf "$work"' EXIT
rm -rf out
mkdir out

if [ "$repo" = . ]; then
	[ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_SHA:-}" ] ||
		die "GITHUB_REPOSITORY and GITHUB_SHA must name the commit of $package"
	# the vendor package builds against the plugins tree's Mk/
	git clone --quiet --depth 1 --branch master https://github.com/LegoTypes/plugins.git "$work/tree"
	mkdir -p "$work/tree/$(dirname "$dir")"
	cp -R "$dir" "$work/tree/$dir"
	source="Built from $GITHUB_REPOSITORY, $dir, commit $GITHUB_SHA, in LegoTypes/plugins master $(git -C "$work/tree" rev-parse HEAD)."
else
	git clone --quiet --depth 1 --branch "$branch" "https://github.com/$repo.git" "$work/tree"
	source="Built from $repo, branch $branch, commit $(git -C "$work/tree" rev-parse HEAD)."
fi

make -C "$work/tree/$dir" package PLUGIN_DEVEL= PLUGIN_PHP=85 PLUGIN_PYTHON=313

set -- "$work/tree/$dir"/work/pkg/*.pkg
[ $# -eq 1 ] && [ -f "$1" ] || die "expected one package, found: $*"
name=$(basename "$1" .pkg)
case $name in
"$package"-[0-9]*) ;;
*) die "built $name, expected $package-<version>" ;;
esac
cp "$1" out/
printf '%s\n' "$source" >out/source
echo "built $name. $source"
