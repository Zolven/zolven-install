# Zolven Install

Canonical machine bootstrap and cleanup for Zolven.

This repository owns machine bootstrap, runtime repository checkout/update,
install-state and cloud-bootstrap files, and narrow cleanup/decommission
foundations. Product onboarding, browser authentication, business
configuration, and runtime state belong to
[`Zolven/zolven`](https://github.com/Zolven/zolven).

## Install

Local self-hosting is the default:

```bash
curl -fsSL https://raw.githubusercontent.com/Zolven/zolven-install/main/install.sh | bash
```

The installer uses GitHub CLI to clone the private `Zolven/zolven` repository,
prepares the runtime, and delegates to its installer. Local product setup then
continues through the Zolven CLI:

```bash
zolven setup
zolven telegram
zolven mail
zolven entities
```

Useful local variants:

```bash
bash install.sh --mode local
bash install.sh --mode local --dev
bash install.sh --mode local --migrate-db ~/Documents/Empresa/_Index/finance_ops.sqlite
bash install.sh --mode local --launchd
bash install.sh --mode local --summary
```

## Cloud

Cloud mode is operator-run, Linux-only VM bootstrap for hosted Zolven runtimes:

```bash
bash install.sh --mode cloud --enrollment-token <one-time-token>
```

Cloud mode installs host prerequisites, enrolls the VM, writes the runtime
bootstrap contract, clones or updates `Zolven/zolven`, and delegates to the
runtime installer in cloud mode. It does not collect company information,
owner details, channel configuration, AI keys, or other customer settings;
browser onboarding owns those.

No cloud control-plane endpoint is embedded in this public repository. Operators
must provide a provisioned endpoint through one of:

```bash
ZOLVEN_CLOUD_API_BASE_URL=<provisioned-control-plane-base-url>
ZOLVEN_CLOUD_ENROLLMENT_URL=<provisioned-enrollment-url>
```

Additional cloud inputs:

```bash
ZOLVEN_CLOUD_MACHINE_REGION=mad
ZOLVEN_CLOUD_TUNNEL_PROVIDER=wireguard
ZOLVEN_CLOUD_ENROLLMENT_STUB_FILE=/path/to/enrollment-response.json  # dev/test only
```

## Contract

| Resource | Local | Cloud |
| --- | --- | --- |
| Runtime repository | `~/.local/opt/zolven` | `/opt/zolven` |
| Runtime data | `~/.local/share/zolven` | `/var/lib/zolven` |
| CLI launcher | `~/.local/bin/zolven` (or `/usr/local/bin/zolven` for root) | `/usr/local/bin/zolven` |
| OpenClaw workspace | `~/.openclaw/workspace/zolven` | `/var/lib/zolven/openclaw/workspace/zolven` |
| Runtime handshake | `Zolven/zolven:.zolven-install-contract` (version `1`) | same |
| Install state | `${ZOLVEN_DATA_DIR}/install/install-state.env` | same |
| Cloud bootstrap | not written | `${ZOLVEN_DATA_DIR}/config/cloud-bootstrap.env` |
| Tunnel bootstrap | not written | `${ZOLVEN_DATA_DIR}/config/tunnel.env` |

Product-owned environment variables use the `ZOLVEN_` prefix. OpenClaw remains
OpenClaw, and its upstream `OPENCLAW_*` configuration names are preserved.
The runtime handshake is a release gate: installation stops before runtime
execution unless the checked-out product repository declares the matching
contract version and exposes the required Zolven identifiers.
`claim_url` from cloud enrollment is printed once and is not persisted;
cloud-bootstrap files are written with owner-only permissions.

The Intelligence distribution contract is owned by
[`Zolven/zolven-intelligence`](https://github.com/Zolven/zolven-intelligence):
the npm package is `@zolven/intelligence`, its product binary is
`zolven-intelligence`, and its release asset is `zolven-intelligence.tgz`.
This installer gates on the package identity but does not download the release
asset.

## Cleanup

Preview cleanup first:

```bash
bash cleanup.sh --dry-run
bash cleanup.sh -y
```

Remote fallback:

```bash
curl -fsSL https://raw.githubusercontent.com/Zolven/zolven-install/main/cleanup.sh | bash -s -- --dry-run
curl -fsSL https://raw.githubusercontent.com/Zolven/zolven-install/main/cleanup.sh | bash -s -- -y
```

Cleanup recognizes only Zolven-owned paths, launchers, services, workspace
names, and marker-fenced mail configuration. It never removes an OpenClaw home,
unrelated OpenClaw workspaces, shared Node/pnpm/GitHub CLI tooling, or unmarked
user data. The optional `--purge-intelligence-cli` flag removes only the
Zolven-owned Intelligence package.

Cloud cleanup attempts best-effort runtime decommission before local deletion.
Use `--keep-cloud-registration` for a same-VM repair flow.

```bash
bash cleanup.sh -y --keep-watch-dir
bash cleanup.sh -y --keep-cloud-registration
bash cleanup.sh -y --purge-intelligence-cli
```

This is a pre-launch hard cut, not an in-place migration. Remove any development
installation created under the former product identity with the cleanup tooling
from that historical checkout before installing Zolven.

## Help

```bash
bash install.sh --help
bash cleanup.sh --help
```
