#!/usr/bin/env bash
# Unit tests for scripts/: bash tests/run.sh (from the repository root or anywhere).
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
pass=0 failed=0
ok() { pass=$((pass + 1)); }
bad() {
	failed=$((failed + 1))
	echo "FAIL: $*"
}
expect_eq() { if [[ $2 == "$3" ]]; then ok; else bad "$1: expected [$3], got [$2]"; fi; }
expect_fail() {
	local name=$1
	shift
	if "$@" >/dev/null 2>&1; then bad "$name: expected failure"; else ok; fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# anchor <file> <name> <line>: "<n> <m>", <n> the assignments to <name> in <file> (any
# indentation, any condition), <m> how many lines are exactly <line>: "1 1" when the one
# assignment is that literal line, with no override
anchor() { echo "$(grep -oE "(^|[^A-Za-z0-9_])$2=" "$1" | wc -l | tr -d ' ') $(grep -cxF -- "$3" "$1")"; }
# The harness runs a copy of scripts/ whose repo.sh and packages.sh read $T/repo.conf and
# $T/packages.conf (the one line that names each file substituted): both files are trust
# anchors (repo.conf pins pkg's source, packages.conf names the repositories a build is
# checked against), so the production scripts honour no environment override of either.
S="$T/scripts"
cp -R "$root/scripts" "$S"
sed "s|^conf=.*|conf=$T/repo.conf|" "$root/scripts/repo.sh" >"$S/repo.sh"
sed "s|^conf=.*|conf=$T/packages.conf|" "$root/scripts/packages.sh" >"$S/packages.sh"
expect_eq "the harness copies read the test configuration" \
	"$(grep -cxF "conf=$T/repo.conf" "$S/repo.sh") $(grep -cxF "conf=$T/packages.conf" "$S/packages.sh")" "1 1"
repo_line='conf=$(dirname "$0")/../repo.conf'
packages_line='conf=$(dirname "$0")/../packages.conf'
expect_eq "repo.sh: repo.conf is found from the script's own location, one literal line, no override" \
	"$(anchor "$root/scripts/repo.sh" conf "$repo_line")" "1 1"
expect_eq "packages.sh: packages.conf is found from the script's own location, one literal line, no override" \
	"$(anchor "$root/scripts/packages.sh" conf "$packages_line")" "1 1"
{ cat "$root/scripts/repo.sh"; echo '[ -z "${X:-}" ] || conf=$X'; } >"$T/mutant.sh"
expect_eq "anchor: the static check rejects an override" "$(anchor "$T/mutant.sh" conf "$repo_line")" "2 1"
sed 's|^conf=.*|conf=${REPO_CONF:-$(dirname "$0")/../repo.conf}|' "$root/scripts/repo.sh" >"$T/mutant.sh"
expect_eq "anchor: the static check rejects a default that an environment variable replaces" \
	"$(anchor "$T/mutant.sh" conf "$repo_line")" "1 0"
printf 'ABI=FreeBSD:9:amd64\nSERIES=1.1\nSERVE=FreeBSD:9:amd64/1.1\n' >"$T/decoy.conf"
printf 'os-decoy Org/decoy br net/decoy yes\n' >"$T/decoy-packages.conf"
expect_eq "repo.sh: REPO_CONF changes nothing" "$(REPO_CONF="$T/decoy.conf" sh "$root/scripts/repo.sh" target)" \
	"$(sh "$root/scripts/repo.sh" target)"
expect_eq "packages.sh: PACKAGES_CONF changes nothing" \
	"$(PACKAGES_CONF="$T/decoy-packages.conf" sh "$root/scripts/packages.sh" catalogue | tr '\n' ' ')" \
	"$(sh "$root/scripts/packages.sh" catalogue | tr '\n' ' ')"

# outside: on stdin markdown, out the lines a CommonMark renderer reads as markdown, outside every
# fenced code block (an opening fence: up to three spaces, three or more backticks or tildes; the
# closing one: as many or more of the same, nothing after but blanks); UNCLOSED if one never closes
outside() {
	awk '
		f == "" && match($0, /^ ? ? ?(```+|~~~+)/) {
			f = substr($0, RSTART, RLENGTH)
			sub(/^ +/, "", f)
			c = substr(f, 1, 1)
			close_re = "^ ? ? ?"
			for (i = 0; i < length(f); i++) close_re = close_re c
			close_re = close_re c "*[ \t]*$"
			next
		}
		f != "" { if ($0 ~ close_re) f = ""; next }
		{ print }
		END { if (f != "") print "UNCLOSED" }
	'
}

conf() { printf '%s\n' "$@" >"$T/packages.conf"; }
pk() { sh "$S/packages.sh" "$@"; }

# --- packages.sh -------------------------------------------------------------
conf '# comment' '' \
	'os-alpha  Org/plugins  br-alpha  net/alpha  yes' \
	'os-beta   Org/plugins  br-beta   net/beta   no' \
	'os-vendor .            main      vendor/v   yes'
expect_eq "row known" "$(pk row os-beta)" "Org/plugins br-beta net/beta no"
expect_fail "row unknown" pk row os-gamma
expect_eq "catalogue" "$(pk catalogue | tr '\n' ' ')" "os-alpha os-vendor "
conf 'os-alpha Org/plugins br net/alpha'
expect_fail "four fields" pk catalogue
conf 'os-alpha Org/plugins br net/alpha maybe'
expect_fail "bad catalogue flag" pk catalogue
conf 'os-alpha Org/plugins br net/a yes' 'os-alpha Org/plugins br net/b no'
expect_fail "duplicate" pk catalogue
conf 'os-alpha-2 Org/plugins br net/a yes'
expect_fail "name with -digit" pk row os-alpha-2
expect_fail "usage" pk
expect_eq "real file: catalogue" "$(sh "$root/scripts/packages.sh" catalogue | tr '\n' ' ')" \
	"os-wg-client-tunnels os-mac-alias-cache os-wan-failover os-unbound-upstream os-legotypes "

# --- repo.sh -----------------------------------------------------------------
rc() {
	printf '%s\n' "$@" >"$T/repo.conf"
	printf '%s\n' "$@" | grep -q '^REQUIRE_IMMUTABLE_RELEASES=' || echo 'REQUIRE_IMMUTABLE_RELEASES=no' >>"$T/repo.conf"
}
rp() { sh "$S/repo.sh" "$@"; }
rc '# served repository' 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7 FreeBSD:15:amd64/27.1'
expect_eq "repo abi" "$(rp abi)" "FreeBSD:15:amd64"
expect_eq "repo series" "$(rp series)" "26.7"
expect_eq "repo target" "$(rp target)" "FreeBSD:15:amd64/26.7"
expect_eq "repo serve" "$(rp serve | tr '\n' ' ')" "FreeBSD:15:amd64/26.7 FreeBSD:15:amd64/27.1 "
expect_eq "repo tree" "$(rp tree)" "site/FreeBSD:15:amd64/26.7/latest"
expect_eq "repo tree of a served entry" "$(rp tree FreeBSD:15:amd64/27.1)" "site/FreeBSD:15:amd64/27.1/latest"
expect_fail "repo tree of an entry not served" rp tree FreeBSD:15:amd64/25.1
rc 'ABI=FreeBSD:16:amd64' 'SERIES=27.7' 'SERVE=FreeBSD:15:amd64/26.7 FreeBSD:16:amd64/27.7'
expect_eq "an ABI change keeps the old tree where firewalls on the old ABI look for it" \
	"$(rp tree FreeBSD:15:amd64/26.7)" "site/FreeBSD:15:amd64/26.7/latest"
expect_eq "an ABI change builds the new tree under the new ABI" "$(rp tree)" "site/FreeBSD:16:amd64/27.7/latest"
rc 'ABI=FreeBSD:15:amd64' 'SERIES=27.1' 'SERVE=FreeBSD:15:amd64/26.7'
expect_fail "SERVE must include the target" rp serve
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
expect_eq "repo immutable: no" "$(rp immutable)" "no"
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7' 'REQUIRE_IMMUTABLE_RELEASES=yes'
expect_eq "repo immutable: yes" "$(rp immutable)" "yes"
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7' 'REQUIRE_IMMUTABLE_RELEASES=maybe'
expect_fail "repo immutable: neither yes nor no" rp immutable
printf '%s\n' 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7' >"$T/repo.conf"
expect_fail "repo immutable: unset" rp immutable
expect_eq "the real repo.conf says no until every package has republished" \
	"$(sh "$root/scripts/repo.sh" immutable)" "no"
ptconf=('ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7')
rc "${ptconf[@]}" "PKG_TOOL_COMMIT=$(printf 'a%.0s' {1..40})" "PKG_TOOL_SHA256=$(printf 'b%.0s' {1..64})"
expect_eq "repo pkg-tool-commit" "$(rp pkg-tool-commit)" "$(printf 'a%.0s' {1..40})"
expect_eq "repo pkg-tool-sha256" "$(rp pkg-tool-sha256)" "$(printf 'b%.0s' {1..64})"
rc "${ptconf[@]}" 'PKG_TOOL_COMMIT=aaaaaaa' "PKG_TOOL_SHA256=$(printf 'b%.0s' {1..64})"
expect_fail "repo pkg-tool-commit: an abbreviated commit" rp pkg-tool-commit
rc "${ptconf[@]}" 'PKG_TOOL_COMMIT=2.8.4' "PKG_TOOL_SHA256=$(printf 'b%.0s' {1..64})"
expect_fail "repo pkg-tool-commit: a tag, which can move" rp pkg-tool-commit
rc "${ptconf[@]}" "PKG_TOOL_COMMIT=$(printf 'A%.0s' {1..40})" "PKG_TOOL_SHA256=$(printf 'b%.0s' {1..64})"
expect_fail "repo pkg-tool-commit: upper case" rp pkg-tool-commit
rc "${ptconf[@]}" "PKG_TOOL_COMMIT=$(printf 'a%.0s' {1..40})" "PKG_TOOL_SHA256=$(printf 'b%.0s' {1..63})"
expect_fail "repo pkg-tool-sha256: 63 digits" rp pkg-tool-sha256
rc "${ptconf[@]}" "PKG_TOOL_COMMIT=$(printf 'a%.0s' {1..40})" "PKG_TOOL_SHA256=$(printf 'B%.0s' {1..64})"
expect_fail "repo pkg-tool-sha256: upper case" rp pkg-tool-sha256
rc "${ptconf[@]}"
expect_fail "repo pkg-tool-commit: unset" rp pkg-tool-commit
expect_fail "repo pkg-tool-sha256: unset" rp pkg-tool-sha256
expect_eq "the real repo.conf pins pkg's source" \
	"$(sh "$root/scripts/repo.sh" pkg-tool-commit >/dev/null && sh "$root/scripts/repo.sh" pkg-tool-sha256 >/dev/null; echo "rc=$?")" "rc=0"
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=26.7'
expect_fail "a SERVE entry without its ABI" rp serve
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERIES=27.1' 'SERVE=FreeBSD:15:amd64/26.7'
expect_fail "SERIES set twice" rp series
rc 'ABI=freebsd15' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
expect_fail "malformed ABI" rp abi
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26' 'SERVE=FreeBSD:15:amd64/26'
expect_fail "malformed series" rp series
expect_eq "real file: tree" "$(sh "$root/scripts/repo.sh" tree)" "site/FreeBSD:15:amd64/26.7/latest"
choices=$(awk '/^ *options:/ { o = 1; next } o && /^ *- / { print $2; next } o { exit }' \
	"$root/.github/workflows/publish.yml" | sort | tr '\n' ' ')
expect_eq "publish.yml offers exactly the catalogue" "$choices" \
	"$(sh "$root/scripts/packages.sh" catalogue | sort | tr '\n' ' ')"

# --- the workflows' shape (static) ---------------------------------------------------
# yflat <workflow>: the workflow as "<path><TAB><value>" lines, read as GitHub reads these
# workflows: block mappings and block sequences indented with spaces, plain keys, a value on
# the key's line or a | or > block. A sequence item is numbered from 1 (jobs.sign.steps.3.uses);
# each line of a block is a line of its own under its key's path; comments, blank lines and a
# " # comment" after a plain value are dropped. A line it cannot place prints as "?<TAB><line>",
# which the tests refuse, so no check passes on a shape it does not see. awk, not a YAML
# library: neither PyYAML nor yq is on both the Mac and the Ubuntu runner.
yflat() {
	awk '
		function path(i, p) {
			p = nm[1]
			for (i = 2; i <= d; i++) p = p "." nm[i]
			return p
		}
		function pop(n) { while (d > 0 && ind[d] >= n) d-- }
		function quoted(v) { return substr(v, 1, 1) == "\"" || substr(v, 1, 1) == q }
		# key(<column>, <text>): place a "key: value" or "key:" line; 0 if <text> is not one
		function key(n, s, k, v) {
			if (!match(s, /^[A-Za-z0-9_-]+:( |$)/)) return 0
			k = substr(s, 1, RLENGTH)
			sub(/: ?$/, "", k)
			v = substr(s, RLENGTH + 1)
			pop(n)
			d++
			ind[d] = n
			nm[d] = k
			sub(/^ +/, "", v)
			if (v ~ /^[|>][-+]?( +#.*)?$/) {
				blk = n
				bpath = path()
				return 1
			}
			if (!quoted(v)) sub(/ +#.*$/, "", v)
			sub(/ +$/, "", v)
			if (v != "") print path() "\t" v
			return 1
		}
		BEGIN { blk = -1; q = sprintf("%c", 39) }
		{
			if (blk >= 0) {
				if ($0 ~ /^ *$/) next
				match($0, /^ */)
				if (RLENGTH > blk) {
					l = $0
					sub(/^ +/, "", l)
					print bpath "\t" l
					next
				}
				blk = -1
			}
			if ($0 ~ /^ *(#.*)?$/) next
			match($0, /^ */)
			n = RLENGTH
			s = substr($0, n + 1)
			if (s ~ /^- /) {
				pop(n)
				p = path()
				d++
				ind[d] = n
				nm[d] = ++items[p]
				s = substr(s, 3)
				if (!key(n + 2, s)) {
					if (!quoted(s)) sub(/ +#.*$/, "", s)
					print path() "\t" s
				}
				next
			}
			if (!key(n, s)) print "?\t" $0
		}
	' "$1"
}
# yget <flattened> <path>: the values at exactly that path, one per line
yget() { awk -F'\t' -v p="$2" '$1 == p { print $2 }' <<<"$1"; }
# ymarks <flattened> <job>: one line per step of the job, in order, naming what it does: the
# action it uses (without @<ref>), each scripts/<name>.sh its run (or the VM's run) names and
# each $RUNNER_TEMP/<name>.sh as tmp:<name>.sh, "stage" if it reads PKG_SIGNING_KEY, "unstage"
# if it removes .signing; "-" for none of these
ymarks() {
	awk -F'\t' -v j="jobs.$2.steps." '
		function add(n, w) { if (index(" " m[n] " ", " " w " ") == 0) m[n] = m[n] (m[n] == "" ? "" : " ") w }
		index($1, j) == 1 {
			rest = substr($1, length(j) + 1)
			n = rest
			sub(/\..*/, "", n)
			n += 0
			if (n > max) max = n
			k = substr(rest, index(rest, ".") + 1)
			if (k == "uses") {
				u = $2
				sub(/@.*/, "", u)
				add(n, u)
			}
			if (k == "env.PKG_SIGNING_KEY") add(n, "stage")
			if (k == "run" || k == "with.run") {
				s = $2
				while (match(s, /(scripts|RUNNER_TEMP)\/[a-z0-9-]+\.sh/)) {
					w = substr(s, RSTART, RLENGTH)
					add(n, (w ~ /^RUNNER_TEMP/ ? "tmp:" : "") substr(w, index(w, "/") + 1))
					s = substr(s, RSTART + RLENGTH)
				}
				if ($2 ~ /rm -rf \.signing/) add(n, "unstage")
			}
		}
		END { for (i = 1; i <= max; i++) print (m[i] == "" ? "-" : m[i]) }
	' <<<"$1"
}
# ystep <marks> <word>: the number of the first step whose marks hold <word> (empty if none)
ystep() { awk -v w="$2" 'index(" " $0 " ", " " w " ") { print NR; exit }' <<<"$1"; }
# yjobs <flattened>: the workflow's jobs, in order
yjobs() { awk -F'\t' '$1 ~ /^jobs\./ { split($1, a, "."); if (!s[a[2]]++) print a[2] }' <<<"$1"; }
# foreign <flattened>: each uses: that is not actions/<name>@<full commit>, the one VM action at
# its pinned commit, or a workflow of this repository (the repository's Actions policy allows these only)
foreign() {
	local p v out=''
	while IFS=$'\t' read -r p v; do
		[[ $p == *.uses ]] || continue
		[[ $v =~ ^actions/[A-Za-z0-9_.-]+@[0-9a-f]{40}$ || $v == vmactions/freebsd-vm@a2f9a41fa97f6848b8c3b791087dfcdaa5b473ff ||
			$v =~ ^\./\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$ ]] || out+="$p=$v "
	done <<<"$1"
	printf '%s' "$out"
}
wf="$root/.github/workflows"
B=$(yflat "$wf/build.yml")
P=$(yflat "$wf/publish.yml")
C=$(yflat "$wf/canary.yml")
for w in build publish canary; do
	f=$(yflat "$wf/$w.yml")
	expect_eq "$w.yml: every line is read" "$(awk -F'\t' '$1 == "?"' <<<"$f")" ""
	expect_eq "$w.yml: no flow mapping, anchor, alias or tag" \
		"$(awk -F'\t' '$2 ~ /^[{&*!]/ && $2 != "{}"' <<<"$f")" ""
	expect_eq "$w.yml: every uses: line is read as a step's or a job's" \
		"$(awk -F'\t' '$1 ~ /^jobs\.[^.]+(\.steps\.[0-9]+)?\.uses$/ { n++ } END { print n + 0 }' <<<"$f")" \
		"$(awk '/^ *(- )?uses:/ { n++ } END { print n + 0 }' "$wf/$w.yml")"
	unpinned=''
	while IFS=$'\t' read -r p v; do
		[[ $p == *.uses ]] || continue
		[[ $v =~ ^[^@\ ]+@[0-9a-f]{40}$ ]] || unpinned+="$p=$v "
	done <<<"$f"
	if [[ $w == publish ]]; then
		expect_eq "$w.yml: every action pinned to a full commit, but the local build workflow" "$unpinned" \
			"jobs.build.uses=./.github/workflows/build.yml "
	else
		expect_eq "$w.yml: every action pinned to a full commit" "$unpinned" ""
	fi
	expect_eq "$w.yml: every action is GitHub's own, the pinned VM action or this repository's workflow" "$(foreign "$f")" ""
	unsafe=''
	while IFS=$'\t' read -r p v; do
		[[ $p =~ ^(jobs\.[^.]+\.steps\.[0-9]+)\.uses$ && $v == actions/checkout@* ]] || continue
		[[ $(yget "$f" "${BASH_REMATCH[1]}.with.persist-credentials") == false ]] || unsafe+="$p "
	done <<<"$f"
	expect_eq "$w.yml: every checkout leaves no token in .git" "$unsafe" ""
	if [[ $w != build ]]; then
		expect_eq "$w.yml: no signing key" "$(awk -F'\t' '($1 $2) ~ /PKG_SIGNING_KEY|\.signing/' <<<"$f")" ""
	fi
	# an expression in a run: is pasted into the script before it runs; values go through env:
	expect_eq "$w.yml: no \${{ in a run:" "$(awk -F'\t' '$1 ~ /\.run$/ && index($2, "${{") { print $1 }' <<<"$f")" ""
	if [[ $w != canary ]]; then
		# pkg 2.8.4, pkg-tool.sh's dependencies and ubuntu-apt.sh's ubuntu.sources are proven on 24.04
		mis=''
		for j in $(yjobs "$f"); do
			[[ -n $(yget "$f" "jobs.$j.uses") ]] && continue
			[[ $(yget "$f" "jobs.$j.runs-on") == ubuntu-24.04 ]] || mis+="$j "
		done
		expect_eq "$w.yml: every job runs on ubuntu-24.04" "$mis" ""
	fi
done
h40=$(printf 'a%.0s' {1..40})
printf 'jobs:\n  x:\n    steps:\n      - uses: %s\n      - uses: %s\n      - uses: %s\n      - uses: %s\n      - uses: %s\n      - uses: %s\n' \
	"someone/action@$h40" actions/checkout@v7 "actions/cache/save@$h40" docker://alpine:3 "vmactions/freebsd-vm@$h40" \
	"actions/checkout@$h40" >"$T/mutant.yml"
expect_eq "foreign: a third-party action, a tag, a sub-action, a container and another VM commit are refused" \
	"$(foreign "$(yflat "$T/mutant.yml")" | wc -w | tr -d ' ')" 5
expect_eq "canary.yml: no environment and no secret" "$(awk -F'\t' '$1 ~ /environment/ || $2 ~ /secrets/' <<<"$C")" ""

# publish.yml: the approved commit, passed on; the deploy and the release wait for the whole
# build workflow (its sign job included: a caller cannot name a called workflow's jobs)
expect_eq "publish.yml: a required commit input" \
	"$(yget "$P" on.workflow_dispatch.inputs.commit.type) $(yget "$P" on.workflow_dispatch.inputs.commit.required)" "string true"
expect_eq "publish.yml: the commit goes to the build workflow" "$(yget "$P" jobs.build.with.commit)" '${{ inputs.commit }}'
expect_eq "publish.yml: the environment's secret reaches the called workflow" "$(yget "$P" jobs.build.secrets)" inherit
expect_eq "publish.yml: no other secret" "$(awk -F'\t' '$2 ~ /secrets/' <<<"$P")" ""
expect_eq "publish.yml: deploy waits for build.yml, signing included" "$(yget "$P" jobs.deploy.needs)" build
expect_eq "publish.yml: release waits for the deploy" "$(yget "$P" jobs.release.needs)" "[build, deploy]"
expect_eq "build.yml: the tag comes from the review job" "$(yget "$B" on.workflow_call.outputs.tag.value)" \
	'${{ jobs.review.outputs.tag }}'
# the sha256 sums the review job showed, which only its runner can set, bind the files sign and
# release use to what the approver read
sums="pkg_sha256 manifest_sha256 source_sha256 build_sha256"
for o in $sums; do
	expect_eq "build.yml: the workflow passes on review's $o" "$(yget "$B" "on.workflow_call.outputs.$o.value")" "\${{ jobs.review.outputs.$o }}"
done
expect_eq "build.yml: a required commit input" \
	"$(yget "$B" on.workflow_call.inputs.commit.type) $(yget "$B" on.workflow_call.inputs.commit.required)" "string true"
# the release notes are the review job's lines, never the VM's
rm_=$(ymarks "$P" release)
expect_eq "publish.yml: release takes both artifacts, checks the build, then releases" "$(tr '\n' ',' <<<"$rm_")" \
	"actions/checkout,actions/download-artifact,actions/download-artifact,out-dir.sh review-sums.sh release.sh,"
expect_eq "publish.yml: release downloads package into out and review into review" \
	"$(for i in 2 3; do printf '%s=%s ' "$(yget "$P" "jobs.release.steps.$i.with.name")" "$(yget "$P" "jobs.release.steps.$i.with.path")"; done)" \
	"package=out review=review "
expect_eq "publish.yml: the release notes come from review/, not out/" \
	"$(yget "$P" jobs.release.steps.4.run | awk '/release\.sh create/ && /review\/source/ && /review\/build/ && !/out\/source|out\/build/ { print "review" }')" review
expect_eq "publish.yml: release checks the files against review's sums before it releases" \
	"$(yget "$P" jobs.release.steps.4.run | tr '\n' ';')" \
	'bash scripts/out-dir.sh "$PACKAGE" out;bash scripts/review-sums.sh check "$PACKAGE" out review;bash scripts/release.sh create out/*.pkg "$(cat review/source)" review/build;'
expect_eq "publish.yml: release takes the sums and the commit through env" \
	"$(for o in PKG MANIFEST SOURCE BUILD; do printf '%s ' "$(yget "$P" "jobs.release.steps.4.env.${o}_SHA256")"; done)$(yget "$P" jobs.release.steps.4.env.COMMIT)" \
	'${{ needs.build.outputs.pkg_sha256 }} ${{ needs.build.outputs.manifest_sha256 }} ${{ needs.build.outputs.source_sha256 }} ${{ needs.build.outputs.build_sha256 }} ${{ inputs.commit }}'

# build.yml: three jobs; build and review have no environment and no secret, sign has both;
# review and sign run only GitHub's actions and this repository's scripts
expect_eq "build.yml: the jobs" "$(yjobs "$B" | tr '\n' ' ')" "build review sign "
expect_eq "build.yml: sign names the release environment" "$(awk -F'\t' '$1 ~ /^jobs\.sign\.environment(\.name)?$/ { print $2 }' <<<"$B")" release
expect_eq "build.yml: only sign names an environment" "$(awk -F'\t' '$1 ~ /^jobs\.[^.]+\.environment/ && $1 !~ /^jobs\.sign\./ { print $1 }' <<<"$B")" ""
expect_eq "build.yml: secrets only in the sign job" "$(awk -F'\t' '$2 ~ /secrets/ && $1 !~ /^jobs\.sign\./ { print $1 }' <<<"$B")" ""
expect_eq "build.yml: the signing key only in the sign job" \
	"$(awk -F'\t' '($1 $2) ~ /PKG_SIGNING_KEY|\.signing/ && $1 !~ /^jobs\.sign\./ { print $1 }' <<<"$B")" ""
for j in review sign; do
	expect_eq "build.yml: $j uses only GitHub's actions" \
		"$(awk -F'\t' -v j="$j" '$1 ~ ("^jobs\\." j "\\.(.*\\.)?uses$") && $2 !~ /^actions\// { print $2 }' <<<"$B")" ""
done
expect_eq "build.yml: review uses three of them" "$(awk -F'\t' '$1 ~ /^jobs\.review\.(.*\.)?uses$/' <<<"$B" | wc -l | tr -d ' ')" 3
expect_eq "build.yml: sign uses four of them" "$(awk -F'\t' '$1 ~ /^jobs\.sign\.(.*\.)?uses$/' <<<"$B" | wc -l | tr -d ' ')" 4
expect_eq "build.yml: review waits for build" "$(yget "$B" jobs.review.needs)" build
expect_eq "build.yml: sign waits for review" "$(yget "$B" jobs.sign.needs)" review
expect_eq "build.yml: sign only for a catalogue build" "$(yget "$B" jobs.sign.if)" inputs.catalogue
expect_eq "build.yml: sign has a timeout" "$(yget "$B" jobs.sign.timeout-minutes | awk '/^[0-9]+$/ { print "minutes" }')" minutes
for j in build review sign; do
	expect_eq "build.yml: $j only reads the repository" \
		"$(awk -F'\t' -v p="jobs.$j.permissions" 'index($1, p) == 1 { print substr($1, length(p) + 2) "=" $2 }' <<<"$B")" "contents=read"
done
expect_eq "build.yml: only review has outputs, the tag and the four sums" \
	"$(awk -F'\t' '$1 ~ /^jobs\.[^.]+\.outputs\./ { print $1 "=" $2 }' <<<"$B" | tr '\n' ' ')" \
	'jobs.review.outputs.tag=${{ steps.check.outputs.tag }} jobs.review.outputs.pkg_sha256=${{ steps.sums.outputs.pkg_sha256 }} jobs.review.outputs.manifest_sha256=${{ steps.sums.outputs.manifest_sha256 }} jobs.review.outputs.source_sha256=${{ steps.sums.outputs.source_sha256 }} jobs.review.outputs.build_sha256=${{ steps.sums.outputs.build_sha256 }} '
expect_eq "build.yml: no ::error:: line repeats the commit as given" \
	"$(awk -F'\t' '$2 ~ /::error::/ && $2 ~ /COMMIT|inputs\.commit/' <<<"$B")" ""

# the build job shares its runner with the VM: after the VM only the out/ check, with a copy of
# out-dir.sh taken before the VM ran (the VM syncs the workspace back), and the upload
bm=$(ymarks "$B" build)
expect_eq "build: the steps in order" "$(tr '\n' ',' <<<"$bm")" \
	"actions/checkout,packages.sh,upstream.sh,out-dir.sh tmp:out-dir.sh,vmactions/freebsd-vm build-package.sh,tmp:out-dir.sh,actions/upload-artifact,"
vmstep=$(ystep "$bm" vmactions/freebsd-vm)
expect_eq "build: the VM runs build-package.sh and nothing else" \
	"$(yget "$B" "jobs.build.steps.$vmstep.with.run" | tr '\n' ';')" 'set -e;umask 022;sh scripts/build-package.sh "$PACKAGE" "$COMMIT";'
expect_eq "build: the VM gets no key, no pkg repo, no site/" \
	"$(awk -F'\t' -v p="jobs.build.steps.$vmstep." 'index($1, p) == 1 && $2 ~ /signing|KEY|pkg repo|site/' <<<"$B")" ""
expect_eq "build: out-dir.sh is copied out of the workspace just before the VM" \
	"$(yget "$B" "jobs.build.steps.$((vmstep - 1)).run")" 'cp scripts/out-dir.sh "$RUNNER_TEMP/out-dir.sh"'
expect_eq "build: the step after the VM runs exactly that copy on out/" \
	"$(yget "$B" "jobs.build.steps.$((vmstep + 1)).run")" 'bash "$RUNNER_TEMP/out-dir.sh" "$PACKAGE" out'
expect_eq "build: and then only the upload, of out/ as package" \
	"$(( $(wc -l <<<"$bm") - vmstep )) $(yget "$B" "jobs.build.steps.$((vmstep + 2)).with.name") $(yget "$B" "jobs.build.steps.$((vmstep + 2)).with.path")" \
	"2 package out/"

# the review job, on a runner the VM never touched: everything the approver reads, and the release
# notes' lines, made by this repository's scripts from its own checkout
rv=$(ymarks "$B" review)
expect_eq "review: the steps in order" "$(tr '\n' ',' <<<"$rv")" \
	"actions/checkout,actions/download-artifact,out-dir.sh,upstream.sh,provenance.sh,release.sh,manifest.sh,plugin-source.sh,ubuntu-apt.sh,summary.sh,review-sums.sh,actions/upload-artifact,"
expect_eq "review: the full history, for the last commit that changed this repository's package" \
	"$(yget "$B" jobs.review.steps.1.with.fetch-depth)" 0
expect_eq "review: downloads package into out" "$(yget "$B" jobs.review.steps.2.with.name) $(yget "$B" jobs.review.steps.2.with.path)" "package out"
expect_eq "review: the version check gives the tag" "$(yget "$B" "jobs.review.steps.$(ystep "$rv" release.sh).id")" check
expect_eq "review: the manifest goes to review/" \
	"$(yget "$B" "jobs.review.steps.$(ystep "$rv" manifest.sh).run" | tr '\n' ';')" 'bash scripts/manifest.sh "$PACKAGE" out;mv out/manifest review/manifest;'
expect_eq "review: the summary goes to the job's summary" \
	"$(yget "$B" "jobs.review.steps.$(ystep "$rv" summary.sh).run")" 'bash scripts/summary.sh "$PACKAGE" out review >> "$GITHUB_STEP_SUMMARY"'
expect_eq "review: the four sums, last, from the files it uploads" \
	"$(yget "$B" "jobs.review.steps.$(ystep "$rv" review-sums.sh).id") $(yget "$B" "jobs.review.steps.$(ystep "$rv" review-sums.sh).run")" \
	'sums bash scripts/review-sums.sh print "$PACKAGE" out review >> "$GITHUB_OUTPUT"'
expect_eq "review: the artifact is review/" \
	"$(yget "$B" "jobs.review.steps.$(ystep "$rv" actions/upload-artifact).with.name") $(yget "$B" "jobs.review.steps.$(ystep "$rv" actions/upload-artifact).with.path")" \
	"review review/"

# the sign job: everything that can run code as root or fetch anything comes before the key; the
# key is removed whatever happens
sm=$(ymarks "$B" sign)
expect_eq "sign: the steps in order" "$(tr '\n' ',' <<<"$sm")" \
	"actions/checkout,actions/download-artifact,actions/download-artifact,out-dir.sh review-sums.sh,plugin-source.sh,ubuntu-apt.sh,payload.sh,release.sh,pkg-tool.sh,carry-forward.sh,stage,sign-catalogue.sh,unstage,actions/upload-pages-artifact,"
pt_step=$(ystep "$sm" pkg-tool.sh) stage_step=$(ystep "$sm" stage) rel_step=$(ystep "$sm" release.sh)
chk_step=$(ystep "$sm" review-sums.sh)
expect_eq "sign: right after the downloads, the files are checked against review's sums" \
	"$chk_step $(yget "$B" "jobs.sign.steps.$chk_step.run" | tail -2 | tr '\n' ';')" \
	'4 bash scripts/out-dir.sh "$PACKAGE" out;bash scripts/review-sums.sh check "$PACKAGE" out review;'
expect_eq "sign: the sums come from the review job's outputs through env, the commit from the input" \
	"$(for o in PKG MANIFEST SOURCE BUILD; do printf '%s ' "$(yget "$B" "jobs.sign.steps.$chk_step.env.${o}_SHA256")"; done)$(yget "$B" jobs.sign.env.COMMIT)" \
	'${{ needs.review.outputs.pkg_sha256 }} ${{ needs.review.outputs.manifest_sha256 }} ${{ needs.review.outputs.source_sha256 }} ${{ needs.review.outputs.build_sha256 }} ${{ inputs.commit }}'
expect_eq "sign: pkg-tool.sh runs before the key is staged" \
	"$([[ -n $pt_step && -n $stage_step ]] && ((pt_step < stage_step)) && echo before)" before
expect_eq "sign: the version is checked again before the key is staged" \
	"$([[ -n $rel_step && -n $stage_step ]] && ((rel_step < stage_step)) && echo before) $(yget "$B" "jobs.sign.steps.$rel_step.run")" \
	'before bash scripts/release.sh check out/*.pkg'
expect_eq "sign: downloads package into out and review into review" \
	"$(for i in 2 3; do printf '%s=%s ' "$(yget "$B" "jobs.sign.steps.$i.with.name")" "$(yget "$B" "jobs.sign.steps.$i.with.path")"; done)" \
	"package=out review=review "
expect_eq "sign: the key comes from the release environment's secret" \
	"$(yget "$B" "jobs.sign.steps.$stage_step.env.PKG_SIGNING_KEY")" '${{ secrets.PKG_SIGNING_KEY }}'
expect_eq "sign: the key is staged private, and an empty secret fails" \
	"$(yget "$B" "jobs.sign.steps.$stage_step.run" | awk '/^umask 077$/ { u = 1 } /-z "\$PKG_SIGNING_KEY"/ { e = 1 } END { print u + e }')" 2
expect_eq "sign: the key is removed whatever happened" "$(yget "$B" "jobs.sign.steps.$(ystep "$sm" unstage).if")" "always()"
expect_eq "sign: a missing artifact is named" \
	"$(yget "$B" "jobs.sign.steps.$(ystep "$sm" out-dir.sh).run" | awk '/no package artifact: re-run the whole workflow/ { n++ } END { print n + 0 }')" 1
for s in payload.sh sign-catalogue.sh; do
	expect_eq "sign: $s output is never read as a workflow command" \
		"$(yget "$B" "jobs.sign.steps.$(ystep "$sm" "$s").run" | awk '/::stop-commands::/ { print "stopped" }')" stopped
done
expect_eq "sign: the carried releases must be the review job's manifest's" \
	"$(yget "$B" "jobs.sign.steps.$(ystep "$sm" carry-forward.sh).env.MANIFEST")" review/manifest
expect_eq "sign: the Pages site is site/" "$(yget "$B" "jobs.sign.steps.$(ystep "$sm" actions/upload-pages-artifact).with.path")" site
# a re-run of sign after the artifacts expired: both downloads go on when theirs is gone, and the check
# step refuses anything but their success first, with its own message
for id in package review; do
	n=$(awk -F'\t' -v id="$id" '$1 ~ /^jobs\.sign\.steps\.[0-9]+\.id$/ && $2 == id { split($1, a, "."); print a[4] }' <<<"$B")
	expect_eq "sign: the $id download goes on when the artifact is gone" \
		"$(yget "$B" "jobs.sign.steps.$n.continue-on-error") $(yget "$B" "jobs.sign.steps.$n.uses" | sed 's/@.*//') $(yget "$B" "jobs.sign.steps.$n.with.name")" \
		"true actions/download-artifact $id"
done
expect_eq "sign: the check reads both downloads' outcomes" \
	"$(yget "$B" "jobs.sign.steps.$chk_step.env.PACKAGE_ARTIFACT") $(yget "$B" "jobs.sign.steps.$chk_step.env.REVIEW_ARTIFACT")" \
	'${{ steps.package.outcome }} ${{ steps.review.outcome }}'
expect_eq "sign: and refuses anything but success before it reads the files" \
	"$(yget "$B" "jobs.sign.steps.$chk_step.run" | head -4 | tr '\n' ';')" \
	'if [ "$PACKAGE_ARTIFACT" != success ] || [ "$REVIEW_ARTIFACT" != success ]; then;echo "::error::no package artifact: re-run the whole workflow";exit 1;fi;'
# the approver reads the review job's summary only, and the build job writes none: text under the build
# job's summary means its runner was tampered with. Only review's summary step names the summary file,
# and no script the build job runs does.
# writers <flattened>: the paths of the values that name GITHUB_STEP_SUMMARY
writers() { awk -F'\t' 'index($2, "GITHUB_STEP_SUMMARY") { print $1 }' <<<"$1" | tr '\n' ' '; }
expect_eq "build.yml: only the review job's summary step writes the job summary" "$(writers "$B")" \
	"jobs.review.steps.$(ystep "$rv" summary.sh).run "
for s in packages.sh upstream.sh out-dir.sh build-package.sh; do
	expect_eq "build: $s, which the build job runs, names no job summary" "$(grep -c GITHUB_STEP_SUMMARY "$root/scripts/$s")" 0
done
awk '{ print } /^  build:$/ { b = 1 } b && /^    steps:$/ { print "      - run: echo \"## Approve\" >> \"$GITHUB_STEP_SUMMARY\""; b = 0 }' \
	"$wf/build.yml" >"$T/mutant.yml"
expect_eq "writers: a build job step writing the summary is found" "$(writers "$(yflat "$T/mutant.yml")" | wc -w | tr -d ' ')" 2

# --- release.sh and carry-forward.sh -----------------------------------------
export PATH="$root/tests/stub:$PATH" GH_REPO=Org/repo
unset GITHUB_SHA
sum() { sha256sum "$1" | awk '{print $1}'; }
reset_stub() {
	export STUB="$T/stub"
	rm -rf "$STUB"
	mkdir -p "$STUB/notes" "$STUB/assets"
	: >"$STUB/tags"
	echo '[]' >"$STUB/releases.json"
	echo '[]' >"$STUB/issues.json"
	: >"$STUB/issue_calls"
}
# publish <tag> <published-at> [notes-sha] [created-at]: a release holding <tag>.pkg. As on GitHub,
# createdAt is the date of the tagged commit (so two releases of one commit share it), publishedAt is
# when the release was made, and gh lists the newest first.
publish() {
	local tag=$1 at=$2 created=${4:-$2} f
	mkdir -p "$STUB/assets/$tag"
	f="$STUB/assets/$tag/$tag.pkg"
	echo "bytes of $tag" >"$f"
	printf 'Built from Org/plugins, branch b, commit 0000000.\n\nsha256: %s\n' "${3:-$(sum "$f")}" >"$STUB/notes/$tag"
	echo "$tag" >>"$STUB/tags"
	jq --arg t "$tag" --arg p "$at" --arg c "$created" '[{tagName: $t, createdAt: $c, publishedAt: $p}] + .' "$STUB/releases.json" >"$STUB/r"
	mv "$STUB/r" "$STUB/releases.json"
}
rel() { bash "$root/scripts/release.sh" "$@"; }
# live [-s <series>] <name-version>...: the packages.txt the live site serves for a series (default 26.7)
live() {
	local s=26.7 nv d
	if [[ $1 == -s ]]; then s=$2 && shift 2; fi
	d="$T/livesite/FreeBSD:15:amd64/$s/latest"
	mkdir -p "$d"
	for nv in "$@"; do printf 'Name           : %s\nVersion        : %s\nOrigin         : opnsense/%s\n\n' "${nv%-*}" "${nv##*-}" "${nv%-*}"; done >"$d/packages.txt"
}
export LIVE_SITE=https://live.test STUB_LIVE_URL=https://live.test STUB_LIVE="$T/livesite"
names() { (cd "$1" && printf '%s ' *); }
# cf <built>: carry-forward in $T/cfw with $T/packages.conf and $T/repo.conf; trees land under $T/cfw/site
cf() { (rm -rf "$T/cfw" && mkdir -p "$T/cfw" && cd "$T/cfw" && bash "$S/carry-forward.sh" "$@"); }
tree() { echo "$T/cfw/site/FreeBSD:15:amd64/${1:-26.7}/latest/All"; }
# cfok <built>: carry-forward that must succeed
cfok() { cf "$@" >/dev/null || bad "carry-forward $* exited non-zero"; }

reset_stub
mkdir -p "$T/out"
echo new >"$T/out/os-alpha-1.1.pkg"
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-1.1_1 2026-01-02T00:00:00Z
expect_eq "check new (a longer tag with the same prefix exists)" "$(rel check "$T/out/os-alpha-1.1.pkg")" "os-alpha-1.1"
echo x >"$T/out/os-alpha-1.0.pkg"
expect_fail "check existing" rel check "$T/out/os-alpha-1.0.pkg"
expect_fail "check two files" rel check "$T/out/os-alpha-1.0.pkg" "$T/out/os-alpha-1.1.pkg"
expect_fail "check no file" rel check "$T/out/missing.pkg"
expect_fail "check not a .pkg" rel check "$T/packages.conf"
touch "$STUB/fail_api"
expect_fail "check with the api down" rel check "$T/out/os-alpha-1.1.pkg"
rm "$STUB/fail_api"
GITHUB_SHA=abc123 rel create "$T/out/os-alpha-1.1.pkg" "Built from Org/plugins, branch b, commit 1234567." >/dev/null
expect_eq "create header" "$(head -1 "$STUB/created")" "os-alpha-1.1|os-alpha-1.1.pkg|abc123"
expect_eq "create source line" "$(sed -n 2p "$STUB/created")" "Built from Org/plugins, branch b, commit 1234567."
expect_eq "create sha line" "$(grep '^sha256: ' "$STUB/created")" "sha256: $(sum "$T/out/os-alpha-1.1.pkg")"
printf 'series: 26.7\nphp: 85\n' >"$T/out/build"
echo two >"$T/out/os-alpha-1.2.pkg"
rel create "$T/out/os-alpha-1.2.pkg" "Built from here." "$T/out/build" >/dev/null
expect_eq "create with the build environment" "$(sed -n '/^os-alpha-1.2|/,$p' "$STUB/created" | sed -n '2,5p')" \
	$'Built from here.\n\nseries: 26.7\nphp: 85'
expect_fail "create with a missing build file" rel create "$T/out/os-alpha-1.2.pkg" "src" "$T/out/none"
expect_fail "create existing" rel create "$T/out/os-alpha-1.0.pkg" "src"
expect_fail "create empty source" rel create "$T/out/os-alpha-1.1.pkg" ""
expect_fail "create two-line source" rel create "$T/out/os-alpha-1.1.pkg" $'a\nb'

rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
conf 'os-alpha        Org/plugins br   net/alpha yes' \
	'os-alpha-extra  Org/plugins br   net/extra yes' \
	'os-beta         Org/plugins br   net/beta  no' \
	'os-vendor       .           main vendor/v  yes'
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-1.1 2026-01-03T00:00:00Z
publish os-alpha-extra-2.0 2026-01-04T00:00:00Z
publish os-beta-9.0 2026-01-05T00:00:00Z
publish os-vendor-1.0_1 2026-01-02T00:00:00Z
live os-alpha-1.1 os-alpha-extra-2.0 os-vendor-1.0_1
cfok os-vendor
expect_eq "carries the newest of each other catalogue package, never a release-only one" \
	"$(names "$(tree)")" "os-alpha-1.1.pkg os-alpha-extra-2.0.pkg "
expect_eq "carries the bytes" "$(cat "$(tree)/os-alpha-1.1.pkg")" "bytes of os-alpha-1.1"
cfok os-alpha
expect_eq "a name prefix does not capture another package's releases" \
	"$(names "$(tree)")" "os-alpha-extra-2.0.pkg os-vendor-1.0_1.pkg "
expect_fail "built package not in the catalogue" cf os-beta
live os-alpha-1.2 os-alpha-extra-2.0 os-vendor-1.0_1
expect_fail "live serves a build that has no release (a publish whose release job failed)" cf os-vendor
expect_fail "the same, for the package being built" cf os-alpha
# the live site may be the previous deploy, cached, or a deploy whose release job failed: the message names both
err=$(cf os-vendor 2>&1 >/dev/null)
expect_eq "a live catalogue that disagrees with the releases: the message names the cache and the failed release" \
	"$(grep -c 'Pages caches each file for up to 10 minutes' <<<"$err") $(grep -c 'otherwise the publish that deployed it has no release yet: re-run its failed jobs; do not publish again' <<<"$err")" "1 1"
live os-alpha-1.1 os-vendor-1.0_1
expect_fail "live lacks a catalogue package that has a release" cf os-vendor
rm -r "$T/livesite"
expect_fail "live catalogue unreadable" cf os-vendor
mkdir -p "$T/livesite/FreeBSD:15:amd64/26.7/latest"
echo 503 >"$T/livesite/FreeBSD:15:amd64/26.7/latest/packages.txt.status"
expect_eq "a live site that answers 503 is unreadable, not empty" \
	"$(cf os-vendor 2>&1 >/dev/null | grep -c 'cannot read')" "1"
rm "$T/livesite/FreeBSD:15:amd64/26.7/latest/packages.txt.status"
publish os-vendor-1.0_2 2026-01-06T00:00:00Z "$(printf '0%.0s' {1..64})"
live os-alpha-1.1 os-alpha-extra-2.0 os-vendor-1.0_2
expect_fail "sha256 mismatch" cf os-alpha
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
live os-alpha-1.0
expect_fail "missing release" cf os-alpha
reset_stub
publish os-alpha-extra-2.0 2026-01-02T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-extra-2.0 os-vendor-1.0
cfok os-alpha
expect_eq "a new package, not yet live or released, can be published" "$(names "$(tree)")" "os-alpha-extra-2.0.pkg os-vendor-1.0.pkg "
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-extra-2.0 2026-01-02T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-1.0 os-alpha-extra-2.0 os-vendor-1.0
cfok os-alpha
expect_eq "consistent live catalogue and releases carry forward" "$(names "$(tree)")" "os-alpha-extra-2.0.pkg os-vendor-1.0.pkg "
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z "" 2026-01-01T00:00:00Z
publish os-alpha-1.1 2026-01-02T00:00:00Z "" 2026-01-01T00:00:00Z
publish os-alpha-extra-2.0 2026-01-02T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-1.1 os-alpha-extra-2.0 os-vendor-1.0
cfok os-vendor
expect_eq "two releases tagged on one commit: the later published is the newest" "$(names "$(tree)")" "os-alpha-1.1.pkg os-alpha-extra-2.0.pkg "
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-extra-2.0 2026-01-02T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-1.0 os-alpha-extra-2.0 os-vendor-1.0
printf 'no checksum here\n' >"$STUB/notes/os-vendor-1.0"
expect_fail "notes without sha256" cf os-alpha
printf 'sha256: %s\nsha256: %s\n' "$(sum "$STUB/assets/os-vendor-1.0/os-vendor-1.0.pkg")" "$(sum "$STUB/assets/os-vendor-1.0/os-vendor-1.0.pkg")" >"$STUB/notes/os-vendor-1.0"
expect_fail "notes with two sha256 lines" cf os-alpha

# two served series: 27.1 is the target, 26.7 stays frozen at its last releases
rc 'ABI=FreeBSD:15:amd64' 'SERIES=27.1' 'SERVE=FreeBSD:15:amd64/26.7 FreeBSD:15:amd64/27.1'
reset_stub
rm -rf "$T/livesite"
publish os-alpha-1.1 2026-01-03T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
publish os-alpha-1.1_1 2026-02-01T00:00:00Z
printf 'Built.\n\nseries: 27.1\n\nsha256: %s\n' "$(sum "$STUB/assets/os-alpha-1.1_1/os-alpha-1.1_1.pkg")" >"$STUB/notes/os-alpha-1.1_1"
live -s 26.7 os-alpha-1.1 os-vendor-1.0
live -s 27.1 os-alpha-1.1_1
cfok os-vendor
expect_eq "series: the target tree carries the 27.1 builds" "$(names "$(tree 27.1)")" "os-alpha-1.1_1.pkg "
expect_eq "series: the frozen tree carries its own releases, the built package's included" "$(names "$(tree 26.7)")" "os-alpha-1.1.pkg os-vendor-1.0.pkg "
live -s 26.7 os-alpha-1.0 os-vendor-1.0
expect_fail "series: a frozen tree serving other than its newest releases" cf os-vendor
live -s 26.7 os-alpha-1.1 os-vendor-1.0
rm -rf "$T/livesite/FreeBSD:15:amd64/27.1"
reset_stub
publish os-alpha-1.1 2026-01-03T00:00:00Z
publish os-alpha-extra-2.0 2026-01-04T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live -s 26.7 os-alpha-1.1 os-alpha-extra-2.0 os-vendor-1.0
cfok os-vendor
expect_eq "series: the first publish into a new series succeeds with nothing else released for it" \
	"$(names "$(tree 27.1)" 2>/dev/null)" "* "
expect_eq "series: the first publish keeps the old series whole" "$(names "$(tree 26.7)")" \
	"os-alpha-1.1.pkg os-alpha-extra-2.0.pkg os-vendor-1.0.pkg "
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
# the served trees, read again to make them, cannot be read: the run fails (set -e holds), even with
# nothing to carry; a stand-in repo.sh fails its second "serve" (carry-plan.sh asks first)
rm -rf "$T/cfs" && cp -R "$S" "$T/cfs" && mv "$T/cfs/repo.sh" "$T/cfs/repo.real.sh"
cat >"$T/cfs/repo.sh" <<'EOF'
#!/bin/sh
if [ "$1" = serve ]; then
	n=$(($(cat "$CFS_COUNT" 2>/dev/null || echo 0) + 1))
	echo "$n" >"$CFS_COUNT"
	[ "$n" -lt 2 ] || { echo "repo.sh: cannot read repo.conf" >&2; exit 1; }
fi
exec sh "$(dirname "$0")/repo.real.sh" "$@"
EOF
conf 'os-alpha Org/plugins br net/alpha yes'
reset_stub
rm -rf "$T/livesite"
rm -f "$T/cfs.count"
expect_fail "carry-forward: served trees it cannot read fail the run" \
	sh -c 'rm -rf "$1/cfw" && mkdir -p "$1/cfw" && cd "$1/cfw" && CFS_COUNT="$1/cfs.count" bash "$1/cfs/carry-forward.sh" os-alpha' \
	_ "$T"
expect_eq "carry-forward: carry-plan.sh read the trees first" "$(cat "$T/cfs.count" 2>/dev/null)" 2
conf 'os-alpha        Org/plugins br   net/alpha yes' \
	'os-alpha-extra  Org/plugins br   net/extra yes' \
	'os-beta         Org/plugins br   net/beta  no' \
	'os-vendor       .           main vendor/v  yes'

# --- manifest.sh and carry-forward's manifest ---------------------------------------
# mf <built>: manifest.sh in $T/mo with the cf configuration
C40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mf() {
	rm -rf "$T/mo" && mkdir -p "$T/mo"
	echo built >"$T/mo/$1-1.1.pkg"
	COMMIT=$C40 bash "$S/manifest.sh" "$1" "$T/mo"
}
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-extra-2.0 2026-01-04T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
mkdir -p "$STUB/immutable"
touch "$STUB/immutable/os-vendor-1.0"
rm -rf "$T/livesite"
live os-alpha-1.0 os-alpha-extra-2.0 os-vendor-1.0
mf os-alpha || bad "manifest.sh exited non-zero"
M="$T/mo/manifest"
alpha_extra_sum=$(sum "$STUB/assets/os-alpha-extra-2.0/os-alpha-extra-2.0.pkg")
vendor_sum=$(sum "$STUB/assets/os-vendor-1.0/os-vendor-1.0.pkg")
expect_eq "manifest: sorted lines, the carried releases with their immutability, the built package, the commit" \
	"$(cat "$M")" "built os-alpha-1.1.pkg $(sum "$T/mo/os-alpha-1.1.pkg")
carry FreeBSD:15:amd64/26.7 os-alpha-extra-2.0 $alpha_extra_sum immutable=no
carry FreeBSD:15:amd64/26.7 os-vendor-1.0 $vendor_sum immutable=yes
commit $C40"
expect_eq "manifest: sorted" "$(LC_ALL=C sort "$M")" "$(cat "$M")"
expect_eq "manifest: ends with a newline" "$(tail -c1 "$M" | od -An -c | tr -d ' ')" '\n'
cfok os-alpha
expect_eq "carry-forward writes the carry lines manifest.sh lists, in the working directory" \
	"$(cat "$T/cfw/manifest.carry")" "$(grep '^carry ' "$M")"
expect_eq "nothing but the trees appears under site/" "$(cd "$T/cfw" && find site -type f | grep -vc '/All/os-')" "0"
expect_eq "no manifest file under site/" "$(cd "$T/cfw" && find site -iname '*manifest*' | wc -l | tr -d ' ')" "0"
mfcf() { MANIFEST="$1" cf os-alpha; }
mfcfok() { mfcf "$1" >/dev/null 2>&1 || bad "carry-forward against $1 exited non-zero"; }
mfcfok "$M"
cp "$M" "$T/m.shuffled"
LC_ALL=C sort -r "$M" >"$T/m.shuffled"
mfcfok "$T/m.shuffled"
printf '%s' "$(cat "$M")" >"$T/m.nonl"
mfcfok "$T/m.nonl"
printf '%s' "$(grep '^carry ' "$M" | LC_ALL=C sort -r)" >"$T/m.carryonly"
mfcfok "$T/m.carryonly"
expect_eq "an empty approved carry list is not equal" "$(printf 'commit %s\n' "$C40" >"$T/m.none"; mfcf "$T/m.none" 2>&1 >/dev/null | grep -c 'differ from the approved manifest')" "1"
sed "s/$vendor_sum/$(printf '0%.0s' {1..64})/" "$M" >"$T/m.sha"
expect_fail "a changed sha256 fails" mfcf "$T/m.sha"
expect_eq "a changed sha256 is reported as a difference" "$(mfcf "$T/m.sha" 2>&1 >/dev/null | grep -c 'differ from the approved manifest')" "1"
sed 's/os-vendor-1.0 /os-vendor-0.9 /' "$M" >"$T/m.tag"
expect_fail "a changed tag fails" mfcf "$T/m.tag"
sed 's/immutable=yes/immutable=no/' "$M" >"$T/m.imm"
expect_fail "a changed immutability fails" mfcf "$T/m.imm"
grep -v 'os-vendor' "$M" >"$T/m.drop"
expect_fail "a missing carry line fails" mfcf "$T/m.drop"
expect_fail "an unreadable manifest fails" mfcf "$T/none"
# a release changing between approval and signing: a newer one is published
publish os-alpha-extra-2.1 2026-01-09T00:00:00Z
live os-alpha-1.0 os-alpha-extra-2.1 os-vendor-1.0
expect_fail "a newer release after the manifest was made fails" mfcf "$M"
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-extra-2.0 2026-01-04T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
live os-alpha-1.0 os-alpha-extra-2.0 os-vendor-1.0
mkdir -p "$STUB/immutable"
# the live site unreachable: the existing message, not a mismatch
echo 503 >"$T/livesite/FreeBSD:15:amd64/26.7/latest/packages.txt.status"
out=$(MANIFEST="$M" cf os-alpha 2>&1 >/dev/null)
expect_eq "Pages unreachable still reports the live site" "$(grep -c 'cannot read .* (HTTP 503)' <<<"$out")" "1"
expect_eq "Pages unreachable is not a manifest mismatch" "$(grep -c 'differ' <<<"$out")" "0"
expect_fail "manifest.sh with Pages unreachable" mf os-alpha
rm "$T/livesite/FreeBSD:15:amd64/26.7/latest/packages.txt.status"
# REQUIRE_IMMUTABLE_RELEASES
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7' 'REQUIRE_IMMUTABLE_RELEASES=yes'
expect_fail "required immutable, newest release is not" cf os-alpha
expect_eq "the die message names the release" "$(cf os-alpha 2>&1 >/dev/null | grep -c 'not immutable: os-alpha-extra-2.0 os-vendor-1.0')" "1"
touch "$STUB/immutable/os-alpha-extra-2.0"
expect_fail "required immutable, one of two is not" cf os-alpha
touch "$STUB/immutable/os-vendor-1.0"
cfok os-alpha
expect_eq "required immutable, all are: carried" "$(names "$(tree)")" "os-alpha-extra-2.0.pkg os-vendor-1.0.pkg "
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
rm "$STUB/immutable/os-vendor-1.0"
cfok os-alpha
expect_eq "not required: a release that is not immutable is carried and listed" \
	"$(grep -c 'immutable=no' "$T/cfw/manifest.carry")" "1"
# the manifest's inputs
expect_fail "manifest.sh without the approved commit" env -u COMMIT bash "$root/scripts/manifest.sh" os-alpha "$T/mo"
expect_fail "manifest.sh with a short commit" env COMMIT=abc123 bash "$root/scripts/manifest.sh" os-alpha "$T/mo"
rm -f "$T/mo/os-alpha-1.1.pkg"
expect_fail "manifest.sh without a built package" env COMMIT=$C40 bash "$S/manifest.sh" os-alpha "$T/mo"
# two served trees (SERVE, a series change): the manifest lists what is carried into each, and
# carry-forward against it fills both
rc 'ABI=FreeBSD:15:amd64' 'SERIES=27.1' 'SERVE=FreeBSD:15:amd64/26.7 FreeBSD:15:amd64/27.1'
reset_stub
rm -rf "$T/livesite"
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-extra-2.0 2026-01-04T00:00:00Z
publish os-vendor-1.0 2026-01-02T00:00:00Z
publish os-vendor-1.0_1 2026-02-01T00:00:00Z
printf 'Built.\n\nseries: 27.1\n\nsha256: %s\n' "$(sum "$STUB/assets/os-vendor-1.0_1/os-vendor-1.0_1.pkg")" >"$STUB/notes/os-vendor-1.0_1"
live -s 26.7 os-alpha-1.0 os-alpha-extra-2.0 os-vendor-1.0
live -s 27.1 os-vendor-1.0_1
mf os-alpha || bad "manifest.sh with two served trees exited non-zero"
expect_eq "manifest: two served trees, the frozen one keeping the built package's last release" "$(cat "$M")" \
	"built os-alpha-1.1.pkg $(sum "$T/mo/os-alpha-1.1.pkg")
carry FreeBSD:15:amd64/26.7 os-alpha-1.0 $(sum "$STUB/assets/os-alpha-1.0/os-alpha-1.0.pkg") immutable=no
carry FreeBSD:15:amd64/26.7 os-alpha-extra-2.0 $(sum "$STUB/assets/os-alpha-extra-2.0/os-alpha-extra-2.0.pkg") immutable=no
carry FreeBSD:15:amd64/26.7 os-vendor-1.0 $(sum "$STUB/assets/os-vendor-1.0/os-vendor-1.0.pkg") immutable=no
carry FreeBSD:15:amd64/27.1 os-vendor-1.0_1 $(sum "$STUB/assets/os-vendor-1.0_1/os-vendor-1.0_1.pkg") immutable=no
commit $C40"
mfcfok "$M"
expect_eq "manifest: carry-forward against it fills both trees" "$(names "$(tree 26.7)")| $(names "$(tree 27.1)")" \
	"os-alpha-1.0.pkg os-alpha-extra-2.0.pkg os-vendor-1.0.pkg | os-vendor-1.0_1.pkg "
LC_ALL=C sort -r "$M" >"$T/m.shuffled"
mfcfok "$T/m.shuffled"
grep -v '27\.1 ' "$M" >"$T/m.drop"
expect_fail "manifest: a manifest without the new tree's line fails" mfcf "$T/m.drop"
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'

# --- newest-release.sh ----------------------------------------------------------
nr() { bash "$root/scripts/newest-release.sh" "$@"; }
reset_stub
publish os-alpha-1.0 2026-01-01T00:00:00Z
publish os-alpha-1.1 2026-01-03T00:00:00Z
publish os-alpha-extra-2.0 2026-01-04T00:00:00Z
expect_eq "newest release" "$(nr os-alpha)" "os-alpha-1.1"
expect_eq "no release" "$(nr os-gamma)" ""
expect_eq "a release without a series line counts as 26.7" "$(nr os-alpha FreeBSD:15:amd64/26.7)" "os-alpha-1.1"
publish os-alpha-1.1_1 2026-01-05T00:00:00Z
printf 'Built from here.\n\nseries: 27.1\n\nsha256: %s\n' "$(sum "$STUB/assets/os-alpha-1.1_1/os-alpha-1.1_1.pkg")" >"$STUB/notes/os-alpha-1.1_1"
expect_eq "newest for 27.1" "$(nr os-alpha FreeBSD:15:amd64/27.1)" "os-alpha-1.1_1"
expect_eq "newest for 26.7 skips the 27.1 build" "$(nr os-alpha FreeBSD:15:amd64/26.7)" "os-alpha-1.1"
expect_eq "newest of any series" "$(nr os-alpha)" "os-alpha-1.1_1"
expect_eq "no release for a series" "$(nr os-alpha-extra FreeBSD:15:amd64/27.1)" ""
publish os-alpha-1.1_2 2026-01-06T00:00:00Z
printf 'Built.\n\nabi: FreeBSD:16:amd64\nseries: 27.1\n\nsha256: %s\n' "$(sum "$STUB/assets/os-alpha-1.1_2/os-alpha-1.1_2.pkg")" >"$STUB/notes/os-alpha-1.1_2"
expect_eq "the ABI counts too: a FreeBSD 16 build is not the FreeBSD 15 27.1 build" "$(nr os-alpha FreeBSD:15:amd64/27.1)" "os-alpha-1.1_1"
expect_eq "newest for the FreeBSD 16 entry" "$(nr os-alpha FreeBSD:16:amd64/27.1)" "os-alpha-1.1_2"
expect_eq "from RELEASES_JSON" "$(RELEASES_JSON='[{"tagName":"os-alpha-9.0","publishedAt":"2026-02-01T00:00:00Z"}]' nr os-alpha)" "os-alpha-9.0"
touch "$STUB/fail_list"
expect_fail "release list unreadable" nr os-alpha
rm "$STUB/fail_list"

# --- build-package.sh and sign-catalogue.sh (VM scripts, stub git/make/pkg) --
# a throwaway signing key (the stub pkg signs with the real openssl), and a second
# one the published public key does not match
openssl genrsa -out "$T/key.pem" 2048 2>/dev/null
openssl rsa -in "$T/key.pem" -pubout -out "$T/pub.pem" 2>/dev/null
openssl genrsa -out "$T/other.pem" 2048 2>/dev/null
# vmdir: a fresh workspace like the VM's, with scripts/, $T/packages.conf and the public key
vmdir() {
	W="$T/vm"
	rm -rf "$W"
	mkdir -p "$W/keys" "$W/vendor/v"
	cp -R "$root/scripts" "$W/"
	cp "$T/packages.conf" "$W/packages.conf"
	printf 'ABI=FreeBSD:15:amd64\nSERIES=26.7\nSERVE=FreeBSD:15:amd64/26.7\n' >"$W/repo.conf"
	cp "$T/pub.pem" "$W/keys/legotypes-pkg-signing.pub"
	trust "$T/pub.pem"
}
# trust <pem>: the fingerprint os-legotypes ships, as clients will check it
trust() {
	mkdir -p "$W/vendor/legotypes/src/etc/pkg/fingerprints/LegoTypes/trusted"
	printf 'function: "sha256"\nfingerprint: "%s"\n' "$(sum "$1")" \
		>"$W/vendor/legotypes/src/etc/pkg/fingerprints/LegoTypes/trusted/test.1"
}
# (STUB_PATH: the PATH the stub pkg runs with, sign-catalogue.sh running it with /usr/bin:/bin)
vm() { (cd "$W" && STUB_PATH="${STUB_PATH:-$PATH}" PATH="$root/tests/stub-vm:$PATH" sh "scripts/$1" "${@:2}"); }
# vmenv VAR=value... -- <script> <args>: vm with those variables exported
vmenv() {
	local a=()
	while [[ $1 != -- ]]; do
		a+=("$1")
		shift
	done
	shift
	(
		export "${a[@]}"
		vm "$@"
	)
}
commit=0123456789abcdef0123456789abcdef01234567

conf 'os-alpha   Org/plugins br-alpha net/alpha yes' \
	'os-vendor  .           main     vendor/v  yes'
vmdir
vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-alpha-1.1.pkg -- build-package.sh os-alpha >/dev/null
expect_eq "build: one package in out/" "$(names "$W/out")" "build os-alpha-1.1.pkg source "
expect_eq "build: source line" "$(cat "$W/out/source")" "Built from Org/plugins, branch br-alpha, commit $commit."
expect_eq "build: the build environment" "$(cat "$W/out/build")" \
	$'abi: FreeBSD:15:amd64\nseries: 26.7\nfreebsd: 15.1-RELEASE-p3\nphp: 85\npython: 313'
expect_fail "build: no upstream PHP" vmenv UPSTREAM_PYTHON=313 STUB_PKGS=os-alpha-1.1.pkg -- build-package.sh os-alpha
vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-alpha-1.1.pkg MK_FROM=upstream -- build-package.sh os-alpha >/dev/null
expect_eq "build: with upstream Mk/" "$(cat "$W/out/source")" \
	"Built from Org/plugins, branch br-alpha, commit $commit. Mk/ from opnsense/plugins master $commit."
expect_fail "build: an unknown MK_FROM" vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-alpha-1.1.pkg MK_FROM=elsewhere -- build-package.sh os-alpha
expect_fail "build: a -devel package" vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-alpha-devel-1.1.pkg -- build-package.sh os-alpha
expect_fail "build: two packages" vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 "STUB_PKGS=os-alpha-1.1.pkg os-alpha-1.0.pkg" -- build-package.sh os-alpha
expect_fail "build: no package" vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS= -- build-package.sh os-alpha
expect_fail "build: not in packages.conf" vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-gamma-1.0.pkg -- build-package.sh os-gamma
vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-vendor-1.0_2.pkg GITHUB_REPOSITORY=Org/repo GITHUB_SHA=feedface -- build-package.sh os-vendor >/dev/null
expect_eq "build: this repository's package names the last commit that changed it" "$(cat "$W/out/source")" \
	"Built from Org/repo, vendor/v, commit abcdef0123456789abcdef0123456789abcdef01 (workflow run at feedface), in LegoTypes/plugins master $commit."
expect_fail "build: this repository's package from a shallow checkout" \
	vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-vendor-1.0_2.pkg GITHUB_REPOSITORY=Org/repo GITHUB_SHA=feedface STUB_GIT_SHALLOW=1 -- build-package.sh os-vendor
expect_fail "build: this repository's package without GITHUB_SHA" \
	vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-vendor-1.0_2.pkg GITHUB_REPOSITORY=Org/repo -- build-package.sh os-vendor

# the approved commit (second argument): checked out and reachable from the branch; the stub make
# records its arguments in $W/make.args
ok=$(printf 'a1b2c3d4e5%.0s' 1 2 3 4 | cut -c1-40)
other=$(printf 'f0e1d2c3b4%.0s' 1 2 3 4 | cut -c1-40)
bp() { vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 "STUB_MAKE_ARGS=$W/make.args" "$@"; }
bp STUB_PKGS=os-alpha-1.1.pkg -- build-package.sh os-alpha "$ok" >/dev/null
expect_eq "build commit: the named commit is built" "$(cat "$W/out/source")" "Built from Org/plugins, branch br-alpha, commit $ok."
expect_eq "build commit: a plugin row passes no PLUGIN_HASH" "$(rg -c PLUGIN_HASH "$W/make.args" || echo 0)" "0"
expect_eq "build commit: PLUGIN_DEVEL= is still passed" "$(rg -c -w 'PLUGIN_DEVEL=' "$W/make.args")" "1"
bp STUB_PKGS=os-alpha-1.1.pkg -- build-package.sh os-alpha >/dev/null
expect_eq "build commit: none given builds the branch head" "$(cat "$W/out/source")" "Built from Org/plugins, branch br-alpha, commit $commit."
expect_fail "build commit: not on the branch" bp STUB_PKGS=os-alpha-1.1.pkg STUB_GIT_OFF_BRANCH=1 -- build-package.sh os-alpha "$ok"
expect_fail "build commit: checkout lands elsewhere" bp STUB_PKGS=os-alpha-1.1.pkg "STUB_GIT_CHECKOUT_AS=$other" -- build-package.sh os-alpha "$ok"
expect_fail "build commit: not 40 hex digits" bp STUB_PKGS=os-alpha-1.1.pkg -- build-package.sh os-alpha abc123
expect_fail "build commit: upper case" bp STUB_PKGS=os-alpha-1.1.pkg -- build-package.sh os-alpha "$(echo "$ok" | tr a-f A-F)"
expect_fail "build commit: a third argument" bp STUB_PKGS=os-alpha-1.1.pkg -- build-package.sh os-alpha "$ok" extra
expect_fail "build commit: an empty second argument (never the branch head)" bp STUB_PKGS=os-alpha-1.1.pkg -- build-package.sh os-alpha ""
bp STUB_PKGS=os-vendor-1.0_2.pkg GITHUB_REPOSITORY=Org/repo "GITHUB_SHA=$ok" -- build-package.sh os-vendor "$ok" >/dev/null
expect_eq "build commit: this repository's package passes the 9-digit PLUGIN_HASH" \
	"$(rg -c -w "PLUGIN_HASH=${ok:0:9}" "$W/make.args")" "1"
expect_eq "build commit: this repository's package keeps PLUGIN_DEVEL=" "$(rg -c -w 'PLUGIN_DEVEL=' "$W/make.args")" "1"
bp STUB_PKGS=os-vendor-1.0_2.pkg GITHUB_REPOSITORY=Org/repo "GITHUB_SHA=$ok" -- build-package.sh os-vendor >/dev/null
expect_eq "build commit: this repository's package without a commit passes no PLUGIN_HASH" "$(rg -c PLUGIN_HASH "$W/make.args" || echo 0)" "0"
expect_fail "build commit: this repository's package, commit is not GITHUB_SHA" \
	bp STUB_PKGS=os-vendor-1.0_2.pkg GITHUB_REPOSITORY=Org/repo "GITHUB_SHA=$other" -- build-package.sh os-vendor "$ok"

conf 'os-alpha      Org/plugins br   net/alpha        yes' \
	'os-beta       Org/plugins br   net/beta         no' \
	'os-legotypes  .           main vendor/legotypes yes'
R="site/FreeBSD:15:amd64/26.7/latest"
openssl rsa -in "$T/other.pem" -pubout -out "$T/other.pub" 2>/dev/null
# signdir <carried file...>: out/ holds the built os-legotypes, All/ the carried files
signdir() {
	vmdir
	mkdir -p "$W/out" "$W/$R/All" "$W/.signing"
	echo "built" >"$W/out/os-legotypes-1.0_2.pkg"
	echo "Built from here." >"$W/out/source"
	cp "$T/key.pem" "$W/.signing/key"
	local f
	for f in "$@"; do echo "carried" >"$W/$R/All/$f"; done
}
# sg [VAR=value...]: sign-catalogue.sh as the sign job runs it, with the workflow run's id
run_id=4815162342
sg() { vmenv "GITHUB_RUN_ID=$run_id" "$@" -- sign-catalogue.sh; }
# stamped <tree dir> <public key>: yes if the tree's stamp verifies with the key as os-legotypes
# checks it (the signature over the stamp's sha256 hex, as pkg signs a catalogue file), else no
stamped() {
	if openssl dgst -sha256 -r "$1/stamp" | cut -d' ' -f1 | tr -d '\n' |
		openssl dgst -sha256 -verify "$2" -signature "$1/stamp.sig" >/dev/null 2>&1; then
		echo yes
	else
		echo no
	fi
}
# fields <stamp>: the stamp with its date replaced by <UTC> if it is a UTC ISO-8601 time
fields() {
	sed 's/^published: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}Z$/published: <UTC>/' "$1"
}
exists() { if [[ -e $1 ]]; then echo yes; else echo no; fi; }
# norun <command...>: the command with GITHUB_RUN_ID unset (a workflow run sets it)
norun() { (
	unset GITHUB_RUN_ID
	"$@"
); }
signdir os-alpha-1.1.pkg
sg >/dev/null
expect_eq "sign: catalogue written" "$(cat "$W/$R/meta.conf")" "version = 2;"
bsdtar -xf "$W/$R/data.pkg" -C "$T" data.sig
expect_eq "sign: signature not empty" "$([[ -s $T/data.sig ]] && echo yes)" "yes"
expect_eq "sign: the site root serves no bootstrap package" "$(exists "$W/site/os-legotypes.pkg")" "no"
expect_eq "sign: public key published" "$(cat "$W/site/legotypes-pkg-signing.pub")" "$(cat "$T/pub.pem")"
expect_eq "sign: packages.txt names both" "$(grep '^Name' "$W/site/packages.txt" | tr '\n' ' ')" \
	"Name : os-alpha-1.1 Name : os-legotypes-1.0_2 "
expect_eq "sign: the tree has its own packages.txt" "$(cat "$W/$R/packages.txt")" "$(cat "$W/site/packages.txt")"
expect_eq "sign: key removed" "$(names "$W/.signing")" "* "
expect_eq "sign: the stamp names the time, the run and the tree" "$(fields "$W/$R/stamp")" \
	$'published: <UTC>\nrun: 4815162342\ntree: FreeBSD:15:amd64/26.7'
expect_eq "sign: the stamp's key is the published key" "$(cat "$W/$R/stamp.pub")" "$(cat "$T/pub.pem")"
expect_eq "sign: the stamp verifies with the published key" "$(stamped "$W/$R" "$T/pub.pem")" "yes"
expect_eq "sign: the stamp does not verify with another key" "$(stamped "$W/$R" "$T/other.pub")" "no"
mkdir -p "$T/forged"
cp "$W/$R/stamp.sig" "$T/forged/"
sed 's/^published: .*/published: 2099-01-01T00:00:00Z/' "$W/$R/stamp" >"$T/forged/stamp"
expect_eq "sign: a stamp given another date does not verify" "$(stamped "$T/forged" "$T/pub.pem")" "no"
printf 'published: %s\nrun: %s\ntree: %s\n' "$(sed -n 's/^published: //p' "$W/$R/stamp")" "$run_id" \
	FreeBSD:15:amd64/26.7 >"$T/stamp.expected"
expect_eq "sign: the stamp is exactly three LF-terminated lines" \
	"$(cmp -s "$W/$R/stamp" "$T/stamp.expected" && echo same) $(wc -l <"$W/$R/stamp" | tr -d ' ')" "same 3"
# nothing published holds the private key, inside the catalogue archives either, and
# .signing/ is left empty, dot files included
expect_eq "sign: no file under site/ holds a private key" "$(grep -rl 'PRIVATE KEY' "$W/site" "$W/out")" ""
# keyscan: "<n> <hits>", the catalogue archives (data.pkg, packagesite.pkg) of every tree under
# $W/site and how many of them hold a private key
keyscan() {
	local a n=0 hits=0
	for a in "$W"/site/*/*/latest/data.pkg "$W"/site/*/*/latest/packagesite.pkg; do
		[[ -f $a ]] || continue
		n=$((n + 1))
		if bsdtar -xOf "$a" | grep -q 'PRIVATE KEY'; then hits=$((hits + 1)); fi
	done
	echo "$n $hits"
}
expect_eq "sign: no catalogue archive holds a private key" "$(keyscan)" "2 0"
expect_eq "sign: .signing/ holds nothing afterwards" "$(ls -A "$W/.signing")" ""
# the tools are the system's: an openssl, bsdtar or coreutils earlier on PATH (on the runner
# /usr/local/bin comes first) is never run; only pkg comes from PATH or PKG=
mkdir -p "$T/evil"
for t in openssl bsdtar cut tr grep cmp head tail wc date mktemp cp cat rm ls mkdir; do
	# shellcheck disable=SC2016 # $EVIL_RAN belongs to the decoy
	printf '#!/bin/sh\necho %s >>"$EVIL_RAN"\nexit 1\n' "$t" >"$T/evil/$t"
	chmod +x "$T/evil/$t"
done
signdir os-alpha-1.1.pkg
rm -f "$T/evil.ran"
sg "STUB_PATH=$PATH" "PATH=$T/evil:$PATH" "EVIL_RAN=$T/evil.ran" >/dev/null 2>&1
expect_eq "sign: no tool from earlier on PATH is run" "$(sort -u "$T/evil.ran" 2>/dev/null | tr '\n' ' ')" ""
expect_eq "sign: signed with the system's tools" "$(stamped "$W/$R" "$T/pub.pem")" "yes"
# the published key, the trusted fingerprints, repo.conf and packages.conf are the script's own
# checkout's, never the working directory's (which holds only out/, .signing/ and site/): a working
# directory with another key and a fingerprint for it changes nothing
signdir os-alpha-1.1.pkg
rm -rf "$T/wd"
cp -R "$W" "$T/wd"
cp "$T/other.pub" "$T/wd/keys/legotypes-pkg-signing.pub"
printf 'function: "sha256"\nfingerprint: "%s"\n' "$(sum "$T/other.pub")" \
	>"$T/wd/vendor/legotypes/src/etc/pkg/fingerprints/LegoTypes/trusted/test.1"
(cd "$T/wd" && STUB_PATH="$PATH" PATH="$root/tests/stub-vm:$PATH" GITHUB_RUN_ID=$run_id sh "$W/scripts/sign-catalogue.sh") \
	>/dev/null 2>&1
expect_eq "sign: from another working directory, the key published is the script's checkout's" \
	"$(cat "$T/wd/site/legotypes-pkg-signing.pub" 2>/dev/null)" "$(cat "$T/pub.pem")"
expect_eq "sign: from another working directory, the stamp verifies with the script's checkout's key" \
	"$(stamped "$T/wd/$R" "$T/pub.pem")" "yes"
signdir os-alpha-1.1.pkg
rm -rf "$T/wd"
cp -R "$W" "$T/wd"
cp "$T/other.pub" "$W/keys/legotypes-pkg-signing.pub"
expect_fail "sign: the script's own checkout's key decides, not the working directory's" \
	sh -c 'cd "$1" && STUB_PATH="$PATH" PATH="$2:$PATH" GITHUB_RUN_ID=1 sh "$3/scripts/sign-catalogue.sh"' _ \
	"$T/wd" "$root/tests/stub-vm" "$W"
signdir os-alpha-1.1.pkg
rm -rf "$T/it's a checkout"
cp -R "$W" "$T/it's a checkout"
(cd "$T/it's a checkout" && STUB_PATH="$PATH" PATH="$root/tests/stub-vm:$PATH" GITHUB_RUN_ID=$run_id \
	sh "$T/it's a checkout/scripts/sign-catalogue.sh") >/dev/null 2>&1
expect_eq "sign: a checkout whose path holds a quote and a space" "$(stamped "$T/it's a checkout/$R" "$T/pub.pem")" "yes"
sign_here='here=$(dirname "$0")'
sign_pub='PUB=$here/../keys/legotypes-pkg-signing.pub'
sign_trusted='TRUSTED=$here/../vendor/legotypes/src/etc/pkg/fingerprints/LegoTypes/trusted'
expect_eq "sign-catalogue.sh: the script's location, one literal line, no override" \
	"$(anchor "$root/scripts/sign-catalogue.sh" here "$sign_here")" "1 1"
expect_eq "sign-catalogue.sh: the published key from the script's location, one literal line, no override" \
	"$(anchor "$root/scripts/sign-catalogue.sh" PUB "$sign_pub")" "1 1"
expect_eq "sign-catalogue.sh: the trusted fingerprints from the script's location, one literal line, no override" \
	"$(anchor "$root/scripts/sign-catalogue.sh" TRUSTED "$sign_trusted")" "1 1"
# shellcheck disable=SC2016 # the patterns name the script's own text
expect_eq "sign-catalogue.sh: repo.sh and packages.sh from the script's location" \
	"$(grep -c 'sh scripts/' "$root/scripts/sign-catalogue.sh") $(grep -c 'sh "$here/\(repo\|packages\)\.sh"' "$root/scripts/sign-catalogue.sh")" "0 5"
# the signing command signs only a sha256 digest: 64 lowercase hex digits, else it answers nothing
for feed in hello "" "$(printf 'A%.0s' {1..64})" "$(printf 'a%.0s' {1..63})" "$(printf 'a%.0s' {1..65})" \
	"$(printf 'a%.0s' {1..64}) " "$(printf 'g%.0s' {1..64})"; do
	signdir os-alpha-1.1.pkg
	rm -f "$T/reply"
	expect_fail "sign: the signing command refuses [$feed]" sg "STUB_PKG_FEED=$feed" "STUB_PKG_REPLY=$T/reply"
	expect_eq "sign: no signature for [$feed]" "$([[ -f $T/reply && ! -s $T/reply ]] && echo empty)" "empty"
done
signdir os-alpha-1.1.pkg
rm -f "$T/reply"
sg "STUB_PKG_FEED=$(printf '0123456789abcdef%.0s' 1 2 3 4)" "STUB_PKG_REPLY=$T/reply" >/dev/null 2>&1
expect_eq "sign: the signing command signs a digest" "$(head -n 1 "$T/reply" 2>/dev/null)" "SIGNATURE"
# a signing reply pkg cannot read (it stops before END): pkg fails, so the signing fails, the key is
# removed and nothing is published
signdir os-alpha-1.1.pkg
if err=$(sg STUB_PKG_TRUNCATE=1 2>&1 >/dev/null); then bad "sign: a malformed signing reply: expected failure"; else ok; fi
expect_eq "sign: pkg refused the malformed signing reply" "$(grep -c 'stub pkg: malformed signing reply' <<<"$err")" 1
expect_eq "sign: nothing published after a malformed reply, and the key removed" \
	"$(exists "$W/site/legotypes-pkg-signing.pub") $(exists "$W/$R/stamp") [$(ls -A "$W/.signing")]" "no no []"
# a cancelled job: TERM reaches the shell while pkg runs, then pkg; the key is removed all the same.
# The stand-in pkg sleeps in place (its pid in $T/blocked) until it is killed: the test waits at most
# 10 s for it, says so if it never came, and leaves nothing running
signdir os-alpha-1.1.pkg
rm -f "$T/blocked"
(cd "$W" && exec env STUB_PATH="$PATH" PATH="$root/tests/stub-vm:$PATH" "GITHUB_RUN_ID=$run_id" \
	"STUB_PKG_BLOCK=$T/blocked" sh scripts/sign-catalogue.sh) >/dev/null 2>&1 &
scpid=$!
started=no
for _ in $(seq 100); do
	if [[ -s $T/blocked ]]; then
		started=yes
		break
	fi
	sleep 0.1
done
expect_eq "sign: the cancelled run reached pkg within 10 s" "$started" yes
kill -TERM "$scpid" 2>/dev/null
sleep 0.3
blocked=$(cat "$T/blocked" 2>/dev/null)
[[ -z $blocked ]] || kill -TERM "$blocked" 2>/dev/null
wait "$scpid" && cancelled=completed || cancelled=failed
expect_eq "sign: a cancelled run fails" "$cancelled" "failed"
expect_eq "sign: key removed after a cancellation" "$(ls -A "$W/.signing")" ""
lingering=no
if [[ -n $blocked ]]; then
	for _ in $(seq 50); do
		kill -0 "$blocked" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$blocked" 2>/dev/null; then
		lingering=yes
		kill -KILL "$blocked" 2>/dev/null
	fi
fi
expect_eq "sign: nothing of the cancelled run is left running" "$lingering" no
signdir os-alpha-1.1.pkg os-beta-9.0.pkg
expect_fail "sign: a release-only package in the catalogue" sg
expect_eq "sign: key removed after a failure" "$(names "$W/.signing")" "* "
signdir
expect_fail "sign: a catalogue package missing" sg
signdir os-alpha-1.1.pkg os-alpha-1.0.pkg
expect_fail "sign: two versions of one package" sg
signdir os-alpha-1.1.pkg
rm "$W/.signing/key"
expect_fail "sign: no key" sg
signdir os-alpha-1.1.pkg
echo >"$W/.signing/key"
expect_fail "sign: an empty key (the secret did not arrive)" sg
expect_eq "sign: nothing published after a failed signing" \
	"$(exists "$W/site/legotypes-pkg-signing.pub") $(exists "$W/$R/stamp")" "no no"
signdir os-alpha-1.1.pkg
cp "$T/other.pem" "$W/.signing/key"
expect_fail "sign: a key the published public key does not match" sg
expect_eq "sign: key removed after a mismatch" "$(names "$W/.signing")" "* "
expect_eq "sign: no stamp after a mismatch" "$(exists "$W/$R/stamp")" "no"
signdir os-alpha-1.1.pkg
trust "$T/other.pub"
expect_fail "sign: a key os-legotypes does not trust (a half-done rotation)" sg
expect_eq "sign: nothing published for an untrusted key" \
	"$(exists "$W/site/legotypes-pkg-signing.pub") $(exists "$W/$R/meta.conf") $(exists "$W/$R/stamp")" "no no no"
# the run id: required and a number, checked before anything is signed
signdir os-alpha-1.1.pkg
expect_fail "sign: GITHUB_RUN_ID unset" norun vm sign-catalogue.sh
expect_eq "sign: nothing signed without a run id" "$(exists "$W/$R/meta.conf") $(exists "$W/$R/stamp")" "no no"
expect_eq "sign: key removed without a run id" "$(names "$W/.signing")" "* "
signdir os-alpha-1.1.pkg
expect_fail "sign: GITHUB_RUN_ID empty" vmenv GITHUB_RUN_ID= -- sign-catalogue.sh
expect_eq "sign: nothing signed with an empty run id" "$(exists "$W/$R/meta.conf")" "no"
signdir os-alpha-1.1.pkg
expect_fail "sign: a run id that is not a number cannot add a line to the stamp" \
	vmenv $'GITHUB_RUN_ID=1\ntree: FreeBSD:15:amd64/26.1' -- sign-catalogue.sh
expect_eq "sign: nothing signed with a malformed run id" "$(exists "$W/$R/meta.conf")" "no"
# PKG=: the pkg the sign job built (pkg-tool.sh); the stub on PATH refuses to run while STUB_PKG_REFUSE is set
mkdir -p "$T/pkgtool/sbin"
# shellcheck disable=SC2016 # $1 and $@ belong to the wrapper
printf '#!/bin/sh\necho "$1" >>"%s"\nSTUB_PKG_REFUSE= exec "%s" "$@"\n' "$T/pkgtool/calls" "$root/tests/stub-vm/pkg" \
	>"$T/pkgtool/sbin/pkg"
chmod +x "$T/pkgtool/sbin/pkg"
signdir os-alpha-1.1.pkg
rm -f "$T/pkgtool/calls"
expect_fail "sign: the stub pkg on PATH refuses while STUB_PKG_REFUSE is set" sg STUB_PKG_REFUSE=1
signdir os-alpha-1.1.pkg
rm -f "$T/pkgtool/calls"
sg "PKG=$T/pkgtool/sbin/pkg" STUB_PKG_REFUSE=1 >/dev/null
expect_eq "sign: PKG= is the pkg that signs and lists the catalogue" "$(sort -u "$T/pkgtool/calls" | tr '\n' ' ')" "info repo "
expect_eq "sign: signed with PKG=" "$(stamped "$W/$R" "$T/pub.pem") $(cat "$W/$R/meta.conf")" "yes version = 2;"
signdir os-alpha-1.1.pkg
expect_fail "sign: a PKG= that is not there" sg "PKG=$T/pkgtool/sbin/none"
cp "$T/pkgtool/sbin/pkg" "$T/pkgtool/sbin/pkg.noexec"
chmod 644 "$T/pkgtool/sbin/pkg.noexec"
expect_fail "sign: a PKG= that is not executable" sg "PKG=$T/pkgtool/sbin/pkg.noexec"
expect_eq "sign: nothing signed without a pkg" "$(exists "$W/$R/meta.conf") $(names "$W/.signing")" "no * "
signdir os-alpha-1.1.pkg
printf 'ABI=FreeBSD:15:amd64\nSERIES=26.7\nSERVE=FreeBSD:15:amd64/26.1 FreeBSD:15:amd64/26.7\n' >"$W/repo.conf"
mkdir -p "$W/site/FreeBSD:15:amd64/26.1/latest/All"
echo "old" >"$W/site/FreeBSD:15:amd64/26.1/latest/All/os-alpha-1.0.pkg"
sg >/dev/null
expect_eq "sign: a frozen tree is signed too" "$(cat "$W/site/FreeBSD:15:amd64/26.1/latest/meta.conf" 2>/dev/null)" "version = 2;"
expect_eq "sign: a frozen tree may lack a package" "$(grep -c '^Name' "$W/site/FreeBSD:15:amd64/26.1/latest/packages.txt" 2>/dev/null)" "1"
expect_eq "sign: a frozen tree has its own stamp" "$(fields "$W/site/FreeBSD:15:amd64/26.1/latest/stamp" 2>/dev/null)" \
	$'published: <UTC>\nrun: 4815162342\ntree: FreeBSD:15:amd64/26.1'
expect_eq "sign: the frozen tree's stamp verifies" "$(stamped "$W/site/FreeBSD:15:amd64/26.1/latest" "$T/pub.pem")" "yes"
expect_eq "sign: one publication time for every tree" "$(sed -n 1p "$W/$R/stamp")" \
	"$(sed -n 1p "$W/site/FreeBSD:15:amd64/26.1/latest/stamp" 2>/dev/null)"
expect_eq "sign: no archive of either tree holds a private key" "$(keyscan)" "4 0"
expect_eq "sign: no file of either tree holds a private key" "$(grep -rl 'PRIVATE KEY' "$W/site" "$W/out")" ""
signdir
printf 'ABI=FreeBSD:15:amd64\nSERIES=26.7\nSERVE=FreeBSD:15:amd64/26.1 FreeBSD:15:amd64/26.7\n' >"$W/repo.conf"
mkdir -p "$W/site/FreeBSD:15:amd64/26.1/latest/All"
echo "old" >"$W/site/FreeBSD:15:amd64/26.1/latest/All/os-alpha-1.0.pkg"
expect_eq "sign: the first publish into a new series signs a target tree holding only the built package" \
	"$(sg >/dev/null 2>&1; echo "rc=$?")" "rc=0"
signdir
expect_fail "sign: with one series served, every catalogue package is still required" sg
signdir os-alpha-1.1.pkg
printf 'ABI=FreeBSD:15:amd64\nSERIES=26.7\nSERVE=FreeBSD:15:amd64/26.1 FreeBSD:15:amd64/26.7\n' >"$W/repo.conf"
mkdir -p "$W/site/FreeBSD:15:amd64/26.1/latest/All"
echo "old" >"$W/site/FreeBSD:15:amd64/26.1/latest/All/os-alpha-1.0.pkg"
sg >/dev/null
expect_eq "sign: the root keeps the target tree" "$(grep '^Name' "$W/site/packages.txt" | tr '\n' ' ')" \
	"Name : os-alpha-1.1 Name : os-legotypes-1.0_2 "

# --- upstream.sh (stub curl serves a fake mirror) -----------------------------
# mirror <series...>: a fake OPNsense mirror with those series under FreeBSD:15:amd64; the root
# index links ABI directories as Apache does for names with a colon ("./FreeBSD:15:amd64/")
mirror() {
	export STUB_MIRROR="$T/mirror" STUB_MIRROR_URL=https://mirror.test UPSTREAM_MIRROR=https://mirror.test
	rm -rf "$STUB_MIRROR"
	mkdir -p "$STUB_MIRROR/FreeBSD:15:amd64"
	printf '<a href="./FreeBSD:14:amd64/">FreeBSD:14:amd64/</a>\n<a href="./FreeBSD:15:amd64/">FreeBSD:15:amd64/</a>\n<a href="sets/">sets/</a>\n' \
		>"$STUB_MIRROR/index.html"
	local s
	printf '<a href="snapshots/">snapshots/</a>\n' >"$STUB_MIRROR/FreeBSD:15:amd64/index.html"
	for s in "$@"; do
		printf '<a href="%s/">%s/</a>\n' "$s" "$s" >>"$STUB_MIRROR/FreeBSD:15:amd64/index.html"
		mkdir -p "$STUB_MIRROR/FreeBSD:15:amd64/$s/latest"
	done
}
# site <series> <json line...>: that series' catalogue (packagesite.pkg holding packagesite.yaml,
# and its .sig and .pub made as pkg makes them: the signature over the file's sha256 hex, by the test key)
site() {
	local s=$1 d
	shift
	d=$(mktemp -d)
	printf '%s\n' "$@" >"$d/packagesite.yaml"
	openssl dgst -sha256 -r "$d/packagesite.yaml" | cut -d' ' -f1 | tr -d '\n' |
		openssl dgst -sha256 -sign "$T/key.pem" -out "$d/packagesite.yaml.sig"
	cp "$T/pub.pem" "$d/packagesite.yaml.pub"
	tar -cf "$STUB_MIRROR/FreeBSD:15:amd64/$s/latest/packagesite.pkg" -C "$d" packagesite.yaml.sig packagesite.yaml.pub packagesite.yaml
	rm -rf "$d"
}
core() { # core <version> <FreeBSD_version> <dependency names...>
	local v=$1 f=$2
	shift 2
	jq -cn --arg v "$v" --arg f "$f" --args '{name: "opnsense", version: $v,
		annotations: {FreeBSD_version: $f}, deps: ($ARGS.positional | map({key: ., value: {}}) | from_entries)}' "$@"
}
# the harness runs a copy of upstream.sh with its fingerprint directory (the one line that
# names it) substituted: the production script honours no environment override of it
mkdir -p "$T/upcopy/scripts" "$T/upfp"
cp "$S/repo.sh" "$T/upcopy/scripts/"
sed "s|^keys=.*|keys=$T/upfp|" "$root/scripts/upstream.sh" >"$T/upcopy/scripts/upstream.sh"
printf 'function: "sha256"\nfingerprint: "%s"\n' "$(openssl dgst -sha256 -r "$T/pub.pem" | cut -d' ' -f1)" >"$T/upfp/test"
up() { bash "$T/upcopy/scripts/upstream.sh" "$@"; }
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
mirror 26.1 26.7
site 26.7 "$(core 26.7.5 1501000 php85-curl php85-xml py313-requests pkg)" '{"name":"php85","version":"8.5.10"}'
expect_eq "upstream facts" "$(up)" $'NEWEST=26.7\nNEXT_ABI=\nSERIES=26.7\nCORE=26.7.5\nPHP=85\nPYTHON=313\nFREEBSD=15.1'
mirror 26.7 27.1
site 26.7 "$(core 26.7.9 1501000 php85-curl py313-requests)"
site 27.1 "$(core 27.1 1502000 php86-curl py314-requests)"
expect_eq "newest series beside the target's facts" "$(up | grep -E '^(NEWEST|SERIES|PHP)=')" $'NEWEST=27.1\nSERIES=26.7\nPHP=85'
expect_eq "facts for a named series" "$(up 27.1 | grep -E '^(SERIES|PHP|PYTHON|FREEBSD)=')" $'SERIES=27.1\nPHP=86\nPYTHON=314\nFREEBSD=15.2'
printf '<a href="./FreeBSD:16:amd64/">FreeBSD:16:amd64/</a>\n' >>"$STUB_MIRROR/index.html"
mkdir -p "$STUB_MIRROR/FreeBSD:16:amd64"
printf '<a href="snapshots/">snapshots/</a>\n' >"$STUB_MIRROR/FreeBSD:16:amd64/index.html"
expect_eq "a next FreeBSD major with only snapshots is not reported yet" "$(up | grep '^NEXT_ABI=')" "NEXT_ABI="
printf '<a href="27.7/">27.7/</a>\n' >>"$STUB_MIRROR/FreeBSD:16:amd64/index.html"
expect_eq "next FreeBSD major" "$(up | grep '^NEXT_ABI=')" "NEXT_ABI=FreeBSD:16:amd64"
mirror 26.7
expect_fail "target series without a catalogue" up
site 26.7 "$(core 26.7.5 1501000 php84-curl php85-xml py313-requests)"
expect_fail "core naming two PHP versions" up
site 26.7 '{"name":"php85","version":"8.5.10"}'
expect_fail "no core package" up
site 26.7 "$(core 26.7.5 1501000 php85-curl)"
expect_fail "core naming no Python" up
mirror 26.7
printf '<a href="sets/">sets/</a>\n' >"$STUB_MIRROR/index.html"
expect_fail "mirror without our ABI" up
rm -rf "$STUB_MIRROR"
expect_fail "mirror unreachable" up

# the catalogue's signature: signed by the test key (above) passes; everything else fails closed
mirror 26.7
site 26.7 "$(core 26.7.5 1501000 php85-curl py313-requests)"
expect_eq "upstream: a catalogue signed by a trusted key" "$(up | grep '^CORE=')" "CORE=26.7.5"
pk_dir="$T/upsite"
repack() { # repack <member to leave out>: the catalogue again without that member
	rm -rf "$pk_dir"
	mkdir -p "$pk_dir"
	tar -xf "$STUB_MIRROR/FreeBSD:15:amd64/26.7/latest/packagesite.pkg" -C "$pk_dir"
	[[ -z ${1:-} ]] || rm "$pk_dir/$1"
	(cd "$pk_dir" && tar -cf "$STUB_MIRROR/FreeBSD:15:amd64/26.7/latest/packagesite.pkg" packagesite.yaml*)
}
repack packagesite.yaml.sig
expect_fail "upstream: no signature" up
site 26.7 "$(core 26.7.5 1501000 php85-curl py313-requests)"
repack packagesite.yaml.pub
expect_fail "upstream: no key" up
site 26.7 "$(core 26.7.5 1501000 php85-curl py313-requests)"
repack
sed -i.bak 's/26\.7\.5/26.7.6/' "$pk_dir/packagesite.yaml"
(cd "$pk_dir" && tar -cf "$STUB_MIRROR/FreeBSD:15:amd64/26.7/latest/packagesite.pkg" packagesite.yaml.sig packagesite.yaml.pub packagesite.yaml)
expect_fail "upstream: tampered catalogue" up
site 26.7 "$(core 26.7.5 1501000 php85-curl py313-requests)"
repack
openssl rsa -in "$T/other.pem" -pubout -out "$pk_dir/packagesite.yaml.pub" 2>/dev/null
openssl dgst -sha256 -r "$pk_dir/packagesite.yaml" | cut -d' ' -f1 | tr -d '\n' |
	openssl dgst -sha256 -sign "$T/other.pem" -out "$pk_dir/packagesite.yaml.sig"
(cd "$pk_dir" && tar -cf "$STUB_MIRROR/FreeBSD:15:amd64/26.7/latest/packagesite.pkg" packagesite.yaml.sig packagesite.yaml.pub packagesite.yaml)
expect_fail "upstream: signed by a key that is no trusted fingerprint" up
site 26.7 "$(core 26.7.5 1501000 php85-curl py313-requests)"
repack
openssl dgst -sha256 -r "$pk_dir/packagesite.yaml" | cut -d' ' -f1 | tr -d '\n' |
	openssl dgst -sha256 -sign "$T/other.pem" -out "$pk_dir/packagesite.yaml.sig"
(cd "$pk_dir" && tar -cf "$STUB_MIRROR/FreeBSD:15:amd64/26.7/latest/packagesite.pkg" packagesite.yaml.sig packagesite.yaml.pub packagesite.yaml)
expect_fail "upstream: a trusted key with another key's signature" up
site 26.7 "$(core 26.7.5 1501000 php85-curl py313-requests)"
rm "$T/upfp/test"
expect_fail "upstream: no fingerprint file" up
: >"$T/upfp/test"
expect_fail "upstream: an empty fingerprint file" up
rm -rf "$T/upfp"
expect_fail "upstream: no fingerprint directory" up
# every keys= in the script (any indentation, any condition) must be the one literal line
keyline() { echo "$(grep -o 'keys=' "$1" | wc -l | tr -d ' ') $(grep -c '^keys="\$here/../keys/upstream"$' "$1")"; }
expect_eq "upstream: the production script's key directory is one literal line, no override" "$(keyline "$root/scripts/upstream.sh")" "1 1"
{ cat "$root/scripts/upstream.sh"; echo '[[ -n ${X:-} ]] && keys=$X'; } >"$T/mutant.sh"
expect_eq "upstream: the static check rejects an override" "$(keyline "$T/mutant.sh")" "2 1"
sed 's|^keys=.*|[[ -n ${X:-} ]] \&\& keys=$X; keys="$here/../keys/upstream"|' "$root/scripts/upstream.sh" >"$T/mutant.sh"
expect_eq "upstream: the static check rejects a conditional on the literal line" "$(keyline "$T/mutant.sh")" "2 0"
# a match in the first of two fingerprint files, the second large: no SIGPIPE-driven failure
mkdir -p "$T/upfp"
printf 'function: "sha256"\nfingerprint: "%s"\n' "$(openssl dgst -sha256 -r "$T/pub.pem" | cut -d' ' -f1)" >"$T/upfp/a"
head -c 3000000 /dev/zero | tr '\0' 'x' >"$T/upfp/b"
site 26.7 "$(core 26.7.5 1501000 php85-curl py313-requests)"
expect_eq "upstream: a match in the first of two fingerprint files" "$(up | grep '^CORE=')" "CORE=26.7.5"
expect_eq "upstream: the vendored OPNsense fingerprint" "$(cat "$root"/keys/upstream/pkg.opnsense.org.20260608)" \
	$'function: "sha256"\nfingerprint: "9f3b76ffef38fb6405595038b324b61043c9a2c375ae5c151d628508e9a845ce"'
unset STUB_MIRROR STUB_MIRROR_URL UPSTREAM_MIRROR

# --- compare-package.sh -------------------------------------------------------
mkpkg() { # mkpkg <file> <+MANIFEST json> [<path> <content>]...: a package with its manifest and those files
	local d out=$1 m=$2
	shift 2
	d=$(mktemp -d)
	printf '%s' "$m" >"$d/+MANIFEST"
	local names=(+MANIFEST)
	while [[ $# -ge 2 ]]; do
		mkdir -p "$d/$(dirname "${1#/}")"
		printf '%s' "$2" >"$d/${1#/}"
		names+=("${1#/}")
		shift 2
	done
	tar -cf "$out" -C "$d" "${names[@]}"
	rm -rf "$d"
}
base='{"name":"os-alpha","abi":"FreeBSD:15:amd64","arch":"freebsd:15:x86:64","flatsize":10,
 "annotations":{"product_abi":"26.7","FreeBSD_version":"1500068","product_hash":"aaaaaaa"},
 "scripts":{"post-install":"echo hi"},
 "files":{"/usr/local/a":{"sum":"1$x","perm":"0644","mtime":1},"/usr/local/b":{"sum":"1$y","perm":"0755","mtime":1}}}'
mod() { jq -c "$@" <<<"$base"; }
cmpk() { bash "$root/scripts/compare-package.sh" "$T/a.pkg" "$T/b.pkg"; echo "rc=$?"; }
mkpkg "$T/a.pkg" "$base"
mkpkg "$T/b.pkg" "$(mod '.annotations.product_hash = "bbbbbbb" | .annotations.FreeBSD_version = "1501000" | .flatsize = 99 | .files["/usr/local/a"].mtime = 9')"
expect_eq "compare: commit, FreeBSD minor, flatsize and mtimes are not material" "$(cmpk)" "rc=0"
mkpkg "$T/b.pkg" "$(mod '.annotations.product_abi = "27.1"')"
expect_eq "compare: series" "$(cmpk)" $'product_abi: "26.7" -> "27.1"\nrc=1'
mkpkg "$T/b.pkg" "$(mod '.annotations.FreeBSD_version = "1600010" | .abi = "FreeBSD:16:amd64"')"
expect_eq "compare: FreeBSD major and ABI" "$(cmpk)" $'abi: "FreeBSD:15:amd64" -> "FreeBSD:16:amd64"\nfreebsd_major: 15 -> 16\nrc=1'
mkpkg "$T/b.pkg" "$(mod '.deps = {"php86":{"origin":"lang/php86","version":"8.6.0"}}')"
expect_eq "compare: a dependency appears" "$(cmpk)" $'deps: [] -> ["php86"]\nrc=1'
mkpkg "$T/b.pkg" "$(mod '.scripts["post-install"] = "echo bye" | .scripts["pre-deinstall"] = "x"')"
expect_eq "compare: scripts" "$(cmpk)" $'script post-install: changed\nscript pre-deinstall: added\nrc=1'
mkpkg "$T/b.pkg" "$(mod '.files["/usr/local/a"].perm = "0755" | .files["/usr/local/b"].sum = "1$z" | .files["/usr/local/c"] = {"sum":"1$c","perm":"0644"}')"
expect_eq "compare: files" "$(cmpk)" $'file /usr/local/a: mode 0644 -> 0755\nfile /usr/local/b: content changed\nfile /usr/local/c: added\nrc=1'
vf='/usr/local/opnsense/version/alpha'
vj() { printf '{"product_hash": "%s", "product_version": "%s"}' "$1" "$2"; }
mkpkg "$T/a.pkg" "$(mod --arg f "$vf" '.files[$f] = {"sum":"1$v1","perm":"0644"}')" "$vf" "$(vj aaaaaaa 1.0)"
mkpkg "$T/b.pkg" "$(mod --arg f "$vf" '.files[$f] = {"sum":"1$v2","perm":"0644"}')" "$vf" "$(vj bbbbbbb 1.0)"
expect_eq "compare: a version file differing only in its commit hash is not material" "$(cmpk)" "rc=0"
mkpkg "$T/b.pkg" "$(mod --arg f "$vf" '.files[$f] = {"sum":"1$v3","perm":"0644"}')" "$vf" "$(vj bbbbbbb 1.1)"
expect_eq "compare: a version file differing otherwise is" "$(cmpk)" $'file /usr/local/opnsense/version/alpha: content changed\nrc=1'
expect_eq "compare: not a package" "$(bash "$root/scripts/compare-package.sh" "$T/repo.conf" "$T/a.pkg" 2>/dev/null; echo "rc=$?")" "rc=2"

# --- verify-payload.sh -------------------------------------------------------------
# A synthetic plugin, net/alpha at $commit, and (written out by hand, not derived) what
# Mk/plugins.mk install makes of it: .in substituted, .shadow as .sample, both for .shadow.in,
# man/ gzipped, modes kept, top-level dot files and symlinks left out, the version file added.
umask 022 # the build VM's: staged files are 0644 or 0755
vp="$T/vp"
vs="$vp/net/alpha/src"
vu="$vp/stage/usr/local"
vhash=${commit:0:9}
vdef=($'PLUGIN_NAME=\t\talpha' $'PLUGIN_VERSION=\t\t1.0' $'PLUGIN_COMMENT=\t\tAlpha' \
	$'PLUGIN_MAINTAINER=\tmaintainer@example.org' $'PLUGIN_WWW=\t\thttps://example.org/alpha/')
vmk() { # vmk <line>...: net/alpha's Makefile, those lines and then the plugins.mk include
	{
		printf '%s\n' "$@"
		printf '\n.include "../../Mk/plugins.mk"\n'
	} >"$vp/net/alpha/Makefile"
}
vsrc() {
	rm -rf "$vp"
	mkdir -p "$vs/opnsense/scripts/Alpha" "$vs/opnsense/mvc/app/views/Alpha" "$vs/etc/pkg/repos" "$vs/man/man8"
	vmk "${vdef[@]}"
	printf '#!/usr/local/bin/python3\nprint("alpha")\n' >"$vs/opnsense/scripts/Alpha/run.py"
	chmod 755 "$vs/opnsense/scripts/Alpha/run.py"
	printf '<h1>alpha</h1>\n' >"$vs/opnsense/mvc/app/views/Alpha/index.volt"
	: >"$vs/opnsense/.placeholder"
	printf 'not installed\n' >"$vs/.hidden"
	ln -s scripts "$vs/opnsense/link"
	printf '%s\n' 'alpha %%PLUGIN_PKGVERSION%% %%PLUGIN_HASH%% %%PLUGIN_NAME%%%%PLUGIN_VARIANT%% %%PLUGIN_UNKNOWN%%' >"$vs/etc/alpha.conf.in"
	printf 'shadowed\n' >"$vs/etc/alpha.conf.shadow"
	printf '%s\n' 'url: %%PLUGIN_WWW%%' >"$vs/etc/pkg/repos/Alpha.conf.shadow.in"
	printf '.Dd October 1, 2026\n.Nm alpha\n' >"$vs/man/man8/alpha.8"
	printf 'Alpha\n' >"$vp/net/alpha/pkg-descr"
}
vver() { # vver [<jq filter>]: the version file Templates/version renders for net/alpha
	jq -n --arg h "$vhash" '{product_abi: "26.7", product_arch: "amd64", product_conflicts: "os-alpha-devel",
		product_email: "maintainer@example.org", product_hash: $h, product_id: "os-alpha", product_name: "alpha",
		product_tier: "3", product_version: "1.0", product_website: "https://example.org/alpha/"}' | jq "${1:-.}"
}
vstage() {
	rm -rf "$vp/stage"
	mkdir -p "$vu/opnsense/scripts/Alpha" "$vu/opnsense/mvc/app/views/Alpha" "$vu/etc/pkg/repos" "$vu/man/man8" "$vu/opnsense/version"
	printf '#!/usr/local/bin/python3\nprint("alpha")\n' >"$vu/opnsense/scripts/Alpha/run.py"
	chmod 755 "$vu/opnsense/scripts/Alpha/run.py"
	printf '<h1>alpha</h1>\n' >"$vu/opnsense/mvc/app/views/Alpha/index.volt"
	: >"$vu/opnsense/.placeholder"
	printf 'alpha 1.0 %s alpha %%%%PLUGIN_UNKNOWN%%%%\n' "$vhash" >"$vu/etc/alpha.conf"
	printf 'shadowed\n' >"$vu/etc/alpha.conf.sample"
	printf 'url: https://example.org/alpha/\n' >"$vu/etc/pkg/repos/Alpha.conf.sample"
	printf '.Dd October 1, 2026\n.Nm alpha\n' | gzip -n >"$vu/man/man8/alpha.8.gz"
	vver >"$vu/opnsense/version/alpha"
}
vbase='{"name":"os-alpha","origin":"opnsense/os-alpha","version":"1.0","comment":"Alpha",
 "maintainer":"maintainer@example.org","www":"https://example.org/alpha/","abi":"FreeBSD:15:amd64",
 "arch":"freebsd:15:x86:64","prefix":"/usr/local","flatsize":1,"licenselogic":"single","licenses":["BSD2CLAUSE"],
 "desc":"Alpha","categories":["net"],"scripts":{"pre-deinstall":"echo bye","post-install":"echo installed\nexit 0"}}'
# vpkg [<jq arguments and filter>]: $vp/alpha.pkg from the stage, as pkg create writes one: zstd, absolute member
# names (relative with VPKG_REL=1), owner VPKG_OWNER (default root:wheel); +MANIFEST lists each staged
# file (1$ sha256, mode, owner) and annotates the version file, then the filter applies;
# +COMPACT_MANIFEST is +MANIFEST without files and scripts unless VPKG_COMPACT gives a filter for it;
# VPKG_TWICE names a staged file to archive a second time
vpkg() {
	local d="$vp/pkgroot" f perm files='{}' m own=${VPKG_OWNER:-root:wheel} t=()
	rm -rf "$d"
	mkdir -p "$d"
	while IFS= read -r f; do
		perm=0644
		[[ -x $vp/stage/$f ]] && perm=0755
		files=$(jq -c --arg p "/$f" --arg s "1\$$(sum "$vp/stage/$f")" --arg m "$perm" \
			'.[$p] = {sum: $s, uname: "root", gname: "wheel", perm: $m, mtime: 1}' <<<"$files")
	done < <(cd "$vp/stage" && find usr -type f | sort)
	m=$(jq -c --argjson f "$files" --slurpfile v "$vu/opnsense/version/alpha" \
		--argjson flat "$(cd "$vp/stage" && find usr -type f -exec cat {} + | wc -c | tr -d ' ')" \
		'.files = $f | .flatsize = $flat | .annotations = ($v[0] + {FreeBSD_version: "1500068"})' <<<"$vbase" |
		jq -c "${@:-.}")
	printf '%s' "$m" >"$d/+MANIFEST"
	jq -c "del(.files, .scripts) | ${VPKG_COMPACT:-.}" <<<"$m" >"$d/+COMPACT_MANIFEST"
	if tar --version 2>/dev/null | grep -q bsdtar; then
		t=(--uname "${own%:*}" --gname "${own#*:}" --uid 0 --gid 0)
		[[ -n ${VPKG_REL:-} ]] || t+=(-P -s ',^usr/,/usr/,')
	else
		t=(--owner="${own%:*}:0" --group="${own#*:}:0")
		[[ -n ${VPKG_REL:-} ]] || t+=(-P --transform 's,^usr/,/usr/,')
	fi
	mapfile -t f < <(cd "$vp/stage" && find usr -type f | sort)
	[[ -z ${VPKG_TWICE:-} ]] || f+=("$VPKG_TWICE")
	tar -cf - "${t[@]}" -C "$d" +COMPACT_MANIFEST +MANIFEST -C "$vp/stage" "${f[@]}" | zstd -q -c >"$vp/alpha.pkg"
}
# vrun: verify-payload.sh on $vp/alpha.pkg, the name and version from VNAME and VVER (default os-alpha, 1.0)
vrun() { bash "$root/scripts/verify-payload.sh" "$vp/alpha.pkg" "$vp/net/alpha" "${VNAME:-os-alpha}" "${VVER:-1.0}" FreeBSD:15:amd64 26.7 "$commit"; }
vpass() { # vpass <name>: verify-payload.sh accepts the package
	local out
	if out=$(vrun 2>&1); then ok; else bad "$1: expected a pass, got [$out]"; fi
}
vfail() { # vfail <name> <reason>: verify-payload.sh refuses it with exactly that reason
	local err
	if err=$(vrun 2>&1 >/dev/null); then bad "$1: expected failure"; else expect_eq "$1" "$err" "verify-payload.sh: $2"; fi
}
# vrepack [<bsdtar arguments>...]: $vp/alpha.pkg again with bsdtar from $vp/pkgroot's manifests (as vpkg
# wrote them, or edited since) and the staged files, those arguments added: more members (an @<mtree spec>,
# a path under the stage) or options (-n for a directory itself)
vrepack() {
	local f
	mapfile -t f < <(cd "$vp/stage" && find usr -type f | sort)
	(cd "$vp/stage" && bsdtar -cf - --format=pax --uname root --gname wheel --uid 0 --gid 0 -P -s ',^usr/,/usr/,' \
		"$@" -C "$vp/pkgroot" +COMPACT_MANIFEST +MANIFEST -C "$vp/stage" "${f[@]}") | zstd -q -c >"$vp/alpha.pkg"
}
# vjson <file> <text>: <text> written before the first key of the JSON object in <file> (a repeated key)
vjson() {
	local j
	j=$(<"$1")
	printf '{%s,%s' "$2" "${j#\{}" >"$1"
}
vreset() { vsrc && vstage && vpkg; }
volt=/usr/local/opnsense/mvc/app/views/Alpha/index.volt
runpy=/usr/local/opnsense/scripts/Alpha/run.py

vreset
expect_eq "payload: identical, with .in, .shadow, .shadow.in and man/" "$(vrun 2>&1; echo "rc=$?")" \
	$'payload: OK (8 files)\nscript post-install:\n\techo installed\n\texit 0\nscript pre-deinstall:\n\techo bye\nrc=0'
VPKG_REL=1 vpkg
vpass "payload: relative member names"
vreset
printf '<h1>beta</h1>\n' >"$vu/opnsense/mvc/app/views/Alpha/index.volt"
vpkg
vfail "payload: a modified file" "$volt differs from src/opnsense/mvc/app/views/Alpha/index.volt"
vreset
printf 'alpha 1.0 %s alpha %%%%PLUGIN_UNKNOWN%%%%\n' fedcba987 >"$vu/etc/alpha.conf"
vpkg
vfail "payload: an .in file substituted with other values" "/usr/local/etc/alpha.conf differs from src/etc/alpha.conf.in"
vreset
printf '.Dd October 1, 2026\n.Nm beta\n' | gzip -n >"$vu/man/man8/alpha.8.gz"
vpkg
vfail "payload: a modified man page" "/usr/local/man/man8/alpha.8.gz differs from src/man/man8/alpha.8"
vreset
printf '.Dd October 1, 2026\n.Nm alpha\n' >"$vu/man/man8/alpha.8.gz"
vpkg
vfail "payload: a man page not gzipped" "/usr/local/man/man8/alpha.8.gz is not gzip data"
vreset
printf '<?php\n' >"$vu/opnsense/extra.php"
vpkg
vfail "payload: an extra packaged file" "/usr/local/opnsense/extra.php is packaged but has no source"
vreset
printf '<?php\n' >"$vs/opnsense/new.php"
vfail "payload: a source file missing from the package" "src/opnsense/new.php is not packaged (as /usr/local/opnsense/new.php)"
vreset
printf 'x\n' >"$vs/etc/alpha.conf"
vfail "payload: two source files that install one path" "src/etc/alpha.conf and src/etc/alpha.conf.in both install /usr/local/etc/alpha.conf"
vreset
mkdir -p "$vs/opnsense/version"
printf '{}\n' >"$vs/opnsense/version/alpha"
vfail "payload: a source file in the version file's place" "src/opnsense/version/alpha would replace the version file"
vreset
printf 'x\n' >"$vs/opnsense/bad*name"
vfail "payload: a source file name tar would read as a pattern" "src/opnsense/bad*name: unsupported file name"
vreset
chmod 644 "$vu/opnsense/scripts/Alpha/run.py"
vpkg
vfail "payload: an executable packaged without its exec bit" "$runpy: mode 0644 in +MANIFEST, expected 0755"
vreset
chmod 644 "$vu/opnsense/scripts/Alpha/run.py"
vpkg --arg p "$runpy" '.files[$p].perm = "0755"'
vfail "payload: the archive mode is what pkg installs" "$runpy: mode 0644 in the archive, expected 0755"
vreset
chmod 755 "$vu/opnsense/mvc/app/views/Alpha/index.volt"
vpkg
vfail "payload: a plain file packaged executable" "$volt: mode 0755 in +MANIFEST, expected 0644"
vreset
chmod 4755 "$vu/opnsense/scripts/Alpha/run.py"
vpkg --arg p "$runpy" '.files[$p].perm = "4755"'
vfail "payload: setuid in +MANIFEST" "$runpy: mode 4755 in +MANIFEST, expected 0755"
vpkg
vfail "payload: setuid in the archive" "$runpy: mode 4755 in the archive, expected 0755"
vreset
vpkg --arg p "$runpy" '.files[$p].uname = "nobody"'
vfail "payload: an owner other than root in +MANIFEST" "$runpy: owner nobody:wheel in +MANIFEST, expected root:wheel"
VPKG_OWNER=nobody:wheel vpkg
vfail "payload: an owner other than root in the archive" "/usr/local/etc/alpha.conf: owner nobody:wheel in the archive, expected root:wheel"
vreset
zero=$(printf '0%.0s' {1..64})
vpkg --arg p "$volt" --arg s "1\$$zero" '.files[$p].sum = $s'
vfail "payload: a +MANIFEST sum that does not match the content" "$volt: +MANIFEST sum does not match the content"
b2='2$18tyyndkxmop9pmun9a8fz6awebt6wz9bbiathkzggib3p81uudj8tuij8qwpgofq449qmdcu6fumzuijx1uzkgkn4eab6o1o6fokub'
vpkg --arg p "$volt" --arg s "$b2" '.files[$p].sum = $s'
vpass "payload: a 2\$ sum (BLAKE2b, pkg's base32), as pkg 2 writes them"
vpkg --arg p "$volt" --arg s "${b2/18ty/19ty}" '.files[$p].sum = $s'
vfail "payload: a 2\$ sum that does not match" "$volt: +MANIFEST sum does not match the content"
vpkg --arg p "$volt" '.files[$p].sum = "13$abc"'
vfail "payload: a sum type it cannot check" "$volt: +MANIFEST sum type 13 is not supported"
vreset
vver '.product_hash = "fedcba987"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: a version file with a foreign product_hash" "version file: product_hash is fedcba987, expected $vhash"
vver '.product_version = "1.1"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: a version file with the wrong product_version" "version file: product_version is 1.1, expected 1.0"
vver '.product_id = "os-beta"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: a version file with the wrong product_id" "version file: product_id is os-beta, expected os-alpha"
vver '.product_abi = "27.1"' >"$vu/opnsense/version/alpha"
vpkg '.annotations.product_abi = "26.7"'
vfail "payload: a version file with the wrong product_abi" "version file: product_abi is 27.1, expected 26.7"
vver '.product_extra = "x"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: a version file with an eleventh key" "version file: not exactly the ten product_* strings"
vver '.product_website = "https://example.org/?a&b"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: a version file value other than the Makefile's" "version file: product_website is https://example.org/?a&b, expected https://example.org/alpha/"
vmk "${vdef[@]}" 'PLUGIN_WWW= https://example.org/?a&b'
vfail "payload: a Makefile value sed would not copy literally" "Makefile: PLUGIN_WWW holds &, = or %%, which sed would not copy literally"
vreset
vpkg '.annotations.product_tier = "2"'
vfail "payload: annotations that differ from the version file" "+MANIFEST annotations differ from the version file"
vpkg --arg v /usr/local/opnsense/version/alpha 'del(.files[$v])'
vfail "payload: no version file" "+MANIFEST lists no /usr/local/opnsense/version/alpha"
vpkg '.name = "os-beta"'
vfail "payload: the wrong name" "+MANIFEST name is os-beta, expected os-alpha"
vpkg '.version = "1.1"'
vfail "payload: the wrong version" "+MANIFEST version is 1.1, expected 1.0"
vpkg '.abi = "FreeBSD:16:amd64"'
vfail "payload: the wrong ABI" "+MANIFEST abi is FreeBSD:16:amd64, expected FreeBSD:15:amd64"
vpkg '.annotations.product_abi = "27.1"'
vfail "payload: the wrong series" "+MANIFEST product_abi is 27.1, expected 26.7"
vpkg '.lua_scripts = {"post-install": ["print(1)"]}'
vfail "payload: a manifest key it does not check" "+MANIFEST key lua_scripts is not expected"
VPKG_COMPACT='.deps = {"php85-curl": {"origin": "ftp/php85-curl", "version": "8.5.0"}}' vpkg
vfail "payload: a compact manifest that differs" "+COMPACT_MANIFEST differs from +MANIFEST"
vpkg '.scripts["post-install"] = "echo \u001b[2Kinstalled"'
vfail "payload: a script with control characters" "script post-install holds characters other than printable ASCII, tab and newline"
vpkg --arg p "$volt" 'del(.files[$p])'
vfail "payload: a source file +MANIFEST does not list" "src/opnsense/mvc/app/views/Alpha/index.volt is not packaged (as $volt)"
printf '<?php\n' >"$vu/opnsense/extra.php"
vpkg 'del(.files["/usr/local/opnsense/extra.php"])'
vfail "payload: an archive member +MANIFEST does not list" "archive member /usr/local/opnsense/extra.php is not in +MANIFEST"
VPKG_TWICE=usr/local/opnsense/mvc/app/views/Alpha/index.volt vpkg
vfail "payload: an archive member twice" "archive member $volt appears twice"
vreset
printf '<?php\n' >"$vs/opnsense/new.php"
vpkg '.files["/usr/local/opnsense/new.php"] = {sum: "1$x", uname: "root", gname: "wheel", perm: "0644", mtime: 1}'
vfail "payload: a +MANIFEST file the archive lacks" "/usr/local/opnsense/new.php is not in the archive"
vreset
vpkg '.deps = {"php85-curl": {"origin": "ftp/php85-curl", "version": "8.5.0"}}'
vfail "payload: dependencies without PLUGIN_DEPENDS" "dependencies (php85-curl) differ from PLUGIN_DEPENDS (none)"
vmk "${vdef[@]}" $'PLUGIN_DEPENDS=\t\tphp85-curl \\\n\t\t\tphp85-xml'
vfail "payload: PLUGIN_DEPENDS without the dependencies" "dependencies (php85-curl) differ from PLUGIN_DEPENDS (php85-curl php85-xml)"
vpkg '.deps = {"php85-curl": {"origin": "ftp/php85-curl", "version": "8.5.0"}, "php85-xml": {"origin": "textproc/php85-xml", "version": "8.5.0"}}'
vpass "payload: dependencies equal to PLUGIN_DEPENDS"
vreset
vmk "${vdef[@]}" $'PLUGIN_VARIANTS=\tA B'
vfail "payload: plugin variants" "Makefile: PLUGIN_VARIANTS is not supported"
vreset
vmk "${vdef[@]}" '.if defined(X)' $'PLUGIN_DEPENDS=\tphp85-curl' '.endif'
vfail "payload: a conditional Makefile" "Makefile: .if defined(X) is not supported"
vreset
mkdir -p "$vp/net/alpha/contrib"
vfail "payload: contrib/" "contrib/ is not supported"
vreset
printf 'alpha \377 %%%%PLUGIN_NAME%%%%\n' >"$vs/etc/alpha.conf.in"
vfail "payload: an .in file that is not UTF-8" "src/etc/alpha.conf.in: not UTF-8 text, cannot substitute"
vreset
# every version file value from the Makefile, the ABI, the series and the commit (plugins.mk:44-122, defaults.mk:42-54)
vreset
vver '.product_arch = "i386"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: product_arch other than the ABI's" "version file: product_arch is i386, expected amd64"
vver '.product_conflicts = "os-alpha-devel os-beta"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: product_conflicts other than plugins.mk's" "version file: product_conflicts is os-alpha-devel os-beta, expected os-alpha-devel"
vver '.product_email = "other@example.org"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: product_email other than PLUGIN_MAINTAINER" "version file: product_email is other@example.org, expected maintainer@example.org"
vver '.product_tier = "1"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: product_tier other than PLUGIN_TIER" "version file: product_tier is 1, expected 3"
vver '.product_name = "beta"' >"$vu/opnsense/version/alpha"
vpkg
vfail "payload: product_name other than PLUGIN_NAME" "version file: product_name is beta, expected alpha"
vreset
vmk "${vdef[@]}" $'PLUGIN_CONFLICTS=\tzeta beta'
vver '.product_conflicts = "os-alpha-devel os-beta os-beta-devel os-zeta os-zeta-devel"' >"$vu/opnsense/version/alpha"
vpkg
vpass "payload: PLUGIN_CONFLICTS as plugins.mk expands it"
vreset
vmk $'PLUGIN_NAME=\talpha' $'PLUGIN_VERSION=\t1.0' $'PLUGIN_COMMENT=\tAlpha'
vver '.product_email = "N/A" | .product_website = "https://opnsense.org/"' >"$vu/opnsense/version/alpha"
printf 'url: https://opnsense.org/\n' >"$vu/etc/pkg/repos/Alpha.conf.sample"
vpkg '.maintainer = "N/A" | .www = "https://opnsense.org/"'
vpass "payload: plugins.mk's defaults for PLUGIN_MAINTAINER, PLUGIN_WWW and PLUGIN_TIER"
vreset
vmk "${vdef[@]}" $'PLUGIN_TIER=\t2' $'PLUGIN_REVISION=\t1'
vver '.product_tier = "2" | .product_version = "1.0_1"' >"$vu/opnsense/version/alpha"
printf 'alpha 1.0_1 %s alpha %%%%PLUGIN_UNKNOWN%%%%\n' "$vhash" >"$vu/etc/alpha.conf"
vpkg '.version = "1.0_1"'
VVER=1.0_1 vpass "payload: PLUGIN_TIER and PLUGIN_REVISION from the Makefile, the .in substituted with them"
vfail "payload: a version other than the Makefile's" "the version 1.0 is not 1.0_1, as the Makefile gives it"
vreset
vmk "${vdef[@]}" $'PLUGIN_REVISION=\t0'
vpass "payload: PLUGIN_REVISION 0 adds no _0"
VNAME=os-beta vfail "payload: a name other than the Makefile's" "the name os-beta is not os-alpha, as the Makefile names it"
vmk "${vdef[@]}" 'PLUGIN_COMMENT= costs $$5'
vfail "payload: a Makefile value make would expand" 'Makefile: PLUGIN_COMMENT holds $, `, " or \, which make or sh would expand'
vmk "${vdef[@]}" 'PLUGIN_COMMENT= say "hi"'
vfail "payload: a Makefile value the shell would unquote" 'Makefile: PLUGIN_COMMENT holds $, `, " or \, which make or sh would expand'
vmk "${vdef[@]}" 'PLUGIN_COMMENT= a\tb'
vfail "payload: a Makefile value with a backslash" 'Makefile: PLUGIN_COMMENT holds $, `, " or \, which make or sh would expand'
vmk "${vdef[@]}" $'PLUGIN_DEVEL=\tyes'
vfail "payload: a Makefile variable plugins.mk reads that is not modelled" "Makefile: PLUGIN_DEVEL is not supported"
vmk "${vdef[@]}"
printf 'PLUGIN_TIER=\t2\n' >>"$vp/net/alpha/Makefile"
vfail "payload: an assignment after the include" "Makefile: PLUGIN_TIER is set after the plugins.mk include"
vmk $'PLUGIN_VERSION=\t1.0' $'PLUGIN_COMMENT=\tAlpha'
vfail "payload: no PLUGIN_NAME" "Makefile: PLUGIN_NAME is not set"
printf 'PLUGIN_NAME=\talpha\n' >"$vp/net/alpha/Makefile"
vfail "payload: no plugins.mk include" 'Makefile: no .include "../../Mk/plugins.mk"'

# repeated JSON keys: jq keeps the last, pkg (libucl) takes them all
vreset
vjson "$vp/pkgroot/+MANIFEST" '"scripts":{"pre-install":"echo hidden"}'
vrepack
vfail "payload: a second scripts object" "+MANIFEST repeats a key"
vreset
vpkg '.deps = {}'
vjson "$vp/pkgroot/+MANIFEST" '"deps":{"evil":{"origin":"x/evil","version":"1"}}'
vrepack
vfail "payload: a second deps object" "+MANIFEST repeats a key"
vreset
j=$(<"$vp/pkgroot/+MANIFEST")
printf '%s' "${j/\"scripts\":\{/\"scripts\":\{\"pre-deinstall\":\"echo hidden\",}" >"$vp/pkgroot/+MANIFEST"
vrepack
vfail "payload: a repeated script name inside scripts" "+MANIFEST repeats a key"
vreset
vjson "$vp/pkgroot/+COMPACT_MANIFEST" '"name":"os-evil"'
vrepack
vfail "payload: a repeated key in +COMPACT_MANIFEST" "+COMPACT_MANIFEST repeats a key"
vreset
vjson "$vu/opnsense/version/alpha" '"product_tier":"1"'
vpkg
vfail "payload: a repeated key in the version file" "version file repeats a key"
vreset
j=$(<"$vp/pkgroot/+MANIFEST")
printf '%s' "${j/\"desc\":\"Alpha\"/\"desc\":\"Alph$'\377'\"}" >"$vp/pkgroot/+MANIFEST"
vrepack
vfail "payload: a +MANIFEST that is not UTF-8" "+MANIFEST is not UTF-8 text"

# script names and text
vreset
vpkg '.scripts["post-install\n```\nrm -rf /"] = "x"'
vfail "payload: a script name pkg does not run" 'script "post-install\n```\nrm -rf /" is not a pkg script name'
vpkg '.scripts["pre-upgrade"] = "x"'
vfail "payload: pre-upgrade, not a pkg script name" 'script "pre-upgrade" is not a pkg script name'
vpkg '.scripts["post-install"] = "echo ‮evil"'
vfail "payload: a script with a bidi override" "script post-install holds characters other than printable ASCII, tab and newline"
vpkg '.scripts["post-install"] = "echo %72m"'
vfail "payload: a %-escape pkg would decode" "script post-install holds a %-escape other than %25, which pkg would decode"
vpkg '.scripts = {"post-install": "echo 100%25"}'
expect_eq "payload: a script is shown as pkg decodes it" "$(vrun 2>&1 | tail -2)" $'script post-install:\n\techo 100%'

# member types and flags, from libarchive's own view
vreset
mv "$vu/opnsense/mvc/app/views/Alpha/index.volt" "$vp/index.volt"
printf '#mtree\nusr/local/opnsense/mvc/app/views/Alpha/index.volt type=file mode=0644 uname=root gname=wheel flags=nodump contents=%s\n' \
	"$vp/index.volt" >"$vp/spec"
vrepack "@$vp/spec"
vfail "payload: file flags, which tar -tv does not show and pkg applies" "archive member $volt has file flags (nodump)"
vreset
rm "$vu/opnsense/mvc/app/views/Alpha/index.volt"
ln -s ../../../scripts/Alpha/run.py "$vu/opnsense/mvc/app/views/Alpha/index.volt"
vrepack usr/local/opnsense/mvc/app/views/Alpha/index.volt
vfail "payload: a symbolic link at a packaged path" "archive member $volt is a symbolic link, not a regular file"
vreset
mkdir -p "$vu/evil /usr/local/opnsense/mvc/app/views/Alpha"
mv "$vu/opnsense/mvc/app/views/Alpha/index.volt" "$vu/evil /usr/local/opnsense/mvc/app/views/Alpha/index.volt"
ln "$vu/evil /usr/local/opnsense/mvc/app/views/Alpha/index.volt" "$vu/opnsense/mvc/app/views/Alpha/index.volt"
vrepack
vfail "payload: a hard link at a packaged path, its target ending in that path" "archive member $volt is a hard link, not a regular file"
vreset
vrepack -n usr/local/opnsense
vfail "payload: a directory member" "archive member /usr/local/opnsense/ is a directory, not a regular file"
vreset
printf '#mtree\n./usr/local/opnsense/mvc/app/views/Alpha/index.volt type=file mode=0644 uname=root gname=wheel contents=%s\n' \
	"$vu/opnsense/mvc/app/views/Alpha/index.volt" >"$vp/spec"
vrepack "@$vp/spec"
vfail "payload: a ./usr/local alias of a packaged file" "archive member ./usr/local/opnsense/mvc/app/views/Alpha/index.volt is not in +MANIFEST"
printf '#mtree\nusr/local/../usr/local/opnsense/mvc/app/views/Alpha/index.volt type=file mode=0644 uname=root gname=wheel contents=%s\n' \
	"$vu/opnsense/mvc/app/views/Alpha/index.volt" >"$vp/spec"
vrepack "@$vp/spec"
vfail "payload: a /usr/local/.. alias of a packaged file" "archive member /usr/local/../usr/local/opnsense/mvc/app/views/Alpha/index.volt is not in +MANIFEST"
vreset
vrepack
vpass "payload: the same package written by bsdtar as pax"
vreset
# a +MANIFEST key pkg reads that plugins.mk never writes, and modes differing only in group or other bits
vreset
vpkg '.directories = {"/usr/local/opnsense/evil/": "y"}'
vfail "payload: a directories key" "+MANIFEST key directories is not expected"
vreset
chmod 664 "$vu/opnsense/mvc/app/views/Alpha/index.volt"
vpkg
vfail "payload: a group-writable file in the archive" "$volt: mode 0664 in the archive, expected 0644"
vpkg --arg p "$volt" '.files[$p].perm = "0664"'
vfail "payload: a group-writable mode in +MANIFEST" "$volt: mode 0664 in +MANIFEST, expected 0644"
vreset
chmod 750 "$vu/opnsense/scripts/Alpha/run.py"
vpkg --arg p "$runpy" '.files[$p].perm = "0755"'
vfail "payload: an executable others cannot run, in the archive" "$runpy: mode 0750 in the archive, expected 0755"
vpkg --arg p "$runpy" '.files[$p].perm = "0750"'
vfail "payload: an executable others cannot run, in +MANIFEST" "$runpy: mode 0750 in +MANIFEST, expected 0755"

# the source's mode is read with stat (its owner execute bit, as git records it), never with test -x,
# which as root is true for any execute bit: a stat that says 644 makes run.py a plain file
vreset
mkdir -p "$T/statshim"
printf '%s\n' '#!/bin/sh' 'echo 644' >"$T/statshim/stat"
chmod 755 "$T/statshim/stat"
expect_eq "payload: the source mode comes from stat" \
	"$(PATH="$T/statshim:$PATH" vrun 2>&1 >/dev/null)" "verify-payload.sh: $runpy: mode 0755 in +MANIFEST, expected 0644"
chmod 645 "$vs/opnsense/mvc/app/views/Alpha/index.volt"
vpass "payload: a source file only others may execute is a plain file (git records the owner's bit)"

# every other value plugins.mk's manifest target and pkg create write, derived from the Makefile, pkg-descr,
# the plugin's directory, the ABI and the packaged files (plugins.mk:125-150, libpkg pkg_manifest.c)
vreset
vpkg '.origin = "opnsense/os-beta"'
vfail "payload: another origin" "+MANIFEST origin is opnsense/os-beta, expected opnsense/os-alpha"
vpkg '.comment = "Beta"'
vfail "payload: another comment" "+MANIFEST comment is Beta, expected Alpha"
vpkg '.maintainer = "other@example.org"'
vfail "payload: another maintainer" "+MANIFEST maintainer is other@example.org, expected maintainer@example.org"
vpkg '.www = "https://example.org/beta/"'
vfail "payload: another www" "+MANIFEST www is https://example.org/beta/, expected https://example.org/alpha/"
vpkg '.categories = ["sysutils"]'
vfail "payload: another category" '+MANIFEST categories is ["sysutils"], expected ["net"]'
vpkg '.categories = ["net", "sysutils"]'
vfail "payload: a second category" '+MANIFEST categories is ["net","sysutils"], expected ["net"]'
vpkg '.prefix = "/usr"'
vfail "payload: another prefix" "+MANIFEST prefix is /usr, expected /usr/local"
vpkg '.licenselogic = "or"'
vfail "payload: another license logic" "+MANIFEST licenselogic is or, expected single"
vpkg '.licenses = ["BSD2CLAUSE", "GPLv2"]'
vfail "payload: another license" '+MANIFEST licenses is ["BSD2CLAUSE","GPLv2"], expected ["BSD2CLAUSE"]'
vpkg '.arch = "freebsd:15:amd64"'
vfail "payload: another legacy arch" "+MANIFEST arch is freebsd:15:amd64, expected freebsd:15:x86:64"
vpkg '.flatsize = 1'
vfail "payload: another flatsize" "+MANIFEST flatsize is 1, expected $(cd "$vp/stage" && find usr -type f -exec cat {} + | wc -c | tr -d ' ')"
vpkg '.flatsize = "x"'
vfail "payload: a flatsize that is not a number" "+MANIFEST flatsize is none, expected $(cd "$vp/stage" && find usr -type f -exec cat {} + | wc -c | tr -d ' ')"
vpkg 'del(.comment)'
vfail "payload: no comment" "+MANIFEST comment is none, expected Alpha"
vpkg '.comment = ["Alpha"]'
vfail "payload: a comment that is not a string" "+MANIFEST comment is none, expected Alpha"
vmk "${vdef[@]}" $'PLUGIN_LICENSE=\tISCL'
vpkg '.licenses = ["ISCL"]'
vpass "payload: PLUGIN_LICENSE from the Makefile"
vmk "${vdef[@]}" $'PLUGIN_LICENSE=\tBSD2CLAUSE GPLv2'
vfail "payload: a PLUGIN_LICENSE of two words" "Makefile: PLUGIN_LICENSE is not one plain word"
vreset
mkdir -p "$vp/sysutils"
mv "$vp/net/alpha" "$vp/sysutils/alpha"
expect_eq "payload: the category is the plugin directory's parent, as plugins.mk takes it" \
	"$(bash "$root/scripts/verify-payload.sh" "$vp/alpha.pkg" "$vp/sysutils/alpha" os-alpha 1.0 FreeBSD:15:amd64 26.7 "$commit" 2>&1 >/dev/null)" \
	'verify-payload.sh: +MANIFEST categories is ["net"], expected ["sysutils"]'
vreset
# pkg-descr: trimmed of blanks at both ends (UCL_STRING_TRIM), compared as pkg reads +MANIFEST's desc
# (url-decoded, STRING_FLAG_URLDECODE)
printf '\n  Alpha does 100%% of alpha.\n\nWWW: https://example.org/alpha/\n\n\n' >"$vp/net/alpha/pkg-descr"
vpkg '.desc = "Alpha does 100%25 of alpha.\n\nWWW: https://example.org/alpha/"'
vpass "payload: desc is pkg-descr trimmed, % encoded as pkg create writes it"
vpkg '.desc = "%41lpha does 100% of alpha.\n\nWWW: https://example.org/alpha/"'
vpass "payload: desc as pkg decodes it (%41 is A, a lone % stays)"
vpkg '.desc = "Alpha does 100%25 of alpha.\n\nWWW: https://example.org/alpha/\n"'
vfail "payload: desc with a blank pkg create would have trimmed" "+MANIFEST desc, as pkg decodes it, is not pkg-descr"
vpkg '.desc = "Alpha does 100%25 of beta.\n\nWWW: https://example.org/alpha/"'
vfail "payload: desc other than pkg-descr" "+MANIFEST desc, as pkg decodes it, is not pkg-descr"
vpkg '.desc = "Alpha does 100%25 of %62eta.\n\nWWW: https://example.org/alpha/"'
vfail "payload: desc that decodes to other text" "+MANIFEST desc, as pkg decodes it, is not pkg-descr"
vpkg '.desc = "Alpha does 100%25 of alpha.%0a%0aWWW: https://example.org/alpha/%c3%a9"'
vfail "payload: desc that decodes to bytes beyond ASCII" "+MANIFEST desc, as pkg decodes it, is not pkg-descr"
vpkg 'del(.desc)'
vfail "payload: no desc" "+MANIFEST desc, as pkg decodes it, is not pkg-descr"
# compared raw, a pkg-descr holding %41 would match a desc pkg shows as A
printf 'Alpha code %%41\n' >"$vp/net/alpha/pkg-descr"
vpkg '.desc = "Alpha code %41"'
vfail "payload: desc equal to pkg-descr only before pkg decodes it" "+MANIFEST desc, as pkg decodes it, is not pkg-descr"
vpkg '.desc = "Alpha code %2541"'
vpass "payload: desc that pkg decodes to pkg-descr's %41"
printf 'Alpha \303\251\n' >"$vp/net/alpha/pkg-descr"
vfail "payload: a pkg-descr beyond printable ASCII" "pkg-descr: not printable ASCII text, tab and newline, which is not supported"
printf 'Alpha\r\n' >"$vp/net/alpha/pkg-descr"
vfail "payload: a pkg-descr with CR" "pkg-descr: not printable ASCII text, tab and newline, which is not supported"
rm "$vp/net/alpha/pkg-descr"
vfail "payload: no pkg-descr" "$vp/net/alpha: no pkg-descr"
ln -s ../../../etc/hosts "$vp/net/alpha/pkg-descr"
vfail "payload: a pkg-descr that is a symbolic link" "$vp/net/alpha: no pkg-descr"
vreset
# dependency entries and file entries: exactly the keys pkg create writes (pkg reads their keys in any case)
vmk "${vdef[@]}" $'PLUGIN_DEPENDS=\tphp85-curl'
vpkg '.deps = {"php85-curl": {"origin": "ftp/php85-curl", "version": "8.5.0", "ORIGIN": "x/evil"}}'
vfail "payload: a dependency with a key pkg create does not write" "+MANIFEST dependencies are not entries of exactly an origin and a version"
vpkg '.deps = {"php85-curl": {"origin": "ftp/php85-curl", "version": 8}}'
vfail "payload: a dependency version that is not a string" "+MANIFEST dependencies are not entries of exactly an origin and a version"
vreset
vpkg --arg p "$volt" '.files[$p].fflags = "schg"'
vfail "payload: file flags in +MANIFEST" "+MANIFEST file $volt is not exactly gname, mtime, perm, sum and uname"
vpkg --arg p "$runpy" '.files[$p].PERM = "4755"'
vfail "payload: a second mode under another case" "+MANIFEST file $runpy is not exactly gname, mtime, perm, sum and uname"
vpkg --arg p "$volt" '.files[$p].symlink_target = "/etc/hosts"'
vfail "payload: a symlink target in +MANIFEST" "+MANIFEST file $volt is not exactly gname, mtime, perm, sum and uname"
vpkg --arg p "$volt" 'del(.files[$p].mtime)'
vfail "payload: a file entry without its mtime" "+MANIFEST file $volt is not exactly gname, mtime, perm, sum and uname"
vpkg --arg p "$volt" '.files[$p].mtime = "1"'
vfail "payload: an mtime that is not a number" "+MANIFEST file $volt is not exactly gname, mtime, perm, sum and uname"
vpkg --arg p "$volt" '.files[$p].perm = 420'
vfail "payload: a mode that is not a string" "+MANIFEST file $volt is not exactly gname, mtime, perm, sum and uname"
# annotations.FreeBSD_version: the build host's, all digits, of the ABI's FreeBSD major
vpkg '.annotations.FreeBSD_version = "1501000"'
vpass "payload: another FreeBSD 15 minor"
vpkg '.annotations.FreeBSD_version = "15x1000"'
vfail "payload: a FreeBSD_version that is not all digits" '+MANIFEST annotation FreeBSD_version is "15x1000", not all digits'
vpkg '.annotations.FreeBSD_version = "1501000\nexit 0"'
vfail "payload: a FreeBSD_version with a line of its own" '+MANIFEST annotation FreeBSD_version is "1501000\nexit 0", not all digits'
vpkg '.annotations.FreeBSD_version = "1600010"'
vfail "payload: a FreeBSD_version of another major than the ABI's" "+MANIFEST annotation FreeBSD_version is \"1600010\", not FreeBSD 15's"
vpkg 'del(.annotations.FreeBSD_version)'
vfail "payload: no FreeBSD_version" "+MANIFEST annotation FreeBSD_version is null, not all digits"
vpkg '.annotations.FreeBSD_version = 1500068'
vfail "payload: a FreeBSD_version that is not a string" "+MANIFEST annotation FreeBSD_version is 1500068, not all digits"
vreset
# the legacy arch for other ABIs, as libpkg's pkg_arch_to_legacy writes it
for pair in aarch64:aarch64:64 armv7:armv7:32:el:eabi:hardfp riscv64:riscv:64:hf powerpc64le:powerpc:64:el; do
	a=${pair%%:*}
	vver ".product_arch = \"$a\"" >"$vu/opnsense/version/alpha"
	vpkg --arg a "FreeBSD:15:$a" --arg l "freebsd:15:${pair#*:}" '.abi = $a | .arch = $l'
	expect_eq "payload: the legacy arch of FreeBSD:15:$a" \
		"$(bash "$root/scripts/verify-payload.sh" "$vp/alpha.pkg" "$vp/net/alpha" os-alpha 1.0 "FreeBSD:15:$a" 26.7 "$commit" 2>&1 | head -1)" \
		"payload: OK (8 files)"
done
vreset
expect_fail "payload: a commit that is not 40 hex digits" bash "$root/scripts/verify-payload.sh" "$vp/alpha.pkg" "$vp/net/alpha" os-alpha 1.0 FreeBSD:15:amd64 26.7 "$vhash"
expect_fail "payload: usage" bash "$root/scripts/verify-payload.sh" "$vp/alpha.pkg"
expect_fail "payload: not a package" bash "$root/scripts/verify-payload.sh" "$T/repo.conf" "$vp/net/alpha" os-alpha 1.0 FreeBSD:15:amd64 26.7 "$commit"

# --- canary-findings.sh and canary-report.sh ----------------------------------------
fd() { bash "$root/scripts/canary-findings.sh" os-alpha "$T/cf"; echo "rc=$?"; }
cfdir() {
	rm -rf "$T/cf"
	mkdir -p "$T/cf"
	mkpkg "$T/cf/published.pkg" "$base"
	printf 'Built from Org/plugins, branch b, commit 1111111aaaa.\n\nsha256: x\n' >"$T/cf/notes"
	mkpkg "$T/cf/fresh.pkg" "$base"
	mkpkg "$T/cf/rebased.pkg" "$base"
	echo "Built from Org/plugins, branch b, commit 1111111aaaa." >"$T/cf/fresh.source"
}
cfdir
expect_eq "findings: all the same" "$(fd)" "rc=0"
mkpkg "$T/cf/rebased.pkg" "$(mod '.scripts["post-install"] = "echo new"')"
expect_eq "findings: upstream Mk/ changes a script" "$(fd)" \
	$'MATERIAL: upstream Mk/ would change script post-install: changed\nrc=1'
cfdir
mkpkg "$T/cf/fresh.pkg" "$(mod '.annotations.product_abi = "27.1"')"
mkpkg "$T/cf/rebased.pkg" "$(mod '.annotations.product_abi = "27.1"')"
expect_eq "findings: a difference both builds show is reported once" "$(fd)" \
	$'MATERIAL: a publish now would change product_abi: "26.7" -> "27.1"\nrc=1'
cfdir
rm "$T/cf/fresh.pkg"
echo "make: error 1" >"$T/cf/fresh.tail"
expect_eq "findings: a failed build is material, with the end of its log" "$(fd)" \
	$'MATERIAL: building the branch as a publish would failed; the end of its log:\nLOG: make: error 1\nrc=1'
cfdir
echo "garbage" >"$T/cf/fresh.pkg"
mkpkg "$T/cf/rebased.pkg" "$(mod '.annotations.product_abi = "27.1"')"
expect_eq "findings: when the as-published build cannot be compared, rebased differences are not blamed on Mk/" "$(fd)" \
	$'MATERIAL: the build as a publish would make it could not be compared with the release\nMATERIAL: a build with upstream Mk/ differs from the release in product_abi: "26.7" -> "27.1" (the as-published build could not be compared)\nrc=1'
cfdir
echo "Built from Org/plugins, branch b, commit 2222222bbbb." >"$T/cf/fresh.source"
expect_eq "findings: unreleased commits are a note" "$(fd)" \
	$'NOTE: the branch has commits after its release (release 1111111aaaa, branch head 2222222bbbb)\nrc=0'
cfdir
rm "$T/cf/published.pkg" "$T/cf/notes"
expect_eq "findings: no release yet is a note" "$(fd)" $'NOTE: os-alpha has no release yet; nothing to compare\nrc=0'

crep() { bash "$root/scripts/canary-report.sh" "canary: os-alpha" "$T/findings" "https://run/1"; }
reset_stub
printf 'MATERIAL: build failed\nLOG: cc: error one\nLOG: *** Error code 1\n' >"$T/findings"
crep >/dev/null
expect_eq "report: log lines become one code block" "$(sed -n '/^```$/,/^```$/p' "$STUB/issue_calls" | tr '\n' '|')" \
	'```|cc: error one|*** Error code 1|```|'
: >"$STUB/issue_calls"
printf 'MATERIAL: build failed\nLOG: a ``` b\nLOG: c ````` d\nLOG: ok\n' >"$T/findings"
crep >/dev/null
expect_eq "report: a log line with backticks cannot close the block" \
	"$(sed -n '/^``````$/,$p' "$STUB/issue_calls" | tr '\n' '|' | sed 's/Run:.*//')" \
	'``````|a ``` b|c ````` d|ok|``````|'"|"
: >"$STUB/issue_calls"
{ echo "MATERIAL: build failed"; for i in $(seq 1 3000); do printf 'LOG: %050d\n' "$i"; done; } >"$T/findings"
crep >/dev/null
expect_eq "report: the body stays under GitHub's limit" "$(($(wc -c <"$STUB/issue_calls") < 65000))" "1"
# a cut body closes the block it cuts, whatever the length of its fence, and the note stays outside it
cutbody() { sed '1s/^create|[^|]*|//' "$STUB/issue_calls"; }
cutnote="(cut: the full log is in the run's canary artifact)"
: >"$STUB/issue_calls"
{ echo "MATERIAL: build failed"; for i in $(seq 1 3000); do printf 'LOG: %050d ````` x\n' "$i"; done; } >"$T/findings"
crep >/dev/null
o=$(cutbody | outside)
expect_eq "report: a cut inside a six-backtick block closes it, the note outside" \
	"$(grep -c UNCLOSED <<<"$o") $(grep -cxF "$cutnote" <<<"$o")" "0 1"
expect_eq "report: and stays under GitHub's limit" "$(($(cutbody | wc -c) < 65000))" "1"
: >"$STUB/issue_calls"
{
	echo "MATERIAL: build failed"
	printf 'LOG: a %s b\n' "$(head -c 61000 /dev/zero | tr '\0' '`')"
	echo "LOG: ok"
} >"$T/findings"
crep >/dev/null
o=$(cutbody | outside)
expect_eq "report: a fence longer than the limit: the cut leaves the block out, the note outside" \
	"$(grep -c UNCLOSED <<<"$o") $(grep -cxF "$cutnote" <<<"$o") $(($(cutbody | wc -c) < 65000))" "0 1 1"
reset_stub
printf 'MATERIAL: x\nNOTE: y\n' >"$T/findings"
expect_eq "report: opens an issue" "$(crep)" "opened"
expect_eq "report: the issue" "$(cut -s -d'|' -f1,2 "$STUB/issue_calls")" "create|canary: os-alpha"
expect_eq "report: the body lists the findings" "$(grep -c '^- \*\*MATERIAL\*\*: x$' "$STUB/issue_calls")" "1"
echo '[{"number":7,"title":"canary: os-alpha"},{"number":8,"title":"canary: os-beta"}]' >"$STUB/issues.json"
: >"$STUB/issue_calls"
expect_eq "report: updates the open one" "$(crep)" "updated"
expect_eq "report: the edit" "$(cut -s -d'|' -f1,2 "$STUB/issue_calls")" "edit|7"
printf 'NOTE: y\n' >"$T/findings"
: >"$STUB/issue_calls"
expect_eq "report: closes it when clean" "$(crep)" "closed"
expect_eq "report: the close" "$(cut -s -d'|' -f1,2 "$STUB/issue_calls")" "close|7"
echo '[]' >"$STUB/issues.json"
expect_eq "report: clean, nothing open" "$(crep)" "clean"
printf 'MATERIAL: x\n' >"$T/findings"
touch "$STUB/fail_issues"
: >"$STUB/issue_calls"
expect_fail "report: the issue list unreadable" crep
expect_eq "report: no duplicate opened when the list fails" "$(cat "$STUB/issue_calls")" ""
rm "$STUB/fail_issues"
echo '[{"number":7,"title":"canary: os-alpha"},{"number":9,"title":"canary: os-alpha"}]' >"$STUB/issues.json"
expect_fail "report: two open issues with one title" crep

# --- canary-vm.sh and canary.sh --------------------------------------------------
conf 'os-alpha  Org/plugins br net/alpha yes' \
	'os-beta   Org/plugins br net/beta  yes'
vmdir
vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_FAIL_DIR=net/beta -- canary-vm.sh >/dev/null
expect_eq "canary-vm: both builds of a good package" "$(names "$W/canary/os-alpha")" "fresh.pkg fresh.source rebased.pkg "
expect_eq "canary-vm: a failing package does not stop the rest, and keeps its logs" "$(names "$W/canary/os-beta")" "fresh.log fresh.tail rebased.log rebased.tail "

cw="$T/cw"
rm -rf "$cw"
mkdir -p "$cw"
cp -R "$W/canary" "$cw/"
printf 'ABI=FreeBSD:15:amd64\nSERIES=26.7\nSERVE=FreeBSD:15:amd64/26.7\n' >"$T/repo.conf"
printf 'NEWEST=26.7\nNEXT_ABI=\nSERIES=26.7\nCORE=26.7.5\nPHP=85\nPYTHON=313\nFREEBSD=15.1\n' >"$cw/upstream.env"
reset_stub
canary_run() { (cd "$cw" && bash "$S/canary.sh" https://run/2); }
out=$(canary_run)
rc=$?
expect_eq "canary: a failed build makes the run fail" "$rc" "1"
expect_eq "canary: one report per package, then the series" "$out" $'clean\nopened\nclean'
expect_eq "canary: the failing package's issue" "$(cut -s -d'|' -f1,2 "$STUB/issue_calls")" "create|canary: os-beta"
expect_eq "canary: package issues carry the upstream facts" "$(grep -c 'NOTE\*\*: upstream PHP=85' "$STUB/issue_calls")" "1"
publish os-alpha-1.0 2026-01-01T00:00:00Z
rm "$STUB/assets/os-alpha-1.0/os-alpha-1.0.pkg"
: >"$STUB/issue_calls"
out=$(canary_run)
expect_eq "canary: a release that cannot be fetched is reported and the run goes on" "$out" $'opened\nopened\nclean'
expect_eq "canary: the fetch failure is in the issue" "$(grep -c 'could not fetch os-alpha-1.0' "$STUB/issue_calls")" "1"
reset_stub
printf 'NEWEST=27.1\nNEXT_ABI=FreeBSD:16:amd64\nSERIES=26.7\nCORE=26.7.9\nPHP=85\nPYTHON=313\nFREEBSD=15.1\n' >"$cw/upstream.env"
: >"$STUB/issue_calls"
canary_run >/dev/null
expect_eq "canary: a new series and a new FreeBSD major open the series issue" \
	"$(grep -c '^create|canary: upstream series|' "$STUB/issue_calls")" "1"
expect_eq "canary: the series issue names both" \
	"$(grep -c -e 'ships series 27.1' -e 'publishes FreeBSD:16:amd64' "$STUB/issue_calls")" "2"
rm "$cw/upstream.env"
expect_fail "canary: refuses to run without upstream facts" canary_run

# --- verify-catalogue.sh -------------------------------------------------------------
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
reset_stub
rm -rf "$T/livesite"
publish os-alpha-1.1 2026-01-03T00:00:00Z
live os-alpha-1.1
d="$T/livesite/FreeBSD:15:amd64/26.7/latest"
echo "catalogue data" >"$T/data"
openssl dgst -sha256 -r "$T/data" | cut -d' ' -f1 | tr -d '\n' | openssl dgst -sha256 -sign "$T/key.pem" -binary >"$T/data.sig"
cp "$T/pub.pem" "$T/data.pub"
tar -cf "$d/data.pkg" -C "$T" data data.sig data.pub
# vstamp <tree dir> <ABI/series> [<signing key> [<published key>]]: the tree's stamp as sign-catalogue.sh
# writes it, signed by the test key (or <signing key>), its key the published one (or <published key>)
vstamp() {
	printf 'published: 2026-10-21T12:00:00Z\nrun: 4815162342\ntree: %s\n' "$2" >"$1/stamp"
	openssl dgst -sha256 -r "$1/stamp" | cut -d' ' -f1 | tr -d '\n' |
		openssl dgst -sha256 -sign "${3:-$T/key.pem}" -binary >"$1/stamp.sig"
	cp "${4:-$T/pub.pem}" "$1/stamp.pub"
}
vstamp "$d" FreeBSD:15:amd64/26.7
# the published key is the script's own checkout's; the harness copy names the test key instead
expect_eq "verify-catalogue.sh: the published key from the script's location, one literal line, no override" \
	"$(anchor "$root/scripts/verify-catalogue.sh" pub 'pub=$here/../keys/legotypes-pkg-signing.pub')" "1 1"
sed "s|^pub=.*|pub=$T/pub.pem|" "$root/scripts/verify-catalogue.sh" >"$S/verify-catalogue.sh"
vc() { bash "$S/verify-catalogue.sh" "$@"; }
expect_eq "verify: a good publish" "$(vc os-alpha >/dev/null; echo "rc=$?")" "rc=0"
expect_eq "verify: the stamp is reported" "$(vc os-alpha 2>/dev/null | grep -c '^FreeBSD:15:amd64/26.7: stamp verified, published 2026-10-21T12:00:00Z$')" 1
expect_fail "verify: PUB_KEY changes nothing (the real key did not sign this catalogue)" \
	env PUB_KEY="$T/pub.pem" bash "$root/scripts/verify-catalogue.sh" os-alpha
for f in stamp stamp.sig stamp.pub; do
	mv "$d/$f" "$T/$f.away"
	expect_fail "verify: a tree without its $f" vc os-alpha
	mv "$T/$f.away" "$d/$f"
done
vstamp "$d" FreeBSD:15:amd64/26.7 "$T/other.pem"
expect_fail "verify: a stamp signed by another key" vc os-alpha
vstamp "$d" FreeBSD:15:amd64/26.7 "$T/other.pem" "$T/other.pub"
expect_fail "verify: a stamp signed and keyed by another key" vc os-alpha
vstamp "$d" FreeBSD:15:amd64/26.7 "$T/key.pem" "$T/other.pub"
expect_fail "verify: a stamp signed by the published key but carrying another" vc os-alpha
vstamp "$d" FreeBSD:15:amd64/26.7
sed -i.bak 's/^published: .*/published: 2099-01-01T00:00:00Z/' "$d/stamp" && rm "$d/stamp.bak"
expect_fail "verify: a stamp changed after signing" vc os-alpha
vstamp "$d" FreeBSD:15:amd64/26.1
expect_fail "verify: a stamp for another tree" vc os-alpha
vstamp "$d" FreeBSD:15:amd64/26.7
# two trees served: the frozen one's stamp is checked too
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.1 FreeBSD:15:amd64/26.7'
d1="$T/livesite/FreeBSD:15:amd64/26.1/latest"
mkdir -p "$d1"
cp "$d/data.pkg" "$d1/"
expect_fail "verify: a frozen tree without a stamp" vc os-alpha
vstamp "$d1" FreeBSD:15:amd64/26.1
expect_eq "verify: both trees' stamps" "$(vc os-alpha 2>/dev/null | grep -c ': stamp verified, published ')" 2
rm -rf "$T/livesite/FreeBSD:15:amd64/26.1"
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
live os-alpha-1.0
expect_fail "verify: the tree serves an older build" vc os-alpha
live os-alpha-1.1
openssl dgst -sha256 -r "$T/data" | cut -d' ' -f1 | tr -d '\n' | openssl dgst -sha256 -sign "$T/other.pem" -binary >"$T/data.sig"
tar -cf "$d/data.pkg" -C "$T" data data.sig
expect_fail "verify: a signature the published key does not verify" vc os-alpha
openssl dgst -sha256 -r "$T/data" | cut -d' ' -f1 | tr -d '\n' | openssl dgst -sha256 -sign "$T/key.pem" -binary >"$T/data.sig"
openssl rsa -in "$T/other.pem" -pubout -out "$T/data.pub" 2>/dev/null
tar -cf "$d/data.pkg" -C "$T" data data.sig data.pub
expect_fail "verify: a catalogue carrying a key other than the published one" vc os-alpha

# --- pkg-tool.sh (stub curl serves GitHub's archive) -----------------------------------
# The archive of a fake commit: its configure records its arguments in $PT_CALLS and writes
# a Makefile that "builds" src/pkg, a script printing a version.
ptc=$(printf '1%.0s' {1..40})
ptsrc="$T/ptsrc/pkg-$ptc"
mkdir -p "$ptsrc" "$T/ptmirror"
printf '%s\n' '#!/bin/sh' 'echo 2.8.4' >"$ptsrc/fake-pkg"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" configure "$@" >"$PT_CALLS"' \
	'printf "all:\n\tmkdir -p src\n\tcp %s/fake-pkg src/pkg\n\tchmod 755 src/pkg\n" "$(cd "$(dirname "$0")" && pwd)" >Makefile' \
	>"$ptsrc/configure"
chmod 755 "$ptsrc/configure"
tar -czf "$T/ptmirror/$ptc.tar.gz" -C "$T/ptsrc" "pkg-$ptc"
# On Linux pkg-tool.sh installs its build dependencies: tests/stub-apt's sudo, apt-get and
# dpkg-query stand in for them
pt() {
	rm -rf "$T/ptdest" "$T/ptcalls"
	PATH="$root/tests/stub-apt:$PATH" PT_CALLS="$T/ptcalls" STUB_MIRROR="$T/ptmirror" \
		STUB_MIRROR_URL=https://github.com/freebsd/pkg/archive bash "$S/pkg-tool.sh" "$@"
}
rc "${ptconf[@]}" "PKG_TOOL_COMMIT=$ptc" "PKG_TOOL_SHA256=$(sum "$T/ptmirror/$ptc.tar.gz")"
expect_eq "pkg-tool: prints the installed pkg" "$(pt "$T/ptdest" 2>/dev/null)" "$T/ptdest/sbin/pkg"
expect_eq "pkg-tool: configured for the destination" "$(sed -n 2p "$T/ptcalls" 2>/dev/null)" "--prefix=$T/ptdest"
expect_eq "pkg-tool: the installed pkg runs" "$("$T/ptdest/sbin/pkg" -v 2>/dev/null)" "2.8.4"
rm -f "$T/curllog"
STUB_CURL_LOG="$T/curllog" pt "$T/ptdest" >/dev/null 2>&1
expect_eq "pkg-tool: the archive is fetched over https only, redirects included" \
	"$(grep -c -e "--proto =https .*--proto-redir =https" -e "--proto-redir =https .*--proto =https" "$T/curllog")" 1
rc "${ptconf[@]}" "PKG_TOOL_COMMIT=$ptc" "PKG_TOOL_SHA256=$(printf '0%.0s' {1..64})"
err=$(pt "$T/ptdest" 2>&1 >/dev/null)
expect_eq "pkg-tool: a wrong sha256 fails" "$?" "1"
expect_eq "pkg-tool: a wrong sha256 is named" \
	"$(grep -c "sha256 $(sum "$T/ptmirror/$ptc.tar.gz"), not the pinned $(printf '0%.0s' {1..64})" <<<"$err")" "1"
expect_eq "pkg-tool: a wrong sha256 dies before configure runs" "$([[ -e $T/ptcalls ]] && echo ran)" ""
expect_eq "pkg-tool: a wrong sha256 installs nothing" "$([[ -e $T/ptdest/sbin/pkg ]] && echo installed)" ""
rc "${ptconf[@]}" "PKG_TOOL_COMMIT=$(printf '2%.0s' {1..40})" "PKG_TOOL_SHA256=$(sum "$T/ptmirror/$ptc.tar.gz")"
expect_fail "pkg-tool: a commit GitHub does not serve" pt "$T/ptdest"
rc "${ptconf[@]}" "PKG_TOOL_COMMIT=$ptc"
expect_fail "pkg-tool: no pinned sha256" pt "$T/ptdest"
expect_fail "pkg-tool: usage" pt

# --- ubuntu-apt.sh (tests/stub-apt stands in for sudo, apt-get and dpkg-query) -------------
# a copy reading a test file for the image's Ubuntu sources (the script itself takes no path)
sed "s|^UBUNTU_SOURCES=.*|UBUNTU_SOURCES=$T/ubuntu.sources|" "$root/scripts/ubuntu-apt.sh" >"$T/ubuntu-apt.sh"
ua() {
	rm -f "$T/aptcalls"
	PATH="$root/tests/stub-apt:$PATH" APT_CALLS="$T/aptcalls" bash "$T/ubuntu-apt.sh" "$@"
}
: >"$T/ubuntu.sources"
expect_eq "ubuntu-apt: prints what it installed" "$(ua libarchive-tools zstd 2>/dev/null)" $'libarchive-tools 0-stub\nzstd 0-stub'
expect_eq "ubuntu-apt: only the Ubuntu sources, no other source list, then the packages without recommends" \
	"$(cat "$T/aptcalls")" "-q -o Dir::Etc::SourceList=$T/ubuntu.sources -o Dir::Etc::SourceParts=<0 entries> update
-q -o Dir::Etc::SourceList=$T/ubuntu.sources -o Dir::Etc::SourceParts=<0 entries> -y --no-install-recommends install libarchive-tools zstd"
expect_fail "ubuntu-apt: no package" ua
expect_fail "ubuntu-apt: an option for a package name" ua -oAPT::Get::AllowUnauthenticated=true
expect_eq "ubuntu-apt: a bad name runs no apt-get" "$([[ -e $T/aptcalls ]] && echo ran)" ""
rm "$T/ubuntu.sources"
expect_fail "ubuntu-apt: no Ubuntu sources" ua zstd
expect_eq "ubuntu-apt: without them no apt-get runs" "$([[ -e $T/aptcalls ]] && echo ran)" ""
expect_eq "the real ubuntu-apt.sh reads the image's Ubuntu sources" \
	"$(awk '/^UBUNTU_SOURCES=/' "$root/scripts/ubuntu-apt.sh")" "UBUNTU_SOURCES=/etc/apt/sources.list.d/ubuntu.sources"
expect_eq "pkg-tool installs its dependencies with ubuntu-apt.sh" \
	"$(awk '/apt-get/ && !/^[[:space:]]*#/' "$root/scripts/pkg-tool.sh") $(awk '/ubuntu-apt\.sh/ && !/^[[:space:]]*#/ { n++ } END { print n + 0 }' "$root/scripts/pkg-tool.sh")" " 1"

# --- out-dir.sh: a build's output, as the VM left it ---------------------------------------
od="$T/od"
# odset [<package>]: $od, a build of <package> (default os-alpha) as build-package.sh leaves one
odset() {
	rm -rf "$od"
	mkdir -p "$od"
	echo pkg >"$od/${1:-os-alpha}-1.0_1.pkg"
	printf 'Built from Org/plugins, branch br-alpha, commit %s.\n' "$commit" >"$od/source"
	printf 'abi: FreeBSD:15:amd64\nseries: 26.7\nfreebsd: 15.1-RELEASE-p3\nphp: 85\npython: 313\n' >"$od/build"
}
odr() { bash "$root/scripts/out-dir.sh" "${1:-os-alpha}" "$od"; }
odset
expect_eq "out-dir: prints the package" "$(odr)" "$od/os-alpha-1.0_1.pkg"
echo manifest >"$od/manifest"
expect_fail "out-dir: a manifest (the review job's, never in out/)" odr
odset && touch "$od/extra"
expect_fail "out-dir: another file" odr
odset && mkdir "$od/sub"
expect_fail "out-dir: a directory" odr
odset && ln -s source "$od/link"
expect_fail "out-dir: a symlink" odr
odset && rm "$od/source" && ln -s /etc/hosts "$od/source"
expect_fail "out-dir: source a symlink" odr
odset && rm "$od/os-alpha-1.0_1.pkg" && ln -s /etc/hosts "$od/os-alpha-1.0_1.pkg"
expect_fail "out-dir: the package a symlink" odr
odset && echo pkg >"$od/os-alpha-1.1.pkg"
expect_fail "out-dir: two packages" odr
odset && rm "$od/os-alpha-1.0_1.pkg"
expect_fail "out-dir: no package" odr
odset && mv "$od/os-alpha-1.0_1.pkg" "$od/os-alpha-devel-1.0.pkg"
expect_fail "out-dir: another package" odr
odset && mv "$od/os-alpha-1.0_1.pkg" "$od/os-alpha-1.0\`x.pkg"
expect_fail "out-dir: a version that is not one plain word" odr
odset
expect_fail "out-dir: not the package asked for" odr os-beta
expect_fail "out-dir: not a package name" odr 'os-alpha*'
odset && rm "$od/source"
expect_fail "out-dir: no source" odr
odset && rm "$od/build"
expect_fail "out-dir: no build" odr
odset && printf 'Built from\nsomewhere\n' >"$od/source"
expect_fail "out-dir: a source of two lines" odr
odset && printf 'Built\tfrom\n' >"$od/source"
expect_fail "out-dir: a source with a control character" odr
odset && printf 'abi: FreeBSD:15:amd64\nseries: 26.7\nfreebsd: 15.1-RELEASE-p3\nphp: 85\npython: 313\nsha256: 00\n' >"$od/build"
expect_fail "out-dir: a build line more" odr
odset && printf 'abi: FreeBSD:15:amd64\nseries: 26.7\nfreebsd: 15.1 RELEASE\nphp: 85\npython: 313\n' >"$od/build"
expect_fail "out-dir: a build value with a space" odr
odset && touch "$od/$(printf 'x\n::error::y')"
err=$(odr 2>&1 >/dev/null)
expect_eq "out-dir: a file name the VM chose stays on the script's own line" "$(wc -l <<<"$err" | tr -d ' ') ${err:0:11}" "1 out-dir.sh:"
expect_fail "out-dir: usage" bash "$root/scripts/out-dir.sh" os-alpha
# what build-package.sh writes passes, for a plugin row and for this repository's row
conf 'os-alpha   Org/plugins br-alpha net/alpha yes' 'os-vendor  .           main     vendor/v  yes'
vmdir
vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-alpha-1.1.pkg -- build-package.sh os-alpha "$ok" >/dev/null
expect_eq "out-dir: build-package.sh's output for a plugin" "$(bash "$root/scripts/out-dir.sh" os-alpha "$W/out")" "$W/out/os-alpha-1.1.pkg"
vmenv UPSTREAM_PHP=85 UPSTREAM_PYTHON=313 STUB_PKGS=os-vendor-1.0_2.pkg GITHUB_REPOSITORY=Org/repo "GITHUB_SHA=$ok" -- build-package.sh os-vendor "$ok" >/dev/null
expect_eq "out-dir: build-package.sh's output for this repository's package" \
	"$(bash "$root/scripts/out-dir.sh" os-vendor "$W/out")" "$W/out/os-vendor-1.0_2.pkg"

# --- a GitHub stand-in for the scripts that clone (real git) -----------------------------------
# git with no global or system configuration (no hooks, no signing), and a fixed author
gitq() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test -c user.email=test@example.org -c init.defaultBranch=main "$@"; }
# ghenv <command>: <command> with https://github.com/<repo>.git served from $T/gh/<repo>.git
ghenv() {
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=1 \
		GIT_CONFIG_KEY_0="url.file://$T/gh/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/ "$@"
}
# ghrepo <repo> <branch> <file> <word>...: a commit per word on <branch> of $T/gh/<repo>.git, each
# writing it to <file>; prints the commits, one per line
ghrepo() {
	local repo=$1 branch=$2 file=$3 w d="$T/ghw/$1"
	shift 3
	if [[ ! -d $d ]]; then
		gitq init -q "$d"
		gitq -C "$d" checkout -q -b "$branch"
	else
		gitq -C "$d" checkout -q -B "$branch"
	fi
	mkdir -p "$d/$(dirname "$file")"
	for w in "$@"; do
		echo "$w" >"$d/$file"
		gitq -C "$d" add -A
		gitq -C "$d" commit -qm "$w"
		git -C "$d" rev-parse HEAD
	done
	rm -rf "$T/gh/$repo.git"
	mkdir -p "$T/gh/$(dirname "$repo")"
	gitq clone -q --bare "$d" "$T/gh/$repo.git"
}
rm -rf "$T/ghw" "$T/gh"
# Org/plugins: br-alpha holds commits one and two, branch other (from two) a third
mapfile -t c < <(ghrepo Org/plugins br-alpha net/alpha/Makefile one two)
c_one=${c[0]}
c_three=$(ghrepo Org/plugins other net/alpha/Makefile three)
# LegoTypes/plugins: master holds m-one and m-two, branch side (from m-two) m-three
mapfile -t c < <(ghrepo LegoTypes/plugins master Mk/plugins.mk m-one m-two)
m_one=${c[0]}
m_side=$(ghrepo LegoTypes/plugins side Mk/plugins.mk m-three)
# served with master as its default branch (a bare clone keeps every branch)
gitq -C "$T/ghw/LegoTypes/plugins" checkout -q master
rm -rf "$T/gh/LegoTypes/plugins.git" && gitq clone -q --bare "$T/ghw/LegoTypes/plugins" "$T/gh/LegoTypes/plugins.git"
# freshrepo: $T/fresh, a checkout of this repository whose vendor/v last changed in $v_changed,
# at a later commit $v_head
freshrepo() {
	rm -rf "$T/fresh"
	mkdir -p "$T/fresh/vendor/v"
	gitq init -q "$T/fresh"
	printf 'PLUGIN_NAME= v\n' >"$T/fresh/vendor/v/Makefile"
	gitq -C "$T/fresh" add -A && gitq -C "$T/fresh" commit -qm vendor
	v_changed=$(git -C "$T/fresh" rev-parse HEAD)
	echo other >"$T/fresh/README" && gitq -C "$T/fresh" add -A && gitq -C "$T/fresh" commit -qm other
	v_head=$(git -C "$T/fresh" rev-parse HEAD)
}

# --- plugin-source.sh: the plugin's directory at the approved commit -----------------------------
conf 'os-alpha   Org/plugins br-alpha net/alpha yes' 'os-vendor  .           main     vendor/v  yes'
# ps <dir> <commit> <args>: plugin-source.sh in <dir>
ps() { (cd "$1" && ghenv env COMMIT="$2" bash "$S/plugin-source.sh" "${@:3}"); }
rm -rf "$T/src"
expect_eq "plugin-source: prints the plugin's directory" "$(ps "$T" "$c_one" os-alpha "$T/src" 2>/dev/null)" "$T/src/net/alpha"
expect_eq "plugin-source: at the commit, not the branch head" "$(cat "$T/src/net/alpha/Makefile")" one
expect_fail "plugin-source: the destination exists" ps "$T" "$c_one" os-alpha "$T/src"
rm -rf "$T/src"
expect_fail "plugin-source: a commit not on the branch" ps "$T" "$c_three" os-alpha "$T/src"
rm -rf "$T/src"
expect_fail "plugin-source: a commit the repository does not have" ps "$T" "$(printf 'e%.0s' {1..40})" os-alpha "$T/src"
rm -rf "$T/src"
expect_fail "plugin-source: an abbreviated commit" ps "$T" "${c_one:0:9}" os-alpha "$T/src"
expect_fail "plugin-source: usage" ps "$T" "$c_one" os-alpha
freshrepo
expect_eq "plugin-source: this repository's package is this checkout's directory" \
	"$(ps "$T/fresh" "$v_head" os-vendor "$T/src" 2>/dev/null)" vendor/v
expect_eq "plugin-source: and clones nothing" "$(exists "$T/src")" no
expect_fail "plugin-source: this checkout is not at the commit" ps "$T/fresh" "$c_one" os-vendor "$T/src"

# --- provenance.sh: the release notes' lines, from trusted inputs --------------------------------
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
# pv <dir> <package> <commit>: provenance.sh in <dir> on $od into $T/rev, the upstream PHP and
# Python from PV_PHP and PV_PY (default 85 and 313)
pv() {
	(cd "$1" && ghenv env COMMIT="$3" \
		UPSTREAM_PHP="${PV_PHP-85}" UPSTREAM_PYTHON="${PV_PY-313}" GITHUB_REPOSITORY=Org/repo \
		bash "$S/provenance.sh" "$2" "$od" "$T/rev")
}
# pvwith <VAR=value> <pv arguments>: pv with PV_PHP or PV_PY set so
pvwith() {
	local "$1"
	pv "${@:2}"
}
# a plugin: the VM's source line is never read
odset && printf 'Built from somewhere else entirely.\n' >"$od/source"
rm -rf "$T/rev"
pv "$T" os-alpha "$c_one" >/dev/null 2>&1 || bad "provenance: a plugin exited non-zero"
expect_eq "provenance: a plugin's source line from packages.conf and the commit" "$(cat "$T/rev/source")" \
	"Built from Org/plugins, branch br-alpha, commit $c_one."
expect_eq "provenance: ABI and series from repo.conf, PHP and Python from upstream.sh, FreeBSD as the VM reported it" \
	"$(cat "$T/rev/build")" $'abi: FreeBSD:15:amd64\nseries: 26.7\nfreebsd: 15.1-RELEASE-p3 (reported by the build VM)\nphp: 85\npython: 313'
expect_eq "provenance: review/ holds the two files" "$(names "$T/rev")" "build source "
expect_fail "provenance: review/ exists already" pv "$T" os-alpha "$c_one"
# the VM's build lines must agree with repo.conf and with upstream.sh run again
for v in 'abi: FreeBSD:16:amd64' 'series: 27.1'; do
	odset && sed -i.bak "s/^${v%%:*}: .*/$v/" "$od/build" && rm "$od/build.bak"
	rm -rf "$T/rev"
	expect_fail "provenance: the VM built for another ${v%%:*}" pv "$T" os-alpha "$c_one"
done
odset
for v in PV_PHP=84 PV_PY=312 PV_PHP= PV_PY=; do
	rm -rf "$T/rev"
	expect_fail "provenance: upstream.sh now says otherwise ($v)" pvwith "$v" "$T" os-alpha "$c_one"
done
rm -rf "$T/rev"
expect_fail "provenance: an abbreviated commit" pv "$T" os-alpha "${c_one:0:9}"
odset && touch "$od/extra"
rm -rf "$T/rev"
expect_fail "provenance: not a build" pv "$T" os-alpha "$c_one"
odset && sed -i.bak 's/^abi: .*/abi: FreeBSD:16:amd64/' "$od/build" && rm "$od/build.bak"
rm -rf "$T/rev"
err=$(pv "$T" os-alpha "$c_one" 2>&1 >/dev/null)
expect_eq "provenance: a refusal is one line of its own" "$(wc -l <<<"$err" | tr -d ' ') ${err:0:14}" "1 provenance.sh:"
# this repository's package: the last change to its directory from this checkout, the plugins
# master commit the VM reported only once it is a commit of LegoTypes/plugins master
freshrepo
vsrcline() { printf 'Built from Org/repo, vendor/v, commit %s (workflow run at %s), in LegoTypes/plugins master %s.\n' "$@"; }
odset os-vendor && vsrcline "$ok" "$v_head" "$m_one" >"$od/source"
rm -rf "$T/rev"
pv "$T/fresh" os-vendor "$v_head" >/dev/null 2>&1 || bad "provenance: this repository's package exited non-zero"
expect_eq "provenance: this repository's source line: this checkout's last change, the plugins master commit" \
	"$(cat "$T/rev/source" 2>/dev/null)" "Built from Org/repo, vendor/v, commit $v_changed (workflow run at $v_head), in LegoTypes/plugins master $m_one."
for bad_line in "$(vsrcline "$ok" "$v_head" "$m_side")" "$(vsrcline "$ok" "$v_head" "${m_one:0:9}")" \
	"$(vsrcline "$ok" "$v_head" "$(printf 'e%.0s' {1..40})")" "$(vsrcline "$ok" "$v_changed" "$m_one")" \
	"Built from Org/repo, vendor/v, in LegoTypes/plugins master $m_one."; do
	odset os-vendor && printf '%s\n' "$bad_line" >"$od/source"
	rm -rf "$T/rev"
	expect_fail "provenance: refuses the VM's line [${bad_line:0:60}...${bad_line: -50}]" pv "$T/fresh" os-vendor "$v_head"
done
odset os-vendor && vsrcline "$ok" "$v_changed" "$m_one" >"$od/source"
rm -rf "$T/rev"
expect_fail "provenance: this checkout is not at the commit" pv "$T/fresh" os-vendor "$v_changed"

# --- payload.sh: verify-payload.sh on a build ---------------------------------------------
vreset
po="$T/po"
rm -rf "$po" && mkdir -p "$po"
cp "$vp/alpha.pkg" "$po/os-alpha-1.0.pkg"
printf 'Built from Org/plugins, branch br-alpha, commit %s.\n' "$commit" >"$po/source"
printf 'abi: FreeBSD:15:amd64\nseries: 26.7\nfreebsd: 15.1-RELEASE-p3\nphp: 85\npython: 313\n' >"$po/build"
rc 'ABI=FreeBSD:15:amd64' 'SERIES=26.7' 'SERVE=FreeBSD:15:amd64/26.7'
pl() { COMMIT="${PCOMMIT-$commit}" bash "$S/payload.sh" os-alpha "$po" "$vp/net/alpha"; }
expect_eq "payload.sh: verify-payload.sh's verdict, the version from the file name" "$(pl 2>&1 | head -1)" "payload: OK (8 files)"
mv "$po/os-alpha-1.0.pkg" "$po/os-alpha-1.1.pkg"
expect_fail "payload.sh: a file name with another version than the Makefile's" pl
mv "$po/os-alpha-1.1.pkg" "$po/os-alpha-1.0.pkg"
PCOMMIT=$other
expect_fail "payload.sh: another commit than the package's" pl
PCOMMIT=''
expect_fail "payload.sh: no commit" pl
unset PCOMMIT
touch "$po/extra"
expect_fail "payload.sh: not a build" pl
rm "$po/extra"

# --- review-sums.sh: the review job's sums, and the check sign and release run against them -------
rs() { bash "$root/scripts/review-sums.sh" "$@"; }
rv_="$T/rv"
# rsset: $od, a build of os-alpha, and $rv_, the review job's files for it; rsv, the sums print gives
rsset() {
	unset RS_MANIFEST
	odset
	rm -rf "$rv_" && mkdir -p "$rv_"
	printf 'Built from Org/plugins, branch br-alpha, commit %s.\n' "$commit" >"$rv_/source"
	printf 'abi: FreeBSD:15:amd64\nseries: 26.7\nfreebsd: 15.1-RELEASE-p3 (reported by the build VM)\nphp: 85\npython: 313\n' >"$rv_/build"
	printf 'built os-alpha-1.0_1.pkg %s\ncarry FreeBSD:15:amd64/26.7 os-beta-1.0 %s immutable=no\ncommit %s\n' \
		"$(sum "$od/os-alpha-1.0_1.pkg")" "$(printf 'b%.0s' {1..64})" "$commit" >"$rv_/manifest"
	mapfile -t rsv < <(rs print os-alpha "$od" "$rv_" | cut -d= -f2)
}
# rsc: check against the sums print gave and $commit; RS_PKG, RS_MANIFEST, RS_SOURCE, RS_BUILD and
# RS_COMMIT replace one
rsc() {
	PKG_SHA256=${RS_PKG-${rsv[0]-}} MANIFEST_SHA256=${RS_MANIFEST-${rsv[1]-}} SOURCE_SHA256=${RS_SOURCE-${rsv[2]-}} \
		BUILD_SHA256=${RS_BUILD-${rsv[3]-}} COMMIT=${RS_COMMIT-$commit} rs check os-alpha "$od" "$rv_"
}
rscwith() {
	local "$1"
	rsc
}
# rsmanifest <built name> <built sum> <commit>: rewrite the manifest; its new sum is the expected one, so
# only the line check can refuse it
rsmanifest() {
	printf 'built %s %s\ncommit %s\n' "$1" "$2" "$3" >"$rv_/manifest"
	RS_MANIFEST=$(sum "$rv_/manifest")
}
rsset
expect_eq "review-sums: print names the four sums, each the file's sha256" "$(rs print os-alpha "$od" "$rv_")" \
	"pkg_sha256=$(sum "$od/os-alpha-1.0_1.pkg")
manifest_sha256=$(sum "$rv_/manifest")
source_sha256=$(sum "$rv_/source")
build_sha256=$(sum "$rv_/build")"
expect_eq "review-sums: check passes on the files print summed" "$(rsc >/dev/null 2>&1; echo "rc=$?")" "rc=0"
echo changed >>"$od/os-alpha-1.0_1.pkg"
expect_eq "review-sums: another package" "$(rsc 2>&1 >/dev/null)" "review-sums.sh: the package is not the one the review job showed"
for f in manifest source build; do
	rsset && echo changed >>"$rv_/$f"
	expect_eq "review-sums: another $f" "$(rsc 2>&1 >/dev/null)" "review-sums.sh: review/$f is not the one the review job wrote"
done
rsset && rsmanifest 'os-alpha-9.9.pkg::error::x' "$(sum "$od/os-alpha-1.0_1.pkg")" "$commit"
err=$(rsc 2>&1 >/dev/null)
expect_eq "review-sums: the manifest's built line names another file, and nothing of it is repeated" \
	"$err" "review-sums.sh: the manifest's built line is not this package and its sha256"
rsset && rsmanifest os-alpha-1.0_1.pkg "$(printf 'c%.0s' {1..64})" "$commit"
expect_fail "review-sums: the manifest's built line has another sha256" rsc
rsset && rsmanifest os-alpha-1.0_1.pkg "$(sum "$od/os-alpha-1.0_1.pkg")" "$other"
expect_eq "review-sums: the manifest's commit line is another commit" "$(rsc 2>&1 >/dev/null)" \
	"review-sums.sh: the manifest's commit line is not the approved commit"
rsset
expect_fail "review-sums: the approved commit is another than the manifest's" rscwith "RS_COMMIT=$other"
rsset && printf 'built os-alpha-1.0_1.pkg %s\nbuilt os-alpha-1.0_1.pkg %s\ncommit %s\n' "$(sum "$od/os-alpha-1.0_1.pkg")" \
	"$(sum "$od/os-alpha-1.0_1.pkg")" "$commit" >"$rv_/manifest" && RS_MANIFEST=$(sum "$rv_/manifest")
expect_fail "review-sums: two built lines" rsc
rsset
for v in RS_PKG= "RS_PKG=$(printf 'A%.0s' {1..64})" "RS_SOURCE=$(printf 'a%.0s' {1..63})" RS_BUILD=x; do
	expect_eq "review-sums: a missing or malformed sum (${v:0:20})" "$(rscwith "$v" 2>&1 >/dev/null)" \
		"review-sums.sh: the review job's sums are missing or not 64 lower-case hex digits"
done
expect_eq "review-sums: an abbreviated approved commit" "$(rscwith "RS_COMMIT=${commit:0:9}" 2>&1 >/dev/null)" \
	"review-sums.sh: COMMIT must be the approved commit, 40 lower-case hex digits"
rsset && touch "$rv_/extra"
expect_fail "review-sums: another file in review/" rsc
rsset && rm "$rv_/source" && ln -s build "$rv_/source"
expect_fail "review-sums: a symlink in review/" rsc
rsset && rm "$rv_/build"
expect_fail "review-sums: no build in review/" rsc
expect_fail "review-sums: print refuses an incomplete review/" rs print os-alpha "$od" "$rv_"
rsset && touch "$od/extra"
expect_fail "review-sums: print refuses an out/ that is not a build" rs print os-alpha "$od" "$rv_"
# a sha256 that is not 64 lower-case hex digits never reaches the job's outputs
mkdir -p "$T/badsha"
printf '%s\n' '#!/bin/sh' 'echo "ABC  $1"' >"$T/badsha/sha256sum"
chmod 755 "$T/badsha/sha256sum"
rsset
expect_eq "review-sums: print refuses a sum that is not 64 hex digits, and prints nothing" \
	"$(PATH="$T/badsha:$PATH" rs print os-alpha "$od" "$rv_" 2>/dev/null; echo "rc=$?")" "rc=1"
expect_fail "review-sums: usage" rs print os-alpha "$od"
expect_fail "review-sums: an unknown command" rs sum os-alpha "$od" "$rv_"

# --- summary.sh ---------------------------------------------------------------------------
conf 'os-alpha   Org/plugins br-alpha net/alpha yes'
reset_stub
so="$T/so" sr="$T/sr"
# soset [<vpkg filter>]: $so, a build of net/alpha as the review job downloads it (its source and
# build lines the VM's own), and $sr, the review job's source, build and manifest
soset() {
	vsrc && vstage && vpkg "$@"
	rm -rf "$so" "$sr" && mkdir -p "$so" "$sr"
	cp "$vp/alpha.pkg" "$so/os-alpha-1.0.pkg"
	printf 'Built from the VM, which no one reads.\n' >"$so/source"
	printf 'abi: FreeBSD:15:amd64\nseries: 26.7\nfreebsd: 15.1-RELEASE-p3\nphp: 85\npython: 313\n' >"$so/build"
	printf 'Built from Org/plugins, branch br-alpha, commit %s.\n' "$commit" >"$sr/source"
	printf 'abi: FreeBSD:15:amd64\nseries: 26.7\nfreebsd: 15.1-RELEASE-p3 (reported by the build VM)\nphp: 85\npython: 313\n' >"$sr/build"
	printf 'built os-alpha-1.0.pkg %s\ncommit %s\n' "$(sum "$so/os-alpha-1.0.pkg")" "$commit" >"$sr/manifest"
}
smr() {
	COMMIT="${SCOMMIT-$commit}" PLUGIN_DIR="$vp/net/alpha" \
		bash "$S/summary.sh" os-alpha "$so" "$sr"
}
# the post-install script holds backtick runs, one a line of its own, and a marker for "package text"
soset '.scripts["post-install"] = "echo ``` and ```` PKGTEXT\n````\nexit 0"'
s=$(smr 2>/dev/null) || bad "summary: exited non-zero"
o=$(outside <<<"$s")
expect_eq "summary: it opens by saying it is the one summary to read" "$(head -n 1 <<<"$s")" \
	"**Read this summary, under the review job, and no other. The build job writes none: any summary under the build job means its runner was tampered with, so reject the run (cancel it; do not approve).**"
expect_eq "summary: every fence closes" "$(grep -c UNCLOSED <<<"$o")" 0
expect_eq "summary: no package text outside a fence" \
	"$(grep -cE 'PKGTEXT|payload:|script |product_|/usr/local|abi:|Built from|built os-alpha|```' <<<"$o")" 0
expect_eq "summary: the payload passes" "$(grep -c '^### Payload check: passed$' <<<"$o")" 1
expect_eq "summary: the decoded scripts, verbatim" "$(grep -cxF "$(printf '\techo ``` and ```` PKGTEXT')" <<<"$s")" 1
expect_eq "summary: a fence longer than the longest backtick run inside" "$(grep -cx '`````' <<<"$s")" 2
expect_eq "summary: the commit, outside a fence" "$(grep -c "\`$commit\`" <<<"$o")" 1
expect_eq "summary: the built file and its sha256" "$(grep -cx "sha256 $(sum "$so/os-alpha-1.0.pkg")" <<<"$s")" 1
expect_eq "summary: the manifest" "$(grep -cx "built os-alpha-1.0.pkg $(sum "$so/os-alpha-1.0.pkg")" <<<"$s")" 1
expect_eq "summary: the review job's source line" "$(grep -cxF "$(cat "$sr/source")" <<<"$s")" 1
expect_eq "summary: never the VM's" "$(grep -c 'Built from the VM' <<<"$s")" 0
expect_eq "summary: the version file" "$(grep -c '"product_version": "1.0"' <<<"$s")" 1
expect_eq "summary: the review job's build lines" "$(grep -cx 'freebsd: 15.1-RELEASE-p3 (reported by the build VM)' <<<"$s")" 1
expect_eq "summary: the first release" "$(grep -c '^No earlier release of os-alpha: nothing to compare\.$' <<<"$o")" 1
# a newer build than a published one whose post-install script differs
vpkg
publish os-alpha-0.9 2026-01-01T00:00:00Z
cp "$vp/alpha.pkg" "$STUB/assets/os-alpha-0.9/os-alpha-0.9.pkg"
soset '.scripts["post-install"] = "echo ``` and ```` PKGTEXT\n````\nexit 0"'
s=$(smr 2>/dev/null) || bad "summary with a release: exited non-zero"
o=$(outside <<<"$s")
expect_eq "summary: compared with the newest release" "$(grep -c '^Material differences from the newest release:$' <<<"$o")" 1
expect_eq "summary: the newest release and the difference, in a fence" \
	"$(grep -cxE 'newest release: os-alpha-0\.9|script post-install: changed' <<<"$s") $(grep -cE 'os-alpha-0\.9|post-install' <<<"$o")" "2 0"
soset
s=$(smr 2>/dev/null) || bad "summary, same as the release: exited non-zero"
expect_eq "summary: no material difference" "$(grep -c '^No material differences from the newest release:$' <<<"$(outside <<<"$s")")" 1
# a failed payload check (a version file of its own, with a line of backticks): reported, fenced
soset
printf '````\n`````` PKGTEXT\n' >"$vu/opnsense/version/alpha"
vrepack
cp "$vp/alpha.pkg" "$so/os-alpha-1.0.pkg"
printf 'built os-alpha-1.0.pkg %s\ncommit %s\n' "$(sum "$so/os-alpha-1.0.pkg")" "$commit" >"$sr/manifest"
s=$(smr 2>/dev/null) || bad "summary, a failed payload check: exited non-zero"
o=$(outside <<<"$s")
expect_eq "summary: a failed payload check is reported" "$(grep -c '^### Payload check: FAILED$' <<<"$o")" 1
expect_eq "summary: the sign job will refuse it" "$(grep -c 'The sign job runs this check again and will refuse to sign this build\.' <<<"$o")" 1
expect_eq "summary: a failed check's text and the version file in fences" "$(grep -cE 'PKGTEXT|verify-payload|```|UNCLOSED' <<<"$o")" 0
expect_eq "summary: the version file verbatim" "$(grep -cx '`````` PKGTEXT' <<<"$s")" 1
# what summary.sh cannot report fails it, so no approval is asked for without it
soset
expect_eq "summary: a release asset that is not a package" \
	"$(printf 'junk\n' >"$STUB/assets/os-alpha-0.9/os-alpha-0.9.pkg"; smr >/dev/null 2>&1; echo "rc=$?")" "rc=1"
rm "$STUB/assets/os-alpha-0.9/os-alpha-0.9.pkg"
expect_fail "summary: a release asset that cannot be downloaded" smr
reset_stub
touch "$STUB/fail_list"
expect_fail "summary: releases that cannot be listed" smr
rm "$STUB/fail_list"
SCOMMIT=${commit:0:9}
expect_fail "summary: an abbreviated commit" smr
unset SCOMMIT
touch "$so/extra"
expect_fail "summary: not a build" smr
rm "$so/extra"
rm "$sr/manifest"
expect_fail "summary: no manifest from the review job" smr
soset && rm "$sr/source"
expect_fail "summary: no source line from the review job" smr
expect_fail "summary: usage" bash "$root/scripts/summary.sh" os-alpha "$so"

echo "passed $pass, failed $failed"
[[ $failed -eq 0 ]]
