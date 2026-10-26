# opnsense-repo

LegoTypes vendor repository for OPNsense plugins: the os-legotypes repository package, the build workflows, and the signed package repository (deployed by the workflows to this repository's GitHub Pages, <https://legotypes.github.io/opnsense-repo/>).

The plugins, what they do and how to install them: <https://legotypes.github.io> (install guide and signing-key fingerprint: <https://legotypes.github.io/install/>).

## Publishing

[`packages.conf`](packages.conf) lists every package, the repository, branch and directory it is built from, and whether it is in the catalogue. Each publish builds **one** package; every other catalogue package is carried forward byte for byte from its latest release, so work on another plugin never ships with it. Every package builds in the pinned framework (below).

| Package | Source | How it ships |
| --- | --- | --- |
| `os-wg-client-tunnels` | `LegoTypes/plugins`, `main`, `net/wg-client-tunnels` | catalogue, `publish` |
| `os-mac-alias-cache` | `LegoTypes/plugins`, `main`, `net/mac-alias-cache` | catalogue, `publish` |
| `os-wan-failover` | `LegoTypes/plugins`, `main`, `net/wan-failover` | catalogue, `publish` (not on the site) |
| `os-unbound-upstream` | `LegoTypes/plugins`, `main`, `dns/unbound-upstream` | catalogue, `publish` (not on the site) |
| `os-legotypes` | this repository, `vendor/legotypes` on `main` | catalogue, `publish` |

1. Commit the change to the plugin's directory on `main` of `LegoTypes/plugins` with a `PLUGIN_VERSION` or `PLUGIN_REVISION` bump, and push it. A run whose version already has a release fails before anything is published: pkg would not see an unchanged version as an update.
2. Start the workflow at the commit to publish, named in full. For `os-legotypes`, from `main` at its head (after a `git fetch`): `gh workflow run publish -R LegoTypes/opnsense-repo -f package=os-legotypes -f commit=$(git rev-parse origin/main)`; the run refuses any commit but the one it runs at. For a plugin, a commit on `main` of `LegoTypes/plugins`, for example `gh workflow run publish -R LegoTypes/opnsense-repo -f package=os-wan-failover -f commit=$(git -C <plugins checkout> rev-parse origin/main)`; a commit that is not on `main` of the package's repository is refused.
3. The `build` job builds exactly that commit in FreeBSD 15, in the pinned framework, and uploads the package; it holds no secret and names no environment, and nothing it does after the VM is trusted. The `review` job then runs on a runner of its own, with this repository's scripts and GitHub's actions only: it writes the release notes' source and build lines itself (the commit and the package's directory, the framework pin in `repo.conf` and OPNsense's mirror, never the VM's lines), checks the version is new, and ends with a summary on the run's page, **build / review summary**. Read it before approving:
   - the commit, the built file with its sha256, and the source line its release notes will start with;
   - the manifest: every release that will be carried forward, with the sha256 its notes record and whether it is immutable;
   - the payload check: whether the package holds exactly what the plugin source at the commit installs. That covers the install scripts: `verify-payload.sh` derives them from the plugin directory at the commit, as `Mk/plugins.mk` and `pkg create` make them, from its own reviewed copies of `opnsense/plugins`' `Templates/` and `Keywords/`, and refuses a package whose scripts differ by one byte (`scripts: derived from the source, identical (<n>)`). Their text is in a collapsed section for reference; there is nothing in it to review. With files, manifest, annotations and scripts all derived, what the build VM chooses is down to each file's mtime, the FreeBSD minor version in the `FreeBSD_version` annotation, and the order of the `@sample`/`@shadow` expansions within a script, each of which is derived (the plist is its own `sort`); besides those, only how the archive is packed (member order, compression, the sum's kind), which changes no content;
   - the material differences from the package's newest release (`compare-package.sh`, as the canary reports them);
   - the version file the package installs, and the release notes' build lines (the FreeBSD version as the build VM reported it).

   Everything the build made is shown as it is, in code blocks. Read that summary and no other; it opens by saying so. The build job writes no summary, and neither does the VM action at its pinned commit or the `anyvm.py` it runs (checked at `vmactions/freebsd-vm` a2f9a41f and anyvm 0.7.2), so any text under **build / build summary** means the build runner was tampered with, however much it looks like the review summary: reject the run (cancel it; do not approve).
4. Approve the `release` environment only for the build you meant, having read only **build / review summary**; with anything under **build / build summary**, cancel the run instead. Its `sign` job holds the signing key and runs only GitHub's own actions and this repository's scripts. Before the key is staged it checks the package against the plugin source at the commit again, and refuses one that fails the payload check; it checks again that the version has no release (an approval can come hours later); it builds `pkg` from the source pinned in [`repo.conf`](repo.conf) (`PKG_TOOL_COMMIT`), and carries the other catalogue packages forward from their releases, each checked against the sha256 in its notes, refusing any change from the manifest the review job wrote. It then signs the catalogue and stamps each served tree. `publish` deploys it to Pages and, only then, records the build as the release `<package>-<version>`.
5. Firewalls update from System > Firmware > Plugins, or with `pkg upgrade`.

The site serves the signed repository, its public key and `packages.txt`, and no package at its root: `os-legotypes` itself installs from the signed repository (<https://legotypes.github.io/install/>).

**If the `sign` job fails** (a payload check, a release changed since approval), nothing was published: fix the cause and start a new publish. It reports "no package artifact: re-run the whole workflow" when the build's or the review's artifact is gone; use **Re-run all jobs**.

**If the `review` job fails because OPNsense's PHP or Python changed since the build** (`provenance.sh` says upstream.sh "now says" another value), use **Re-run all jobs** or start a new publish: **Re-run failed jobs** runs only `review` again, against the old build, and fails again.

**If a run fails after its deploy** (the catalogue went live but the `release` job did not create the release): use **Re-run failed jobs** on that run; its artifact still holds the deployed build. Never start a new publish for it: that would build it again, a different file under the same version. Until the release exists, every publish fails at carry-forward, which checks that the live catalogue serves exactly each package's newest release, so nothing is silently rolled back.

**If the `review` job fails at the manifest** ("serves ... but its newest release ... is ..."), straight after another publish deployed: Pages caches each file for up to 10 minutes (a query string does not bypass it), so the live catalogue can still be the previous deploy. Wait 10 minutes and use **Re-run failed jobs**. If no publish deployed in the last 10 minutes, the publish that deployed the live catalogue has no release yet: re-run its failed jobs, as above.

A bad release is replaced by publishing a newer version: pkg never downgrades.

The workflows run the scripts in [`scripts/`](scripts); `bash tests/run.sh` tests them with stand-ins for `gh`, `git`, `make`, `pkg`, `curl` and `apt-get`.

After a publish, `bash scripts/verify-catalogue.sh <package>` checks what firewalls will check: every served
catalogue's signature, every served tree's stamp (`scripts/stamp-check.sh`: one file in its format, signed by the
published key, carrying that key and naming that tree), that the target series serves the package's newest release,
and that the release asset matches its notes. Straight after a deploy, Pages may still serve the previous deploy's
`packages.txt` for up to 10 minutes: a "serves ... its newest release is ..." failure then clears by itself, so run
it again after 10 minutes before acting on it.

## The pinned framework

Every package builds inside one `opnsense/plugins` commit, `FRAMEWORK` in [`repo.conf`](repo.conf). The build fetches
that commit by its SHA and copies the package's directory into it, so the `Mk/`, `Keywords/`, `Templates/` and
`Scripts/` a package is built with are the pin's, not whatever `opnsense/plugins` master holds that day. The plugin
repository holds only the plugins: `LegoTypes/plugins` has one `main`, with each plugin in its directory, and no copy
of the framework.

It is pinned so that a package's scripts and plist change only when this repository says so: `verify-payload.sh`
derives the install scripts from its own reviewed copies of `Templates/` and `Keywords/`, and a framework that moved
under a build would make the payload check refuse it.

To move it, edit `FRAMEWORK` in `repo.conf` in a reviewed commit:

1. The canary says when upstream master has moved past the pin (a NOTE from `canary-constants.sh`, and a
   "upstream master's framework would change ..." finding on each package it would change). Choose a commit of
   `opnsense/plugins` master. The canary refuses a pin that is not an ancestor of upstream master, so a commit from
   a fork or a branch of `opnsense/plugins` cannot be pinned.
2. Check what changed in the four directories (the canary lists the `Templates/` and `Keywords/` differences), and
   change the copies in `verify-payload.sh` along with them where they differ (see the canary section).
3. Set the full 40-digit SHA, run `bash tests/run.sh`, and review the commit as any other change.
4. Publish each plugin with a `PLUGIN_REVISION` bump: until it is republished, a package keeps the framework it was
   built in, and the canary's "a publish now would change ..." finding says so.

## The canary

`canary` runs every Monday (and from the Actions tab). It reads OPNsense's mirror for the series it ships and
the PHP and Python core depends on (`scripts/upstream.sh`). It then builds every catalogue package twice in
FreeBSD 15, as a publish would now (in the pinned framework) and in `opnsense/plugins` master's head instead,
and compares both with the package of its newest release (`scripts/compare-package.sh`). Each package has one issue labelled `canary`,
opened or updated when something material differs and closed when it is clean again. `canary: upstream series`
opens when OPNsense ships a newer series or a new FreeBSD ABI, and when the pinned framework no longer agrees
with what `verify-payload.sh` copies of `Templates/` and `Keywords/` to derive the install scripts
(`scripts/canary-constants.sh`; upstream master's difference is only a NOTE, and the pin must be an ancestor of
master): a template byte for byte, a keyword file's flags and script bodies as `verify-payload.sh --model` reads them (a change to its comments is not
reported; a line of another kind is). A material finding fails the run.

The canary never publishes. A finding is acted on by a person:

- **"a publish now would change ..."**: bump `PLUGIN_REVISION` in the plugin's directory on `main` and publish.
- **"upstream master's framework would change ..."**: upstream has moved past the pin in a way that changes this
  package. Move the pin (The pinned framework), test, bump, publish.
- **NOTE "release ... was built from a commit this repository does not hold"**: the release was built before
  `LegoTypes/plugins` was one repository with a `main`, from a commit only the retired fork had, so the canary cannot
  compare the plugin's directory. Nothing is wrong. The package's next publish builds from `main` and clears it.
- **A failed build**: read the log tail in the issue.
- **The series issue**: see Series change.
- **"... master's Templates/... or Keywords/... differs from verify-payload.sh's copy"** (or is not in the form
  modelled, or a file is added or missing): compare master's file with the copy (`bash scripts/verify-payload.sh
  --copied Keywords/shadow.ucl`, and `--model <file>` for how a keyword file reads). The canary blocks nothing,
  but a package built from the changed file fails the payload check. Once the change is understood, change the
  copy in `verify-payload.sh` in a reviewed commit: a template whole, a keyword's flags and script bodies only,
  never its comment header. Change how they are used along with them (`Mk/plugins.mk`'s scripts and plist
  targets, `pkg create`), update the copies tests and fixtures in `tests/run.sh` (a template's blob id, the
  master-shaped keyword fixtures), and run the tests. Then move `FRAMEWORK` to a
  commit carrying the new `Templates/` and `Keywords/` in the same commit, or before the next publish: a package
  builds in the pin's copies, so a pin still holding the old ones builds a package whose scripts differ from
  what `verify-payload.sh` now derives, and that publish fails the payload check. Every row, `.` included,
  builds in the pin.

## Developing a plugin

1. **Source.**
   - Each plugin lives in its directory on `main` of `LegoTypes/plugins` (see `packages.conf`), and the
     repository holds no copy of `opnsense/plugins`.
   - A package builds in the pinned framework (The pinned framework), so upstream's changes reach a plugin only
     when `FRAMEWORK` moves. Run the plugin's tests again after it moves.
2. **Versions.**
   - `PLUGIN_VERSION` for a behaviour change, with a changelog line in `pkg-descr`.
   - `PLUGIN_REVISION` (`_N`) for a rebuild with no source change.
   - pkg only offers a firewall a version it has not got.
3. **Tests.**
   - The plugin's own suite on the test VM.
   - Its scenario harness where one exists.
   - The install rehearsal through the setup script with `OPNSENSE_HOST` pointing at the test VM.
4. **Publish.** Push to `main`, then run `gh workflow run publish -R LegoTypes/opnsense-repo -f
   package=<package> -f commit=<the commit on main>`, read the review job's summary, approve `release`, and
   run `bash scripts/verify-catalogue.sh <package>`.
5. **Firewall.**
   - A new plugin installs with its setup-script command (for example `opnsense install-wan-failover`).
   - Upgrades go through `opnsense upgrade-legotypes [package]`.
   - On the firewall, `configctl legotypes check` (Monit runs it every cycle as `legotypes_runtime`) says whether
     every LegoTypes package and the repository config fit the firewall's series and ABI, then reads the
     repository's signed catalogue stamp: one file, `stamp` beside the catalogue, holding the date, the run, the
     tree, the published key and a signature over all of them (its format is in `scripts/stamp-check.sh`). One file
     is cached whole by Pages, so a deploy can never be read half old and half new. It prints one line per finding
     and exits 1 on any MISMATCH, which Monit alerts on (and again when it clears):
     - **INFO** `catalogue published <UTC time> (<n> days ago)`: the stamp is valid, signed by a trusted LegoTypes
       key; the date says how fresh the catalogue is, as a pkg catalogue carries none.
     - **INFO**, no alert: an update available; a hand-installed package; the site cannot be reached or answers
       5xx (`could not fetch the stamp`); a stamp dated ahead of the firewall's clock.
     - **MISMATCH**, alert: a package or the repository config that does not fit the series or ABI; a site that
       answers without a valid stamp: a 404 (or any answer but 200 and 5xx) for the stamp, a stamp over 64 KiB, a
       malformed stamp, a key in it that is no trusted fingerprint, a signature that does not verify (a forged or
       edited stamp), a stamp for another tree.
     - `LegoTypes packages fit series <series> on <ABI>` closes the output only when there is no MISMATCH at all.
6. **A new plugin** needs:
   - a `packages.conf` row;
   - a `publish.yml` choice (`tests/run.sh` fails without it);
   - a README row;
   - a setup-script install command;
   - a `pkg-descr`: a regular file, not a symbolic link, holding only printable ASCII, tab and newline (bytes
     0x20 to 0x7E, tab and LF; a CR or any byte beyond ASCII fails the payload check);
   - a `PLUGIN_LICENSE`, if the Makefile sets one, of one plain word (`[A-Za-z0-9._+-]+`; unset, it is
     BSD2CLAUSE);
   - no `PLUGIN_DEPENDS` (dependencies are refused until their origin and version are derived from the verified
     upstream catalogue);
   - install script sources, if any, only as `+PRE_INSTALL`, `+POST_INSTALL`, `+PRE_DEINSTALL` and
     `+POST_DEINSTALL`, each alone or as `.pre` or `.post` (no other `+` file in the plugin directory): regular
     files holding only printable ASCII, tab and newline, each ending with a newline, and none making an empty
     script (one of blanks only).

## Series change

When the canary's series issue opens (or `configctl legotypes check` reports a series mismatch):

1. **Serve both series.** In `repo.conf`, set `SERIES` to the new series and add its tree to `SERVE`, which lists
   `<ABI>/<series>` entries (for example `SERIES=27.1`, `SERVE=FreeBSD:15:amd64/26.7 FreeBSD:15:amd64/27.1`). The
   old tree stays frozen at its last releases; every publish rebuilds it from them. While two trees are served,
   the new one holds only what has been released for it, so the first publish into it succeeds.
2. **Publish os-legotypes, then every plugin,** each with a `PLUGIN_REVISION` bump, so pkg on the new series
   sees a newer version.
3. **Upgrade the firewall.** At its next boot, os-legotypes points the repository at the series it now runs.
   Then run `opnsense upgrade-legotypes` and `opnsense check-drift`.
4. **Retire the old tree.** Once the firewall runs the new series, drop the old series from `SERVE`; the next
   publish no longer deploys its tree.

A new FreeBSD ABI follows the same steps: set `ABI` (and usually `SERIES`) to the new values and list both trees,
each under its own ABI (for example `SERVE=FreeBSD:15:amd64/26.7 FreeBSD:16:amd64/27.7`), so a firewall still on
the old ABI keeps finding its tree.
