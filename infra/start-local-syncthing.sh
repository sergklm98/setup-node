#!/bin/bash
# This script starts a local Syncthing container using Docker or Podman for managing node configurations via the Syncthing REST API.
# The script is idempotent - it will skip steps that are already completed.
#
# Steps:
# 1. Detect if Docker or Podman is installed (fail if neither is available).
# 2. Load Syncthing API configuration from creds/node.conf (SYNCTHING_API_URL and SYNCTHING_API_KEY).
# 3. Create persistent mount directories for Syncthing configuration and default folder location in creds/mounts/syncthing.
# 4. Start Syncthing container with:
#    - Mount of the entire setup-node repository at the same path as on host (for path consistency)
#    - Persistent configuration and default folder location from creds/mounts/syncthing
#    - Exposed ports: 8384 (web/API) and 22000/UDP (QUIC sync protocol)
#    Note: TCP port not needed for relay (uses outbound connections) or QUIC-only mode
# 5. Wait for Syncthing to initialize and verify it's accessible via API.
# 6. If API key is not configured, extract it from the container and update creds/node.conf.
# 7. If Device ID is not configured, extract it from the container and update creds/node.conf.



set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NODE_CONF="$REPO_ROOT/creds/node.conf"
SYNCTHING_MOUNT_DIR="$REPO_ROOT/creds/mounts/syncthing"
CONTAINER_NAME="setup-node-syncthing"

# Step 1: Detect Docker or Podman
echo "=== Starting Local Syncthing ==="
echo ""

if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
    echo "✓ Using Podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
    echo "✓ Using Docker"
else
    echo "Error: Neither Docker nor Podman is installed"
    echo "Please install Docker (https://docs.docker.com/get-docker/) or Podman (https://podman.io/getting-started/installation)"
    exit 1
fi

# Step 2: Load Syncthing API configuration
echo ""
echo "Step 2: Loading Syncthing API configuration..."

if [[ -f "$NODE_CONF" ]]; then
    source "$NODE_CONF"
fi

SYNCTHING_API_URL="${SYNCTHING_API_URL:-http://localhost:8384}"
SYNCTHING_API_KEY="${SYNCTHING_API_KEY:-}"

echo "API URL: $SYNCTHING_API_URL"
if [[ -n "$SYNCTHING_API_KEY" ]]; then
    echo "API Key: [configured]"
else
    echo "API Key: [not configured - will be extracted from container]"
fi

# Step 3: Create persistent mount directories
echo ""
echo "Step 3: Setting up persistent mount directories..."

mkdir -p "$SYNCTHING_MOUNT_DIR/config"
mkdir -p "$SYNCTHING_MOUNT_DIR/data"

# Set proper permissions for Syncthing
# With --userns=keep-id, container runs as current user, so ensure directories are writable
chmod 755 "$SYNCTHING_MOUNT_DIR/config"
chmod 755 "$SYNCTHING_MOUNT_DIR/data"

echo "✓ Mount directories created: $SYNCTHING_MOUNT_DIR"

# Step 4: Start Syncthing container
echo ""
echo "Step 4: Starting Syncthing container..."

# Check if container already exists
if $CONTAINER_CMD ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    # Container exists, check if running
    if $CONTAINER_CMD ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        echo "✓ Syncthing container is already running"
    else
        echo "Starting existing Syncthing container..."
        $CONTAINER_CMD start "$CONTAINER_NAME"
        echo "✓ Syncthing container started"
    fi
else
    # Create new container
    echo "Creating new Syncthing container..."
    
    # Build container run command with appropriate user namespace options
    CONTAINER_RUN_CMD="$CONTAINER_CMD run -d"
    
    $CONTAINER_RUN_CMD \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p 8384:8384 \
        -p 22000:22000/udp \
        -v "$REPO_ROOT:$REPO_ROOT" \
        -v "$SYNCTHING_MOUNT_DIR/config:/var/syncthing/config" \
        -v "$SYNCTHING_MOUNT_DIR/data:/var/syncthing/data" \
        docker.io/syncthing/syncthing:latest \
        --gui-address=0.0.0.0:8384 \
        --no-browser \
        --no-restart \
        --home=/var/syncthing/config
    
    echo "✓ Syncthing container created and started"
fi

# Step 5: Wait for Syncthing to initialize
echo ""
echo "Step 5: Waiting for Syncthing to initialize..."

MAX_WAIT=60
WAIT_COUNT=0
while [[ $WAIT_COUNT -lt $MAX_WAIT ]]; do
    # Check if Syncthing is responding (any HTTP response, including CSRF errors, means it's up)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$SYNCTHING_API_URL" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" =~ ^[234] ]] || [[ "$HTTP_CODE" != "000" ]]; then
        # Any 2xx, 3xx, or 4xx response means Syncthing is running (4xx includes CSRF errors)
        echo "✓ Syncthing is accessible"
        break
    fi
    echo -n "."
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [[ $WAIT_COUNT -ge $MAX_WAIT ]]; then
    echo ""
    echo "Warning: Syncthing did not become accessible within $MAX_WAIT seconds"
    echo "Container logs:"
    $CONTAINER_CMD logs --tail 20 "$CONTAINER_NAME"
    exit 1
fi

# Step 6: Extract API key if not configured
echo ""
if [[ -z "$SYNCTHING_API_KEY" ]]; then
    echo "Step 6: Extracting API key from Syncthing configuration..."
    
    # Wait for config.xml to be created and contain API key
    CONFIG_XML="$SYNCTHING_MOUNT_DIR/config/config.xml"
    MAX_CONFIG_WAIT=30
    CONFIG_WAIT_COUNT=0
    EXTRACTED_KEY=""
    
    while [[ $CONFIG_WAIT_COUNT -lt $MAX_CONFIG_WAIT ]]; do
        if [[ -f "$CONFIG_XML" ]]; then
            # Extract API key from config.xml (between <apikey> tags)
            # Use sed for portability (works on Alpine/BusyBox)
            EXTRACTED_KEY=$(sed -n 's/.*<apikey>\([^<]*\)<\/apikey>.*/\1/p' "$CONFIG_XML" | head -1 || echo "")
            if [[ -n "$EXTRACTED_KEY" ]]; then
                break
            fi
        fi
        echo -n "."
        sleep 1
        CONFIG_WAIT_COUNT=$((CONFIG_WAIT_COUNT + 1))
    done
    
    if [[ -n "$EXTRACTED_KEY" ]]; then
        SYNCTHING_API_KEY="$EXTRACTED_KEY"
        echo ""
        echo "✓ API key extracted from configuration"
        
        # Update node.conf with the API key
        if grep -q "SYNCTHING_API_KEY=" "$NODE_CONF"; then
            sed -i "s|^SYNCTHING_API_KEY=.*|SYNCTHING_API_KEY=$SYNCTHING_API_KEY|" "$NODE_CONF"
        else
            echo "SYNCTHING_API_KEY=$SYNCTHING_API_KEY" >> "$NODE_CONF"
        fi
            echo "✓ API key saved to $NODE_CONF"
        else
            echo ""
            echo "Warning: Could not extract API key from config.xml within $MAX_CONFIG_WAIT seconds"
            if [[ -f "$CONFIG_XML" ]]; then
                echo "Config file exists but API key not found. You may need to set it manually in $NODE_CONF"
            else
                echo "Config file not found at $CONFIG_XML. You may need to set the API key manually in $NODE_CONF"
            fi
        fi
    else
        echo "Step 6: API key already configured, skipping extraction"
    fi
    
    # Test API key if available and extract device ID
    if [[ -n "$SYNCTHING_API_KEY" ]]; then
        echo ""
        echo "Testing API key..."
        if curl -s -f -H "X-API-Key: $SYNCTHING_API_KEY" "$SYNCTHING_API_URL/rest/system/status" >/dev/null 2>&1; then
            echo "✓ API key is valid and working"
            
            # Extract device ID from Syncthing system status
            echo "Extracting device ID..."
            DEVICE_ID=$(curl -s -H "X-API-Key: $SYNCTHING_API_KEY" "$SYNCTHING_API_URL/rest/system/status" 2>/dev/null | jq -r '.myID // empty' 2>/dev/null)
            
            if [[ -n "$DEVICE_ID" ]] && [[ "$DEVICE_ID" != "null" ]]; then
                echo "✓ Device ID extracted: $DEVICE_ID"
                
                # Update node.conf with device ID
                if grep -q "SYNCTHING_DEVICE_ID=" "$NODE_CONF"; then
                    sed -i "s|^SYNCTHING_DEVICE_ID=.*|SYNCTHING_DEVICE_ID=$DEVICE_ID|" "$NODE_CONF"
                else
                    # Add after SYNCTHING_FOLDER_ID if it exists, otherwise add after SYNCTHING_API_KEY
                    if grep -q "SYNCTHING_FOLDER_ID=" "$NODE_CONF"; then
                        sed -i "/^SYNCTHING_FOLDER_ID=/a SYNCTHING_DEVICE_ID=$DEVICE_ID" "$NODE_CONF"
                    elif grep -q "SYNCTHING_API_KEY=" "$NODE_CONF"; then
                        sed -i "/^SYNCTHING_API_KEY=/a SYNCTHING_DEVICE_ID=$DEVICE_ID" "$NODE_CONF"
                    else
                        echo "SYNCTHING_DEVICE_ID=$DEVICE_ID" >> "$NODE_CONF"
                    fi
                fi
                echo "✓ Device ID saved to $NODE_CONF"
            else
                echo "⚠ Warning: Could not extract device ID from Syncthing API"
                if ! command -v jq >/dev/null 2>&1; then
                    echo "  Note: jq is required for device ID extraction. Please install 'jq' and rerun this script."
                fi
            fi
            
            # Ask user about relay and protocol priority
            if [[ -n "$DEVICE_ID" ]] && [[ "$DEVICE_ID" != "null" ]]; then
                echo ""
                echo "Configure relay and protocol priority:"
                echo "1) Disable relay + prioritize QUIC (for direct connections)"
                echo "2) Enable relay + prioritize relay (for private networks)"
                echo "3) Keep settings as is"
                read -p "Choose option [1-3] (default: 3): " RELAY_OPTION
                RELAY_OPTION="${RELAY_OPTION:-3}"
                
                if [[ "$RELAY_OPTION" == "1" ]]; then
                    echo "Configuring: Disable relay + prioritize QUIC..."
                    
                    # Get current options
                    CURRENT_OPTIONS=$(curl -s -H "X-API-Key: $SYNCTHING_API_KEY" "$SYNCTHING_API_URL/rest/config/options" 2>/dev/null)
                    
                    if [[ -n "$CURRENT_OPTIONS" ]]; then
                        # Update options: disable relay and set QUIC priority
                        UPDATED_OPTIONS=$(echo "$CURRENT_OPTIONS" | jq '
                            .relaysEnabled = false |
                            .connectionPriorityQuicLan = 10 |
                            .connectionPriorityQuicWan = 20 |
                            .connectionPriorityTcpLan = 30 |
                            .connectionPriorityTcpWan = 40 |
                            .connectionPriorityRelay = 50 |
                            .urAccepted = -1
                        ' 2>/dev/null)
                        
                        if [[ -n "$UPDATED_OPTIONS" ]]; then
                            if curl -s -X PUT -H "X-API-Key: $SYNCTHING_API_KEY" \
                                -H "Content-Type: application/json" \
                                -d "$UPDATED_OPTIONS" \
                                "$SYNCTHING_API_URL/rest/config/options" >/dev/null 2>&1; then
                                echo "✓ Relay disabled and QUIC prioritized"
                            else
                                echo "⚠ Warning: Failed to update Syncthing options"
                            fi
                        else
                            echo "⚠ Warning: Failed to prepare options update (jq required)"
                        fi
                    else
                        echo "⚠ Warning: Failed to fetch current options"
                    fi
                elif [[ "$RELAY_OPTION" == "2" ]]; then
                    echo "Configuring: Enable relay + prioritize relay..."
                    
                    # Get current options
                    CURRENT_OPTIONS=$(curl -s -H "X-API-Key: $SYNCTHING_API_KEY" "$SYNCTHING_API_URL/rest/config/options" 2>/dev/null)
                    
                    if [[ -n "$CURRENT_OPTIONS" ]]; then
                        # Update options: enable relay and set relay priority
                        UPDATED_OPTIONS=$(echo "$CURRENT_OPTIONS" | jq '
                            .relaysEnabled = true |
                            .connectionPriorityRelay = 10 |
                            .connectionPriorityTcpLan = 20 |
                            .connectionPriorityTcpWan = 30 |
                            .connectionPriorityQuicLan = 40 |
                            .connectionPriorityQuicWan = 50 |
                            .urAccepted = -1
                        ' 2>/dev/null)
                        
                        if [[ -n "$UPDATED_OPTIONS" ]]; then
                            if curl -s -X PUT -H "X-API-Key: $SYNCTHING_API_KEY" \
                                -H "Content-Type: application/json" \
                                -d "$UPDATED_OPTIONS" \
                                "$SYNCTHING_API_URL/rest/config/options" >/dev/null 2>&1; then
                                echo "✓ Relay enabled and prioritized"
                            else
                                echo "⚠ Warning: Failed to update Syncthing options"
                            fi
                        else
                            echo "⚠ Warning: Failed to prepare options update (jq required)"
                        fi
                    else
                        echo "⚠ Warning: Failed to fetch current options"
                    fi
                else
                    echo "Keeping settings as is"
                fi
                
                # Update default folder settings
                echo ""
                echo "Updating default folder settings..."
                
                # Get current defaults
                CURRENT_DEFAULTS=$(curl -s -H "X-API-Key: $SYNCTHING_API_KEY" "$SYNCTHING_API_URL/rest/config/defaults/folder" 2>/dev/null)
                
                if [[ -n "$CURRENT_DEFAULTS" ]]; then
                    # Update defaults: path, ignorePerms, minDiskFree
                    UPDATED_DEFAULTS=$(echo "$CURRENT_DEFAULTS" | jq '
                        .path = "/var/syncthing/data" |
                        .ignorePerms = true |
                        .minDiskFree.value = 100 |
                        .minDiskFree.unit = "MB"
                    ' 2>/dev/null)
                    
                    if [[ -n "$UPDATED_DEFAULTS" ]]; then
                        if curl -s -X PUT -H "X-API-Key: $SYNCTHING_API_KEY" \
                            -H "Content-Type: application/json" \
                            -d "$UPDATED_DEFAULTS" \
                            "$SYNCTHING_API_URL/rest/config/defaults/folder" >/dev/null 2>&1; then
                            echo "✓ Default folder settings updated:"
                            echo "  - Path: /var/syncthing/data"
                            echo "  - Ignore permissions: enabled"
                            echo "  - Min free disk space: 100 MB"
                        else
                            echo "⚠ Warning: Failed to update default folder settings"
                        fi
                    else
                        echo "⚠ Warning: Failed to prepare defaults update (jq required)"
                    fi
                else
                    echo "⚠ Warning: Failed to fetch current default folder settings"
                fi
            fi
        else
            echo "⚠ Warning: API key test failed. The key may be incorrect or Syncthing may not be fully initialized yet."
            echo "  You can test manually with: curl -H \"X-API-Key: $SYNCTHING_API_KEY\" $SYNCTHING_API_URL/rest/system/status"
        fi
    fi

echo ""
echo "=== Local Syncthing Setup Completed ==="
echo "Container: $CONTAINER_NAME"
echo "Web UI: http://localhost:8384"
echo "API URL: $SYNCTHING_API_URL"
echo "Configuration: $SYNCTHING_MOUNT_DIR/config"
echo "Data directory: $SYNCTHING_MOUNT_DIR/data"
echo ""
echo "To view logs: $CONTAINER_CMD logs -f $CONTAINER_NAME"
echo "To stop: $CONTAINER_CMD stop $CONTAINER_NAME"
echo "To remove: $CONTAINER_CMD rm -f $CONTAINER_NAME"
