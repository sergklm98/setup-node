#!/bin/bash
# This script deploys and bootstraps a node by connecting to it, cloning/updating the repository, copying node configuration, and triggering the bootstrap process.
#
# Steps:
# 1. Connect to chosen node.
# 2. Clone the git repo (if not exist) or pull updates.
# 3. Copy target node config to server if not yet done.
# 4. Start syncthing if not yet running.
# 5. Trigger bootstrap.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NODES_DIR="$REPO_ROOT/creds/nodes"

# Get node name from argument or prompt
NODE_NAME="${1:-}"
if [[ -z "$NODE_NAME" ]]; then
    echo "Available nodes:"
    ls -1 "$NODES_DIR" 2>/dev/null || { echo "No nodes found in $NODES_DIR"; exit 1; }
    echo ""
    read -p "Enter node name: " NODE_NAME
fi

# Validate node exists
NODE_DIR="$NODES_DIR/$NODE_NAME"
if [[ ! -d "$NODE_DIR" ]]; then
    echo "Error: Node '$NODE_NAME' not found in $NODES_DIR"
    exit 1
fi

# Load node configuration
NODE_CONF="$NODE_DIR/node.conf"
if [[ ! -f "$NODE_CONF" ]]; then
    echo "Error: Node configuration file not found: $NODE_CONF"
    exit 1
fi

source "$NODE_CONF"

# Validate required SSH configuration
if [[ -z "${SSH_USER:-}" ]]; then
    echo "Error: SSH_USER not set in $NODE_CONF"
    exit 1
fi

SSH_PORT="${SSH_PORT:-22}"
SSH_HOST="${NODE_IPs%% *}"  # Use first IP if multiple provided
if [[ -z "$SSH_HOST" ]]; then
    echo "Error: NODE_IPs not set in $NODE_CONF"
    exit 1
fi

# Construct SSH command
SSH_CMD="ssh -p $SSH_PORT $SSH_USER@$SSH_HOST"
if [[ -n "${SSH_PUB_KEY:-}" ]]; then
    SSH_CMD="$SSH_CMD -i $SSH_PUB_KEY"
fi

# Get git repository URL
GIT_REPO_URL="$(cd "$REPO_ROOT" && git remote get-url origin 2>/dev/null || echo "https://sergklm98@github.com/sergklm98/setup-node.git")"
REPO_PATH_ON_SERVER="~/setup-node"

echo "Connecting to node: $NODE_NAME ($SSH_USER@$SSH_HOST:$SSH_PORT)"
echo "Repository: $GIT_REPO_URL"
echo ""

# Step 1 & 2: Connect and clone/pull repository
echo "Step 1-2: Checking repository on remote server..."
$SSH_CMD bash <<EOF
set -euo pipefail

REPO_PATH="$REPO_PATH_ON_SERVER"

if [[ -d "\$REPO_PATH/.git" ]]; then
    echo "Repository exists, pulling latest changes..."
    cd "\$REPO_PATH"
    git pull || echo "Warning: git pull failed, continuing..."
else
    echo "Repository not found, cloning..."
    git clone "$GIT_REPO_URL" "\$REPO_PATH" || { echo "Error: Failed to clone repository"; exit 1; }
fi
EOF

# Step 3: Copy node config to server if not yet done
echo ""
echo "Step 3: Copying node configuration to server..."
$SSH_CMD bash <<EOF
set -euo pipefail

REPO_PATH="$REPO_PATH_ON_SERVER"
NODE_NAME="$NODE_NAME"
NODES_DIR="\$REPO_PATH/creds/nodes"
TARGET_NODE_DIR="\$NODES_DIR/\$NODE_NAME"

# Create nodes directory if it doesn't exist
mkdir -p "\$NODES_DIR"

# Copy node directory if it doesn't exist or is different
if [[ ! -d "\$TARGET_NODE_DIR" ]]; then
    echo "Node config directory doesn't exist, will be created by rsync..."
elif ! diff -r "\$TARGET_NODE_DIR" "$NODE_DIR" >/dev/null 2>&1; then
    echo "Node config differs, updating..."
fi
EOF

# Use rsync to sync the node directory
rsync -avz -e "ssh -p $SSH_PORT ${SSH_PUB_KEY:+-i $SSH_PUB_KEY}" \
    "$NODE_DIR/" \
    "$SSH_USER@$SSH_HOST:$REPO_PATH_ON_SERVER/creds/nodes/$NODE_NAME/"

# Step 4: Start syncthing if not yet running
echo ""
echo "Step 4: Checking Syncthing status..."
$SSH_CMD bash <<'REMOTE_SCRIPT'
set -euo pipefail

# Check if syncthing is running as a podman container
if podman ps --format "{{.Names}}" | grep -q syncthing; then
    echo "Syncthing container is already running"
elif podman ps -a --format "{{.Names}}" | grep -q syncthing; then
    echo "Starting existing Syncthing container..."
    podman start syncthing || echo "Warning: Failed to start Syncthing container"
else
    echo "Syncthing container not found. It will be started by bootstrap.sh"
fi

# Also check systemd service (for Quadlet)
if systemctl is-active --quiet syncthing-container.service 2>/dev/null; then
    echo "Syncthing systemd service is active"
elif systemctl list-units --all --type=service | grep -q syncthing-container.service; then
    echo "Starting Syncthing systemd service..."
    systemctl start syncthing-container.service || echo "Warning: Failed to start Syncthing service"
fi
REMOTE_SCRIPT

# Step 5: Trigger bootstrap.sh
echo ""
echo "Step 5: Triggering bootstrap.sh on remote server..."
$SSH_CMD bash <<EOF
set -euo pipefail

REPO_PATH="$REPO_PATH_ON_SERVER"
cd "\$REPO_PATH"

if [[ ! -f bootstrap.sh ]]; then
    echo "Error: bootstrap.sh not found in repository"
    exit 1
fi

echo "Executing bootstrap.sh..."
bash bootstrap.sh
EOF

echo ""
echo "Setup completed successfully for node: $NODE_NAME"
