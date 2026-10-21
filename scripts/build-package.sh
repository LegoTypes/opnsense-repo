#!/bin/sh
# Build one packages.conf package in the FreeBSD VM. Leaves exactly one
# out/<name>-<version>.pkg and out/source, one line saying where it came from.
#   build-package.sh <package> [<commit>]
# With a commit (the full 40 hex digits the owner approved), exactly that commit is
# built: it must be what the workflow was dispatched at (the "." row, GITHUB_SHA) or a
# commit on the branch (a plugin row). Without one (the canary) the branch head is built.
# For the "." row (this repository), its source line names the last commit that
# changed the package's directory (so a later commit elsewhere in this repository
# is not an unreleased change of the package; needs the full history), and the
# workflow run's commit beside it. GITHUB_REPOSITORY and GITHUB_SHA name the
# commit being built.
set -eu

die() {
	echo "build-package.sh: $*" >&2
	exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: build-package.sh <package> [<commit>]"
package=$1
commit=${2:-}
if [ $# -eq 2 ]; then
	case $commit in
	*[!0123456789abcdef]* | '') die "the commit must be 40 lower-case hex digits, not $commit" ;;
	esac
	[ ${#commit} -eq 40 ] || die "the commit must be 40 lower-case hex digits, not $commit"
fi
row=$(sh scripts/packages.sh row "$package")
read -r repo branch dir _catalogue <<ROW
$row
ROW
series=$(sh scripts/repo.sh series)
[ -n "${UPSTREAM_PHP:-}" ] && [ -n "${UPSTREAM_PYTHON:-}" ] ||
	die "UPSTREAM_PHP and UPSTREAM_PYTHON must be set (bash scripts/upstream.sh)"
case ${MK_FROM:-} in
'' | upstream) ;;
*) die "MK_FROM must be empty or upstream, not $MK_FROM" ;;
esac

# make's PLUGIN_HASH for the "." row; a plugin row's gitversion prints its own checked-out commit
hash=''
# outside the workspace, so the plugins tree is not copied back to the runner
work=$(mktemp -d /tmp/legotypes-build.XXXXXX)
trap 'rm -rf "$work"' EXIT
rm -rf out
mkdir out

if [ "$repo" = . ]; then
	[ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_SHA:-}" ] ||
		die "GITHUB_REPOSITORY and GITHUB_SHA must name the commit of $package"
	[ -z "$commit" ] || [ "$commit" = "$GITHUB_SHA" ] ||
		die "the commit $commit is not the workflow run's commit $GITHUB_SHA"
	# gitversion would print the plugins tree's commit, so name this one the way it does (nine digits)
	[ -z "$commit" ] || hash=PLUGIN_HASH=$(printf '%.9s' "$commit")
	# the vendor package builds against the plugins tree's Mk/
	git clone --quiet --depth 1 --branch master https://github.com/LegoTypes/plugins.git "$work/tree"
	mkdir -p "$work/tree/$(dirname "$dir")"
	cp -R "$dir" "$work/tree/$dir"
	# the workspace synced into the VM keeps the runner's owner, so git needs it named safe
	changed=$(git -c safe.directory="$PWD" log -1 --format=%H -- "$dir")
	[ -n "$changed" ] || die "cannot find the last commit that changed $dir (a shallow checkout? check out with fetch-depth: 0)"
	source="Built from $GITHUB_REPOSITORY, $dir, commit $changed (workflow run at $GITHUB_SHA), in LegoTypes/plugins master $(git -C "$work/tree" rev-parse HEAD)."
else
	git clone --quiet --depth 1 --branch "$branch" "https://github.com/$repo.git" "$work/tree"
	if [ -n "$commit" ]; then
		git -C "$work/tree" fetch --quiet --depth 1 origin "$commit"
		git -C "$work/tree" checkout --quiet "$commit"
		[ "$(git -C "$work/tree" rev-parse HEAD)" = "$commit" ] || die "checked out $(git -C "$work/tree" rev-parse HEAD), not $commit"
		# on the branch: the whole branch history, then the commit must be an ancestor of its tip
		git -C "$work/tree" fetch --quiet --unshallow origin "+refs/heads/$branch:refs/remotes/origin/$branch"
		git -C "$work/tree" merge-base --is-ancestor "$commit" "refs/remotes/origin/$branch" ||
			die "the commit $commit is not on branch $branch of $repo"
	fi
	source="Built from $repo, branch $branch, commit $(git -C "$work/tree" rev-parse HEAD)."
fi

# the canary's rebased build: the packaging rules a rebase on upstream would bring
if [ "${MK_FROM:-}" = upstream ]; then
	git clone --quiet --depth 1 --branch master https://github.com/opnsense/plugins.git "$work/upstream"
	rm -rf "$work/tree/Mk"
	cp -R "$work/upstream/Mk" "$work/tree/Mk"
	source="$source Mk/ from opnsense/plugins master $(git -C "$work/upstream" rev-parse HEAD)."
fi

# $hash is unquoted so that it vanishes when empty
make -C "$work/tree/$dir" package PLUGIN_DEVEL= PLUGIN_ABI="$series" \
	PLUGIN_PHP="$UPSTREAM_PHP" PLUGIN_PYTHON="$UPSTREAM_PYTHON" $hash

set -- "$work/tree/$dir"/work/pkg/*.pkg
[ $# -eq 1 ] && [ -f "$1" ] || die "expected one package, found: $*"
name=$(basename "$1" .pkg)
case $name in
"$package"-[0-9]*) ;;
*) die "built $name, expected $package-<version>" ;;
esac
cp "$1" out/
printf '%s\n' "$source" >out/source
printf 'abi: %s\nseries: %s\nfreebsd: %s\nphp: %s\npython: %s\n' "$(sh scripts/repo.sh abi)" "$series" "$(freebsd-version -u)" \
	"$UPSTREAM_PHP" "$UPSTREAM_PYTHON" >out/build
echo "built $name. $source"
