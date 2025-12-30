#!/bin/bash
# This bootstrap script orchestrates the setup of a new node by executing four key scripts in sequence.
# The script is idempotent - it can be run multiple times safely.
# 1. infra/podman.sh - Identifies the Debian version and installs the latest Podman with Quadlet support.
# 2. infra/network.sh - Creates a dualstack Podman network (supporting both IPv4 and IPv6).
# 3. infra/pull-config.sh - Pulls the latest configuration files for the node via syncthing.
# 4. infra/apps.sh - Installs the selected applications chosen to be deployed on the node.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/infra"

echo "Starting bootstrap..."
echo "Script directory: $SCRIPT_DIR"
echo ""

# Step 1: Install Podman with Quadlet support
echo "=========================================="
echo "Step 1: Installing Podman with Quadlet..."
echo "=========================================="
bash "$INFRA_DIR/podman.sh"
echo "✓ Podman installation completed"
echo ""

# Step 2: Create dualstack Podman network
echo "=========================================="
echo "Step 2: Creating dualstack Podman network..."
echo "=========================================="
bash "$INFRA_DIR/network.sh"
echo "✓ Network creation completed"
echo ""

# Step 3: Pull configuration files via Syncthing
echo "=========================================="
echo "Step 3: Pulling configuration files via Syncthing..."
echo "=========================================="
bash "$INFRA_DIR/pull-config.sh"
echo "✓ Configuration files pulled"
echo ""

# Step 4: Install selected applications
echo "=========================================="
echo "Step 4: Installing selected applications..."
echo "=========================================="
bash "$INFRA_DIR/apps.sh"
echo "✓ Applications installation completed"
echo ""

echo "=========================================="
echo "Bootstrap completed successfully!"
echo "=========================================="

exit 0
