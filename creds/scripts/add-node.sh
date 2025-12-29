#!/bin/bash
# This script adds a new node to the repository by collecting connection information, establishing SSH access, creating node configuration templates, and setting up Syncthing sync folder.
#
# Steps:
# 1. Collect from user info to connect through ssh: node name, ip, port (22 as default), username, auth-mode (key or pass), key location or password.
# 2. Connect to server using provided credentials, check supported ssh key algorithms.
# 3. Based on algos support generate ssh key (locally, prefer curve-based over rsa) and send to server, add server block to ssh config.
# 4. Add node folder and configs templates to creds folder of repo.
# 5. Create a new Syncthing sync folder for the node using the Syncthing REST API (connect to local Syncthing API, create folder with specified path and label, configure folder settings, return folder ID for use in node configuration).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NODES_DIR="$REPO_ROOT/creds/nodes"
SSH_KEYS_DIR="$REPO_ROOT/creds/ssh"
SSH_CONFIG="$HOME/.ssh/config"
SSH_KEY_DIR="$HOME/.ssh"

# Step 1: Collect connection information
echo "=== Adding New Node ==="
echo ""

read -p "Node name: " NODE_NAME
if [[ -z "$NODE_NAME" ]]; then
    echo "Error: Node name cannot be empty"
    exit 1
fi

# Check if node already exists
if [[ -d "$NODES_DIR/$NODE_NAME" ]]; then
    echo "Error: Node '$NODE_NAME' already exists in $NODES_DIR"
    exit 1
fi

read -p "Node IP address: " NODE_IP
if [[ -z "$NODE_IP" ]]; then
    echo "Error: IP address cannot be empty"
    exit 1
fi

read -p "SSH port [22]: " SSH_PORT
SSH_PORT="${SSH_PORT:-22}"

read -p "SSH username: " SSH_USER
if [[ -z "$SSH_USER" ]]; then
    echo "Error: SSH username cannot be empty"
    exit 1
fi

echo ""
echo "Authentication method:"
echo "1) SSH key"
echo "2) Password"
read -p "Choose [1-2]: " AUTH_METHOD

SSH_KEY_PATH=""
SSH_PASSWORD=""

if [[ "$AUTH_METHOD" == "1" ]]; then
    read -p "SSH key path: " SSH_KEY_PATH
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        echo "Error: SSH key file not found: $SSH_KEY_PATH"
        exit 1
    fi
    SSH_KEY_OPT="-i $SSH_KEY_PATH"
else
    read -sp "SSH password: " SSH_PASSWORD
    echo ""
    SSH_KEY_OPT=""
fi

# Step 2: Connect and check supported SSH key algorithms
echo ""
echo "Step 2: Connecting to server and checking supported SSH key algorithms..."

# Test connection and get supported algorithms
if [[ "$AUTH_METHOD" == "1" ]]; then
    SSH_CMD="ssh -i $SSH_KEY_PATH -p $SSH_PORT -o StrictHostKeyChecking=no"
else
    # Use sshpass if available, otherwise prompt
    if command -v sshpass >/dev/null 2>&1; then
        SSH_CMD="sshpass -p '$SSH_PASSWORD' ssh -p $SSH_PORT -o StrictHostKeyChecking=no"
    else
        echo "Note: sshpass not found. You may need to enter password manually."
        SSH_CMD="ssh -p $SSH_PORT -o StrictHostKeyChecking=no"
    fi
fi

# Check supported host key algorithms by testing connection
echo "Checking supported SSH key algorithms..."
# Test connection to get server algorithms
SSH_TEST_OUTPUT=$($SSH_CMD $SSH_USER@$NODE_IP "echo 'test'" 2>&1)
SSH_TEST_EXIT=$?

if [[ $SSH_TEST_EXIT -ne 0 ]]; then
    echo "SSH connection test output:"
    echo "$SSH_TEST_OUTPUT"
    echo ""
    # Check if it's just a host key verification issue or actual connection failure
    if echo "$SSH_TEST_OUTPUT" | grep -qi "host key verification failed\|host key"; then
        echo "Error: SSH connection failed. Please check the error above."
        exit 1
    elif echo "$SSH_TEST_OUTPUT" | grep -qi "connection refused\|connection timed out\|no route to host"; then
        echo "Error: Cannot connect to $SSH_USER@$NODE_IP:$SSH_PORT"
        echo "Please verify:"
        echo "  - IP address is correct"
        echo "  - SSH port is correct"
        echo "  - Server is accessible"
        echo "  - SSH service is running on the server"
        exit 1
    elif echo "$SSH_TEST_OUTPUT" | grep -qi "permission denied\|authentication failed"; then
        echo "Error: Authentication failed. Please check credentials."
        exit 1
    else
        echo "Error: SSH connection failed. Please check the error above."
        exit 1
    fi
fi

# Try to extract server algorithms from output
SERVER_ALGOS=$(echo "$SSH_TEST_OUTPUT" | grep -iE "server_host_key_algorithms|algorithm" | head -1 || echo "")

# Get client supported algorithms and extract base types
if command -v ssh >/dev/null 2>&1 && ssh -Q key >/dev/null 2>&1; then
    CLIENT_ALGOS_FULL=$(ssh -Q key 2>/dev/null | tr '\n' ' ')
    echo "Client supported key types: $CLIENT_ALGOS_FULL"
    # Extract base algorithm names (ed25519, ecdsa, rsa)
    CLIENT_ALGOS=""
    echo "$CLIENT_ALGOS_FULL" | grep -q "ed25519" && CLIENT_ALGOS="$CLIENT_ALGOS ed25519"
    echo "$CLIENT_ALGOS_FULL" | grep -q "ecdsa" && CLIENT_ALGOS="$CLIENT_ALGOS ecdsa"
    echo "$CLIENT_ALGOS_FULL" | grep -q "ssh-rsa\|rsa" && CLIENT_ALGOS="$CLIENT_ALGOS rsa"
    CLIENT_ALGOS=$(echo "$CLIENT_ALGOS" | xargs)  # Trim whitespace
else
    CLIENT_ALGOS="ed25519 ecdsa rsa"
    echo "Using default key types: $CLIENT_ALGOS"
fi

# If server algorithms not identified, ask user
if [[ -z "$SERVER_ALGOS" ]]; then
    echo ""
    echo "Could not automatically detect server-supported SSH key algorithms."
    echo "Common algorithms: ssh-ed25519, ecdsa-sha2-nistp256, ecdsa-sha2-nistp384, ecdsa-sha2-nistp521, ssh-rsa"
    read -p "Enter supported algorithms (space-separated, or press Enter to use client defaults): " USER_ALGOS
    if [[ -n "$USER_ALGOS" ]]; then
        # Extract base types from user input
        CLIENT_ALGOS=""
        echo "$USER_ALGOS" | grep -qi "ed25519" && CLIENT_ALGOS="$CLIENT_ALGOS ed25519"
        echo "$USER_ALGOS" | grep -qi "ecdsa" && CLIENT_ALGOS="$CLIENT_ALGOS ecdsa"
        echo "$USER_ALGOS" | grep -qi "rsa" && CLIENT_ALGOS="$CLIENT_ALGOS rsa"
        CLIENT_ALGOS=$(echo "$CLIENT_ALGOS" | xargs)
        if [[ -z "$CLIENT_ALGOS" ]]; then
            echo "Warning: Could not parse algorithms, using client defaults"
            CLIENT_ALGOS="ed25519 ecdsa rsa"
        else
            echo "Using user-specified algorithms: $CLIENT_ALGOS"
        fi
    fi
fi

# Step 3: Generate SSH key and copy to server
echo ""
echo "Step 3: Generating SSH key and setting up access..."

# Determine best key type (prefer curve-based: ed25519 > ecdsa > rsa)
KEY_TYPE="ed25519"
if echo "$CLIENT_ALGOS" | grep -qE "\bed25519\b"; then
    KEY_TYPE="ed25519"
    KEY_BITS=""
elif echo "$CLIENT_ALGOS" | grep -qE "\becdsa\b"; then
    KEY_TYPE="ecdsa"
    KEY_BITS="-b 521"
else
    KEY_TYPE="rsa"
    KEY_BITS="-b 4096"
fi

echo "Selected key type: $KEY_TYPE"

# Store keys in creds/ssh directory (flat structure)
mkdir -p "$SSH_KEYS_DIR"

NEW_KEY_NAME="${NODE_NAME}_${KEY_TYPE}"
NEW_KEY_PATH="$SSH_KEYS_DIR/$NEW_KEY_NAME"
NEW_KEY_PUB_PATH="${NEW_KEY_PATH}.pub"

if [[ -f "$NEW_KEY_PATH" ]]; then
    echo "Key $NEW_KEY_PATH already exists, skipping generation"
else
    echo "Generating $KEY_TYPE key: $NEW_KEY_PATH"
    if [[ -n "$KEY_BITS" ]]; then
        ssh-keygen -t "$KEY_TYPE" $KEY_BITS -f "$NEW_KEY_PATH" -N "" -C "setup-node-$NODE_NAME"
    else
        ssh-keygen -t "$KEY_TYPE" -f "$NEW_KEY_PATH" -N "" -C "setup-node-$NODE_NAME"
    fi
    echo "Keys generated in: $SSH_KEYS_DIR"
fi

# Link/copy private key to ~/.ssh for SSH config
SSH_KEY_LINK="$SSH_KEY_DIR/$NEW_KEY_NAME"
if [[ ! -e "$SSH_KEY_LINK" ]]; then
    # Try to create hardlink first (same filesystem requirement)
    if ln "$NEW_KEY_PATH" "$SSH_KEY_LINK" 2>/dev/null; then
        echo "Created hardlink to private key in ~/.ssh"
    else
        # Fallback to copy if hardlink fails (different filesystem)
        echo "Hardlink not possible, copying private key to ~/.ssh"
        cp "$NEW_KEY_PATH" "$SSH_KEY_LINK"
        chmod 600 "$SSH_KEY_LINK"
    fi
else
    # Update if source is newer (in case key was regenerated)
    if [[ "$NEW_KEY_PATH" -nt "$SSH_KEY_LINK" ]]; then
        rm -f "$SSH_KEY_LINK"
        # Try hardlink again, fallback to copy
        if ln "$NEW_KEY_PATH" "$SSH_KEY_LINK" 2>/dev/null; then
            echo "Updated hardlink to private key in ~/.ssh"
        else
            echo "Updated copy of private key in ~/.ssh"
            cp "$NEW_KEY_PATH" "$SSH_KEY_LINK"
            chmod 600 "$SSH_KEY_LINK"
        fi
    fi
fi

# Copy public key to server
echo "Copying public key to server..."
PUBLIC_KEY=$(cat "$NEW_KEY_PUB_PATH")

if [[ "$AUTH_METHOD" == "1" ]]; then
    # Use existing key to copy new key
    if ! $SSH_CMD $SSH_USER@$NODE_IP "mkdir -p ~/.ssh && echo '$PUBLIC_KEY' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"; then
        echo "Error: Failed to copy public key to server"
        exit 1
    fi
elif command -v sshpass >/dev/null 2>&1; then
    if ! sshpass -p "$SSH_PASSWORD" ssh-copy-id -i "$NEW_KEY_PUB_PATH" -p "$SSH_PORT" $SSH_USER@$NODE_IP; then
        echo "Error: Failed to copy public key to server"
        exit 1
    fi
else
    echo "Please run manually: ssh-copy-id -i $NEW_KEY_PUB_PATH -p $SSH_PORT $SSH_USER@$NODE_IP"
    read -p "Press Enter after copying the key..."
fi

# Test new key works
echo "Testing new key..."
if ! ssh -i "$NEW_KEY_PATH" -p "$SSH_PORT" -o StrictHostKeyChecking=no $SSH_USER@$NODE_IP "echo 'SSH key authentication successful'"; then
    echo "Error: New key authentication test failed"
    exit 1
fi

# Add to SSH config
echo "Adding entry to SSH config: $SSH_CONFIG"
mkdir -p "$(dirname "$SSH_CONFIG")"

SSH_CONFIG_ENTRY="
Host $NODE_NAME
    HostName $NODE_IP
    User $SSH_USER
    Port $SSH_PORT
    IdentityFile $SSH_KEY_LINK
    StrictHostKeyChecking no
    ServerAliveInterval 40
    ServerAliveCountMax 2
    TCPKeepAlive yes
"

if ! grep -q "Host $NODE_NAME" "$SSH_CONFIG" 2>/dev/null; then
    echo "$SSH_CONFIG_ENTRY" >> "$SSH_CONFIG"
    echo "Added SSH config entry for $NODE_NAME"
else
    echo "SSH config entry for $NODE_NAME already exists"
fi

# Step 4: Create node folder and config templates
echo ""
echo "Step 4: Creating node folder and configuration templates..."

NODE_DIR="$NODES_DIR/$NODE_NAME"
mkdir -p "$NODE_DIR"

# Create node.conf template
cat > "$NODE_DIR/node.conf" <<EOF
#NODE_NAME=$NODE_NAME
NODE_IPs=$NODE_IP

NETWORK_IP4_CIDR=
NETWORK_IP6_CIDR=

APPS=syncthing,nebula,awg,dns
EOF

echo "Created node configuration: $NODE_DIR/node.conf"

# Step 5: Create Syncthing sync folder
echo ""
echo "Step 5: Creating Syncthing sync folder..."

# Load Syncthing API configuration from creds/node.conf
ROOT_NODE_CONF="$REPO_ROOT/creds/node.conf"
if [[ -f "$ROOT_NODE_CONF" ]]; then
    source "$ROOT_NODE_CONF"
fi

SYNCTHING_API_URL="${SYNCTHING_API_URL:-http://localhost:8384}"
SYNCTHING_API_KEY="${SYNCTHING_API_KEY:-}"

if [[ -z "$SYNCTHING_API_KEY" ]]; then
    echo "Note: SYNCTHING_API_URL and SYNCTHING_API_KEY should be configured in creds/node.conf"
    echo "Skipping Syncthing folder creation (no API key configured)"
    SYNCTHING_API_KEY=""
fi

if [[ -n "$SYNCTHING_API_KEY" ]]; then
    # Create folder via API
    FOLDER_LABEL="setup-node-$NODE_NAME"
    FOLDER_PATH="$NODES_DIR/$NODE_NAME"
    
    # Get current config
    CONFIG_RESPONSE=$(curl -s -X GET -H "X-API-Key: $SYNCTHING_API_KEY" "$SYNCTHING_API_URL/rest/config")
    
    # Generate folder ID (Syncthing format)
    FOLDER_ID=$(echo -n "$FOLDER_PATH" | sha256sum | cut -d' ' -f1 | cut -c1-8)
    
    # Create folder configuration
    FOLDER_CONFIG=$(cat <<EOF
{
    "id": "$FOLDER_ID",
    "label": "$FOLDER_LABEL",
    "path": "$FOLDER_PATH",
    "type": "sendonly",
    "devices": [],
    "rescanIntervalS": 3600,
    "fsWatcherEnabled": true,
    "fsWatcherDelayS": 10,
    "ignorePerms": false,
    "autoNormalize": true
}
EOF
)
    
    # Add folder to config
    echo "Creating Syncthing folder: $FOLDER_LABEL"
    curl -s -X PUT -H "X-API-Key: $SYNCTHING_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$FOLDER_CONFIG" \
        "$SYNCTHING_API_URL/rest/config/folders/$FOLDER_ID" >/dev/null
    
    if [[ $? -eq 0 ]]; then
        echo "Syncthing folder created successfully (ID: $FOLDER_ID)"
        
        # Update node.conf with folder ID
        if grep -q "SYNCTHING_FOLDER_ID" "$NODE_DIR/node.conf"; then
            sed -i "s|SYNCTHING_FOLDER_ID=.*|SYNCTHING_FOLDER_ID=$FOLDER_ID|" "$NODE_DIR/node.conf"
        else
            echo "SYNCTHING_FOLDER_ID=$FOLDER_ID" >> "$NODE_DIR/node.conf"
        fi
    else
        echo "Warning: Failed to create Syncthing folder via API"
    fi
else
    echo "Skipping Syncthing folder creation (no API key provided)"
fi

echo ""
echo "=== Node '$NODE_NAME' added successfully ==="
echo "Configuration: $NODE_DIR/node.conf"
echo "SSH config: Use 'ssh $NODE_NAME' to connect"
echo ""
echo "Next steps:"
echo "1. Edit $NODE_DIR/node.conf to configure network CIDRs and apps"
echo "2. Run: creds/scripts/setup-node.sh $NODE_NAME"
