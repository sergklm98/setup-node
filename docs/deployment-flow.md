# Deployment Flow

## Purpose

This document defines how node deployment must work end-to-end so every rerun is idempotent and converges node state to desired configuration.

## Scope

- local operator machine with repository clone,
- target node reachable over SSH,
- desired state in creds/nodes/<node>/,
- app deployment through infra and apps contracts.

## Actors

- Operator: edits desired state and triggers apply.
- Control scripts: infra/add-node.sh, infra/setup-node.sh, bootstrap.sh.
- Node runtime: Debian host with Podman/Quadlet.

## High-Level Sequence

1. Node registration and SSH bootstrap.
2. Desired-state configuration authoring.
3. Remote apply run.
4. Host convergence.
5. App convergence.
6. Verification.
7. Repeat apply when state changes.

## Step-by-Step Flow

## Step 0: Preconditions

Required before apply:
- node exists in SSH config,
- node config exists at creds/nodes/<node>/node.conf,
- required keys are defined (NODE_NAME, NETWORK_IP4_CIDR, APPS at minimum),
- repository is available from target node.

Idempotency requirement:
- precondition checks are read-only and must not mutate state.

## Step 1: Register Node (one-time, rerunnable)

Command:
- infra/add-node.sh <node>

Expected behavior:
- takes node name from argument, interactive prompt, or environment variable,
- checks that creds/nodes/<node>/node.conf exists; if not, prints instructions to create it and exits,
- creates or updates SSH entry for node in local ~/.ssh/config,
- configures local Syncthing to share the node's config directory with the node,
- connects via SSH and idempotently clones or pulls the setup-node git repository on the target (repository URL is configurable),
- hands off to setup-node.sh.

Idempotency requirement:
- if SSH entry already exists, only missing fields are added,
- if Syncthing share already configured, no duplicate entry is created,
- if repository already cloned, git pull is run instead.

## Step 2: Define Desired State

Operator edits:
- creds/nodes/<node>/node.conf
- creds/nodes/<node>/<app>.conf (optional)

Expected behavior:
- configuration is declarative and source-of-truth.

Idempotency requirement:
- editing files does not trigger runtime changes until apply is called.

## Step 3: Start Remote Apply

Command:
- infra/setup-node.sh <node>

Expected behavior:
- checks that creds/nodes/<node>/node.conf exists locally,
- idempotently copies node.conf to the target node via SSH (scp or heredoc),
- connects via SSH and runs bootstrap.sh, streaming output to local terminal,
- monitors bootstrap.sh output for sshd configuration change signals; if detected, updates the corresponding entry in local ~/.ssh/config (e.g. port change),
- exits with the exit code of bootstrap.sh.

TODO:
- define a machine-readable stdout signal format for SSH changes (for example, a structured marker like SSHD_PORT_CHANGED=<port>). setup-node.sh should parse this marker instead of relying on free-form log text.

Note: full config sync (mounts, app configs) is handled by Syncthing on the node side during the pull-config.sh stage inside bootstrap.sh. Local Syncthing share is prepared in add-node.sh.

Idempotency requirement:
- node.conf copy is skipped if remote file is already identical,
- ssh config update is only applied when output signals a real change.

## Step 4: Host Convergence (bootstrap.sh)

bootstrap.sh runs on the node, invoked by setup-node.sh with node name passed via argument or environment variable.

### Stage 0: Config Bootstrap

- idempotently creates or updates symlink creds/current -> creds/nodes/<node-name>,
- loads creds/current/node.conf as environment variables,
- all subsequent stages read config exclusively from creds/current/.

Idempotency requirement:
- symlink is only (re)created if target differs.

### Stage 1: Host Configuration (configure-server.sh)

- SSH hardening (sshd config, optionally changes port — signals change to stdout for setup-node.sh to detect),
- sysctl tweaks,
- required system packages installation.

Each sub-step is gated by config flags; disabled steps are skipped.

Idempotency requirement:
- detect current state before applying; log no-op if already converged.

### Stage 2: Podman (podman.sh)

- installs Podman and Quadlet if not present,
- applies required Podman configuration.

Idempotency requirement:
- skips install if already at required version.

### Stage 3: Network (network.sh)

- creates dualstack Podman network from config (NETWORK_IP4_CIDR, NETWORK_IP6_CIDR),
- applies network-level sysctl if needed.

Idempotency requirement:
- skips network creation if network with matching config already exists.

### Stage 4: Config Sync (pull-config.sh)

- starts a temporary Syncthing container if not already running,
- configures Syncthing to sync the node's config directory (connects to the local Syncthing share prepared by add-node.sh),
- waits for sync completion with a configurable timeout,
- checks Syncthing API and considers sync complete only when machine status is Up to Date,
- stops the temporary container after sync.

Idempotency requirement:
- if config directory is already in sync, no-op after verification.

### Stage 5: Apps (apps.sh)

- reads APPS list from config,
- for each enabled app: runs apps/<app-name>/configure.sh,
- each configure.sh is responsible for its own idempotency.

Idempotency requirement:
- apps not in APPS list are not touched,
- unchanged app state must not trigger restart.

## Step 5: App Convergence

App convergence is implemented in Step 4, Stage 5 (apps.sh).

Design contract for app deployment is defined in docs/app-deployment-design.md.

## Step 6: Verification

Verification output should include:
- applied changes summary,
- no-op summary,
- failed components with actionable reason,
- app/service health snapshot.

Idempotency requirement:
- verification is read-only and deterministic.

## Step 7: Repeat Apply (day-2)

Trigger conditions:
- config changed,
- app list changed,
- infra script improvements,
- node drift detected.

Expected behavior:
- same command path,
- minimal required changes only,
- predictable end state.

## Configuration Resolution

Control machine precedence (before remote bootstrap):
1. creds/nodes/<node>/<app>.conf
2. creds/nodes/<node>/node.conf
3. apps/<app>/defaults.env

Runtime precedence on node (inside bootstrap after Stage 0 symlink):
1. creds/current/<app>.conf
2. creds/current/node.conf
3. apps/<app>/defaults.env

Rules:
- app scope overrides node scope,
- node scope overrides app defaults,
- missing required keys fail fast before mutation.

## Failure Policy

- Any step must fail with explicit reason and non-zero exit code.
- Partial progress is allowed, but failure must indicate recovery action.
- Rerun after correction must continue safely from current state.

## Logging Contract

Each script should log:
- step name,
- action type: detect/apply/no-op/fail,
- key identifiers: node, app, file, service,
- final status line.

## Non-Goals (current phase)

- secret management hardening,
- full rollback orchestration,
- multi-node parallel orchestration.
