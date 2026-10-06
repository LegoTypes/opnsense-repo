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
| `os-legotypes` | this repository, `vendor/legotypes` on `main` | catalogue, `publish` |

1. Commit the change on its branch with a `PLUGIN_VERSION` or `PLUGIN_REVISION` bump and push it. A run whose version already has a release fails before anything is published: pkg would not see an unchanged version as an update.
2. Start the workflow: `gh workflow run publish -R LegoTypes/opnsense-repo -f package=<package>`.
3. Approve the `release` environment when the run waits; it holds the signing key.
4. `publish` builds the package in FreeBSD 15, adds the other catalogue packages from their releases (each checked against the sha256 in its release notes), signs the catalogue, deploys it to Pages and, only then, records the build as the release `<package>-<version>`.
5. Firewalls update from System > Firmware > Plugins, or with `pkg upgrade`.

**If a run fails after its deploy** (the catalogue went live but the `release` job did not create the release): use **Re-run failed jobs** on that run; its artifact still holds the deployed build. Never start a new publish for it: that would rebuild from the branch head under the same version. Until the release exists, every publish fails at carry-forward, which checks that the live catalogue serves exactly each package's newest release, so nothing is silently rolled back.

A bad release is replaced by publishing a newer version: pkg never downgrades. Releases `publish-N` are the builds from before per-package publishing (all packages at once) and are kept as history.

The workflows run the scripts in [`scripts/`](scripts); `bash tests/run.sh` tests them with stand-ins for `gh`, `git`, `make`, `pkg` and `curl`.

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
   package=<package>`, approve `release`, and run `bash scripts/verify-catalogue.sh <package>`.
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
