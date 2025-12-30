# Setup Node

This repository provides automation scripts for setting up and managing VPS nodes in an overlay network infrastructure. All applications run in Podman containers, and nodes are interconnected through multiple mesh networks (VPNs and overlay networks).

## Prerequisites

Before using this repository, ensure you have:

1. **Local setup-node repository**: Clone this repository to your local machine
2. **Syncthing running locally**: Syncthing must be running and accessible via API for configuration synchronization
3. **Syncthing API configuration**: Configure `SYNCTHING_API_URL` and `SYNCTHING_API_KEY` in `creds/node.conf` (see example below)
4. **Separate sync folders**: Each node has its own dedicated Syncthing sync folder for configuration management

### Syncthing API Configuration

Edit `creds/node.conf` and add your Syncthing API settings:

```bash
SYNCTHING_API_URL=http://localhost:8384
SYNCTHING_API_KEY=your-api-key-here
```

You can find your API key in your Syncthing configuration file (usually `~/.config/syncthing/config.xml` or `/var/lib/syncthing/config.xml`).

## Workflow

### 1. Initial Node Setup

Run `infra/add-node.sh` to add a new VPS node to the repository. This script will:
- Collect SSH connection details (node name, IP, port, username, authentication method)
- Establish SSH access with key-based authentication
- Create node configuration templates in `creds/nodes/<node-name>/`
- Create a new Syncthing sync folder for the node using the Syncthing REST API

### 2. Configure Node

Edit the generated configuration files in `creds/nodes/<node-name>/` to:
- Specify which applications to install
- Configure network CIDRs (IPv4 and IPv6)
- Set up application-specific settings

### 3. Deploy and Bootstrap Node

Run `infra/setup-node.sh` to deploy and configure the target VPS. This script will:
- Connect to the node via SSH
- Clone or update the repository on the remote server
- Copy node-specific configuration files
- Start Syncthing if not already running
- Execute `bootstrap.sh` to complete the setup process

### 4. Update Node Configuration

If you need to modify node settings:
1. Update the configuration files in `creds/nodes/<node-name>/`
2. Run `infra/setup-node.sh` again to apply the changes to the VPS

## Architecture

- **Container Runtime**: All applications run in Podman containers
- **Service Management**: Podman Quadlet for systemd integration
- **Networking**: Dualstack Podman networks (IPv4 and IPv6)
- **Mesh Networks**: Nodes are connected through multiple VPN and overlay network solutions (Nebula, WireGuard, Yggdrasil, I2P)

## TODO

- [ ] **Low Priority**: Create script to delete a node (remove node folder, remove SSH config entry, remove Syncthing sync folder)
