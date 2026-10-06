#!/bin/sh
# In the FreeBSD VM, for the canary: build every catalogue package twice, as a
# publish would (fresh) and with opnsense/plugins master's Mk/ (rebased), into
# canary/<package>/: fresh.pkg, fresh.source, rebased.pkg, or for a failed build
# <variant>.log (its whole log, kept for the run's artifact) and <variant>.tail
# (its end, for the issue). Every package and variant is attempted; a failure
# never stops the rest. Needs UPSTREAM_PHP and UPSTREAM_PYTHON (upstream.sh).
set -u
rm -rf canary
catalogue=$(sh scripts/packages.sh catalogue) || {
	echo "canary-vm.sh: cannot read the catalogue" >&2
	exit 1
}
for p in $catalogue; do
	d=canary/$p
	mkdir -p "$d"
	for variant in fresh rebased; do
		mk=
		if [ "$variant" = rebased ]; then mk=upstream; fi
		if MK_FROM=$mk sh scripts/build-package.sh "$p" >"$d/$variant.log" 2>&1; then
			mv out/*.pkg "$d/$variant.pkg"
			if [ "$variant" = fresh ]; then cp out/source "$d/fresh.source"; fi
			rm -f "$d/$variant.log"
		else
			tail -n 40 "$d/$variant.log" >"$d/$variant.tail"
		fi
	done
done
