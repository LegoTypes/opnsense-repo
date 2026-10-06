#!/usr/bin/env bash
# canary.sh <run-url>
# On the runner, after upstream.sh (upstream.env) and canary-vm.sh (canary/): for
# each catalogue package fetch its newest release beside the fresh builds, write
# its findings and keep its issue in step; then the same for the upstream series
# and FreeBSD ABI. Exits 1 if anything was material, so the run fails and GitHub
# mails the owner; 2 if it cannot run at all.
# gh takes the repository from GH_REPO and the token from GH_TOKEN.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
die() {
	echo "canary.sh: $*" >&2
	exit 2
}

[[ $# -eq 1 ]] || die "usage: canary.sh <run-url>"
run=$1
[[ -s upstream.env ]] || die "no upstream.env: run upstream.sh first"
[[ -d canary ]] || die "no canary/: run canary-vm.sh first"
material=0
releases=$(gh release list --limit 1000 --json tagName,publishedAt) || die "cannot list releases"

for p in $(sh "$here/packages.sh" catalogue); do
	d=canary/$p
	mkdir -p "$d"
	tag=$(RELEASES_JSON="$releases" bash "$here/newest-release.sh" "$p")
	if [[ -n $tag ]]; then
		gh release download "$tag" --pattern "$tag.pkg" --dir "$d" || die "cannot download $tag.pkg"
		mv "$d/$tag.pkg" "$d/published.pkg"
		gh release view "$tag" --json body --jq .body >"$d/notes" || die "cannot read the notes of $tag"
	fi
	if ! bash "$here/canary-findings.sh" "$p" "$d" >"$d/findings"; then material=1; fi
	bash "$here/canary-report.sh" "canary: $p" "$d/findings" "$run"
done

newest=$(sed -n 's/^NEWEST=//p' upstream.env)
next=$(sed -n 's/^NEXT_ABI=//p' upstream.env)
series=$(sh "$here/repo.sh" series)
{
	if [[ $newest != "$series" ]]; then
		echo "MATERIAL: OPNsense now ships series $newest; this repository builds and serves $series (README: Series change)"
	fi
	if [[ -n $next ]]; then
		echo "MATERIAL: OPNsense now publishes $next; this repository targets $(sh "$here/repo.sh" abi) (README: Series change)"
	fi
	sed 's/^/NOTE: upstream /' upstream.env
} >canary/series.findings
if grep -q '^MATERIAL: ' canary/series.findings; then material=1; fi
bash "$here/canary-report.sh" "canary: upstream series" canary/series.findings "$run"
exit "$material"
