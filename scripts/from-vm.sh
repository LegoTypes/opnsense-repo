#!/usr/bin/env bash
# from-vm.sh <package> <copy>
# In the build job, from a fresh checkout of the run's commit, once the workspace the build
# VM synced back has been moved to <copy>: fail unless the VM changed nothing in it but out/
# and upstream.env (every tracked file as committed, mode included, and nothing added,
# ignored files included), and out/ is a build (out-dir.sh) without a manifest, which only
# manifest.sh writes; then move <copy>/out here. The copy is compared with this checkout's
# git, through an index of its own read from HEAD, never with the copy's .git, which the VM
# could have rewritten (a moved ref or index hides a change; a configuration can name a
# command for git to run); nothing in the copy is run. The VM's output reaches the later
# steps, which run this checkout's scripts, only as out/.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

die() {
	echo "from-vm.sh: $*" >&2
	exit 1
}

[[ $# -eq 2 ]] || die "usage: from-vm.sh <package> <copy>"
pkg=$1 copy=$2
[[ -d $copy/out && ! -L $copy/out ]] || die "the VM left no out/"
[[ ! -e out ]] || die "out/ exists in this checkout already"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
index=$tmp/index
git=(git --git-dir="$PWD/.git" --work-tree="$copy")
GIT_INDEX_FILE=$index "${git[@]}" read-tree HEAD
# porcelain quotes any unusual name, so each change is one line of plain text
changes=$(GIT_INDEX_FILE=$index "${git[@]}" status --porcelain=v1 --untracked-files=all --ignored=matching) ||
	die "cannot compare the VM's workspace with this checkout"
bad=$(grep -Ev '^\?\? (out/[^/"]+|upstream\.env)$' <<<"$changes" || true)
[[ -z $bad ]] || die "the VM changed the workspace outside out/: $(tr '\n' ';' <<<"$bad")"

bash "$here/out-dir.sh" "$pkg" "$copy/out" >/dev/null
[[ ! -e $copy/out/manifest ]] || die "the VM wrote out/manifest"
mv "$copy/out" out
echo "from-vm.sh: the workspace is as committed; out/ holds $(cd out && echo *)"
