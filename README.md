# opnsense-repo

LegoTypes vendor repository for OPNsense plugins: the os-legotypes repository package, the build workflows, and the signed package repository (deployed by the workflows to this repository's GitHub Pages, <https://legotypes.github.io/opnsense-repo/>).

The plugins, what they do and how to install them: <https://legotypes.github.io> (install guide and signing-key fingerprint: <https://legotypes.github.io/install/>).

## Publishing

[`packages.conf`](packages.conf) lists every package, the branch it is built from and whether it is in the catalogue. Each publish builds **one** package; every other catalogue package is carried forward byte for byte from its latest release, so work on another plugin's branch never ships with it.

| Package | Source | How it ships |
| --- | --- | --- |
| `os-wg-client-tunnels` | `LegoTypes/plugins`, branch `add-wg-ipv6-gateway` | catalogue, `publish` |
| `os-mac-alias-cache` | `LegoTypes/plugins`, branch `add-mac-alias-cache` | catalogue, `publish` |
| `os-legotypes` | this repository, `vendor/legotypes` on `main` | catalogue, `publish` |
| `os-avahi-reflector` | `LegoTypes/plugins`, branch `add-avahi-reflector` | release only, `avahi` (being retired in favour of net/netflector; not offered to firewalls) |

1. Commit the change on its branch with a `PLUGIN_VERSION` or `PLUGIN_REVISION` bump and push it. A run whose version already has a release fails before anything is published: pkg would not see an unchanged version as an update.
2. Start the workflow: `gh workflow run publish -R LegoTypes/opnsense-repo -f package=<package>` (or `gh workflow run avahi -R LegoTypes/opnsense-repo`).
3. Approve the `release` environment when the run waits; it holds the signing key.
4. `publish` builds the package in FreeBSD 15, adds the other catalogue packages from their releases (each checked against the sha256 in its release notes), signs the catalogue, deploys it to Pages and, only then, records the build as the release `<package>-<version>`. `avahi` builds and records the release only.
5. Firewalls update from System > Firmware > Plugins, or with `pkg upgrade`.

**If a run fails after its deploy** (the catalogue went live but the `release` job did not create the release): use **Re-run failed jobs** on that run; its artifact still holds the deployed build. Never start a new publish for it: that would rebuild from the branch head under the same version. Until the release exists, every publish fails at carry-forward, which checks that the live catalogue serves exactly each package's newest release, so nothing is silently rolled back.

A bad release is replaced by publishing a newer version: pkg never downgrades. Releases `publish-N` are the builds from before per-package publishing (all packages at once) and are kept as history.

The workflows run the scripts in [`scripts/`](scripts); `bash tests/run.sh` tests them with stand-ins for `gh`, `git`, `make` and `pkg`.
