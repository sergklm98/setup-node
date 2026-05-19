# Setup-Node Final Architecture Plan

## 1. Core Mission

This is a public repository for simplifying and automating node provisioning and application lifecycle in a mesh network.

Primary requirement:
- every process must be idempotent,
- every rerun must only apply the minimal set of changes needed to bring a node to the state declared in configuration.

Repository roles:
- infra/:
  - scripts that converge host system state to the declared target (SSH hardening, nftables, Podman/Quadlet setup, network setup, system prerequisites),
- apps/:
  - templates and logic for deploying and configuring individual services,
  - default deployment target is Podman containers via Quadlet,
- creds/:
  - public repo keeps examples only,
  - local/private copy stores real node desired-state configs,
  - configuration distribution is done through Syncthing.

This plan intentionally ignores temporary secret-handling shortcuts for now.

## 2. Current Baseline

What already exists and should be preserved:
- bootstrap orchestration with ordered infra steps,
- node onboarding via add-node script,
- remote deployment via setup-node script,
- dualstack podman network bootstrap,
- per-node and global config fallback helpers.

Main gaps to close:
- app deployment contract is not implemented end-to-end,
- pull-config is still mostly declarative,
- node config synchronization logic in setup-node is unfinished,
- app configuration format is not normalized,
- validation and tests are missing.

## 3. Target End-State

### 3.1 Operator Workflow

1. Register node once:
   - infra/add-node.sh <node>
2. Edit node profile in creds/nodes/<node>/
3. Apply node configuration:
   - infra/setup-node.sh <node>
4. Re-apply safely anytime after config updates.

### 3.2 Runtime Architecture

- Base host layer:
  - package prerequisites,
  - SSH hardening,
  - podman + quadlet runtime,
  - system tuning (optional profile).
- Network layer:
  - main dualstack podman network managed by quadlet.
- Config layer:
  - node config source in repository,
  - local fallback order: app config -> node config -> global config.
- App layer:
  - each app provides a minimal deployment interface,
  - apps are enabled by node config only.

### 3.3 App Contract (Required)

Each app directory must follow this minimal contract:
- required configure.sh for app deployment and configuration convergence,
- required defaults.env with safe non-secret defaults,
- optional app.container (temporary compatibility path while migrating to configure.sh-driven deployment),
- optional app.build / Containerfile when image build is needed.

Each app must support:
- install/apply idempotently,
- restart through systemd/quadlet,
- run inside expected network,
- mount paths from creds/mounts/<app>/ when required.

### 3.4 Configuration Model

Control-machine precedence:
1. creds/nodes/<node>/<app>.conf
2. creds/nodes/<node>/node.conf
3. apps/<app>/defaults.env

Runtime precedence on node after bootstrap symlink:
1. creds/current/<app>.conf
2. creds/current/node.conf
3. apps/<app>/defaults.env

Required normalized keys:
- NODE_NAME
- NODE_IPs
- NETWORK_IP4_CIDR
- NETWORK_IP6_CIDR
- APPS (comma-separated app IDs)
- PODMAN_BIN (optional override)

Optional operational keys:
- ADDITIONAL_UTILS
- APP_<APPNAME>_ENABLED=true|false (future extension)

## 4. Repository Structure Target

Target structure additions (non-breaking):
- docs/
  - final-architecture-plan.md
  - runbook.md
  - app-contract.md
- tests/
  - smoke/
  - fixtures/
- scripts/
  - lint-shell.sh
  - validate-config.sh

Existing folders remain primary sources:
- infra/
- apps/
- creds/

## 5. System Work Stages

### Stage A: Declare Desired State

Inputs:
- node profile files in creds/nodes/<node>/,
- app selection and network settings in config files.

Output:
- a complete declared target state for one node.

### Stage B: Prepare Node Access

Actions:
- create/verify SSH connectivity,
- initialize node metadata and sync folder.

Output:
- node is reachable by name and bound to configuration source.

### Stage C: Converge Host Infrastructure

Actions:
- apply host baseline from infra/ (packages, SSH policy, Podman, network, synchronization bootstrap).

Output:
- host runtime is ready for app deployment.

### Stage D: Converge Application Layer

Actions:
- read APPS and app-specific config,
- deploy/update only enabled apps,
- keep unchanged apps untouched.

Output:
- app layer matches declared config.

### Stage E: Verify and Re-Apply

Actions:
- run health and config checks,
- support safe repeat runs.

Output:
- stable day-2 operations with deterministic reruns.

## 6. Deployment Flow (Detailed)

1. Operator adds node identity and access:
  - infra/add-node.sh <node>
2. Operator fills desired state in node config files:
  - creds/nodes/<node>/node.conf
  - creds/nodes/<node>/<app>.conf (optional)
3. Operator runs apply command:
  - infra/setup-node.sh <node>
4. setup-node performs remote repository sync (clone or update).
5. setup-node synchronizes effective node config only when changed (hash-based behavior target).
6. bootstrap executes ordered convergence steps:
  - configure-server
  - podman
  - network
  - pull-config
  - apps
7. apps stage evaluates APPS and applies app contract per enabled app.
8. Post-apply verification reports resulting state.
9. Any next run repeats the same flow and changes only drifted parts.

Convergence rule for all steps:
- detect current state,
- compare to desired state,
- apply delta only,
- report action taken or explicit no-op.

## 7. Implementation Phases

## Phase 0: Freeze Contract and Rules

Deliverables:
- document app contract and config precedence,
- define app naming conventions,
- define standard logging and exit code style for scripts.

Done when:
- docs/app-deployment-design.md exists,
- docs/runbook.md exists,
- all infra scripts reference the same contract names.

## Phase 1: Core Infra Reliability

Deliverables:
- finish setup-node config sync logic (hash-based, update only on change),
- complete pull-config implementation or explicitly stub with clear failure,
- implement infra/apps.sh app loop and contract invocation,
- standardize error handling and timestamps in logs.

Done when:
- setup-node is idempotent for unchanged node config,
- bootstrap succeeds on clean Debian host and on rerun,
- infra/apps.sh installs at least caddy, headscale, tailscale using common flow.

## Phase 2: App Packaging Normalization

Deliverables:
- align all existing apps to shared app contract,
- validate mount paths and required env files,
- add app-level health checks.

Done when:
- each app has deterministic start/stop behavior,
- each enabled app appears in systemctl and podman status,
- failed app deployment reports clear actionable reason.

## Phase 3: Verification and Safety Nets

Deliverables:
- config validator for required keys and formats,
- shell checks and formatting checks,
- smoke test script for local dry-run and remote apply.

Done when:
- invalid configs fail fast before remote actions,
- CI or local check command validates shell scripts and config,
- operator can run one verification command after deployment.

## Phase 4: Operational Readiness

Deliverables:
- runbook for recovery and common operations,
- node decommission script (planned TODO),
- optional rollback strategy per app.

Done when:
- adding, updating, and removing nodes is documented and script-backed,
- common incidents have runbook entries.

## 8. Definition of Done (Project)

Project is in final shape when all of the following are true:
- Node onboarding, setup, and re-setup are fully idempotent.
- APPS config is the single source of truth for app activation.
- Every app follows one documented deployment contract.
- Configuration validation exists and blocks bad input early.
- A smoke verification command reports deployment health.
- Runbook exists for day-2 operations.

## 9. Immediate Next Execution Batch

Recommended next coding batch:
1. Implement infra/apps.sh orchestration contract.
2. Implement config hash sync in infra/setup-node.sh.
3. Keep docs/app-deployment-design.md and docs/runbook.md aligned with implementation.
4. Add scripts/validate-config.sh for required keys.

This sequence delivers the largest reliability gain with minimal structural risk.
