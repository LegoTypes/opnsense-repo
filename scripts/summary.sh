#!/usr/bin/env bash
# summary.sh <package> <out dir> <review dir>
# Markdown for the review job's summary ($GITHUB_STEP_SUMMARY), what the owner reads before
# approving the sign job: first a fixed line saying this summary, under the review job, is the
# only one to read, and that the build job writes none (text under the build job's summary means
# its runner was tampered with); then the approved commit; the built file (<out dir>, the build job's
# artifact), its sha256 and the source line its release notes will start with; the manifest,
# whose carry lines the sign job must find unchanged; the payload check (payload.sh:
# informational here, the sign job enforces it), with the install scripts as pkg will run
# them; compare-package.sh between the package's newest release and this build, as the
# canary reports it, or that there is no release yet; the version file the package installs;
# the build lines of the release notes. The source line, the build lines and the manifest are
# <review dir>'s, which the review job wrote (provenance.sh, manifest.sh), never the VM's.
# Everything the build made (the package, the manifest that names the built file, the
# FreeBSD version the VM reported) and the release's tag are printed inside fenced code
# blocks, each fence longer than any run of backticks inside it, so none of it is read as
# markdown; outside them are only this script's own words, the package name (packages.conf)
# and the commit (checked). Nothing from the build goes to stderr, which is the job's log.
# Environment: COMMIT, the approved commit (40 lower-case hex digits); PLUGIN_DIR, the
# plugin's directory at it (plugin-source.sh); GH_REPO and GH_TOKEN for gh, which only reads.
# Exits 0 once the summary is complete, whatever the payload check found; 1 when any part of
# it cannot be made, so no approval is asked for without it (nothing is printed then).
# Needs jq and bsdtar (libarchive-tools) with zstd, as compare-package.sh and payload.sh do.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

die() {
	echo "summary.sh: $*" >&2
	exit 1
}

# fence <text>: <text> in a fenced code block, its fence longer than any run of backticks in
# <text>, so no line of it can close the block
fence() {
	local longest f='```'
	longest=$(awk '{ s = $0; while (match(s, /`+/)) { if (RLENGTH > m) m = RLENGTH; s = substr(s, RSTART + RLENGTH) } }
		END { print m + 0 }' <<<"$1")
	while ((${#f} <= longest)); do f+='`'; done
	printf '%s\n%s\n%s\n\n' "$f" "$1" "$f"
}

[[ $# -eq 3 ]] || die "usage: summary.sh <package> <out dir> <review dir>"
pkg=$1 out=$2 rev=$3
[[ ${COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || die "COMMIT must be the approved commit, 40 lower-case hex digits"
[[ -n ${PLUGIN_DIR:-} ]] || die "PLUGIN_DIR must name the plugin's directory at the commit (plugin-source.sh)"
sh "$here/packages.sh" row "$pkg" >/dev/null
file=$(bash "$here/out-dir.sh" "$pkg" "$out")
for f in source build manifest; do
	[[ -f $rev/$f && ! -L $rev/$f ]] || die "$rev holds no $f: run provenance.sh and manifest.sh first"
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# gathered first, so a part that cannot be made leaves no summary at all
payload_rc=0
payload=$(bash "$here/payload.sh" "$pkg" "$out" "$PLUGIN_DIR" 2>&1) || payload_rc=$?
tag=$(bash "$here/newest-release.sh" "$pkg" 2>/dev/null) || die "cannot find the newest release of $pkg"
compare_rc=0 differences=''
if [[ -n $tag ]]; then
	gh release download "$tag" --pattern "$tag.pkg" --dir "$work" </dev/null >/dev/null 2>&1 ||
		die "cannot download the package of the newest release of $pkg"
	differences=$(bash "$here/compare-package.sh" "$work/$tag.pkg" "$file" 2>&1) || compare_rc=$?
	((compare_rc < 2)) || die "cannot compare the build with the newest release of $pkg"
fi
members=$(bsdtar -tf "$file" 2>/dev/null) || die "cannot list the files of the build"
versions=''
while IFS= read -r m; do
	[[ $m =~ ^/?usr/local/opnsense/version/[^/]+$ ]] || continue
	text=$(bsdtar -xOPf "$file" "$m" 2>/dev/null) || text='(cannot be read)'
	versions+="$m"$'\n'"$text"$'\n'
done <<<"$members"

printf '%s\n\n' "**Read this summary, under the review job, and no other. The build job writes none: any summary under the build job means its runner was tampered with, so reject the run (cancel it; do not approve).**"
# shellcheck disable=SC2016 # the backticks are markdown, a code span
printf '## %s at `%s`\n\n' "$pkg" "$COMMIT"
printf 'Approve the sign job only for this build. What the build made is shown as it is, in code blocks.\n\n'
printf '### Built package\n\n'
fence "${file##*/}
sha256 $(sha256sum "$file" | cut -d' ' -f1)"
printf 'Its release notes will start with:\n\n'
fence "$(cat "$rev/source")"
printf '### Manifest\n\n'
printf 'The releases the sign job carries forward (each checked against the sha256 its notes record, and refused if any has changed since), the built package and the commit:\n\n'
fence "$(cat "$rev/manifest")"
if ((payload_rc == 0)); then
	printf '### Payload check: passed\n\n'
	printf 'The package holds exactly what the plugin source at the commit installs. The install scripts, as pkg will run them:\n\n'
else
	printf '### Payload check: FAILED\n\n'
	printf 'The sign job runs this check again and will refuse to sign this build.\n\n'
fi
fence "$payload"
printf '### Compared with the newest release\n\n'
if [[ -z $tag ]]; then
	printf 'No earlier release of %s: nothing to compare.\n\n' "$pkg"
elif ((compare_rc == 0)); then
	printf 'No material differences from the newest release:\n\n'
	fence "newest release: $tag"
else
	printf 'Material differences from the newest release:\n\n'
	fence "newest release: $tag
$differences"
fi
printf '### Version file\n\n'
if [[ -z $versions ]]; then
	printf 'The package installs no version file.\n\n'
else
	fence "${versions%$'\n'}"
fi
printf '### Build environment\n\n'
printf 'The build lines of the release notes:\n\n'
fence "$(cat "$rev/build")"
