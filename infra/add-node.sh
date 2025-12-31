#!/bin/bash
# This script adds a new node to the repository by collecting connection information, establishing SSH access, creating node configuration templates, and setting up Syncthing sync folder.
# The script is idempotent - it will skip steps that are already completed.
#
# Steps:
# 1. Collect from user info to connect through ssh: node name, ip, port (22 as default), username, auth-mode (key or pass), key location or password.
# 2. Connect to server using provided credentials, check supported ssh key algorithms.
# 3. Based on algos support generate ssh key (locally, prefer curve-based over rsa) and send to server, add server block to ssh config.
# 4. Add node folder and configs templates to creds folder of repo.
# 5. Create a new Syncthing sync folder for the node using the Syncthing REST API (connect to local Syncthing API, create folder with specified path and label, configure folder settings, return folder ID for use in node configuration).

set -euo pipefail

# Function to extract value from key=value format (removes quotes and whitespace)
get_value() {
    local file="$1"
    local key="$2"
    grep "^$key=" "$file" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]' | tr -d '"'
}

# Function to set value in config file
set_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    if grep -q "^$key=" "$file" 2>/dev/null; then
        sed -i "s|^$key=.*|$key=$value|" "$file"
    else
        echo "$key=$value" >> "$file"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NODES_DIR="$REPO_ROOT/creds/nodes"
SSH_KEYS_DIR="$REPO_ROOT/creds/ssh"
SSH_CONFIG="$HOME/.ssh/config"
SSH_KEY_DIR="$HOME/.ssh"

# Step 1: Collect connection information
echo "=== Adding New Node ==="
echo ""

# Get node name from argument or prompt
NODE_NAME="${1:-}"
if [[ -z "$NODE_NAME" ]]; then
    read -p "Node name: " NODE_NAME
    if [[ -z "$NODE_NAME" ]]; then
        echo "Error: Node name cannot be empty"
        exit 1
    fi
fi

NODE_DIR="$NODES_DIR/$NODE_NAME"
NODE_CONF="$NODE_DIR/node.conf"

# Check if node already exists and load config
SSH_USER=""
SSH_PORT=""
NODE_IP=""

# Try to read from SSH config first
if [[ -f "$SSH_CONFIG" ]]; then
    in_block=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Remove comments and trim whitespace
        line=$(echo "$line" | sed 's/#.*$//' | xargs)
        
        # Convert to lowercase for case-insensitive comparison
        line_lower=$(echo "$line" | tr '[:upper:]' '[:lower:]')
        
        # Find Host block
        if [[ "$line_lower" =~ ^host[[:space:]]+$NODE_NAME$ ]]; then
            in_block=true
            continue
        fi
        
        # Stop at empty line, another Host, or end of file
        if [[ "$in_block" == "true" ]]; then
            if [[ -z "$line" ]] || [[ "$line_lower" =~ ^host[[:space:]] ]]; then
                break
            fi
            
            # Extract HostName, User, Port (case-insensitive)
            if [[ "$line_lower" =~ ^hostname[[:space:]]+(.+)$ ]]; then
                NODE_IP="${BASH_REMATCH[1]}"
            elif [[ "$line_lower" =~ ^user[[:space:]]+(.+)$ ]]; then
                SSH_USER="${BASH_REMATCH[1]}"
            elif [[ "$line_lower" =~ ^port[[:space:]]+(.+)$ ]]; then
                SSH_PORT="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$SSH_CONFIG"
fi

# Try to load from node.conf if it exists (and fill what is missing)
if [[ -f "$NODE_CONF" ]]; then
    # Read only specific variables to avoid overwriting others
    NODE_IPs=$(get_value "$NODE_CONF" "NODE_IPs")
    # Only set NODE_IP if it's missing
    if [[ -z "$NODE_IP" && -n "$NODE_IPs" ]]; then
        NODE_IP="${NODE_IPs%% *}"
    fi
    echo "Node '$NODE_NAME' already exists."
    if [[ -n "$NODE_IP" ]] || [[ -n "$SSH_USER" ]] || [[ -n "$SSH_PORT" ]]; then
        echo "Found configuration: IP=${NODE_IP:-<not set>}, User=${SSH_USER:-<not set>}, Port=${SSH_PORT:-<not set>}"
    fi
    read -p "Press Enter to continue or Ctrl+C to cancel..."
fi


# Collect missing information
if [[ -z "$NODE_IP" ]]; then
    read -p "Node IP address: " NODE_IP
    if [[ -z "$NODE_IP" ]]; then
        echo "Error: IP address cannot be empty"
        exit 1
    fi
fi

if [[ -z "$SSH_PORT" ]]; then
    read -p "SSH port [22]: " SSH_PORT_INPUT
    SSH_PORT="${SSH_PORT_INPUT:-22}"
fi

if [[ -z "$SSH_USER" ]]; then
    read -p "SSH username: " SSH_USER
    if [[ -z "$SSH_USER" ]]; then
        echo "Error: SSH username cannot be empty"
        exit 1
    fi
fi

# Check if we can connect with existing key
EXISTING_KEY_WORKS=false
for KEY_PATH in "$SSH_KEYS_DIR"/${NODE_NAME}_*; do
    [[ ! -f "$KEY_PATH" ]] && continue
    [[ "$KEY_PATH" == *.pub ]] && continue
    echo "Testing existing key: $KEY_PATH"
    if ssh -i "$KEY_PATH" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 $SSH_USER@$NODE_IP "echo 'test'" >/dev/null 2>&1; then
        echo "Existing key works! Skipping authentication setup."
        EXISTING_KEY_WORKS=true
        KEY_BASENAME="$(basename "$KEY_PATH")"
        KEY_TYPE="${KEY_BASENAME#${NODE_NAME}_}"
        NEW_KEY_NAME="$KEY_BASENAME"
        NEW_KEY_PATH="$KEY_PATH"
        NEW_KEY_PUB_PATH="${KEY_PATH}.pub"
        SSH_KEY_LINK="$SSH_KEY_DIR/$NEW_KEY_NAME"
        break
    fi
done

if [[ "$EXISTING_KEY_WORKS" == "false" ]]; then
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
    else
        read -sp "SSH password: " SSH_PASSWORD
        echo ""
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
        echo "✓ Key $NEW_KEY_PATH already exists, skipping generation"
    else
        echo "Generating $KEY_TYPE key: $NEW_KEY_PATH"
        if [[ -n "$KEY_BITS" ]]; then
            ssh-keygen -t "$KEY_TYPE" $KEY_BITS -f "$NEW_KEY_PATH" -N "" -C "setup-node-$NODE_NAME"
        else
            ssh-keygen -t "$KEY_TYPE" -f "$NEW_KEY_PATH" -N "" -C "setup-node-$NODE_NAME"
        fi
        echo "✓ Keys generated in: $SSH_KEYS_DIR"
    fi

    # Check if public key is already on server
    echo "Checking if public key is already on server..."
    PUBLIC_KEY=$(cat "$NEW_KEY_PUB_PATH")
    KEY_ON_SERVER=false
    
    if ssh -i "$NEW_KEY_PATH" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 $SSH_USER@$NODE_IP "grep -q '^$PUBLIC_KEY$' ~/.ssh/authorized_keys 2>/dev/null" 2>/dev/null; then
        echo "✓ Public key already exists on server, skipping copy"
        KEY_ON_SERVER=true
    fi

    if [[ "$KEY_ON_SERVER" == "false" ]]; then
        echo "Copying public key to server..."
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
        echo "✓ Public key copied to server"
    fi

    # Test new key works
    echo "Testing new key..."
    if ! ssh -i "$NEW_KEY_PATH" -p "$SSH_PORT" -o StrictHostKeyChecking=no $SSH_USER@$NODE_IP "echo 'SSH key authentication successful'"; then
        echo "Error: New key authentication test failed"
        exit 1
    fi
    echo "✓ Key authentication test successful"
fi

# Link/copy private key to ~/.ssh for SSH config (for both existing and new keys)
if [[ -n "${NEW_KEY_NAME:-}" ]] && [[ -n "${NEW_KEY_PATH:-}" ]]; then
    SSH_KEY_LINK="$SSH_KEY_DIR/$NEW_KEY_NAME"
    if [[ ! -e "$SSH_KEY_LINK" ]]; then
        # Try to create hardlink first (same filesystem requirement)
        if ln "$NEW_KEY_PATH" "$SSH_KEY_LINK" 2>/dev/null; then
            echo "✓ Created hardlink to private key in ~/.ssh"
        else
            # Fallback to copy if hardlink fails (different filesystem)
            echo "Hardlink not possible, copying private key to ~/.ssh"
            cp "$NEW_KEY_PATH" "$SSH_KEY_LINK"
            chmod 600 "$SSH_KEY_LINK"
        fi
    else
        echo "✓ Private key link in ~/.ssh already exists"
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
fi

# Add to SSH config
echo ""
echo "Step 4: Adding SSH config entry..."
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
    echo "✓ Added SSH config entry for $NODE_NAME"
else
    echo "✓ SSH config entry for $NODE_NAME already exists"
fi

# Step 5: Create node folder and config templates
echo ""
echo "Step 5: Creating node folder and configuration templates..."

mkdir -p "$NODE_DIR"

# Create or update node.conf template
if [[ ! -f "$NODE_CONF" ]]; then
    cat > "$NODE_CONF" <<EOF
NODE_NAME=$NODE_NAME
NODE_IPs=$NODE_IP

# podman dualstack
NETWORK_IP4_CIDR=
NETWORK_IP6_CIDR=

APPS=syncthing # ,nebula,awg

# Sync config
SYNCTHING_API_URL=
SYNCTHING_API_KEY=
SYNCTHING_DEVICE_ID=
SYNCTHING_FOLDER_ID=
SYNCTHING_TARGET_DEVICE_ID=
EOF
    echo "✓ Created node configuration: $NODE_CONF"
else
    # Update IP if different
    if ! grep -q "NODE_IPs=$NODE_IP" "$NODE_CONF"; then
        sed -i "s|^NODE_IPs=.*|NODE_IPs=$NODE_IP|" "$NODE_CONF"
        echo "✓ Updated NODE_IPs in existing config"
    fi
    echo "✓ Node configuration already exists: $NODE_CONF"
fi

# Step 6: Create Syncthing sync folder
echo ""
echo "Step 6: Creating Syncthing sync folder..."

# Load Syncthing API configuration from creds/node.conf
ROOT_NODE_CONF="$REPO_ROOT/creds/node.conf"
if [[ -f "$ROOT_NODE_CONF" ]]; then
    # Read only specific variables to avoid overwriting others
    SYNCTHING_API_URL=$(get_value "$ROOT_NODE_CONF" "SYNCTHING_API_URL")
    SYNCTHING_API_KEY=$(get_value "$ROOT_NODE_CONF" "SYNCTHING_API_KEY")
fi

SYNCTHING_API_URL="${SYNCTHING_API_URL:-http://localhost:8384}"
SYNCTHING_API_KEY="${SYNCTHING_API_KEY:-}"

if [[ -z "$SYNCTHING_API_KEY" ]]; then
    echo "Note: SYNCTHING_API_URL and SYNCTHING_API_KEY should be configured in creds/node.conf"
    echo "Skipping Syncthing folder creation (no API key configured)"
else
    FOLDER_LABEL="setup-node-$NODE_NAME"
    FOLDER_PATH="$NODES_DIR/$NODE_NAME"
    
    FOLDER_ID=""
    
    # First, check if folder ID from config exists in Syncthing (direct check)
    CONFIG_FOLDER_ID=$(get_value "$NODE_CONF" "SYNCTHING_FOLDER_ID")
    if [[ -n "$CONFIG_FOLDER_ID" ]]; then
        # Check if this ID exists in Syncthing by direct GET request
        FOLDER_CHECK=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X GET -H "X-API-Key: $SYNCTHING_API_KEY" "$SYNCTHING_API_URL/rest/config/folders/$CONFIG_FOLDER_ID" 2>/dev/null)
        HTTP_CODE=$(echo "$FOLDER_CHECK" | grep "HTTP_CODE:" | cut -d: -f2)
        FOLDER_CHECK_BODY=$(echo "$FOLDER_CHECK" | grep -v "HTTP_CODE:")
        
        # Check if folder exists (HTTP 200 and not an error message)
        if [[ "$HTTP_CODE" == "200" ]] && [[ -n "$FOLDER_CHECK_BODY" ]] && ! echo "$FOLDER_CHECK_BODY" | grep -qi "no folder\|not found\|error"; then
            FOLDER_ID="$CONFIG_FOLDER_ID"
        fi
    fi
    
    # If not found by ID, check by label
    if [[ -z "$FOLDER_ID" ]]; then
        if command -v jq >/dev/null 2>&1; then
            EXISTING_FOLDERS=$(curl -s -X GET -H "X-API-Key: $SYNCTHING_API_KEY" "$SYNCTHING_API_URL/rest/config/folders" 2>/dev/null || echo "{}")
            FOLDER_ID=$(echo "$EXISTING_FOLDERS" | jq -r "to_entries[] | select(.value.label == \"$FOLDER_LABEL\") | .value.id" | head -1)
        else
            echo "Error: jq is required for Syncthing folder detection. Please install 'jq' and rerun this script."
            exit 1
        fi
    fi
    
    if [[ -n "$FOLDER_ID" ]]; then
        echo "✓ Syncthing folder already exists (Label: $FOLDER_LABEL, ID: $FOLDER_ID)"
        # Update node.conf with folder ID
        set_value "$NODE_CONF" "SYNCTHING_FOLDER_ID" "$FOLDER_ID"
        
        # Read SYNCTHING_DEVICE_ID from creds/node.conf and set as SYNCTHING_TARGET_DEVICE_ID
        HOST_DEVICE_ID=$(get_value "$ROOT_NODE_CONF" "SYNCTHING_DEVICE_ID")
        if [[ -n "$HOST_DEVICE_ID" ]]; then
            set_value "$NODE_CONF" "SYNCTHING_TARGET_DEVICE_ID" "$HOST_DEVICE_ID"
        else
            echo "Note: SYNCTHING_DEVICE_ID is not configured in creds/node.conf, skipping SYNCTHING_TARGET_DEVICE_ID"
        fi
    else
        # Generate folder ID from folder path (deterministic)
        # Use SHA256 hash of the path, truncated to 8 characters
        FOLDER_ID=$(echo -n "$FOLDER_LABEL" | sha256sum | cut -c1-8 | tr '[:lower:]' '[:upper:]')
        
        # Create folder configuration with generated ID
        FOLDER_CONFIG=$(cat <<EOF
{
    "id": "$FOLDER_ID",
    "label": "$FOLDER_LABEL",
    "path": "$FOLDER_PATH",
    "ignorePerms": true,
    "minDiskFree": {
        "value": 100,
        "unit": "MB"
    },
    "type": "sendreceive"
}
EOF
)
        # Create folder via PUT (Syncthing requires ID to be provided)
        echo "Creating Syncthing folder: $FOLDER_LABEL"
        echo "API URL: $SYNCTHING_API_URL"
        echo "Folder path: $FOLDER_PATH"
        echo "Folder ID: $FOLDER_ID"
        
        CREATE_RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X PUT -H "X-API-Key: $SYNCTHING_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$FOLDER_CONFIG" \
            "$SYNCTHING_API_URL/rest/config/folders/$FOLDER_ID" 2>&1)
        
        HTTP_CODE=$(echo "$CREATE_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
        CREATE_RESPONSE_BODY=$(echo "$CREATE_RESPONSE" | grep -v "HTTP_CODE:")
        
        if [[ "$HTTP_CODE" == "200" ]] || [[ "$HTTP_CODE" == "201" ]]; then
            echo "✓ Syncthing folder created successfully (Label: $FOLDER_LABEL, ID: $FOLDER_ID)"
            
            # Update node.conf with folder ID
            set_value "$NODE_CONF" "SYNCTHING_FOLDER_ID" "$FOLDER_ID"
            
            # Read SYNCTHING_DEVICE_ID from creds/node.conf and set as SYNCTHING_TARGET_DEVICE_ID
            TARGET_DEVICE_ID=$(get_value "$ROOT_NODE_CONF" "SYNCTHING_DEVICE_ID")
            if [[ -n "$TARGET_DEVICE_ID" ]]; then
                set_value "$NODE_CONF" "SYNCTHING_TARGET_DEVICE_ID" "$TARGET_DEVICE_ID"
            fi
            
        else
            echo "Error: Failed to create Syncthing folder via API"
            echo "HTTP Code: ${HTTP_CODE:-unknown}"
            echo "Response: $CREATE_RESPONSE_BODY"
        fi
    fi
fi

echo ""
echo "=== Node '$NODE_NAME' setup completed ==="
echo "Configuration: $NODE_CONF"
echo "SSH config: Use 'ssh $NODE_NAME' to connect"
echo ""
echo "Next steps:"
echo "1. Edit $NODE_CONF to configure network CIDRs and apps"
echo "2. Run: infra/setup-node.sh $NODE_NAME"
