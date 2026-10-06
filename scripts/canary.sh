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
catalogue=$(sh "$here/packages.sh" catalogue) || die "cannot read the catalogue"
facts=$(sed 's/^/NOTE: upstream /' upstream.env)

for p in $catalogue; do
	d=canary/$p
	mkdir -p "$d"
	tag=$(RELEASES_JSON="$releases" bash "$here/newest-release.sh" "$p") || die "cannot find the newest release of $p"
	fetched=yes
	if [[ -n $tag ]]; then
		if gh release download "$tag" --pattern "$tag.pkg" --dir "$d" && mv "$d/$tag.pkg" "$d/published.pkg" &&
			gh release view "$tag" --json body --jq .body >"$d/notes"; then :; else fetched=no; fi
	fi
	if [[ $fetched == no ]]; then
		# this week's comparison is impossible; say so in the issue instead of stopping every report
		echo "MATERIAL: could not fetch $tag (its asset or notes); nothing was compared" >"$d/findings"
		material=1
	else
		rc=0
		bash "$here/canary-findings.sh" "$p" "$d" >"$d/findings" || rc=$?
		if ((rc == 1)); then material=1; fi
		if ((rc > 1)); then
			# never let a crashed comparison close an open issue as clean
			echo "MATERIAL: the canary could not compute the findings (exit $rc)" >>"$d/findings"
			material=1
		fi
	fi
	printf '%s\n' "$facts" >>"$d/findings"
	bash "$here/canary-report.sh" "canary: $p" "$d/findings" "$run" || die "cannot report canary: $p"
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
	printf '%s\n' "$facts"
} >canary/series.findings
if grep -q '^MATERIAL: ' canary/series.findings; then material=1; fi
bash "$here/canary-report.sh" "canary: upstream series" canary/series.findings "$run" || die "cannot report the upstream series"
exit "$material"
