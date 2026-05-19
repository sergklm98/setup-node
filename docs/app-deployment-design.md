# App Deployment Design

## Purpose

This document defines how application deployment should work inside the setup-node system.

## Scope

- Application directory contract in apps/<app-name>/.
- Configuration sources and override behavior.
- Interaction with shared helper functions.
- Handling of creds directory in git.

## Application Directory Contract

Each application directory should contain:

- configure.sh
- defaults.env

### configure.sh

Responsibilities:

- Main entrypoint for deploy and configuration of the application.
- Uses shared helpers from infra/functions.sh.
- Generates required runtime files from templates.
- Can include application-specific pre-configuration logic.
- Can include application-specific post-configuration logic.

Behavior rules:

- Must be idempotent.
- Must detect current state before applying changes.
- Must log clear detect/apply/no-op/fail steps.
- Must exit non-zero on unrecoverable error.

### defaults.env

Responsibilities:

- Provides minimal default values required for successful first deployment.
- Acts as base layer for app configuration.

Behavior rules:

- Should include only safe default values.
- Secrets must not be stored here.

## Configuration Sources

Application configuration can be overridden from:

1. creds/current/<app>.conf
2. creds/current/node.conf

In addition, creds/current/ may include application files directly (for example: Caddyfile) that are consumed by configure.sh.

## Path Conventions

- On control machine, config is authored in creds/nodes/<node>/ using full paths.
- setup-node.sh copies node.conf to the target using full node path semantics.
- In bootstrap.sh, Stage 0 creates or updates creds/current -> creds/nodes/<node>.
- After Stage 0, runtime scripts should read configuration only through creds/current/.

## Configuration Precedence

Recommended effective precedence (highest to lowest):

1. creds/current/<app>.conf
2. creds/current/node.conf
3. apps/<app-name>/defaults.env

Meaning:

- App-specific config overrides node-level config.
- Node-level config overrides app defaults.
- Missing required values must fail fast with actionable error.

## Integration with apps.sh

- apps.sh reads APPS list and calls apps/<app-name>/configure.sh for each enabled app.
- apps not listed in APPS are skipped.
- Each configure.sh handles its own idempotent convergence.

## creds Directory and Git Policy

- Entire creds/ directory is gitignored in normal workflow.
- Only selected example files are committed to git (for documentation and onboarding).
- Real node-specific credentials and runtime configuration remain local/synced, not versioned in public git.

## Non-Goals (current phase)

- Secret encryption design.
- Full rollback orchestration for app deploy failures.
- Multi-node parallel app orchestration.
