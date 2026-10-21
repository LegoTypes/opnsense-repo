# opnsense-repo

LegoTypes vendor repository for OPNsense plugins: the os-legotypes repository package, the build workflows, and the signed package repository (deployed by the workflows to this repository's GitHub Pages, <https://legotypes.github.io/opnsense-repo/>).

The plugins, what they do and how to install them: <https://legotypes.github.io> (install guide and signing-key fingerprint: <https://legotypes.github.io/install/>).

## Publishing

[`packages.conf`](packages.conf) lists every package, the branch it is built from and whether it is in the catalogue. Each publish builds **one** package; every other catalogue package is carried forward byte for byte from its latest release, so work on another plugin's branch never ships with it.

| Package | Source | How it ships |
| --- | --- | --- |
| `os-wg-client-tunnels` | `LegoTypes/plugins`, branch `add-wg-ipv6-gateway` | catalogue, `publish` |
| `os-mac-alias-cache` | `LegoTypes/plugins`, branch `add-mac-alias-cache` | catalogue, `publish` |
| `os-wan-failover` | `LegoTypes/plugins`, branch `add-wan-failover` | catalogue, `publish` (not on the site) |
| `os-unbound-upstream` | `LegoTypes/plugins`, branch `add-unbound-upstream` | catalogue, `publish` (not on the site) |
| `os-legotypes` | this repository, `vendor/legotypes` on `main` | catalogue, `publish` |

1. Commit the change on its branch with a `PLUGIN_VERSION` or `PLUGIN_REVISION` bump and push it. A run whose version already has a release fails before anything is published: pkg would not see an unchanged version as an update.
2. Start the workflow at the commit to publish, named in full. For `os-legotypes`, from `main` at its head (after a `git fetch`): `gh workflow run publish -R LegoTypes/opnsense-repo -f package=os-legotypes -f commit=$(git rev-parse origin/main)`; the run refuses any commit but the one it runs at. For a plugin, a commit on its branch, for example `gh workflow run publish -R LegoTypes/opnsense-repo -f package=os-wan-failover -f commit=$(git -C <plugins checkout> rev-parse origin/add-wan-failover)`; a commit that is not on the package's branch is refused.
3. The `build` job builds exactly that commit in FreeBSD 15 and uploads the package; it holds no secret and names no environment, and nothing it does after the VM is trusted. The `review` job then runs on a runner of its own, with this repository's scripts and GitHub's actions only: it writes the release notes' source and build lines itself (the commit and the plugin source, `repo.conf` and OPNsense's mirror, never the VM's lines), checks the version is new, and ends with a summary on the run's page. Read it before approving:
   - the commit, the built file with its sha256, and the source line its release notes will start with;
   - the manifest: every release that will be carried forward, with the sha256 its notes record and whether it is immutable;
   - the payload check: whether the package holds exactly what the plugin source at the commit installs, and its install scripts as pkg will run them (the one part of a package not taken from `src/`);
   - the material differences from the package's newest release (`compare-package.sh`, as the canary reports them);
   - the version file the package installs, and the release notes' build lines (the FreeBSD version as the build VM reported it).

   Everything the build made is shown as it is, in code blocks.
4. Approve the `release` environment only for the build you meant. Its `sign` job holds the signing key and runs only GitHub's own actions and this repository's scripts. Before the key is staged it checks the package against the plugin source at the commit again, and refuses one that fails the payload check; it checks again that the version has no release (an approval can come hours later); it builds `pkg` from the source pinned in [`repo.conf`](repo.conf), and carries the other catalogue packages forward from their releases, each checked against the sha256 in its notes, refusing any change from the manifest the review job wrote. It then signs the catalogue and stamps each served tree. `publish` deploys it to Pages and, only then, records the build as the release `<package>-<version>`.
5. Firewalls update from System > Firmware > Plugins, or with `pkg upgrade`.

The site serves the signed repository, its public key and `packages.txt`, and no package at its root: `os-legotypes` itself installs from the signed repository (<https://legotypes.github.io/install/>).

**If the `sign` job fails** (a payload check, a release changed since approval), nothing was published: fix the cause and start a new publish. It reports "no package artifact: re-run the whole workflow" when the build's or the review's artifact is gone; use **Re-run all jobs**.

**If the `review` job fails because OPNsense's PHP or Python changed since the build** (`provenance.sh` says upstream.sh "now says" another value), use **Re-run all jobs** or start a new publish: **Re-run failed jobs** runs only `review` again, against the old build, and fails again.

**If a run fails after its deploy** (the catalogue went live but the `release` job did not create the release): use **Re-run failed jobs** on that run; its artifact still holds the deployed build. Never start a new publish for it: that would build it again, a different file under the same version. Until the release exists, every publish fails at carry-forward, which checks that the live catalogue serves exactly each package's newest release, so nothing is silently rolled back.

A bad release is replaced by publishing a newer version: pkg never downgrades. Releases `publish-N` are the builds from before per-package publishing (all packages at once) and are kept as history.

The workflows run the scripts in [`scripts/`](scripts); `bash tests/run.sh` tests them with stand-ins for `gh`, `git`, `make`, `pkg`, `curl` and `apt-get`.

After a publish, `bash scripts/verify-catalogue.sh <package>` checks what firewalls will check: every served
catalogue's signature, that the target series serves the package's newest release, and that the release asset
matches its notes.

## The canary

`canary` runs every Monday (and from the Actions tab). It reads OPNsense's mirror for the series it ships and
the PHP and Python core depends on (`scripts/upstream.sh`). It then builds every catalogue package twice in
FreeBSD 15, as a publish would now and with `opnsense/plugins` master's `Mk/`, and compares both with the
package of its newest release (`scripts/compare-package.sh`). Each package has one issue labelled `canary`,
opened or updated when something material differs and closed when it is clean again. `canary: upstream series`
opens when OPNsense ships a newer series or a new FreeBSD ABI. A material finding fails the run.

The canary never publishes. A finding is acted on by a person:

- **"a publish now would change ..."**: bump `PLUGIN_REVISION` on the plugin's branch and publish.
- **"upstream Mk/ would change ..."**: rebase the branch on the fork's master (below), test, bump, publish.
- **A failed build**: read the log tail in the issue.
- **The series issue**: see Series change.

## Developing a plugin

1. **Branches.**
   - Each plugin lives on its own branch of `LegoTypes/plugins` (see `packages.conf`). The fork's master only
     fast-forwards from upstream: `gh repo sync LegoTypes/plugins -b master`.
   - Rebase a plugin branch on it when the canary reports "upstream Mk/ would change", or before a feature
     release. Run the plugin's tests again after a rebase.
2. **Versions.**
   - `PLUGIN_VERSION` for a behaviour change, with a changelog line in `pkg-descr`.
   - `PLUGIN_REVISION` (`_N`) for a rebuild with no source change.
   - pkg only offers a firewall a version it has not got.
3. **Tests.**
   - The plugin's own suite on the test VM.
   - Its scenario harness where one exists.
   - The install rehearsal through the setup script with `OPNSENSE_HOST` pointing at the test VM.
4. **Publish.** Push the branch, then run `gh workflow run publish -R LegoTypes/opnsense-repo -f
   package=<package> -f commit=<the branch's commit>`, read the review job's summary, approve `release`, and
   run `bash scripts/verify-catalogue.sh <package>`.
5. **Firewall.**
   - A new plugin installs with its setup-script command (for example `opnsense install-wan-failover`).
   - Upgrades go through `opnsense upgrade-legotypes [package]`.
   - On the firewall, `configctl legotypes check` says whether every LegoTypes package fits its series and ABI.
6. **A new plugin** needs:
   - a `packages.conf` row;
   - a `publish.yml` choice (`tests/run.sh` fails without it);
   - a README row;
   - a setup-script install command.

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
