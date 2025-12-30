#!/bin/bash
# This script deploys and bootstraps a node by connecting to it, cloning/updating the repository, copying node configuration, and triggering the bootstrap process.
#
# Steps:
# 1. Connect to chosen node.
# 2. Clone the git repo (if not exist) or pull updates.
# 3. Copy target node config (creds/nodes/<node>/node.conf) to creds/node.conf on target machine.
# 4. Trigger bootstrap.sh (which will handle Syncthing setup via apps/syncthing/configure.sh).

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

# Load node configuration
NODE_CONF="$NODES_DIR/$NODE_NAME/node.conf"
if [[ ! -f "$NODE_CONF" ]]; then
    echo "Error: Node configuration file not found: $NODE_CONF"
    exit 1
fi

# Get git repository URL
GIT_REPO_URL="$(cd "$REPO_ROOT" && git remote get-url origin 2>/dev/null || echo "https://sergklm98@github.com/sergklm98/setup-node.git")"
REPO_PATH_ON_SERVER="\$HOME/setup-node"

echo "Connecting to node: $NODE_NAME (using SSH config)"
echo "Repository: $GIT_REPO_URL"
echo ""

# Use node name as SSH host (from SSH config)
# SSH config should be set up by add-node.sh
SSH_CMD="ssh $NODE_NAME"

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

# Step 3: Copy node config to server
echo ""
echo "Step 3: Copying node configuration to server..."
# Copy node.conf to creds/node.conf on target machine
# Use $HOME instead of ~ for proper expansion in scp
scp "$NODE_CONF" "$NODE_NAME:~/setup-node/creds/node.conf"
echo "✓ Copied node configuration to creds/node.conf"

# Step 4: Trigger bootstrap.sh
echo ""
echo "Step 4: Triggering bootstrap.sh on remote server..."
$SSH_CMD "bash \$HOME/setup-node/bootstrap.sh"

echo ""
echo "Setup completed successfully for node: $NODE_NAME"
