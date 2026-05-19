# Future Ideas

This document tracks optional ideas that are not part of the current deployment flow contract.

## Config-driven host maintenance options

- `apt update && apt upgrade` as an optional scheduled or on-apply step.
- `podman auto-update` systemd service enable/disable via config flag.

## Network customization

- nftables rules and routing table entries configurable via `node.conf`.

## Quadlet integration

- Symlink `/etc/containers/systemd` to `creds/systemd` so Quadlet unit files are managed as part of the synced config tree.

## App runtime backends

- Apps support multiple backends declared per app: `quadlet`, `podman run`, `docker run`, `compose`, and potentially plain systemd service.
- `apps.sh` (or each app `configure.sh`) selects backend based on app config.

## Automated testing and CI

- Add integration tests that start a temporary Docker container with sshd and validate setup scripts by connecting over SSH to localhost.
- Use this harness to test add-node/setup-node flow end-to-end without requiring a real remote VPS.
- Add GitHub Actions workflow for automated test runs; prefer Docker-based test jobs (rather than Podman) for compatibility with GitHub-hosted runners.
