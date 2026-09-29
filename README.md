# opnsense-repo

LegoTypes vendor repository for OPNsense plugins: the os-legotypes repository package, its build workflow, and the signed package repository (deployed by the workflow to this repository's GitHub Pages, <https://legotypes.github.io/opnsense-repo/>).

The plugins, what they do and how to install them: <https://legotypes.github.io> (install guide and signing-key fingerprint: <https://legotypes.github.io/install/>).

## Publishing

Every publish builds and ships all four packages from their branch heads:

| Package | Source |
| --- | --- |
| `os-wg-client-tunnels` | `LegoTypes/plugins`, branch `add-wg-ipv6-gateway` |
| `os-avahi-reflector` | `LegoTypes/plugins`, branch `add-avahi-reflector` |
| `os-mac-alias-cache` | `LegoTypes/plugins`, branch `add-mac-alias-cache` |
| `os-legotypes` | this repository, `vendor/legotypes` on `main` |

1. Commit the change on its branch with a `PLUGIN_VERSION` or `PLUGIN_REVISION` bump and a `pkg-descr` entry, and push it. Without a bump, pkg sees the same version and firewalls do not upgrade.
2. Start the workflow: `gh workflow run publish -R LegoTypes/opnsense-repo` (it runs only on request).
3. Approve the `release` environment when the run waits; it holds the signing key.
4. The workflow builds the packages in FreeBSD 15, signs the catalogue, removes the key from the runner, deploys the repository to Pages, and keeps the `.pkg` files as the release `publish-N`.
5. Firewalls update from System > Firmware > Plugins, or with `pkg upgrade`.

Anything pushed to one of these branches ships with the next publish, whichever package it was run for: keep unfinished work off them.
